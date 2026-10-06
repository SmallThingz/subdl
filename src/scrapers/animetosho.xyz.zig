const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const feed = "https://feed.animetosho.xyz/json";
const site = "https://animetosho.net";
const max_search_items = 16;
const max_subtitle_items = 120;
const max_decoded_subtitle_bytes = 16 * 1024 * 1024;

pub const download_token_prefix = "animetosho-xz:";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    season: ?u16,
    episode: ?u16,
    release_id: i64,
    release: []const u8,
    page_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const ParsedQuery = common.EpisodeQuery;
const parseQuery = common.parseEpisodeQuery;

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

        const parsed_query = parseQuery(query);
        if (parsed_query.title.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, query);
        const search_url = try std.fmt.allocPrint(a, "{s}?q={s}", .{ feed, encoded });
        const response = try common.fetchBytes(self.client, a, search_url, .{
            .accept = "application/json,*/*",
            .cache = false,
            .max_attempts = 2,
        });

        return parseSearchBody(common.takeArena(&arena), response.body, parsed_query);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const detail_url = try std.fmt.allocPrint(a, "{s}?show=torrent&id={d}", .{ feed, item.release_id });
        const response = try common.fetchBytes(self.client, a, detail_url, .{
            .accept = "application/json,*/*",
            .cache = false,
            .max_attempts = 2,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const obj = common.jsonObject(root) orelse return error.InvalidFieldType;

        var normal: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var forced: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.AutoHashMapUnmanaged(i64, void).empty;

        if (common.jsonArray(obj.get("attachments") orelse .null)) |attachments| {
            try appendRootAttachments(a, &normal, &forced, &seen, item, attachments);
        }

        if (common.jsonArray(obj.get("files") orelse .null)) |files| {
            for (files.items) |file_value| {
                if (normal.items.len + forced.items.len >= max_subtitle_items) break;
                const file_obj = common.jsonObject(file_value) orelse continue;
                const filename = common.jsonString(file_obj, "filename") orelse "";
                if (item.episode != null and !fileMatchesEpisode(filename, item.season orelse 1, item.episode.?)) continue;

                const attachments = common.jsonArray(file_obj.get("attachments") orelse .null) orelse continue;
                try appendAttachments(a, &normal, &forced, &seen, item, attachments, filename);

                // For a TV season/batch search without a requested episode, avoid
                // exploding the UI with every track from every episode.
                if (item.media_kind == .tv and item.episode == null and normal.items.len + forced.items.len > 0) break;
            }
        }

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        try subtitles.appendSlice(a, normal.items);
        if (subtitles.items.len < max_subtitle_items) {
            const remaining = max_subtitle_items - subtitles.items.len;
            try subtitles.appendSlice(a, forced.items[0..@min(remaining, forced.items.len)]);
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parsed = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/download/{d}/subs/file/{d}",
            .{ site, parsed.release_id, parsed.attachment_id },
        );
        defer allocator.free(url);

        const response = try common.fetchBytes(self.client, allocator, url, .{
            .accept = "application/x-xz,application/octet-stream,*/*",
            .cache = false,
            .max_attempts = 2,
        });
        defer allocator.free(response.body);

        if (response.status != .ok) return error.UnexpectedHttpStatus;
        if (response.body.len < 6 or !std.mem.eql(u8, response.body[0..6], &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 })) {
            return error.UnexpectedResponseType;
        }

        const decoded = try common.decompressXz(allocator, response.body, max_decoded_subtitle_bytes);
        if (decoded.len == 0) {
            allocator.free(decoded);
            return error.UnexpectedResponseType;
        }
        return .{ .status = .ok, .body = decoded };
    }
};

