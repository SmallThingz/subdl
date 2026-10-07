const std = @import("std");
const common = @import("common.zig");
const cf_shared = @import("opensubtitles_com_cf.zig");

const Allocator = std.mem.Allocator;
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;
const site = "https://subhd.tv";
const download_site = "https://dl.subhd.me";
const prepare_url = site ++ "/api/sub/prepare-download";
const download_api_url = site ++ "/api/sub/down";
pub const download_token_prefix = "subhd-session:";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    release_info: []const u8,
    media_kind: MediaKind,
    season: ?i64,
    episode: ?i64,
    language_code: []const u8,
    subtitle_id: []const u8,
    filename: []const u8,
    detail_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const Detail = struct {
    title: []const u8,
    release_info: []const u8,
    subtitle_id: []const u8,
    filename: []const u8,
    language_code: []const u8,
};

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted_title = std.mem.trim(u8, stripEpisodeTag(trimmed), " \t\r\n");
        const wanted = try common.normalizeTitle(a, wanted_title);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const search_url = try std.fmt.allocPrint(a, "{s}/search/{s}", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, search_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        const items = try parseSearchItems(a, response.body, trimmed);
        return .{ .arena = arena, .items = items };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderRoute(item.detail_url, .detail, item.subtitle_id);
        var language_code = item.language_code;
        var filename = item.filename;
        const detail_response = try common.fetchBytes(self.client, a, item.detail_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .allow_non_ok = true,
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        try requireProviderResponseSuccess(detail_response.status, detail_response.body);
        if (try parseDetail(detail_response.body)) |detail| {
            try validateDetailId(item.subtitle_id, detail.subtitle_id);
            language_code = detail.language_code;
            filename = detail.filename;
        }

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, language_code),
            .filename = try a.dupe(u8, filename),
            .download_url = try makeDownloadToken(a, item.subtitle_id, item.detail_url, filename),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateProviderRoute(parts.detail_url, .detail, parts.subtitle_id);

        var cookies: CookieJar = .empty;
        defer cookies.deinit(allocator);

        const prepare_payload = try std.fmt.allocPrint(allocator, "{{\"sid\":\"{s}\"}}", .{parts.subtitle_id});
        defer allocator.free(prepare_payload);
        try validateProviderRoute(prepare_url, .prepare, null);
        var prepared = try fetchRaw(self.client, allocator, .POST, prepare_url, prepare_payload, &cookies, parts.detail_url, "application/json", deadline_ms);
        defer prepared.deinit(allocator);
        try requireProviderResponseSuccess(prepared.status, prepared.body);
        const temporary_path = try parseJsonStringField(allocator, prepared.body, "url");
        defer allocator.free(temporary_path);
        const temporary_url = try common.resolveUrl(allocator, site, temporary_path);
        defer allocator.free(temporary_url);
        try validateProviderRoute(temporary_url, .temporary, null);

        var temporary = try fetchRaw(self.client, allocator, .GET, temporary_url, null, &cookies, parts.detail_url, null, deadline_ms);
        defer temporary.deinit(allocator);
        try requireProviderResponseSuccess(temporary.status, temporary.body);
        const down_payload = try std.fmt.allocPrint(allocator, "{{\"sid\":\"{s}\"}}", .{parts.subtitle_id});
        defer allocator.free(down_payload);
        try validateProviderRoute(download_api_url, .download_api, null);
        var down = try fetchRaw(self.client, allocator, .POST, download_api_url, down_payload, &cookies, temporary_url, "application/json", deadline_ms);
        defer down.deinit(allocator);
        try requireProviderResponseSuccess(down.status, down.body);

        const pass = try parseJsonBoolField(allocator, down.body, "pass");
        if (!pass) return error.ProviderAccessBlocked;
        const final_url = try parseJsonStringField(allocator, down.body, "url");
        defer allocator.free(final_url);
        try validateFinalDownloadUrl(final_url);

        return common.fetchBytes(self.client, allocator, final_url, .{
            .accept = "application/octet-stream,text/plain,application/zip,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
            .deadline_ms = deadline_ms,
        });
    }
};

fn parseSearchItems(allocator: Allocator, body: []const u8, query: []const u8) ![]const SearchItem {
    const wanted_title = std.mem.trim(u8, stripEpisodeTag(query), " \t\r\n");
    const wanted = try common.normalizeTitle(allocator, wanted_title);
    if (wanted.len == 0) return &.{};
    const requested_episode = common.parseSeasonEpisode(query);

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    const card_marker = "<div class=\"bg-white shadow-sm rounded-3 mb-4\">";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, card_marker)) |start| {
        const next = std.mem.indexOfPos(u8, body, start + card_marker.len, card_marker) orelse body.len;
        const card = body[start..next];
        cursor = next;

        const subtitle_id = detailIdFromCard(card) orelse continue;
        if (seen.contains(subtitle_id)) continue;

        const release_info = anchorTextAfter(card, "view-text text-secondary") orelse continue;
        const poster_alt = attributeAfter(card, "<img", "alt");
        const result_title = if (poster_alt) |alt|
            asciiTitleSuffix(alt)
        else
            wanted_title;
        const normalized_title = try common.normalizeTitle(allocator, result_title);
        if (normalized_title.len == 0) continue;
        if (!normalizedTitlesRelated(normalized_title, wanted)) continue;

        const release_episode = common.parseSeasonEpisode(release_info);
        const season = release_episode.season orelse requested_episode.season;
        const episode = release_episode.episode orelse requested_episode.episode;
        const media_kind: MediaKind = if (episode != null) .tv else .movie;
        const extension = searchCardExtension(card);
        const detail_url = try std.fmt.allocPrint(allocator, "{s}/a/{s}", .{ site, subtitle_id });
        const item: SearchItem = .{
            .title = try allocator.dupe(u8, result_title),
            .release_info = try allocator.dupe(u8, std.mem.trim(u8, release_info, " \t\r\n")),
            .media_kind = media_kind,
            .season = season,
            .episode = episode,
            .language_code = try allocator.dupe(u8, preferredLanguageCode(card)),
            .subtitle_id = try allocator.dupe(u8, subtitle_id),
            .filename = try std.fmt.allocPrint(allocator, "subhd-{s}.{s}", .{ subtitle_id, extension }),
            .detail_url = detail_url,
        };

        try seen.put(allocator, item.subtitle_id, {});
        const exact_title = std.mem.eql(u8, normalized_title, wanted);
        const exact_episode = requested_episode.episode == null or
            (episode != null and episode.? == requested_episode.episode.? and
                (requested_episode.season == null or season == requested_episode.season));
        if (exact_title and exact_episode)
            try exact.append(allocator, item)
        else
            try partial.append(allocator, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(allocator, exact.items);
    try items.appendSlice(allocator, partial.items);
    return items.toOwnedSlice(allocator);
}

fn normalizedTitlesRelated(lhs: []const u8, rhs: []const u8) bool {
    return containsNormalizedPhrase(lhs, rhs) or containsNormalizedPhrase(rhs, lhs);
}

fn containsNormalizedPhrase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len == 0 or needle.len == 0 or needle.len > haystack.len) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        const end = index + needle.len;
        const starts_at_boundary = index == 0 or haystack[index - 1] == ' ';
        const ends_at_boundary = end == haystack.len or haystack[end] == ' ';
        if (starts_at_boundary and ends_at_boundary) return true;
        start = index + 1;
    }
    return false;
}

