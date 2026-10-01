const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const imdb_suggest = "https://v2.sg.media-imdb.com/suggestion/x";
const api = "https://api.thesubtitledb.org/v1";
const download_base = "https://api.thesubtitledb.org/get";
const max_search_items = 8;
const max_subtitle_items = 30;

pub const MediaKind = enum {
    movie,
    tv,
};

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    imdb_id: []const u8,
    season: ?u16,
    episode: ?u16,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    language_code: []const u8,
    filename: []const u8,
    release_name: []const u8,
    format: []const u8,
    hearing_impaired: bool,
    download_url: []const u8,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SearchItem,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    subtitles: []const SubtitleItem,

    pub fn deinit(self: *SubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ParsedQuery = struct {
    title: []const u8,
    season: ?u16,
    episode: ?u16,
};

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn deinit(_: *Scraper) void {}

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const parsed_query = parseQuery(query);
        if (parsed_query.title.len < 2) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, parsed_query.title);
        const url = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ imdb_suggest, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json,*/*",
            .max_attempts = 2,
        });

        const items = try parseSearchBody(a, response.body, parsed_query);
        return .{ .arena = arena, .items = items };
    }

    pub fn fetchSubtitlesBySearchItem(
        self: *Scraper,
        item: SearchItem,
        language_code: []const u8,
    ) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const language = providerLanguageCode(language_code) orelse "en";
        const encoded_language = try common.encodeUriComponent(a, language);
        const url = if (item.media_kind == .tv and item.season != null and item.episode != null)
            try std.fmt.allocPrint(
                a,
                "{s}/by-imdb/{s}/season/{d}/episode/{d}?lang={s}&limit={d}",
                .{ api, item.imdb_id, item.season.?, item.episode.?, encoded_language, max_subtitle_items },
            )
        else
            try std.fmt.allocPrint(
                a,
                "{s}/by-imdb/{s}?lang={s}&limit={d}",
                .{ api, item.imdb_id, encoded_language, max_subtitle_items },
            );

        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json,*/*",
            .max_attempts = 2,
        });

        const parsed = try parseSubtitlesBody(a, response.body, item.title, language);
        return .{
            .arena = arena,
            .title = parsed.title,
            .subtitles = parsed.subtitles,
        };
    }
};