fn parseSearchBody(arena: std.heap.ArenaAllocator, body: []const u8, parsed_query: ParsedQuery) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const values = common.jsonArray(root) orelse return error.InvalidFieldType;
    const wanted = try common.normalizeTitle(a, parsed_query.title);

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.AutoHashMapUnmanaged(i64, void).empty;

    for (values.items) |value| {
        if (items.items.len >= max_search_items) break;
        const obj = common.jsonObject(value) orelse continue;
        const status = common.jsonString(obj, "status") orelse "";
        if (!std.ascii.eqlIgnoreCase(status, "complete")) continue;

        const release_id = objectInt(obj, "id") orelse continue;
        if (release_id <= 0 or seen.contains(release_id)) continue;
        const release = common.jsonString(obj, "title") orelse continue;

        const normalized_release = try common.normalizeTitle(a, release);
        if (wanted.len > 0 and std.mem.indexOf(u8, normalized_release, wanted) == null) continue;

        const media_kind: MediaKind = if (parsed_query.episode != null or looksLikeTvRelease(release)) .tv else .movie;
        if (parsed_query.episode == null and media_kind == .tv) {
            const marker = seasonMarkerIndex(release) orelse continue;
            const normalized_prefix = try common.normalizeTitle(a, release[0..marker]);
            if (std.mem.indexOf(u8, normalized_prefix, wanted) == null) continue;
        }
        const page_url = if (common.jsonString(obj, "link")) |link|
            try a.dupe(u8, link)
        else
            try std.fmt.allocPrint(a, "{s}/view/{d}", .{ site, release_id });

        try seen.put(a, release_id, {});
        try items.append(a, .{
            .title = try a.dupe(u8, parsed_query.title),
            .year = parseYear(release),
            .media_kind = media_kind,
            .season = if (media_kind == .tv) parsed_query.season else null,
            .episode = if (media_kind == .tv) parsed_query.episode else null,
            .release_id = release_id,
            .release = try a.dupe(u8, release),
            .page_url = page_url,
        });
    }

    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn appendRootAttachments(
    allocator: Allocator,
    normal: *std.ArrayListUnmanaged(SubtitleItem),
    forced: *std.ArrayListUnmanaged(SubtitleItem),
    seen: *std.AutoHashMapUnmanaged(i64, void),
    item: SearchItem,
    attachments: std.json.Array,
) !void {
    // Root tracks belong to the release as a whole. A batch cannot prove
    // that these tracks belong to an explicitly requested episode.
    if (item.episode) |episode| {
        if (isBatchRelease(item.release)) return;
        if (!fileMatchesEpisode(item.release, item.season orelse 1, episode)) return;
    }
    try appendAttachments(allocator, normal, forced, seen, item, attachments, null);
}

fn appendAttachments(
    allocator: Allocator,
    normal: *std.ArrayListUnmanaged(SubtitleItem),
    forced: *std.ArrayListUnmanaged(SubtitleItem),
    seen: *std.AutoHashMapUnmanaged(i64, void),
    item: SearchItem,
    attachments: std.json.Array,
    media_filename: ?[]const u8,
) !void {
    for (attachments.items) |attachment_value| {
        if (normal.items.len + forced.items.len >= max_subtitle_items) break;
        const attachment = common.jsonObject(attachment_value) orelse continue;
        if (!isSubtitleAttachment(attachment)) continue;

        const attachment_id = objectInt(attachment, "id") orelse continue;
        if (attachment_id <= 0 or seen.contains(attachment_id)) continue;
        const info = common.jsonObject(attachment.get("info") orelse .null) orelse continue;
        const format = common.jsonString(info, "format") orelse continue;
        const extension = supportedTextFormat(format) orelse continue;

        const raw_code = common.jsonString(info, "language_code") orelse common.jsonString(info, "lang") orelse "";
        const language_name = common.jsonString(info, "language") orelse "";
        const language_code = normalizeLanguage(raw_code, language_name);
        const is_forced = jsonTruthy(info.get("forced"));

        try seen.put(allocator, attachment_id, {});

        const filename = if (media_filename) |media|
            try subtitleFilenameFromMedia(allocator, media, language_code, extension, is_forced)
        else
            try std.fmt.allocPrint(
                allocator,
                "animetosho-{d}-{d}-{s}{s}.{s}",
                .{ item.release_id, attachment_id, language_code, if (is_forced) "-forced" else "", extension },
            );

        const download_url = try makeDownloadToken(allocator, item.release_id, attachment_id, extension);
        const target = if (is_forced) forced else normal;
        try target.append(allocator, .{
            .language_code = try allocator.dupe(u8, language_code),
            .filename = filename,
            .download_url = download_url,
        });
    }
}

