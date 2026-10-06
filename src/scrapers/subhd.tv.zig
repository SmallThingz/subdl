const std = @import("std");
const common = @import("common.zig");
const cf_shared = @import("opensubtitles_com_cf.zig");

const Allocator = std.mem.Allocator;
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;
const site = "https://subhd.tv";
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
        const encoded = try common.encodeUriComponent(a, trimmed);
        const search_url = try std.fmt.allocPrint(a, "{s}/search/{s}", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, search_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });

        const items = try parseSearchItems(a, response.body, trimmed);
        return .{ .arena = arena, .items = items };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderEndpoint(item.detail_url);
        var language_code = item.language_code;
        var filename = item.filename;
        const detail_response = try common.fetchBytes(self.client, a, item.detail_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .allow_non_ok = true,
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .require_public_origin = true,
        });
        try requireProviderResponseSuccess(detail_response.status, detail_response.body);
        if (try parseDetail(detail_response.body)) |detail| {
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
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateProviderEndpoint(parts.detail_url);

        const prepare_payload = try std.fmt.allocPrint(allocator, "{{\"sid\":\"{s}\"}}", .{parts.subtitle_id});
        defer allocator.free(prepare_payload);
        var prepared = try fetchRaw(self.client, allocator, .POST, prepare_url, prepare_payload, null, parts.detail_url, "application/json");
        defer prepared.deinit(allocator);
        try requireProviderResponseSuccess(prepared.status, prepared.body);
        const prepare_cookie = prepared.cookie orelse return error.SessionExpired;
        const temporary_path = try parseJsonStringField(allocator, prepared.body, "url");
        defer allocator.free(temporary_path);
        if (!std.mem.startsWith(u8, temporary_path, "/down/")) return error.InvalidDownloadUrl;
        const temporary_url = try common.resolveUrl(allocator, site, temporary_path);
        defer allocator.free(temporary_url);

        var temporary = try fetchRaw(self.client, allocator, .GET, temporary_url, null, prepare_cookie, parts.detail_url, null);
        defer temporary.deinit(allocator);
        try requireProviderResponseSuccess(temporary.status, temporary.body);
        const down_cookie = temporary.cookie orelse return error.SessionExpired;

        const combined_cookie = try std.fmt.allocPrint(allocator, "{s}; {s}", .{ prepare_cookie, down_cookie });
        defer allocator.free(combined_cookie);
        const down_payload = try std.fmt.allocPrint(allocator, "{{\"sid\":\"{s}\"}}", .{parts.subtitle_id});
        defer allocator.free(down_payload);
        var down = try fetchRaw(self.client, allocator, .POST, download_api_url, down_payload, combined_cookie, temporary_url, "application/json");
        defer down.deinit(allocator);
        try requireProviderResponseSuccess(down.status, down.body);

        const pass = try parseJsonBoolField(allocator, down.body, "pass");
        if (!pass) return error.ProviderAccessBlocked;
        const final_url = try parseJsonStringField(allocator, down.body, "url");
        defer allocator.free(final_url);
        if (!std.mem.startsWith(u8, final_url, "https://") and !std.mem.startsWith(u8, final_url, "http://"))
            return error.InvalidDownloadUrl;
        try common.validatePublicHttpUrl(final_url);

        return common.fetchBytes(self.client, allocator, final_url, .{
            .accept = "application/octet-stream,text/plain,application/zip,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });
    }
};

fn parseSearchItems(allocator: Allocator, body: []const u8, query: []const u8) ![]const SearchItem {
    const wanted_title = std.mem.trim(u8, stripEpisodeTag(query), " \t\r\n");
    const wanted = try common.normalizeTitle(allocator, wanted_title);
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
        try seen.put(allocator, try allocator.dupe(u8, subtitle_id), {});

        const release_info = anchorTextAfter(card, "view-text text-secondary") orelse continue;
        const poster_alt = attributeAfter(card, "<img", "alt");
        const result_title = if (poster_alt) |alt|
            asciiTitleSuffix(alt)
        else
            wanted_title;
        const normalized_title = try common.normalizeTitle(allocator, result_title);
        if (normalized_title.len == 0) continue;
        if (std.mem.indexOf(u8, normalized_title, wanted) == null and
            std.mem.indexOf(u8, wanted, normalized_title) == null)
        {
            continue;
        }

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

fn detailIdFromCard(card: []const u8) ?[]const u8 {
    for ([_][]const u8{ "href='/a/", "href=\"/a/" }) |marker| {
        const pos = std.mem.indexOf(u8, card, marker) orelse continue;
        const start = pos + marker.len;
        var end = start;
        while (end < card.len and std.ascii.isAlphanumeric(card[end])) : (end += 1) {}
        if (end > start) return card[start..end];
    }
    return null;
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
    const sid = attributeAfter(body, "subtitle-prepare-download", "data-sid") orelse return null;
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
    return std.fmt.allocPrint(allocator, "{s}{s}|{s}|{s}", .{ download_token_prefix, sid, detail_url, filename });
}

const DownloadToken = struct {
    subtitle_id: []const u8,
    detail_url: []const u8,
    filename: []const u8,
};

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    const a = std.mem.indexOfScalar(u8, payload, '|') orelse return null;
    const rest = payload[a + 1 ..];
    const b_rel = std.mem.indexOfScalar(u8, rest, '|') orelse return null;
    const b = a + 1 + b_rel;
    if (a == 0 or b <= a + 1 or b + 1 >= payload.len) return null;
    return .{
        .subtitle_id = payload[0..a],
        .detail_url = payload[a + 1 .. b],
        .filename = payload[b + 1 ..],
    };
}

const RawResponse = common.RawResponse;

fn fetchRaw(
    client: *std.http.Client,
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    cookie: ?[]const u8,
    referer: ?[]const u8,
    content_type: ?[]const u8,
) !RawResponse {
    try validateProviderEndpoint(url);
    if (referer) |value| try validateProviderEndpoint(value);
    try common.ensureClientTlsReady(client);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

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

    var req = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
            .content_type = if (content_type) |value| .{ .override = value } else .default,
        },
        .extra_headers = extra_storage[0..count],
    });
    defer req.deinit();
    errdefer if (req.connection) |connection| {
        connection.closing = true;
    };
    if (payload) |body_const| {
        const body = try allocator.dupe(u8, body_const);
        defer allocator.free(body);
        try req.sendBodyComplete(body);
    } else try req.sendBodiless();

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = try req.receiveHead(&head_buffer);
    const response_cookie = try extractCookie(allocator, response.head.bytes);
    errdefer if (response_cookie) |value| allocator.free(value);

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = readRawBody(allocator, reader, max_raw_response_bytes) catch |err| {
        if (err == error.ReadFailed) {
            if (response.bodyErr()) |body_err| return body_err;
            if (req.connection.?.stream_reader.err) |stream_err| return stream_err;
        }
        return err;
    };
    errdefer allocator.free(body);
    switch (req.reader.state) {
        .body_remaining_content_length => |left| if (left != 0) return error.HttpBodyTruncated,
        .body_remaining_chunk_len => return error.HttpChunkTruncated,
        else => {},
    }

    return .{
        .status = response.head.status,
        .body = body,
        .cookie = response_cookie,
    };
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
            else => return err,
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

fn extractCookie(allocator: Allocator, headers: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        if (end == 0) continue;
        return @as(?[]u8, try allocator.dupe(u8, value[0..end]));
    }
    return null;
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
