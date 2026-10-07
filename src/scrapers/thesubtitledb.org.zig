const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const imdb_suggest = "https://v2.sg.media-imdb.com/suggestion/x";
const api = "https://api.thesubtitledb.org/v1";
const download_base = "https://api.thesubtitledb.org/get";
const max_search_items = 8;
const max_subtitle_items = 30;

pub const MediaKind = common.MediaKind;

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

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const ParsedQuery = struct {
    title: []const u8,
    year: ?i64 = null,
    season: ?u16,
    episode: ?u16,
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

        const parsed_query = parseQuery(query);
        if (parsed_query.title.len < 2) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, parsed_query.title);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, parsed_query.title);
        const url = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ imdb_suggest, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json,*/*",
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
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

        const language = requestedProviderLanguage(language_code) orelse return common.finishResponse(
            SubtitlesResponse,
            &arena,
            .{ .arena = arena, .title = try a.dupe(u8, item.title), .subtitles = &.{} },
        );
        if (!isImdbTitleId(item.imdb_id)) return error.InvalidDownloadUrl;
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
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
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
    const root_obj = common.jsonObject(root) orelse return error.InvalidFieldType;
    const results = common.jsonArray(root_obj.get("d") orelse .null) orelse return &.{};
    const wanted = try common.normalizeTitle(allocator, parsed_query.title);

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    for (results.items) |value| {
        const obj = common.jsonObject(value) orelse continue;
        const imdb_id = common.jsonString(obj, "id") orelse continue;
        if (!isImdbTitleId(imdb_id)) continue;
        const title = common.jsonString(obj, "l") orelse continue;
        const media_kind = mediaKind(obj) orelse continue;
        if (parsed_query.episode != null and media_kind != .tv) continue;
        const candidate_year = common.jsonIntField(obj, "y");
        if (parsed_query.year) |wanted_year| {
            if (candidate_year == null or candidate_year.? != wanted_year) continue;
        }

        const normalized = try common.normalizeTitle(allocator, title);
        const is_exact = if (wanted.len > 0)
            std.mem.eql(u8, normalized, wanted)
        else
            std.ascii.eqlIgnoreCase(title, parsed_query.title);
        const is_partial = common.normalizedTitlesRelated(normalized, wanted);
        if (!is_exact and !is_partial) continue;

        if (is_exact) {
            if (searchItemIndex(exact.items, imdb_id) != null) continue;
            if (searchItemIndex(partial.items, imdb_id)) |index| {
                _ = partial.orderedRemove(index);
            }
        } else {
            if (searchItemIndex(exact.items, imdb_id) != null or
                searchItemIndex(partial.items, imdb_id) != null or
                partial.items.len >= max_search_items) continue;
        }

        const owned_id = try allocator.dupe(u8, imdb_id);
        const item: SearchItem = .{
            .title = try allocator.dupe(u8, title),
            .year = candidate_year,
            .media_kind = media_kind,
            .imdb_id = owned_id,
            .season = if (media_kind == .tv) parsed_query.season else null,
            .episode = if (media_kind == .tv) parsed_query.episode else null,
            .page_url = try std.fmt.allocPrint(allocator, "https://www.imdb.com/title/{s}/", .{imdb_id}),
        };
        if (is_exact) {
            try exact.append(allocator, item);
            if (exact.items.len >= max_search_items) break;
        } else {
            try partial.append(allocator, item);
        }
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

fn searchItemIndex(items: []const SearchItem, imdb_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.imdb_id, imdb_id)) return index;
    }
    return null;
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
    const root_obj = common.jsonObject(root) orelse return error.InvalidFieldType;
    const title_obj = common.jsonObject(root_obj.get("title") orelse .null);
    const title = if (title_obj) |obj| common.jsonString(obj, "name") orelse fallback_title else fallback_title;
    const subtitles_obj = common.jsonObject(root_obj.get("subtitles") orelse .null) orelse
        return .{ .title = try allocator.dupe(u8, title), .subtitles = &.{} };
    const values = common.jsonArray(subtitles_obj.get("items") orelse .null) orelse
        return .{ .title = try allocator.dupe(u8, title), .subtitles = &.{} };

    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.AutoHashMapUnmanaged(i64, void).empty;
    for (values.items) |value| {
        const obj = common.jsonObject(value) orelse continue;
        const id = common.jsonIntField(obj, "id") orelse continue;
        if (id <= 0 or seen.contains(id)) continue;
        if (subtitles.items.len >= max_subtitle_items) break;
        const raw_format = common.jsonString(obj, "format") orelse continue;
        const format = supportedTextFormat(raw_format) orelse continue;
        const raw_language = common.jsonString(obj, "language") orelse fallback_language;
        const language = canonicalOutputLanguageCode(raw_language);
        const release = common.jsonString(obj, "release_name") orelse "TheSubtitleDB subtitle";

        try seen.put(allocator, id, {});
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
    if (std.ascii.eqlIgnoreCase(input, "pb")) return "pb";
    if (std.ascii.eqlIgnoreCase(input, "zt")) return "zt";
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

fn canonicalOutputLanguageCode(input: []const u8) []const u8 {
    const provider_code = providerLanguageCode(input) orelse return input;
    if (std.mem.eql(u8, provider_code, "pb")) return "pt-br";
    if (std.mem.eql(u8, provider_code, "zt")) return "zh-tw";
    return provider_code;
}

fn requestedProviderLanguage(input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return "en";
    return providerLanguageCode(trimmed);
}

fn parseQuery(input: []const u8) ParsedQuery {
    const episode = common.parseEpisodeQuery(input);
    const title_year = common.splitTrailingYear(episode.title);
    return .{
        .title = title_year.title,
        .year = title_year.year,
        .season = episode.season,
        .episode = episode.episode,
    };
}

fn mediaKind(obj: std.json.ObjectMap) ?MediaKind {
    const qid = common.jsonString(obj, "qid") orelse "";
    const q = common.jsonString(obj, "q") orelse "";

    if (std.ascii.eqlIgnoreCase(qid, "movie") or
        std.ascii.eqlIgnoreCase(qid, "tvMovie") or
        std.ascii.eqlIgnoreCase(q, "feature")) return .movie;
    if (startsWithIgnoreCase(qid, "tv") or
        std.ascii.eqlIgnoreCase(q, "TV series") or
        std.ascii.eqlIgnoreCase(q, "TV mini-series")) return .tv;
    return null;
}

fn isImdbTitleId(value: []const u8) bool {
    if (value.len < 9 or value.len > 12 or value[0] != 't' or value[1] != 't') return false;
    var has_nonzero_digit = false;
    for (value[2..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
        has_nonzero_digit = has_nonzero_digit or (c != '0');
    }
    return has_nonzero_digit;
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

    const qualified_movie = parseQuery("Inception (2010)");
    try std.testing.expectEqualStrings("Inception", qualified_movie.title);
    try std.testing.expectEqual(@as(?i64, 2010), qualified_movie.year);
    const qualified_episode = parseQuery("Breaking Bad (2008) S01E01");
    try std.testing.expectEqualStrings("Breaking Bad", qualified_episode.title);
    try std.testing.expectEqual(@as(?i64, 2008), qualified_episode.year);

    const numeric_title = parseQuery("Blade Runner 2049");
    try std.testing.expectEqualStrings("Blade Runner 2049", numeric_title.title);
    try std.testing.expectEqual(@as(?i64, null), numeric_title.year);
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

test "thesubtitledb invalid exact imdb ids do not consume the candidate cap" {
    const fixture =
        \\{"d":[
        \\  {"id":"tt0","l":"Target","qid":"movie"},
        \\  {"id":"tt00","l":"Target","qid":"movie"},
        \\  {"id":"tt000","l":"Target","qid":"movie"},
        \\  {"id":"tt0000","l":"Target","qid":"movie"},
        \\  {"id":"tt00000","l":"Target","qid":"movie"},
        \\  {"id":"tt000000","l":"Target","qid":"movie"},
        \\  {"id":"tt0000000","l":"Target","qid":"movie"},
        \\  {"id":"tt00000000","l":"Target","qid":"movie"},
        \\  {"id":"tt000000000","l":"Target","qid":"movie"},
        \\  {"id":"tt0000000000","l":"Target","qid":"movie"},
        \\  {"id":"tt00000000000","l":"Target","qid":"movie"},
        \\  {"id":"tt000000000000","l":"Target","qid":"movie"},
        \\  {"id":"tt0000000000000","l":"Target","qid":"movie"},
        \\  {"id":"tt00000000000000","l":"Target","qid":"movie"},
        \\  {"id":"tt000000000000000","l":"Target","qid":"movie"},
        \\  {"id":"tt0000000000000000","l":"Target","qid":"movie"},
        \\  {"id":"tt1375666","l":"Target","qid":"movie"}
        \\]}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try parseSearchBody(arena.allocator(), fixture, .{ .title = "Target", .season = null, .episode = null });
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("tt1375666", items[0].imdb_id);
    try std.testing.expect(isImdbTitleId("tt0000001"));
    try std.testing.expect(!isImdbTitleId("tt0000000"));
}

test "thesubtitledb later exact match displaces capped partial matches" {
    const fixture =
        \\{"d":[
        \\  {"id":"tt1000001","l":"Target One","qid":"movie"},
        \\  {"id":"tt1000002","l":"Target Two","qid":"movie"},
        \\  {"id":"tt1000003","l":"Target Three","qid":"movie"},
        \\  {"id":"tt1000004","l":"Target Four","qid":"movie"},
        \\  {"id":"tt1000005","l":"Target Five","qid":"movie"},
        \\  {"id":"tt1000006","l":"Target Six","qid":"movie"},
        \\  {"id":"tt1000007","l":"Target Seven","qid":"movie"},
        \\  {"id":"tt1000008","l":"Target Eight","qid":"movie"},
        \\  {"id":"tt1000009","l":"Target Nine","qid":"movie"},
        \\  {"id":"tt1000010","l":"Target Ten","qid":"movie"},
        \\  {"id":"tt1000011","l":"Target Eleven","qid":"movie"},
        \\  {"id":"tt1000012","l":"Target Twelve","qid":"movie"},
        \\  {"id":"tt1000013","l":"Target Thirteen","qid":"movie"},
        \\  {"id":"tt1000014","l":"Target Fourteen","qid":"movie"},
        \\  {"id":"tt1000015","l":"Target Fifteen","qid":"movie"},
        \\  {"id":"tt1000016","l":"Target Sixteen","qid":"movie"},
        \\  {"id":"tt1000001","l":"Target","qid":"movie"}
        \\]}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try parseSearchBody(arena.allocator(), fixture, .{ .title = "Target", .season = null, .episode = null });
    try std.testing.expectEqual(@as(usize, max_search_items), items.len);
    try std.testing.expectEqualStrings("Target", items[0].title);
    try std.testing.expectEqualStrings("tt1000001", items[0].imdb_id);
    try std.testing.expectEqualStrings("tt1000002", items[1].imdb_id);
}

test "thesubtitledb explicit year excludes same-title remakes" {
    const fixture =
        \\{"d":[{"id":"tt1375666","l":"Inception","qid":"movie","y":2010},{"id":"tt9999999","l":"Inception","qid":"movie","y":2026}]}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try parseSearchBody(arena.allocator(), fixture, parseQuery("Inception (2010)"));
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("tt1375666", items[0].imdb_id);
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

test "thesubtitledb duplicate subtitle ids do not consume the item cap" {
    var fixture: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.writer.writeAll("{\"subtitles\":{\"items\":[");
    for (0..max_subtitle_items) |index| {
        if (index != 0) try fixture.writer.writeAll(",");
        try fixture.writer.writeAll("{\"id\":1,\"language\":\"en\",\"format\":\"srt\"}");
    }
    try fixture.writer.writeAll(",{\"id\":2,\"language\":\"en\",\"format\":\"srt\"}]}}");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try parseSubtitlesBody(arena.allocator(), fixture.written(), "fallback", "en");
    try std.testing.expectEqual(@as(usize, 2), response.subtitles.len);
    try std.testing.expectEqualStrings("thesubtitledb-1.srt", response.subtitles[0].filename);
    try std.testing.expectEqualStrings("thesubtitledb-2.srt", response.subtitles[1].filename);
}

test "thesubtitledb emits canonical provider language variants" {
    const fixture =
        \\{"subtitles":{"items":[{"id":1,"language":"pb","format":"srt"},{"id":2,"language":"zt","format":"srt"},{"id":3,"format":"srt"}]}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try parseSubtitlesBody(arena.allocator(), fixture, "fallback", "pb");
    try std.testing.expectEqual(@as(usize, 3), response.subtitles.len);
    try std.testing.expectEqualStrings("pt-br", response.subtitles[0].language_code);
    try std.testing.expectEqualStrings("zh-tw", response.subtitles[1].language_code);
    try std.testing.expectEqualStrings("pt-br", response.subtitles[2].language_code);
}

test "thesubtitledb normalizes provider language codes" {
    try std.testing.expectEqualStrings("en", providerLanguageCode("eng").?);
    try std.testing.expectEqualStrings("pb", providerLanguageCode("pt-BR").?);
    try std.testing.expectEqualStrings("zt", providerLanguageCode("zh-TW").?);
    try std.testing.expectEqualStrings("pb", providerLanguageCode(providerLanguageCode("pt-BR").?).?);
    try std.testing.expectEqualStrings("zt", providerLanguageCode(providerLanguageCode("zh-TW").?).?);
    try std.testing.expectEqualStrings("en", requestedProviderLanguage(" \t").?);
    try std.testing.expectEqualStrings("en", requestedProviderLanguage(" \teng\r\n").?);
    try std.testing.expectEqualStrings("es", requestedProviderLanguage(" spa ").?);
    try std.testing.expectEqualStrings("pb", requestedProviderLanguage("\tpb ").?);
    try std.testing.expectEqualStrings("zt", requestedProviderLanguage(" zt\n").?);
    try std.testing.expect(requestedProviderLanguage("not-a-language") == null);
}

test "thesubtitledb unsupported language returns no English fallback" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.fetchSubtitlesBySearchItem(.{
        .title = "Inception",
        .year = 2010,
        .media_kind = .movie,
        .imdb_id = "tt1375666",
        .season = null,
        .episode = null,
        .page_url = "https://www.imdb.com/title/tt1375666/",
    }, "not-a-language");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.subtitles.len);
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
        .require_public_origin = true,
        .require_https = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, download.body, "-->") != null);
}