fn isSubtitleAttachment(obj: std.json.ObjectMap) bool {
    const value = obj.get("type") orelse return false;
    return switch (value) {
        .string => |s| std.ascii.eqlIgnoreCase(s, "subtitle"),
        .integer => |n| n == 1,
        else => false,
    };
}

fn subtitleFilenameFromMedia(
    allocator: Allocator,
    media_filename: []const u8,
    language_code: []const u8,
    extension: []const u8,
    forced: bool,
) ![]u8 {
    const basename = if (std.mem.lastIndexOfScalar(u8, media_filename, '/')) |slash|
        media_filename[slash + 1 ..]
    else
        media_filename;
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
        basename[0..dot]
    else
        basename;
    return std.fmt.allocPrint(
        allocator,
        "{s}.{s}{s}.{s}",
        .{ stem, language_code, if (forced) ".forced" else "", extension },
    );
}

const DownloadToken = struct {
    release_id: i64,
    attachment_id: i64,
    extension: []const u8,
};

pub fn makeDownloadToken(allocator: Allocator, release_id: i64, attachment_id: i64, extension: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}{d}|{d}|{s}",
        .{ download_token_prefix, release_id, attachment_id, extension },
    );
}

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    const first = std.mem.indexOfScalar(u8, payload, '|') orelse return null;
    const second_rel = std.mem.indexOfScalar(u8, payload[first + 1 ..], '|') orelse return null;
    const second = first + 1 + second_rel;
    if (first == 0 or second <= first + 1 or second + 1 >= payload.len) return null;

    const release_id = std.fmt.parseInt(i64, payload[0..first], 10) catch return null;
    const attachment_id = std.fmt.parseInt(i64, payload[first + 1 .. second], 10) catch return null;
    if (release_id <= 0 or attachment_id <= 0) return null;

    const extension = payload[second + 1 ..];
    if (supportedTextFormat(extension) == null) return null;
    return .{ .release_id = release_id, .attachment_id = attachment_id, .extension = extension };
}

fn supportedTextFormat(value: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(value, "srt")) return "srt";
    if (std.ascii.eqlIgnoreCase(value, "ass")) return "ass";
    if (std.ascii.eqlIgnoreCase(value, "ssa")) return "ssa";
    if (std.ascii.eqlIgnoreCase(value, "vtt") or std.ascii.eqlIgnoreCase(value, "webvtt")) return "vtt";
    return null;
}