fn detailIdFromCard(card: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (nextHtmlTag(card, &cursor)) |tag| {
        const href = tagAttributeValue(tag, "href") orelse continue;
        if (!std.mem.startsWith(u8, href, "/a/")) continue;
        const subtitle_id = href["/a/".len..];
        if (!isSubtitleId(subtitle_id)) continue;
        return subtitle_id;
    }
    return null;
}

fn downloadSidFromDetail(body: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (nextHtmlTag(body, &cursor)) |tag| {
        const classes = tagAttributeValue(tag, "class") orelse continue;
        if (!hasHtmlClass(classes, "subtitle-prepare-download")) continue;
        const subtitle_id = tagAttributeValue(tag, "data-sid") orelse continue;
        if (!isSubtitleId(subtitle_id)) continue;
        return subtitle_id;
    }
    return null;
}

fn nextHtmlTag(body: []const u8, cursor: *usize) ?[]const u8 {
    var search = cursor.*;
    while (std.mem.indexOfScalarPos(u8, body, search, '<')) |start| {
        if (std.mem.startsWith(u8, body[start..], "<!--")) {
            const comment_end = std.mem.indexOfPos(u8, body, start + "<!--".len, "-->") orelse {
                cursor.* = body.len;
                return null;
            };
            search = comment_end + "-->".len;
            continue;
        }

        var index = start + 1;
        var quote: ?u8 = null;
        while (index < body.len) : (index += 1) {
            const c = body[index];
            if (quote) |active_quote| {
                if (c == active_quote) quote = null;
                continue;
            }
            if (c == '"' or c == '\'') {
                quote = c;
                continue;
            }
            if (c == '<') {
                search = index;
                break;
            }
            if (c == '>') {
                cursor.* = index + 1;
                return body[start .. index + 1];
            }
        }
        if (index == body.len) {
            cursor.* = body.len;
            return null;
        }
    }
    cursor.* = body.len;
    return null;
}

fn tagAttributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    if (tag.len < 3 or tag[0] != '<' or name.len == 0) return null;
    var cursor: usize = 1;
    if (tag[cursor] == '/' or tag[cursor] == '!' or tag[cursor] == '?') return null;

    while (cursor < tag.len and
        !std.ascii.isWhitespace(tag[cursor]) and
        tag[cursor] != '/' and tag[cursor] != '>')
    {
        cursor += 1;
    }

    while (cursor < tag.len) {
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] == '>') return null;
        if (tag[cursor] == '/') {
            cursor += 1;
            continue;
        }

        const attribute_start = cursor;
        while (cursor < tag.len and isHtmlAttributeNameByte(tag[cursor])) : (cursor += 1) {}
        if (cursor == attribute_start) {
            cursor += 1;
            continue;
        }
        const attribute_name = tag[attribute_start..cursor];
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] != '=') {
            if (std.ascii.eqlIgnoreCase(attribute_name, name)) return null;
            continue;
        }

        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len) return null;

        var value_start: usize = undefined;
        var value_end: usize = undefined;
        if (tag[cursor] == '"' or tag[cursor] == '\'') {
            const quote = tag[cursor];
            value_start = cursor + 1;
            value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
            cursor = value_end + 1;
        } else {
            value_start = cursor;
            while (cursor < tag.len and !std.ascii.isWhitespace(tag[cursor]) and tag[cursor] != '>') : (cursor += 1) {
                if (tag[cursor] == '/' and cursor + 1 < tag.len and tag[cursor + 1] == '>') break;
            }
            value_end = cursor;
        }
        if (std.ascii.eqlIgnoreCase(attribute_name, name)) {
            if (value_end == value_start) return null;
            return tag[value_start..value_end];
        }
    }
    return null;
}

fn isHtmlAttributeNameByte(c: u8) bool {
    return !std.ascii.isWhitespace(c) and
        c != '=' and c != '>' and c != '/' and c != '<' and c != '"' and c != '\'';
}

fn hasHtmlClass(value: []const u8, wanted: []const u8) bool {
    var classes = std.mem.tokenizeAny(u8, value, " \t\r\n\x0c");
    while (classes.next()) |class| {
        if (std.mem.eql(u8, class, wanted)) return true;
    }
    return false;
}

fn anchorTextAfter(body: []const u8, marker: []const u8) ?[]const u8 {
    const marker_pos = std.mem.indexOf(u8, body, marker) orelse return null;
    const anchor_pos = std.mem.indexOfPos(u8, body, marker_pos + marker.len, "<a ") orelse return null;
    const open_end = std.mem.indexOfPos(u8, body, anchor_pos, ">") orelse return null;
    const close = std.mem.indexOfPos(u8, body, open_end + 1, "</a>") orelse return null;
    return std.mem.trim(u8, body[open_end + 1 .. close], " \t\r\n");
}

fn asciiTitleSuffix(value: []const u8) []const u8 {
    var last_non_ascii: ?usize = null;
    for (value, 0..) |c, idx| {
        if (c >= 0x80) last_non_ascii = idx;
    }
    const suffix = if (last_non_ascii) |idx| value[idx + 1 ..] else value;
    const trimmed = std.mem.trim(u8, suffix, " \t\r\n-–—/");
    return if (trimmed.len > 0) trimmed else std.mem.trim(u8, value, " \t\r\n");
}

fn searchCardExtension(card: []const u8) []const u8 {
    if (std.mem.indexOf(u8, card, ">ASS<") != null) return "ass";
    if (std.mem.indexOf(u8, card, ">SSA<") != null) return "ssa";
    if (std.mem.indexOf(u8, card, ">VTT<") != null) return "vtt";
    if (std.mem.indexOf(u8, card, ">SUB<") != null) return "sub";
    if (std.mem.indexOf(u8, card, ">ZIP<") != null) return "zip";
    return "srt";
}

fn parseDetail(body: []const u8) !?Detail {
    const sid = downloadSidFromDetail(body) orelse return null;
    const release_raw = betweenAfter(body, "subtitle-edition", ">", "</div>") orelse return null;
    const title_raw = betweenAfter(body, "<b>Title</b>", "：", "<br>") orelse return null;
    const filename = attributeAfter(body, "subtitleFilePreview", "data-filename") orelse
        attributeAfter(body, "subtitle-file", "data-filename") orelse
        findFirstDataFilename(body) orelse "subhd-subtitle.srt";
    const language_code = preferredLanguageCode(body);
    return .{
        .title = std.mem.trim(u8, title_raw, " \t\r\n"),
        .release_info = std.mem.trim(u8, stripTags(release_raw), " \t\r\n"),
        .subtitle_id = sid,
        .filename = filename,
        .language_code = language_code,
    };
}