fn parseSearchBody(
    allocator: Allocator,
    body: []const u8,
    parsed_query: ParsedQuery,
) ![]const SearchItem {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    const root_obj = valueObject(root) orelse return error.InvalidFieldType;
    const results = valueArray(root_obj.get("d") orelse .null) orelse return &.{};
    const wanted = try normalizeTitle(allocator, parsed_query.title);

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    for (results.items) |value| {
        if (exact.items.len + partial.items.len >= max_search_items * 2) break;
        const obj = valueObject(value) orelse continue;
        const imdb_id = objectString(obj, "id") orelse continue;
        if (!isImdbTitleId(imdb_id) or seen.contains(imdb_id)) continue;
        const title = objectString(obj, "l") orelse continue;
        const media_kind = mediaKind(obj) orelse continue;
        if (parsed_query.episode != null and media_kind != .tv) continue;

        const normalized = try normalizeTitle(allocator, title);
        const is_exact = if (wanted.len > 0)
            std.mem.eql(u8, normalized, wanted)
        else
            std.ascii.eqlIgnoreCase(title, parsed_query.title);
        const is_partial = wanted.len > 0 and std.mem.indexOf(u8, normalized, wanted) != null;
        if (!is_exact and !is_partial) continue;

        const owned_id = try allocator.dupe(u8, imdb_id);
        try seen.put(allocator, owned_id, {});
        const item: SearchItem = .{
            .title = try allocator.dupe(u8, title),
            .year = objectInt(obj, "y"),
            .media_kind = media_kind,
            .imdb_id = owned_id,
            .season = if (media_kind == .tv) parsed_query.season else null,
            .episode = if (media_kind == .tv) parsed_query.episode else null,
            .page_url = try std.fmt.allocPrint(allocator, "https://www.imdb.com/title/{s}/", .{imdb_id}),
        };
        if (is_exact) try exact.append(allocator, item) else try partial.append(allocator, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    const exact_count = @min(exact.items.len, max_search_items);
    try items.appendSlice(allocator, exact.items[0..exact_count]);
    if (items.items.len < max_search_items) {
        const remaining = max_search_items - items.items.len;
        try items.appendSlice(allocator, partial.items[0..@min(remaining, partial.items.len)]);
    }

    return items.toOwnedSlice(allocator);
}

const ParsedSubtitles = struct {
    title: []const u8,
    subtitles: []const SubtitleItem,
};

fn parseSubtitlesBody(
    allocator: Allocator,
    body: []const u8,
    fallback_title: []const u8,
    fallback_language: []const u8,
) !ParsedSubtitles {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    const root_obj = valueObject(root) orelse return error.InvalidFieldType;
    const title_obj = valueObject(root_obj.get("title") orelse .null);
    const title = if (title_obj) |obj| objectString(obj, "name") orelse fallback_title else fallback_title;
    const subtitles_obj = valueObject(root_obj.get("subtitles") orelse .null) orelse
        return .{ .title = try allocator.dupe(u8, title), .subtitles = &.{} };
    const values = valueArray(subtitles_obj.get("items") orelse .null) orelse
        return .{ .title = try allocator.dupe(u8, title), .subtitles = &.{} };

    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    for (values.items) |value| {
        if (subtitles.items.len >= max_subtitle_items) break;
        const obj = valueObject(value) orelse continue;
        const id = objectInt(obj, "id") orelse continue;
        if (id <= 0) continue;
        const raw_format = objectString(obj, "format") orelse continue;
        const format = supportedTextFormat(raw_format) orelse continue;
        const language = objectString(obj, "language") orelse fallback_language;
        const release = objectString(obj, "release_name") orelse "TheSubtitleDB subtitle";

        try subtitles.append(allocator, .{
            .language_code = try allocator.dupe(u8, language),
            .filename = try std.fmt.allocPrint(allocator, "thesubtitledb-{d}.{s}", .{ id, format }),
            .release_name = try allocator.dupe(u8, release),
            .format = format,
            .hearing_impaired = objectBool(obj, "hearing_impaired") orelse false,
            .download_url = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ download_base, id }),
        });
    }

    return .{
        .title = try allocator.dupe(u8, title),
        .subtitles = try subtitles.toOwnedSlice(allocator),
    };
}