fn normalizeLanguage(code: []const u8, name: []const u8) []const u8 {
    if (common.normalizeLanguageCode(code)) |normalized| return normalized;
    if (common.normalizeLanguageCode(name)) |normalized| return normalized;

    if (std.ascii.eqlIgnoreCase(code, "eng")) return "en";
    if (std.ascii.eqlIgnoreCase(code, "fre") or std.ascii.eqlIgnoreCase(code, "fra")) return "fr";
    if (std.ascii.eqlIgnoreCase(code, "ger") or std.ascii.eqlIgnoreCase(code, "deu")) return "de";
    if (std.ascii.eqlIgnoreCase(code, "spa")) return "es";
    if (std.ascii.eqlIgnoreCase(code, "ita")) return "it";
    if (std.ascii.eqlIgnoreCase(code, "por")) return if (std.mem.indexOf(u8, name, "[BR]") != null) "pt-br" else "pt";
    if (std.ascii.eqlIgnoreCase(code, "jpn")) return "ja";
    if (std.ascii.eqlIgnoreCase(code, "ara")) return "ar";
    if (std.ascii.eqlIgnoreCase(code, "cze") or std.ascii.eqlIgnoreCase(code, "ces")) return "cs";
    if (std.ascii.eqlIgnoreCase(code, "dan")) return "da";
    if (std.ascii.eqlIgnoreCase(code, "fin")) return "fi";
    if (std.ascii.eqlIgnoreCase(code, "heb")) return "he";
    if (std.ascii.eqlIgnoreCase(code, "hrv")) return "hr";
    if (std.ascii.eqlIgnoreCase(code, "hun")) return "hu";
    if (std.ascii.eqlIgnoreCase(code, "nob") or std.ascii.eqlIgnoreCase(code, "nor")) return "no";
    if (std.ascii.eqlIgnoreCase(code, "dut") or std.ascii.eqlIgnoreCase(code, "nld")) return "nl";
    if (std.ascii.eqlIgnoreCase(code, "pol")) return "pl";
    if (std.ascii.eqlIgnoreCase(code, "rum") or std.ascii.eqlIgnoreCase(code, "ron")) return "ro";
    if (std.ascii.eqlIgnoreCase(code, "swe")) return "sv";
    if (std.ascii.eqlIgnoreCase(code, "tur")) return "tr";

    if (code.len > 0) return code;
    if (name.len > 0) return name;
    return "und";
}

fn looksLikeTvRelease(title: []const u8) bool {
    return seasonMarkerIndex(title) != null;
}

fn seasonMarkerIndex(title: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 < title.len) : (i += 1) {
        if (std.ascii.toLower(title[i]) != 's') continue;
        var cursor = i + 1;
        var digits: usize = 0;
        while (cursor < title.len and std.ascii.isDigit(title[cursor]) and digits < 2) : ({
            cursor += 1;
            digits += 1;
        }) {}
        if (digits > 0 and cursor < title.len and (std.ascii.toLower(title[cursor]) == 'e' or isReleaseBoundary(title[cursor]))) return i;
    }
    return null;
}

fn isBatchRelease(value: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(value, "batch") != null or
        std.ascii.indexOfIgnoreCase(value, "complete") != null) return true;
    for (value, 0..) |c, separator| {
        if ((c == '-' or c == '~') and isEpisodeRangeAt(value, separator)) return true;
    }
    return false;
}

fn isEpisodeRangeAt(value: []const u8, separator: usize) bool {
    var right_start = separator + 1;
    while (right_start < value.len and std.ascii.isWhitespace(value[right_start])) : (right_start += 1) {}
    if (right_start < value.len and std.ascii.toLower(value[right_start]) == 'e') right_start += 1;
    const right = parseEpisodeNumber(value, right_start) orelse return false;
    if (right.end - right_start > 3 or isDecimalNumber(value, right_start, right.end)) return false;
    _ = episodeTokenEnd(value, right.end) orelse return false;

    var left_end = separator;
    while (left_end > 0 and std.ascii.isWhitespace(value[left_end - 1])) : (left_end -= 1) {}
    var left_start = left_end;
    while (left_start > 0 and std.ascii.isDigit(value[left_start - 1])) : (left_start -= 1) {}
    if (left_start == left_end or left_end - left_start > 3) return false;
    if (left_start > 0 and std.ascii.toLower(value[left_start - 1]) != 'e' and std.ascii.isAlphanumeric(value[left_start - 1])) return false;
    if (isDecimalNumber(value, left_start, left_end)) return false;
    _ = std.fmt.parseInt(u16, value[left_start..left_end], 10) catch return false;
    return true;
}

fn fileMatchesEpisode(filename: []const u8, season: u16, episode: u16) bool {
    if (explicitEpisodeMarkerMatches(filename, season, episode)) |matches| return matches;
    if (season != 1) return false;
    if (releaseEpisodeMarkerMatches(filename, episode)) |matches| return matches;
    return bareEpisodeNumberMatches(filename, episode);
}

const ParsedEpisodeNumber = struct {
    value: u16,
    end: usize,
};