fn preferredLanguageCode(body: []const u8) []const u8 {
    if (std.mem.indexOf(u8, body, ">英语<") != null) return "en";
    if (std.mem.indexOf(u8, body, ">简体<") != null or
        std.mem.indexOf(u8, body, ">繁体<") != null or
        std.mem.indexOf(u8, body, ">双语<") != null) return "zh";
    if (std.mem.indexOf(u8, body, ">日语<") != null) return "ja";
    if (std.mem.indexOf(u8, body, ">韩语<") != null) return "ko";
    if (std.mem.indexOf(u8, body, ">法语<") != null) return "fr";
    if (std.mem.indexOf(u8, body, ">西班牙语<") != null) return "es";
    if (std.mem.indexOf(u8, body, ">德语<") != null) return "de";
    if (std.mem.indexOf(u8, body, ">俄语<") != null) return "ru";
    return "und";
}

fn attributeAfter(body: []const u8, anchor: []const u8, name: []const u8) ?[]const u8 {
    const anchor_pos = std.mem.indexOf(u8, body, anchor) orelse return null;
    const attr_pos = std.mem.indexOfPos(u8, body, anchor_pos, name) orelse return null;
    const eq_pos = std.mem.indexOfPos(u8, body, attr_pos + name.len, "=") orelse return null;
    if (eq_pos + 1 >= body.len) return null;
    const quote = body[eq_pos + 1];
    if (quote != '"' and quote != '\'') return null;
    const start = eq_pos + 2;
    const end_rel = std.mem.indexOfScalar(u8, body[start..], quote) orelse return null;
    return body[start .. start + end_rel];
}

fn findFirstDataFilename(body: []const u8) ?[]const u8 {
    const marker = "data-filename=\"";
    const pos = std.mem.indexOf(u8, body, marker) orelse return null;
    const start = pos + marker.len;
    const end_rel = std.mem.indexOfScalar(u8, body[start..], '"') orelse return null;
    return body[start .. start + end_rel];
}

fn betweenAfter(body: []const u8, anchor: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const anchor_pos = std.mem.indexOf(u8, body, anchor) orelse return null;
    const open_pos = std.mem.indexOfPos(u8, body, anchor_pos + anchor.len, open) orelse return null;
    const start = open_pos + open.len;
    const end_rel = std.mem.indexOf(u8, body[start..], close) orelse return null;
    return body[start .. start + end_rel];
}

fn stripTags(value: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, value, '<') == null) return value;
    const lt = std.mem.indexOfScalar(u8, value, '<') orelse return value;
    return value[0..lt];
}

fn stripEpisodeTag(value: []const u8) []const u8 {
    const se = common.parseSeasonEpisode(value);
    if (se.episode == null) return value;
    var i: usize = 0;
    while (i + 4 < value.len) : (i += 1) {
        if ((value[i] == 's' or value[i] == 'S') and i > 0) {
            var p = i + 1;
            while (p < value.len and (std.ascii.isDigit(value[p]) or value[p] == 'e' or value[p] == 'E')) : (p += 1) {}
            if (p > i + 3) return std.mem.trimEnd(u8, value[0..i], " \t-._");
        }
    }
    return value;
}

pub fn makeDownloadToken(allocator: Allocator, sid: []const u8, detail_url: []const u8, filename: []const u8) ![]u8 {
    if (!isSubtitleId(sid) or !isSafeFilename(filename)) return error.InvalidDownloadUrl;
    try validateProviderRoute(detail_url, .detail, sid);
    return std.fmt.allocPrint(
        allocator,
        "{s}v1:{d}:{s}{d}:{s}{d}:{s}",
        .{ download_token_prefix, sid.len, sid, detail_url.len, detail_url, filename.len, filename },
    );
}

const DownloadToken = struct {
    subtitle_id: []const u8,
    detail_url: []const u8,
    filename: []const u8,
};

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    if (!std.mem.startsWith(u8, payload, "v1:")) return null;
    var cursor: usize = "v1:".len;
    const subtitle_id = takeTokenField(payload, &cursor) orelse return null;
    const detail_url = takeTokenField(payload, &cursor) orelse return null;
    const filename = takeTokenField(payload, &cursor) orelse return null;
    if (cursor != payload.len or !isSubtitleId(subtitle_id) or !isSafeFilename(filename)) return null;
    validateProviderRoute(detail_url, .detail, subtitle_id) catch return null;
    return .{
        .subtitle_id = subtitle_id,
        .detail_url = detail_url,
        .filename = filename,
    };
}

fn takeTokenField(payload: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= payload.len) return null;
    const length_end_rel = std.mem.indexOfScalar(u8, payload[cursor.*..], ':') orelse return null;
    const length_end = cursor.* + length_end_rel;
    if (length_end == cursor.*) return null;
    const length_text = payload[cursor.*..length_end];
    if (length_text.len > 1 and length_text[0] == '0') return null;
    for (length_text) |c| if (!std.ascii.isDigit(c)) return null;
    const field_len = std.fmt.parseInt(usize, length_text, 10) catch return null;
    const field_start = length_end + 1;
    const field_end = std.math.add(usize, field_start, field_len) catch return null;
    if (field_end > payload.len) return null;
    cursor.* = field_end;
    return payload[field_start..field_end];
}