pub fn providerLanguageCode(input: []const u8) ?[]const u8 {
    if (common.normalizeLanguageCode(input)) |normalized| {
        if (std.mem.eql(u8, normalized, "pt-br")) return "pb";
        if (std.mem.eql(u8, normalized, "zh-tw")) return "zt";
        return normalized;
    }

    if (std.ascii.eqlIgnoreCase(input, "eng")) return "en";
    if (std.ascii.eqlIgnoreCase(input, "spa")) return "es";
    if (std.ascii.eqlIgnoreCase(input, "fra") or std.ascii.eqlIgnoreCase(input, "fre")) return "fr";
    if (std.ascii.eqlIgnoreCase(input, "deu") or std.ascii.eqlIgnoreCase(input, "ger")) return "de";
    if (std.ascii.eqlIgnoreCase(input, "ita")) return "it";
    if (std.ascii.eqlIgnoreCase(input, "por")) return "pt";
    if (std.ascii.eqlIgnoreCase(input, "pob")) return "pb";
    if (std.ascii.eqlIgnoreCase(input, "zho") or std.ascii.eqlIgnoreCase(input, "chi")) return "zh";
    if (std.ascii.eqlIgnoreCase(input, "zht")) return "zt";
    if (std.ascii.eqlIgnoreCase(input, "jpn")) return "ja";
    if (std.ascii.eqlIgnoreCase(input, "kor")) return "ko";
    if (std.ascii.eqlIgnoreCase(input, "ara")) return "ar";
    if (std.ascii.eqlIgnoreCase(input, "fas") or std.ascii.eqlIgnoreCase(input, "per")) return "fa";
    if (std.ascii.eqlIgnoreCase(input, "ind")) return "id";
    if (std.ascii.eqlIgnoreCase(input, "pol")) return "pl";
    if (std.ascii.eqlIgnoreCase(input, "ron") or std.ascii.eqlIgnoreCase(input, "rum")) return "ro";
    if (std.ascii.eqlIgnoreCase(input, "rus")) return "ru";
    if (std.ascii.eqlIgnoreCase(input, "tur")) return "tr";
    if (std.ascii.eqlIgnoreCase(input, "ukr")) return "uk";
    if (std.ascii.eqlIgnoreCase(input, "heb")) return "he";
    if (std.ascii.eqlIgnoreCase(input, "nld") or std.ascii.eqlIgnoreCase(input, "dut")) return "nl";
    if (std.ascii.eqlIgnoreCase(input, "swe")) return "sv";
    if (std.ascii.eqlIgnoreCase(input, "nor") or std.ascii.eqlIgnoreCase(input, "nob")) return "no";
    if (std.ascii.eqlIgnoreCase(input, "dan")) return "da";
    if (std.ascii.eqlIgnoreCase(input, "fin")) return "fi";
    if (std.ascii.eqlIgnoreCase(input, "ces") or std.ascii.eqlIgnoreCase(input, "cze")) return "cs";
    if (std.ascii.eqlIgnoreCase(input, "hun")) return "hu";
    if (std.ascii.eqlIgnoreCase(input, "ell") or std.ascii.eqlIgnoreCase(input, "gre")) return "el";
    if (std.ascii.eqlIgnoreCase(input, "hrv")) return "hr";
    if (std.ascii.eqlIgnoreCase(input, "srp")) return "sr";
    if (std.ascii.eqlIgnoreCase(input, "bul")) return "bg";
    if (std.ascii.eqlIgnoreCase(input, "vie")) return "vi";
    return null;
}

fn parseQuery(input: []const u8) ParsedQuery {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (std.ascii.toLower(trimmed[i]) != 's') continue;
        var cursor = i + 1;
        const season_start = cursor;
        while (cursor < trimmed.len and std.ascii.isDigit(trimmed[cursor]) and cursor - season_start < 2) : (cursor += 1) {}
        if (cursor == season_start or cursor >= trimmed.len or std.ascii.toLower(trimmed[cursor]) != 'e') continue;
        const season = std.fmt.parseInt(u16, trimmed[season_start..cursor], 10) catch continue;
        cursor += 1;
        const episode_start = cursor;
        while (cursor < trimmed.len and std.ascii.isDigit(trimmed[cursor]) and cursor - episode_start < 3) : (cursor += 1) {}
        if (cursor == episode_start) continue;
        const episode = std.fmt.parseInt(u16, trimmed[episode_start..cursor], 10) catch continue;
        const title = std.mem.trim(u8, trimmed[0..i], " \t\r\n-._");
        if (title.len == 0) continue;
        return .{ .title = title, .season = season, .episode = episode };
    }
    return .{ .title = trimmed, .season = null, .episode = null };
}