fn parseEpisodeNumber(value: []const u8, start: usize) ?ParsedEpisodeNumber {
    if (start >= value.len or !std.ascii.isDigit(value[start])) return null;
    var end = start + 1;
    while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
    const number = std.fmt.parseInt(u16, value[start..end], 10) catch return null;
    return .{ .value = number, .end = end };
}

fn episodeTokenEnd(value: []const u8, number_end: usize) ?usize {
    var end = number_end;
    if (end < value.len and std.ascii.toLower(value[end]) == 'v') {
        end += 1;
        const revision_start = end;
        while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
        if (end == revision_start) return null;
    }
    if (end < value.len and std.ascii.isAlphanumeric(value[end])) return null;
    return end;
}

fn explicitEpisodeMarkerMatches(value: []const u8, season: u16, episode: u16) ?bool {
    var found = false;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (i > 0 and std.ascii.isAlphanumeric(value[i - 1])) continue;

        const lower = std.ascii.toLower(value[i]);
        if (lower == 's') {
            const parsed_season = parseEpisodeNumber(value, i + 1) orelse continue;
            if (parsed_season.end >= value.len or std.ascii.toLower(value[parsed_season.end]) != 'e') continue;
            const parsed_episode = parseEpisodeNumber(value, parsed_season.end + 1) orelse continue;
            _ = episodeTokenEnd(value, parsed_episode.end) orelse continue;
            found = true;
            if (parsed_season.value == season and parsed_episode.value == episode) return true;
            continue;
        }

        if (std.ascii.isDigit(value[i])) {
            const parsed_season = parseEpisodeNumber(value, i) orelse continue;
            if (parsed_season.value > 99 or parsed_season.end >= value.len or std.ascii.toLower(value[parsed_season.end]) != 'x') continue;
            const parsed_episode = parseEpisodeNumber(value, parsed_season.end + 1) orelse continue;
            if (parsed_episode.value > 999) continue;
            _ = episodeTokenEnd(value, parsed_episode.end) orelse continue;
            found = true;
            if (parsed_season.value == season and parsed_episode.value == episode) return true;
            continue;
        }

        if (lower == 'e') {
            var cursor = i + 1;
            const word = "episode";
            if (i + word.len <= value.len and std.ascii.eqlIgnoreCase(value[i .. i + word.len], word)) cursor = i + word.len;
            while (cursor < value.len and (std.ascii.isWhitespace(value[cursor]) or value[cursor] == '.' or value[cursor] == '_' or value[cursor] == '-')) : (cursor += 1) {}
            const parsed_episode = parseEpisodeNumber(value, cursor) orelse continue;
            _ = episodeTokenEnd(value, parsed_episode.end) orelse continue;
            found = true;
            if (parsed_episode.value == episode and episodeOnlySeasonMatches(value, season)) return true;
        }
    }
    return if (found) false else null;
}

fn episodeOnlySeasonMatches(value: []const u8, season: u16) bool {
    var found = false;
    for (value, 0..) |c, i| {
        if (i > 0 and std.ascii.isAlphanumeric(value[i - 1])) continue;
        if (std.ascii.isDigit(c)) {
            const parsed = parseEpisodeNumber(value, i) orelse continue;
            if (parsed.value > 99 or parsed.end >= value.len or std.ascii.toLower(value[parsed.end]) != 'x') continue;
            const episode = parseEpisodeNumber(value, parsed.end + 1) orelse continue;
            if (episode.value > 999) continue;
            _ = episodeTokenEnd(value, episode.end) orelse continue;
            found = true;
            if (parsed.value != season) return false;
            continue;
        }
        if (std.ascii.toLower(c) != 's') continue;

        var number_start = i + 1;
        const word = "season";
        if (i + word.len <= value.len and std.ascii.eqlIgnoreCase(value[i .. i + word.len], word)) {
            number_start = i + word.len;
            while (number_start < value.len and (std.ascii.isWhitespace(value[number_start]) or
                value[number_start] == '.' or value[number_start] == '_' or value[number_start] == '-')) : (number_start += 1)
            {}
        }
        const parsed = parseEpisodeNumber(value, number_start) orelse continue;
        if (parsed.end < value.len and std.ascii.isAlphanumeric(value[parsed.end])) {
            // A compact S02E03 is also explicit season context for a later E-only token.
            if (std.ascii.toLower(value[parsed.end]) != 'e') continue;
            const episode = parseEpisodeNumber(value, parsed.end + 1) orelse continue;
            _ = episodeTokenEnd(value, episode.end) orelse continue;
        }
        found = true;
        if (parsed.value != season) return false;
    }
    return found or season == 1;
}