fn isSubtitleId(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn isSafeFilename(value: []const u8) bool {
    if (value.len == 0 or value.len > 4096) return false;
    for (value) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn validateDetailId(expected: []const u8, actual: []const u8) !void {
    if (!isSubtitleId(actual) or !std.mem.eql(u8, expected, actual)) return error.InvalidDownloadUrl;
}

const RawResponse = struct {
    status: std.http.Status,
    body: []u8,

    fn deinit(self: *@This(), allocator: Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

fn fetchRaw(
    client: *std.http.Client,
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    cookies: *CookieJar,
    referer: ?[]const u8,
    content_type: ?[]const u8,
    deadline_ms: i64,
) !RawResponse {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;

    const FetchTask = struct {
        fn run(
            result: *?RawResponse,
            task_client: *std.http.Client,
            task_allocator: Allocator,
            task_method: std.http.Method,
            task_url: []const u8,
            task_payload: ?[]const u8,
            task_cookies: *CookieJar,
            task_referer: ?[]const u8,
            task_content_type: ?[]const u8,
        ) !void {
            result.* = try fetchRawUnbounded(
                task_client,
                task_allocator,
                task_method,
                task_url,
                task_payload,
                task_cookies,
                task_referer,
                task_content_type,
            );
        }
    };
    const FetchResult = @typeInfo(@TypeOf(FetchTask.run)).@"fn".return_type.?;
    const TimeoutResult = @typeInfo(@TypeOf(std.Io.Timeout.sleep)).@"fn".return_type.?;
    const Selection = union(enum) {
        fetch: FetchResult,
        timeout: TimeoutResult,
    };
    var selection_buffer: [2]Selection = undefined;
    var selection = std.Io.Select(Selection).init(client.io, &selection_buffer);
    var owned_response: ?RawResponse = null;
    defer {
        selection.cancelDiscard();
        if (owned_response) |*response| response.deinit(allocator);
    }

    const remaining_ms: i64 = deadline_ms -| now_ms;
    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(client.io, .{
        .raw = std.Io.Duration.fromMilliseconds(remaining_ms),
        .clock = .awake,
    }) };
    try selection.concurrent(.fetch, FetchTask.run, .{
        &owned_response,
        client,
        allocator,
        method,
        url,
        payload,
        cookies,
        referer,
        content_type,
    });
    try selection.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, client.io });

    switch (try selection.await()) {
        .fetch => |result| {
            try result;
            const response = owned_response orelse return error.MissingHttpResponse;
            owned_response = null;
            return response;
        },
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}

fn fetchRawUnbounded(
    client: *std.http.Client,
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    cookies: *CookieJar,
    referer: ?[]const u8,
    content_type: ?[]const u8,
) !RawResponse {
    try validateProviderEndpoint(url);
    if (referer) |value| try validateProviderEndpoint(value);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);
    const cookie = try cookies.cookieHeaderForUrl(allocator, normalized, common.compatUnixTimestamp());
    defer if (cookie) |value| allocator.free(value);

    var extra_storage: [3]std.http.Header = undefined;
    var count: usize = 0;
    if (cookie) |value| {
        extra_storage[count] = .{ .name = "cookie", .value = value };
        count += 1;
    }
    if (referer) |value| {
        extra_storage[count] = .{ .name = "referer", .value = value };
        count += 1;
    }
    extra_storage[count] = .{ .name = "accept", .value = "application/json,text/html,*/*" };
    count += 1;
    try common.validateHttpHeaders(extra_storage[0..count]);
    if (content_type) |value| if (!common.validHttpHeaderValue(value)) return error.InvalidHttpHeader;

    var public_client: std.http.Client = undefined;
    try common.initPublicOriginClient(client, &public_client);
    defer public_client.deinit();
    const pinned_connection = try common.connectPinnedPublicHttpUrl(&public_client, allocator, normalized);
    pinned_connection.closing = true;

    var req = public_client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .handle_continue = false,
        .keep_alive = false,
        .connection = pinned_connection,
        .headers = .{
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
            .content_type = if (content_type) |value| .{ .override = value } else .default,
        },
        .extra_headers = extra_storage[0..count],
    }) catch |err| {
        public_client.connection_pool.release(pinned_connection, public_client.io);
        return err;
    };
    defer req.deinit();
    errdefer if (req.connection) |connection| {
        connection.closing = true;
    };
    if (payload) |body_const| {
        const body = try allocator.dupe(u8, body_const);
        defer allocator.free(body);
        req.sendBodyComplete(body) catch |err| return common.normalizeRequestWriteError(&req, err);
    } else req.sendBodiless() catch |err| return common.normalizeRequestWriteError(&req, err);

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    var interim_count: usize = 0;
    while (response.head.status.class() == .informational) {
        if (response.head.status == .switching_protocols) return error.UnsupportedProtocolUpgrade;
        try validateRawApiResponseHead(response.head);
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    try validateRawApiResponseHead(response.head);
    try cookies.updateFromResponseHeaders(
        allocator,
        normalized,
        response.head.bytes,
        common.compatUnixTimestamp(),
    );

    const body = try common.readStrictResponseBody(&req, &response, allocator, max_raw_response_bytes);
    errdefer allocator.free(body);

    return .{
        .status = response.head.status,
        .body = body,
    };
}

fn validateRawApiResponseHead(head: std.http.Client.Response.Head) !void {
    try common.validateResponseFraming(head);
}

fn readRawBody(allocator: Allocator, reader: *std.Io.Reader, max_bytes: usize) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var received: usize = 0;
    while (true) {
        if (received == max_bytes) {
            _ = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            return error.ResponseTooLarge;
        }
        const count = reader.stream(&writer.writer, .limited(max_bytes - received)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return common.normalizeAllocatingWriterError(err),
        };
        received += count;
    }
    var body = writer.toArrayList();
    errdefer body.deinit(allocator);
    return body.toOwnedSlice(allocator);
}

fn validateProviderEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

const ProviderRoute = enum { detail, prepare, temporary, download_api };

fn validateProviderRoute(url: []const u8, route: ProviderRoute, expected_sid: ?[]const u8) !void {
    try validateProviderEndpoint(url);
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.query != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (std.mem.indexOfScalar(u8, path, '\\') != null or
        std.ascii.findIgnoreCase(path, "%2f") != null or
        std.ascii.findIgnoreCase(path, "%5c") != null or
        std.ascii.findIgnoreCase(path, "%2e") != null)
    {
        return error.UnsafeHttpTarget;
    }

    const valid = switch (route) {
        .detail => blk: {
            const prefix = "/a/";
            if (!std.mem.startsWith(u8, path, prefix)) break :blk false;
            const sid = path[prefix.len..];
            if (!isSubtitleId(sid)) break :blk false;
            if (expected_sid) |expected| {
                if (!std.mem.eql(u8, sid, expected)) break :blk false;
            }
            break :blk true;
        },
        .prepare => std.mem.eql(u8, path, "/api/sub/prepare-download"),
        .temporary => blk: {
            const prefix = "/down/";
            if (!std.mem.startsWith(u8, path, prefix)) break :blk false;
            break :blk isSafeTemporarySegment(path[prefix.len..]);
        },
        .download_api => std.mem.eql(u8, path, "/api/sub/down"),
    };
    if (!valid) return error.UnsafeHttpTarget;
}

fn isSafeTemporarySegment(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024 or
        std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, ".."))
    {
        return false;
    }
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}

fn validateFinalDownloadUrl(url: []const u8) !void {
    // SubHD's evidenced CDN form is https://dl.subhd.me/...; keep the final
    // provider-controlled handoff encrypted instead of accepting a downgrade.
    try common.validateFetchTarget(url, .{
        .require_public_origin = true,
        .require_https = true,
    });
    if (!(try common.sameOrigin(download_site, url))) return error.UnsafeHttpTarget;
}

const CookieRequestTarget = struct {
    secure: bool,
    host: []const u8,
    path: []const u8,
};

const ProviderCookie = struct {
    name: []u8,
    value: []u8,
    domain: []u8,
    path: []u8,
    secure: bool,
    host_only: bool,
    expires_unix_seconds: ?i64,

    fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        allocator.free(self.domain);
        allocator.free(self.path);
    }
};

const ParsedProviderCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    secure: bool,
    host_only: bool,
    expires_unix_seconds: ?i64,
};