fn normalizeTitle(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            pending_space = out.items.len > 0;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn mediaKind(obj: std.json.ObjectMap) ?MediaKind {
    const qid = objectString(obj, "qid") orelse "";
    const q = objectString(obj, "q") orelse "";

    if (std.ascii.eqlIgnoreCase(qid, "movie") or
        std.ascii.eqlIgnoreCase(qid, "tvMovie") or
        std.ascii.eqlIgnoreCase(q, "feature")) return .movie;
    if (startsWithIgnoreCase(qid, "tv") or
        std.ascii.eqlIgnoreCase(q, "TV series") or
        std.ascii.eqlIgnoreCase(q, "TV mini-series")) return .tv;
    return null;
}

fn isImdbTitleId(value: []const u8) bool {
    if (value.len < 3 or value[0] != 't' or value[1] != 't') return false;
    for (value[2..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn supportedTextFormat(value: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(value, "srt")) return "srt";
    if (std.ascii.eqlIgnoreCase(value, "ass")) return "ass";
    if (std.ascii.eqlIgnoreCase(value, "ssa")) return "ssa";
    if (std.ascii.eqlIgnoreCase(value, "vtt") or std.ascii.eqlIgnoreCase(value, "webvtt")) return "vtt";
    if (std.ascii.eqlIgnoreCase(value, "sub")) return "sub";
    return null;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn valueArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn objectInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        .float => |number| @intFromFloat(number),
        else => null,
    };
}

fn objectBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

test "thesubtitledb parses movie and episode queries" {
    const movie = parseQuery("Inception");
    try std.testing.expectEqualStrings("Inception", movie.title);
    try std.testing.expectEqual(@as(?u16, null), movie.season);
    try std.testing.expectEqual(@as(?u16, null), movie.episode);

    const episode = parseQuery("Breaking Bad S01E01");
    try std.testing.expectEqualStrings("Breaking Bad", episode.title);
    try std.testing.expectEqual(@as(?u16, 1), episode.season);
    try std.testing.expectEqual(@as(?u16, 1), episode.episode);
}

test "thesubtitledb parses imdb suggestions" {
    const fixture =
        \\{"d":[{"id":"tt1375666","l":"Inception","qid":"movie","q":"feature","y":2010},{"id":"tt1790736","l":"Inception: The Cobol Job","qid":"video","q":"video","y":2010}]}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try parseSearchBody(arena.allocator(), fixture, .{ .title = "Inception", .season = null, .episode = null });
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("tt1375666", items[0].imdb_id);
    try std.testing.expectEqual(MediaKind.movie, items[0].media_kind);
}

test "thesubtitledb parses subtitle items" {
    const fixture =
        \\{"title":{"name":"Inception"},"subtitles":{"items":[{"id":8426820,"language":"en","format":"srt","release_name":"Inception.WEBRip","hearing_impaired":false},{"id":9,"language":"en","format":"idx","release_name":"unsupported"}]}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try parseSubtitlesBody(arena.allocator(), fixture, "fallback", "en");
    try std.testing.expectEqualStrings("Inception", response.title);
    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    try std.testing.expectEqualStrings("thesubtitledb-8426820.srt", response.subtitles[0].filename);
    try std.testing.expectEqualStrings("https://api.thesubtitledb.org/get/8426820", response.subtitles[0].download_url);
}

test "thesubtitledb normalizes provider language codes" {
    try std.testing.expectEqualStrings("en", providerLanguageCode("eng").?);
    try std.testing.expectEqualStrings("pb", providerLanguageCode("pt-BR").?);
    try std.testing.expectEqualStrings("zt", providerLanguageCode("zh-TW").?);
}

test "live thesubtitledb movie search subtitles and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "thesubtitledb.org")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Inception");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var chosen: ?SearchItem = null;
    for (search.items) |item| {
        if (std.mem.eql(u8, item.imdb_id, "tt1375666")) {
            chosen = item;
            break;
        }
    }
    const movie = chosen orelse return error.TestUnexpectedResult;

    var subtitles = try scraper.fetchSubtitlesBySearchItem(movie, "en");
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);

    var download_url: ?[]const u8 = null;
    for (subtitles.subtitles) |subtitle| {
        if (std.mem.eql(u8, subtitle.format, "srt")) {
            download_url = subtitle.download_url;
            break;
        }
    }
    const url = download_url orelse return error.TestUnexpectedResult;
    const download = try common.fetchBytes(&client, std.testing.allocator, url, .{
        .accept = "text/plain,application/x-subrip,*/*",
        .cache = false,
        .max_attempts = 2,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, download.body, "-->") != null);
}