fn releaseEpisodeMarkerMatches(value: []const u8, episode: u16) ?bool {
    for (value, 0..) |c, i| {
        if (c != '-') continue;
        var start = i + 1;
        while (start < value.len and std.ascii.isWhitespace(value[start])) : (start += 1) {}
        const parsed = parseEpisodeNumber(value, start) orelse continue;
        if (parsed.end - start > 3 or isDecimalNumber(value, start, parsed.end)) continue;
        _ = episodeTokenEnd(value, parsed.end) orelse continue;
        return parsed.value == episode;
    }
    return null;
}

fn isDecimalNumber(value: []const u8, start: usize, end: usize) bool {
    return (start >= 2 and value[start - 1] == '.' and std.ascii.isDigit(value[start - 2])) or
        (end + 1 < value.len and value[end] == '.' and std.ascii.isDigit(value[end + 1]));
}

fn bareEpisodeNumberMatches(value: []const u8, episode: u16) bool {
    var i: usize = 0;
    while (i < value.len) {
        if (!std.ascii.isDigit(value[i]) or (i > 0 and std.ascii.isAlphanumeric(value[i - 1]))) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
        const digits_end = i;
        const number = std.fmt.parseInt(u16, value[start..i], 10) catch continue;
        if (isDecimalNumber(value, start, digits_end)) continue;
        var end = i;
        if (end < value.len and std.ascii.toLower(value[end]) == 'v') {
            end += 1;
            const revision_start = end;
            while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
            if (end == revision_start) continue;
        }
        if (end < value.len and std.ascii.isAlphanumeric(value[end])) continue;
        if (digits_end - start == 4 and number >= 1900 and number <= 2099) continue;
        return number == episode;
    }
    return false;
}

fn isReleaseBoundary(c: u8) bool {
    return c == ' ' or c == '.' or c == '-' or c == '_' or c == '[' or c == '(';
}

fn parseYear(input: []const u8) ?i64 {
    if (input.len < 4) return null;
    var i: usize = 0;
    while (i + 4 <= input.len) : (i += 1) {
        const chunk = input[i .. i + 4];
        var digits = true;
        for (chunk) |c| {
            if (!std.ascii.isDigit(c)) {
                digits = false;
                break;
            }
        }
        if (!digits) continue;
        const year = std.fmt.parseInt(i64, chunk, 10) catch continue;
        if (year >= 1900 and year <= 2100) return year;
    }
    return null;
}

fn objectInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

fn jsonTruthy(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return switch (v) {
        .bool => |b| b,
        .integer => |n| n != 0,
        .string => |s| std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "true"),
        else => false,
    };
}