const CookieJar = struct {
    const empty: @This() = .{};

    cookies: std.ArrayListUnmanaged(ProviderCookie) = .empty,

    fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.cookies.items) |cookie| cookie.deinit(allocator);
        self.cookies.deinit(allocator);
        self.* = .empty;
    }

    fn updateFromResponseHeaders(
        self: *@This(),
        allocator: Allocator,
        request_url: []const u8,
        headers: []const u8,
        now: i64,
    ) !void {
        const target = parseCookieRequestTarget(request_url) orelse return error.InvalidDownloadUrl;
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(header_name, "set-cookie")) continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            const parsed = parseProviderSetCookie(value, target, now) orelse continue;
            try self.apply(allocator, parsed, now);
        }
    }

    fn apply(self: *@This(), allocator: Allocator, parsed: ParsedProviderCookie, now: i64) !void {
        var existing: ?usize = null;
        for (self.cookies.items, 0..) |cookie, index| {
            if (!std.mem.eql(u8, cookie.name, parsed.name)) continue;
            if (!std.ascii.eqlIgnoreCase(cookie.domain, parsed.domain)) continue;
            if (!std.mem.eql(u8, cookie.path, parsed.path)) continue;
            existing = index;
            break;
        }

        const expired = if (parsed.expires_unix_seconds) |expires| expires <= now else false;
        if (expired) {
            if (existing) |index| {
                self.cookies.items[index].deinit(allocator);
                _ = self.cookies.orderedRemove(index);
            }
            return;
        }

        var owned: ProviderCookie = .{
            .name = try allocator.dupe(u8, parsed.name),
            .value = undefined,
            .domain = undefined,
            .path = undefined,
            .secure = parsed.secure,
            .host_only = parsed.host_only,
            .expires_unix_seconds = parsed.expires_unix_seconds,
        };
        errdefer allocator.free(owned.name);
        owned.value = try allocator.dupe(u8, parsed.value);
        errdefer allocator.free(owned.value);
        owned.domain = try allocator.dupe(u8, parsed.domain);
        errdefer allocator.free(owned.domain);
        owned.path = try allocator.dupe(u8, parsed.path);
        errdefer allocator.free(owned.path);

        if (existing) |index| {
            self.cookies.items[index].deinit(allocator);
            self.cookies.items[index] = owned;
        } else {
            try self.cookies.append(allocator, owned);
        }
    }

    fn cookieHeaderForUrl(self: *const @This(), allocator: Allocator, url: []const u8, now: i64) !?[]u8 {
        const target = parseCookieRequestTarget(url) orelse return null;
        var selected: std.ArrayListUnmanaged(usize) = .empty;
        defer selected.deinit(allocator);
        for (self.cookies.items, 0..) |cookie, index| {
            if (!providerCookieApplies(cookie, target, now)) continue;
            try selected.append(allocator, index);
            var position = selected.items.len - 1;
            while (position > 0 and self.cookies.items[selected.items[position]].path.len > self.cookies.items[selected.items[position - 1]].path.len) : (position -= 1) {
                std.mem.swap(usize, &selected.items[position], &selected.items[position - 1]);
            }
        }
        if (selected.items.len == 0) return null;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        for (selected.items, 0..) |index, output_index| {
            const cookie = self.cookies.items[index];
            if (output_index != 0) try out.appendSlice(allocator, "; ");
            try out.appendSlice(allocator, cookie.name);
            try out.append(allocator, '=');
            try out.appendSlice(allocator, cookie.value);
        }
        return try out.toOwnedSlice(allocator);
    }
};

fn parseCookieRequestTarget(url: []const u8) ?CookieRequestTarget {
    const uri = std.Uri.parse(url) catch return null;
    if (uri.user != null or uri.password != null) return null;
    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!secure and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    const host_component = uri.host orelse return null;
    const host = switch (host_component) {
        .raw => |bytes| bytes,
        .percent_encoded => |bytes| if (std.mem.indexOfScalar(u8, bytes, '%') == null) bytes else return null,
    };
    if (host.len == 0) return null;
    const path_component = switch (uri.path) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    return .{
        .secure = secure,
        .host = host,
        .path = if (path_component.len == 0) "/" else path_component,
    };
}

fn parseProviderSetCookie(value: []const u8, target: CookieRequestTarget, now: i64) ?ParsedProviderCookie {
    var attributes = std.mem.splitScalar(u8, value, ';');
    const pair = std.mem.trim(u8, attributes.next() orelse return null, " \t");
    const equals = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
    const name = std.mem.trim(u8, pair[0..equals], " \t");
    const cookie_value = std.mem.trim(u8, pair[equals + 1 ..], " \t");
    if (!validCookieName(name) or !validCookieValue(cookie_value)) return null;

    var domain = target.host;
    var host_only = true;
    var path = defaultCookiePath(target.path);
    var secure = false;
    var expires_attribute: ?i64 = null;
    var max_age_attribute: ?i64 = null;
    while (attributes.next()) |raw_attribute| {
        const attribute = std.mem.trim(u8, raw_attribute, " \t");
        if (attribute.len == 0) continue;
        const attribute_equals = std.mem.indexOfScalar(u8, attribute, '=');
        const attribute_name = std.mem.trim(u8, attribute[0 .. attribute_equals orelse attribute.len], " \t");
        const attribute_value = if (attribute_equals) |position|
            std.mem.trim(u8, attribute[position + 1 ..], " \t")
        else
            "";

        if (std.ascii.eqlIgnoreCase(attribute_name, "secure")) {
            secure = true;
        } else if (std.ascii.eqlIgnoreCase(attribute_name, "path")) {
            if (validCookiePath(attribute_value)) path = attribute_value;
        } else if (std.ascii.eqlIgnoreCase(attribute_name, "domain")) {
            const candidate = stripLeadingDots(attribute_value);
            if (candidate.len == 0 or candidate[candidate.len - 1] == '.') return null;
            // Raw requests are confined to this provider's exact host. Refuse
            // foreign and broader Domain attributes instead of storing them.
            if (!std.ascii.eqlIgnoreCase(candidate, target.host)) return null;
            domain = candidate;
            host_only = false;
        } else if (std.ascii.eqlIgnoreCase(attribute_name, "max-age")) {
            if (std.fmt.parseInt(i64, attribute_value, 10) catch null) |parsed| max_age_attribute = parsed;
        } else if (std.ascii.eqlIgnoreCase(attribute_name, "expires")) {
            if (parseCookieDate(attribute_value)) |parsed| expires_attribute = parsed;
        }
    }

    const expires = if (max_age_attribute) |max_age|
        if (max_age <= 0)
            now
        else
            saturatingAddSeconds(now, max_age)
    else
        expires_attribute;
    return .{
        .name = name,
        .value = cookie_value,
        .domain = domain,
        .path = path,
        .secure = secure,
        .host_only = host_only,
        .expires_unix_seconds = expires,
    };
}

fn validCookieName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={} ", byte) != null) return false;
    }
    return true;
}

fn validCookieValue(value: []const u8) bool {
    const content = if (value.len >= 2 and value[0] == '\"' and value[value.len - 1] == '\"')
        value[1 .. value.len - 1]
    else
        value;
    for (content) |byte| {
        if (byte < 0x21 or byte >= 0x7f or byte == '\"' or byte == ',' or byte == ';' or byte == '\\') return false;
    }
    return true;
}

fn validCookiePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f or byte == ';') return false;
    return true;
}

fn defaultCookiePath(request_path: []const u8) []const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return "/";
    const last_slash = std.mem.lastIndexOfScalar(u8, request_path, '/') orelse return "/";
    return if (last_slash == 0) "/" else request_path[0..last_slash];
}