test "animetosho parses query and download token" {
    const parsed = parseQuery("Death Note S01E01");
    try std.testing.expectEqualStrings("Death Note", parsed.title);
    try std.testing.expectEqual(@as(?u16, 1), parsed.season);
    try std.testing.expectEqual(@as(?u16, 1), parsed.episode);
    try std.testing.expect(fileMatchesEpisode("DEATH.NOTE.S01E01.Rebirth.mkv", 1, 1));
    try std.testing.expect(!fileMatchesEpisode("DEATH.NOTE.S01E02.Confrontation.mkv", 1, 1));
    try std.testing.expect(!fileMatchesEpisode("DEATH.NOTE.S01E010.mkv", 1, 1));
    try std.testing.expect(!fileMatchesEpisode("DEATH.NOTES01E01.mkv", 1, 1));
    try std.testing.expect(fileMatchesEpisode("DEATH.NOTE.S01E01v2.mkv", 1, 1));

    const token = try makeDownloadToken(std.testing.allocator, 692954, 3637452, "srt");
    defer std.testing.allocator.free(token);
    const decoded = parseDownloadToken(token).?;
    try std.testing.expectEqual(@as(i64, 692954), decoded.release_id);
    try std.testing.expectEqual(@as(i64, 3637452), decoded.attachment_id);
    try std.testing.expectEqualStrings("srt", decoded.extension);
}

test "animetosho root attachments require the requested release episode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"id\":1,\"type\":\"subtitle\",\"info\":{\"format\":\"srt\",\"language_code\":\"eng\"}}]", .{});
    var normal: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var forced: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.AutoHashMapUnmanaged(i64, void).empty;
    var item: SearchItem = .{
        .title = "Show",
        .year = null,
        .media_kind = .tv,
        .season = 1,
        .episode = 1,
        .release_id = 1,
        .release = "Show S01 batch",
        .page_url = "https://fixture.invalid/1",
    };
    try appendRootAttachments(a, &normal, &forced, &seen, item, root.array);
    try std.testing.expectEqual(@as(usize, 0), normal.items.len);
    item.release = "Show S01E010";
    try appendRootAttachments(a, &normal, &forced, &seen, item, root.array);
    try std.testing.expectEqual(@as(usize, 0), normal.items.len);
    for ([_][]const u8{ "Show - 010", "Show - 01-12", "Show S01E01-E12", "Show - 01 Complete" }) |release| {
        item.release = release;
        try appendRootAttachments(a, &normal, &forced, &seen, item, root.array);
        try std.testing.expectEqual(@as(usize, 0), normal.items.len);
    }
    try std.testing.expect(isBatchRelease("Show - 01-12"));
    try std.testing.expect(isBatchRelease("Show S01E01-E12"));
    item.release = "Show S01E01 - 1080p";
    try std.testing.expect(!isBatchRelease(item.release));
    try appendRootAttachments(a, &normal, &forced, &seen, item, root.array);
    try std.testing.expectEqual(@as(usize, 1), normal.items.len);
    item.release = "[Group] Show - 01v2 [1080p]";
    try appendRootAttachments(a, &normal, &forced, &seen, item, root.array);
    try std.testing.expectEqual(@as(usize, 1), normal.items.len);
    item.release = "Show S01E01";
    try appendRootAttachments(a, &normal, &forced, &seen, item, root.array);
    try std.testing.expectEqual(@as(usize, 1), normal.items.len);
}

test "animetosho episode markers reject unrelated release and audio numbers" {
    for ([_][]const u8{
        "Show - 03 [FLAC 2.0]",
        "Show - 03 [02]",
        "Show S01E03 [02]",
        "Show Episode 3 [02]",
        "Show 01x03 [02]",
        "Show S02E02 [02]",
        "Show [FLAC 2.0]",
    }) |release| try std.testing.expect(!fileMatchesEpisode(release, 1, 2));
    for ([_][]const u8{ "Show S1E2", "Show 1x2", "Show Episode 02", "Show - 02 [FLAC 2.0]" }) |release| try std.testing.expect(fileMatchesEpisode(release, 1, 2));
}

test "animetosho later-season selection requires a season-qualified episode" {
    for ([_][]const u8{ "Show Episode 02.mkv", "Show E02.mkv", "Show S01E02.mkv" }) |name| {
        try std.testing.expect(!fileMatchesEpisode(name, 2, 2));
    }
    for ([_][]const u8{ "Show S02E02.mkv", "Show 2x02.mkv" }) |name| {
        try std.testing.expect(fileMatchesEpisode(name, 2, 2));
    }
}

test "animetosho E-only markers respect separated season context" {
    for ([_][]const u8{
        "Show S02 E02.mkv",
        "Show Season 2 Episode 02.mkv",
        "Show Season.2.Episode.02.mkv",
        "Show E02 S02.mkv",
        "Show 2x03 E02.mkv",
        "Show E02 2x03.mkv",
    }) |name| {
        try std.testing.expect(!fileMatchesEpisode(name, 1, 2));
        try std.testing.expect(fileMatchesEpisode(name, 2, 2));
    }
    for ([_][]const u8{ "Show E02.mkv", "Show Episode 02.mkv", "Show S01 E02.mkv", "Show Season 1 Episode 02.mkv" }) |name| {
        try std.testing.expect(fileMatchesEpisode(name, 1, 2));
        try std.testing.expect(!fileMatchesEpisode(name, 2, 2));
    }
    try std.testing.expect(!fileMatchesEpisode("Show S01 Season 2 Episode 02.mkv", 1, 2));
    try std.testing.expect(!fileMatchesEpisode("Show S01 Season 2 Episode 02.mkv", 2, 2));
    try std.testing.expect(!fileMatchesEpisode("Show S02E03 E02.mkv", 1, 2));
    try std.testing.expect(fileMatchesEpisode("Show S02E02.mkv", 2, 2));
    try std.testing.expect(fileMatchesEpisode("Show 100x03 E02.mkv", 1, 2));
    try std.testing.expect(fileMatchesEpisode("Show 2x1000 E02.mkv", 1, 2));
    try std.testing.expect(fileMatchesEpisode("Show 2x03audio E02.mkv", 1, 2));
}

test "animetosho parses completed title search results" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchBody(
        arena,
        \\[
        \\  {"id": 1, "status": "complete", "title": "Spirited Away (2001) [BD]", "link": "https://animetosho.net/view/1"},
        \\  {"id": 2, "status": "unknown", "title": "Spirited Away (2001) [RAW]", "link": "https://animetosho.net/view/2"},
        \\  {"id": 3, "status": "complete", "title": "Unrelated Show S01", "link": "https://animetosho.net/view/3"},
        \\  {"id": 4, "status": "complete", "title": "Gibiate S01E01 - Spirited Away", "link": "https://animetosho.net/view/4"}
        \\]
    ,
        .{ .title = "Spirited Away", .season = null, .episode = null },
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqual(@as(i64, 1), response.items[0].release_id);
    try std.testing.expectEqual(@as(?i64, 2001), response.items[0].year);
    try std.testing.expect(response.items[0].media_kind == .movie);
}

test "live animetosho movie and tv attachment downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "animetosho.xyz")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Spirited Away");
    defer movie.deinit();
    var movie_downloaded = false;
    for (movie.items) |item| {
        var subtitles = scraper.fetchSubtitlesBySearchItem(item) catch continue;
        defer subtitles.deinit();
        if (subtitles.subtitles.len == 0) continue;
        const download = scraper.fetchDownloadByToken(std.testing.allocator, subtitles.subtitles[0].download_url) catch continue;
        defer std.testing.allocator.free(download.body);
        if (download.body.len > 100) {
            movie_downloaded = true;
            break;
        }
    }
    try std.testing.expect(movie_downloaded);

    var tv = try scraper.search("Death Note S01E01");
    defer tv.deinit();
    var tv_downloaded = false;
    for (tv.items) |item| {
        var subtitles = scraper.fetchSubtitlesBySearchItem(item) catch continue;
        defer subtitles.deinit();
        if (subtitles.subtitles.len == 0) continue;
        const download = scraper.fetchDownloadByToken(std.testing.allocator, subtitles.subtitles[0].download_url) catch continue;
        defer std.testing.allocator.free(download.body);
        if (download.body.len > 100 and std.mem.indexOf(u8, download.body, "-->") != null) {
            tv_downloaded = true;
            break;
        }
    }
    try std.testing.expect(tv_downloaded);
}