fn providerCookieApplies(cookie: ProviderCookie, target: CookieRequestTarget, now: i64) bool {
    if (cookie.secure and !target.secure) return false;
    if (cookie.expires_unix_seconds) |expires| if (expires <= now) return false;
    if (cookie.host_only) {
        if (!std.ascii.eqlIgnoreCase(cookie.domain, target.host)) return false;
    } else if (!cookieDomainMatches(target.host, cookie.domain)) return false;
    return cookiePathMatches(cookie.path, target.path);
}

fn cookieDomainMatches(host: []const u8, domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len or !std.ascii.endsWithIgnoreCase(host, domain)) return false;
    return host[host.len - domain.len - 1] == '.';
}

fn cookiePathMatches(cookie_path: []const u8, request_path: []const u8) bool {
    if (std.mem.eql(u8, cookie_path, request_path)) return true;
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;
    if (cookie_path[cookie_path.len - 1] == '/') return true;
    return request_path.len > cookie_path.len and request_path[cookie_path.len] == '/';
}

fn stripLeadingDots(value: []const u8) []const u8 {
    var result = value;
    while (result.len > 0 and result[0] == '.') result = result[1..];
    return result;
}

fn saturatingAddSeconds(now: i64, delta: i64) i64 {
    const sum = @as(i128, now) + @as(i128, delta);
    return if (sum > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(sum);
}

const CookieTime = struct { hour: u8, minute: u8, second: u8 };

fn parseCookieDate(value: []const u8) ?i64 {
    var month: ?u8 = null;
    var time: ?CookieTime = null;
    var day: ?u8 = null;
    var year: ?u16 = null;

    var tokens = std.mem.tokenizeAny(u8, value, "\x09 !\"#$%&'()*+,-./;<=>?@[\\]^_`{|}~");
    while (tokens.next()) |token| {
        if (time == null) if (parseCookieTime(token)) |parsed_time| {
            time = parsed_time;
            continue;
        };
        if (day == null) if (parseCookieDay(token)) |parsed_day| {
            day = parsed_day;
            continue;
        };
        if (month == null) if (parseCookieMonth(token)) |parsed_month| {
            month = parsed_month;
            continue;
        };
        if (year == null) if (parseCookieYear(token)) |parsed_year| {
            year = parsed_year;
            continue;
        };
    }
    if (month == null or time == null or day == null or year == null) return null;
    var full_year = year.?;
    if (full_year <= 69) full_year += 2000 else if (full_year <= 99) full_year += 1900;
    if (full_year < 1601) return null;
    if (day.? > daysInCookieMonth(full_year, month.?)) return null;
    if (full_year < 1970) return 0;

    var days: i64 = 0;
    var cursor_year: u16 = 1970;
    while (cursor_year < full_year) : (cursor_year += 1) days += if (isCookieLeapYear(cursor_year)) 366 else 365;
    var cursor_month: u8 = 1;
    while (cursor_month < month.?) : (cursor_month += 1) days += daysInCookieMonth(full_year, cursor_month);
    days += day.? - 1;
    return days * 86400 + @as(i64, time.?.hour) * 3600 + @as(i64, time.?.minute) * 60 + time.?.second;
}

fn leadingCookieDigits(value: []const u8, max_digits: usize) ?struct { value: u16, len: usize } {
    var len: usize = 0;
    while (len < value.len and len < max_digits and std.ascii.isDigit(value[len])) : (len += 1) {}
    if (len == 0 or (len < value.len and std.ascii.isDigit(value[len]))) return null;
    return .{ .value = std.fmt.parseInt(u16, value[0..len], 10) catch return null, .len = len };
}

fn parseCookieDay(value: []const u8) ?u8 {
    const parsed = leadingCookieDigits(value, 2) orelse return null;
    if (parsed.value < 1 or parsed.value > 31) return null;
    return @intCast(parsed.value);
}

fn parseCookieYear(value: []const u8) ?u16 {
    const parsed = leadingCookieDigits(value, 4) orelse return null;
    if (parsed.len < 2) return null;
    return parsed.value;
}

fn parseCookieMonth(value: []const u8) ?u8 {
    if (value.len < 3) return null;
    inline for (.{
        .{ "jan", 1 }, .{ "feb", 2 },  .{ "mar", 3 },  .{ "apr", 4 },
        .{ "may", 5 }, .{ "jun", 6 },  .{ "jul", 7 },  .{ "aug", 8 },
        .{ "sep", 9 }, .{ "oct", 10 }, .{ "nov", 11 }, .{ "dec", 12 },
    }) |entry| if (std.ascii.eqlIgnoreCase(value[0..3], entry[0])) return entry[1];
    return null;
}

fn parseCookieTime(value: []const u8) ?CookieTime {
    const first_colon = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    const second_colon_relative = std.mem.indexOfScalar(u8, value[first_colon + 1 ..], ':') orelse return null;
    const second_colon = first_colon + 1 + second_colon_relative;
    const hour = leadingCookieDigits(value[0..first_colon], 2) orelse return null;
    const minute = leadingCookieDigits(value[first_colon + 1 .. second_colon], 2) orelse return null;
    const second = leadingCookieDigits(value[second_colon + 1 ..], 2) orelse return null;
    if (hour.len != first_colon or minute.len != second_colon - first_colon - 1) return null;
    if (hour.value > 23 or minute.value > 59 or second.value > 59) return null;
    return .{ .hour = @intCast(hour.value), .minute = @intCast(minute.value), .second = @intCast(second.value) };
}

fn isCookieLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInCookieMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isCookieLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn parseJsonStringField(allocator: Allocator, body: []const u8, key: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidFieldType,
    };
    const value = obj.get(key) orelse return error.MissingField;
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidFieldType,
    };
}

fn parseJsonBoolField(allocator: Allocator, body: []const u8, key: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidFieldType,
    };
    const value = obj.get(key) orelse return error.MissingField;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidFieldType,
    };
}

fn isDownloadRateLimit(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "下载频率过高") != null or
        std.mem.indexOf(u8, body, "try again later") != null or
        std.mem.indexOf(u8, body, "too frequent") != null;
}

fn requireProviderResponseSuccess(status: std.http.Status, body: []const u8) !void {
    if (status == .too_many_requests or (status == .forbidden and isDownloadRateLimit(body)))
        return error.RateLimited;
    if (cf_shared.isChallengeBody(body)) return error.CloudflareChallenge;
    if (status == .forbidden or status == .unauthorized) return error.ProviderAccessBlocked;
    if (status != .ok) return error.UnexpectedHttpStatus;
}

test "subhd parses detail and session token" {
    const body =
        "<div class=\"f16 fw-bold mb-2 subtitle-edition\">Chernobyl.S01E01.WEB</div>" ++
        "<span class=\"p-1 fw-bold\">英语</span>" ++
        "<button class=\"btn subtitle-prepare-download\" data-sid=\"abc123\"></button>" ++
        "<div id=\"subtitleFilePreview\" data-filename=\"test.srt\"></div>" ++
        "<b>Title</b>：Chernobyl<br>";
    const detail = (try parseDetail(body)).?;
    try std.testing.expectEqualStrings("Chernobyl", detail.title);
    try std.testing.expectEqualStrings("abc123", detail.subtitle_id);
    try std.testing.expectEqualStrings("en", detail.language_code);
    const se = common.parseSeasonEpisode(detail.release_info);
    try std.testing.expectEqual(@as(?i64, 1), se.season);
    try std.testing.expectEqual(@as(?i64, 1), se.episode);
}

test "subhd detail SID is element-bound and skips malformed controls" {
    const body =
        "<div class=\"f16 fw-bold mb-2 subtitle-edition\">Chernobyl.S01E01.WEB</div>" ++
        "<button class='subtitle-prepare-download'></button>" ++
        "<div data-sid='unrelated'></div>" ++
        "<button class='subtitle-prepare-download' data-sid='bad/id'></button>" ++
        "<button data-sid=\"abc123\" class=\"btn subtitle-prepare-download\"></button>" ++
        "<div id=\"subtitleFilePreview\" data-filename=\"test.srt\"></div>" ++
        "<b>Title</b>：Chernobyl<br>";
    const detail = (try parseDetail(body)).?;
    try std.testing.expectEqualStrings("abc123", detail.subtitle_id);
}

test "subhd download token rejects non-alphanumeric subtitle ids" {
    const valid = try makeDownloadToken(
        std.testing.allocator,
        "abc123",
        "https://subhd.tv/a/abc123",
        "subtitle|release.srt",
    );
    defer std.testing.allocator.free(valid);
    const parsed = parseDownloadToken(valid).?;
    try std.testing.expectEqualStrings("abc123", parsed.subtitle_id);
    try std.testing.expectEqualStrings("subtitle|release.srt", parsed.filename);

    for ([_][]const u8{ "ab\"c", "ab\\c", "ab\x01c", "../abc", "abc/def" }) |sid| {
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            makeDownloadToken(std.testing.allocator, sid, "https://subhd.tv/a/abc123", "subtitle.srt"),
        );
    }
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        makeDownloadToken(std.testing.allocator, "abc123", "https://subhd.tv/a/different", "subtitle.srt"),
    );
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "v1:01:x") == null);
}

test "subhd rejects mismatched detail response ids" {
    try validateDetailId("abc123", "abc123");
    try std.testing.expectError(error.InvalidDownloadUrl, validateDetailId("abc123", "different"));
    try std.testing.expectError(error.InvalidDownloadUrl, validateDetailId("abc123", "bad/id"));
}

test "subhd valid duplicate is not shadowed by an unusable card" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const marker = "<div class=\"bg-white shadow-sm rounded-3 mb-4\">";
    const fixture = marker ++
        "<a href='/a/abc123'>missing release</a>" ++
        marker ++
        "<a href='/a/abc123'>detail</a><span class='view-text text-secondary'></span>" ++
        "<a href='/release'>The.Matrix.1999.WEB</a>";
    const items = try parseSearchItems(arena.allocator(), fixture, "The Matrix");
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("abc123", items[0].subtitle_id);
}

test "subhd malformed first detail href does not shadow a later candidate" {
    try std.testing.expectEqualStrings(
        "abc123",
        detailIdFromCard(
            "<a href='/a/'>missing</a>" ++
                "<a href='/a/bad/extra'>malformed</a>" ++
                "<a href='/a/abc123'>valid</a>",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "xyz789",
        detailIdFromCard(
            "<a href=\"/a/\">missing</a>" ++
                "<a href=\"/a/xyz789\">valid</a>",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "first123",
        detailIdFromCard(
            "<a title=\"href='/a/shadow999'\" data-href='/a/also999' href=\"/a/first123\">first</a>" ++
                "<a href='/a/second456'>second</a>",
        ).?,
    );
}

test "subhd quoted attributes cannot supply href values" {
    for ([_][]const u8{
        "<a title=\" href='/a/decoy'\" href=\"/a/abc123\">valid</a>",
        "<a title=' href=\"/a/decoy\"' href='/a/abc123'>valid</a>",
    }) |tag| {
        try std.testing.expectEqualStrings("abc123", detailIdFromCard(tag).?);
    }
    try std.testing.expect(detailIdFromCard("<a title=\" href='/a/decoy'\">no link</a>") == null);
}

test "subhd quoted attributes cannot supply download button identity" {
    const tag = "<button title=\" class='subtitle-prepare-download' data-sid='decoy'\" class=\"subtitle-prepare-download\" data-sid=\"abc123\"></button>";
    try std.testing.expectEqualStrings("abc123", downloadSidFromDetail(tag).?);
    try validateDetailId("abc123", downloadSidFromDetail(tag).?);
    try std.testing.expect(downloadSidFromDetail("<button title=\" class='subtitle-prepare-download' data-sid='decoy'\"></button>") == null);
    try std.testing.expect(downloadSidFromDetail("<button class='subtitle-prepare-download' title=\" data-sid='decoy'\"></button>") == null);
}

test "subhd attribute scanner preserves real attribute boundaries" {
    try std.testing.expectEqualStrings(
        "abc123",
        detailIdFromCard("<a disabled data-href='/a/decoy' HREF \t= /a/abc123>valid</a>").?,
    );
    try std.testing.expectEqualStrings(
        "abc123",
        downloadSidFromDetail("<button disabled CLASS = 'btn subtitle-prepare-download' data-sid = abc123>download</button>").?,
    );
    try std.testing.expect(tagAttributeValue("<a title=\" href='/a/decoy'", "href") == null);
    try std.testing.expect(detailIdFromCard("<a title=\" href='/a/decoy'\" href='/a/bad/extra'>bad</a>") == null);
}

test "subhd empty unrelated attributes do not hide real link or SID" {
    try std.testing.expectEqualStrings(
        "abc123",
        detailIdFromCard("<a title='' aria-label=\"\" href='/a/abc123'>valid</a>").?,
    );
    const button = "<button title='' class='subtitle-prepare-download' data-note=\"\" data-sid='abc123'></button>";
    try std.testing.expectEqualStrings("abc123", downloadSidFromDetail(button).?);
    try validateDetailId("abc123", downloadSidFromDetail(button).?);
    // An empty requested attribute still means there is no usable value.
    try std.testing.expect(tagAttributeValue("<a href='' href='/a/abc123'>", "href") == null);
    try std.testing.expect(downloadSidFromDetail("<button class='' title='' data-sid='abc123'></button>") == null);
}

test "subhd title relevance rejects episode-only and partial-word queries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try parseSearchItems(arena.allocator(), "ignored", "S01E01")).len);
    try std.testing.expect(normalizedTitlesRelated("jack reacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("preacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("reacher", ""));
}

test "subhd cookie jar processes every header then rotates and deletes by identity" {
    const allocator = std.testing.allocator;
    const now: i64 = 1_800_000_000;
    var jar: CookieJar = .empty;
    defer jar.deinit(allocator);

    try jar.updateFromResponseHeaders(
        allocator,
        prepare_url,
        "Set-Cookie: unrelated=first; Path=/\r\n" ++
            "Set-Cookie: required=second; Domain=.subhd.tv; Path=/; Secure\r\n" ++
            "Set-Cookie: foreign=ignored; Domain=example.com; Path=/; Secure",
        now,
    );
    const initial = (try jar.cookieHeaderForUrl(allocator, download_api_url, now)).?;
    defer allocator.free(initial);
    try std.testing.expectEqualStrings("unrelated=first; required=second", initial);

    try jar.updateFromResponseHeaders(
        allocator,
        site ++ "/down/ticket",
        "Set-Cookie: required=rotated; Domain=subhd.tv; Path=/; Secure",
        now,
    );
    const rotated = (try jar.cookieHeaderForUrl(allocator, download_api_url, now)).?;
    defer allocator.free(rotated);
    try std.testing.expectEqualStrings("unrelated=first; required=rotated", rotated);

    try jar.updateFromResponseHeaders(
        allocator,
        download_api_url,
        "Set-Cookie: required=deleted; Domain=subhd.tv; Path=/; Max-Age=0; Secure",
        now,
    );
    const after_delete = (try jar.cookieHeaderForUrl(allocator, download_api_url, now)).?;
    defer allocator.free(after_delete);
    try std.testing.expectEqualStrings("unrelated=first", after_delete);
}

test "subhd cookie jar confines path and secure cookies to matching requests" {
    const allocator = std.testing.allocator;
    const now: i64 = 1_800_000_000;
    var jar: CookieJar = .empty;
    defer jar.deinit(allocator);

    try jar.updateFromResponseHeaders(
        allocator,
        site ++ "/down/ticket",
        "Set-Cookie: down_only=explicit; Path=/down; Secure\r\n" ++
            "Set-Cookie: default_down=default; Secure\r\n" ++
            "Set-Cookie: api_only=api; Path=/api/sub; Secure",
        now,
    );
    const temporary = (try jar.cookieHeaderForUrl(allocator, site ++ "/down/next", now)).?;
    defer allocator.free(temporary);
    try std.testing.expectEqualStrings("down_only=explicit; default_down=default", temporary);

    const api = (try jar.cookieHeaderForUrl(allocator, download_api_url, now)).?;
    defer allocator.free(api);
    try std.testing.expectEqualStrings("api_only=api", api);
    try std.testing.expect((try jar.cookieHeaderForUrl(allocator, "http://subhd.tv/down/next", now)) == null);
}

test "live subhd movie and tv search/listing" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subhd.tv")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subs = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subs.deinit();
    try std.testing.expect(movie_subs.subtitles.len > 0);

    var tv = try scraper.search("Chernobyl S01E01");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    const tv_item = for (tv.items) |item| {
        if (item.media_kind == .tv and item.episode == 1) break item;
    } else return error.TestUnexpectedResult;
    var tv_subs = try scraper.fetchSubtitlesBySearchItem(tv_item);
    defer tv_subs.deinit();
    try std.testing.expect(tv_subs.subtitles.len > 0);
}

test "subhd detects explicit download throttle response" {
    try std.testing.expect(isDownloadRateLimit("{\"success\":false,\"msg\":\"下载频率过高，请稍后再试。\"}"));
}

test "subhd rejects unsafe session targets before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("http://127.0.0.1/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://user:pass@subhd.tv/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://www.google.com/private"));

    try validateProviderRoute("https://subhd.tv/a/abc123", .detail, "abc123");
    try validateProviderRoute("https://subhd.tv/down/abc-123", .temporary, null);
    for ([_][]const u8{
        "https://subhd.tv/a/abc123?next=/private",
        "https://subhd.tv/a/abc123#fragment",
        "https://subhd.tv/a/%61bc123",
        "https://subhd.tv/a/abc123/extra",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderRoute(url, .detail, "abc123"));
    }
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        validateProviderRoute("https://subhd.tv/a/different", .detail, "abc123"),
    );
    for ([_][]const u8{
        "https://subhd.tv/down/abc/extra",
        "https://subhd.tv/down/%2fprivate",
        "https://subhd.tv/down/abc?next=/private",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderRoute(url, .temporary, null));
    }
}

test "subhd final CDN handoff requires public HTTPS" {
    try validateFinalDownloadUrl("https://dl.subhd.me/2026/10/example.zip");
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        validateFinalDownloadUrl("http://dl.subhd.me/2026/10/example.zip"),
    );
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        validateFinalDownloadUrl("https://127.0.0.1/example.zip"),
    );
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        validateFinalDownloadUrl("https://cdn.example.org/example.zip"),
    );
}

test "subhd detail and download steps stop on rate limits and access barriers" {
    try std.testing.expectError(error.RateLimited, requireProviderResponseSuccess(.too_many_requests, ""));
    try std.testing.expectError(error.RateLimited, requireProviderResponseSuccess(.too_many_requests, "{\"pass\":true,\"url\":\"https://dl.subhd.me/example.srt\"}"));
    try std.testing.expectError(error.RateLimited, requireProviderResponseSuccess(.forbidden, "下载频率过高，请稍后再试。"));
    try std.testing.expectError(error.ProviderAccessBlocked, requireProviderResponseSuccess(.forbidden, "access denied"));
    try std.testing.expectError(error.ProviderAccessBlocked, requireProviderResponseSuccess(.unauthorized, "login required"));
    try std.testing.expectError(error.CloudflareChallenge, requireProviderResponseSuccess(.ok, "<html><title>Just a moment...</title><script>window._cf_chl_opt = {};</script></html>"));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireProviderResponseSuccess(.found, ""));
    try requireProviderResponseSuccess(.ok, "{\"pass\":true}");
}

test "subhd raw response limit accepts exact bounds and rejects excess" {
    const allocator = std.testing.allocator;
    var exact: std.Io.Reader = .fixed("1234");
    const body = try readRawBody(allocator, &exact, 4);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("1234", body);
    var oversized: std.Io.Reader = .fixed("12345");
    try std.testing.expectError(error.ResponseTooLarge, readRawBody(allocator, &oversized, 4));
    var empty: std.Io.Reader = .fixed("");
    const empty_body = try readRawBody(allocator, &empty, 0);
    defer allocator.free(empty_body);
    try std.testing.expectEqual(@as(usize, 0), empty_body.len);
    var zero_limit: std.Io.Reader = .fixed("1");
    try std.testing.expectError(error.ResponseTooLarge, readRawBody(allocator, &zero_limit, 0));
}

test "subhd raw request rejects an expired deadline before I/O" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var cookies: CookieJar = .empty;
    defer cookies.deinit(std.testing.allocator);
    const now_ms = common.compatMilliTimestamp();
    try std.testing.expectError(
        error.Timeout,
        fetchRaw(
            &client,
            std.testing.allocator,
            .GET,
            site ++ "/",
            null,
            &cookies,
            null,
            null,
            now_ms,
        ),
    );
}

test "subhd raw API transport rejects ambiguous response framing" {
    for ([_][]const u8{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
    }) |raw_head| {
        const head = try std.http.Client.Response.Head.parse(raw_head);
        try std.testing.expectError(error.AmbiguousHttpFraming, validateRawApiResponseHead(head));
    }
}
