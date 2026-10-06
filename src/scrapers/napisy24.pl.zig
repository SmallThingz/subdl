const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://napisy24.pl";
const search_endpoint = site ++ "/libs/webapi.php";
const download_endpoint = site ++ "/run/pages/download.php";
const max_search_items = 8;
const max_subtitle_items = 40;

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    imdb_id: []const u8,
    season: ?u16,
    episode: ?u16,
    search_query: []const u8,
    page_url: []const u8,
};

pub const SubtitleItem = common.ReleaseSubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const ParsedQuery = common.EpisodeQuery;
const parseQuery = common.parseEpisodeQuery;

const SubtitleRecord = struct {
    id: i64,
    title: []const u8,
    imdb_id: []const u8,
    year: ?i64,
    language_code: []const u8,
    release_name: []const u8,
    season: ?u16,
    episode: ?u16,
};

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,
    language_code: []const u8,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client, .language_code = "en" };
    }

    pub fn initWithLanguage(allocator: Allocator, client: *std.http.Client, language_code: []const u8) Scraper {
        return .{
            .allocator = allocator,
            .client = client,
            .language_code = providerLanguageCode(language_code) orelse "en",
        };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const parsed_query = parseQuery(query);
        if (parsed_query.title.len < 2) return .{ .arena = arena, .items = &.{} };

        const response = try fetchSearch(self.client, a, query);
        const records = try parseRecords(a, response.body);
        const items = try buildSearchItems(a, records, query, parsed_query, self.language_code);
        return .{ .arena = arena, .items = items };
    }

    pub fn fetchSubtitlesBySearchItem(
        self: *Scraper,
        item: SearchItem,
        requested_language: []const u8,
    ) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try fetchSearch(self.client, a, item.search_query);
        const records = try parseRecords(a, response.body);
        const language = providerLanguageCode(requested_language) orelse "en";

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        for (records) |record| {
            if (subtitles.items.len >= max_subtitle_items) break;
            if (!recordMatchesItem(record, item)) continue;
            if (!std.ascii.eqlIgnoreCase(record.language_code, language)) continue;

            try subtitles.append(a, .{
                .language_code = try a.dupe(u8, record.language_code),
                .filename = try std.fmt.allocPrint(a, "napisy24-{d}.zip", .{record.id}),
                .release_name = try a.dupe(u8, if (record.release_name.len > 0) record.release_name else record.title),
                .download_url = try downloadUrl(a, record.id),
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }
};

fn fetchSearch(client: *std.http.Client, allocator: Allocator, query: []const u8) !common.HttpResponse {
    const encoded = try common.encodeUriComponent(allocator, query);
    const url = try std.fmt.allocPrint(allocator, "{s}?title={s}", .{ search_endpoint, encoded });
    return common.fetchBytes(client, allocator, url, .{
        .accept = "application/xml,text/xml,text/plain,*/*",
        .max_attempts = 2,
        .require_public_origin = true,
    });
}

fn buildSearchItems(
    allocator: Allocator,
    records: []const SubtitleRecord,
    original_query: []const u8,
    parsed_query: ParsedQuery,
    requested_language: []const u8,
) ![]const SearchItem {
    const wanted = try common.normalizeTitle(allocator, parsed_query.title);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    for (records) |record| {
        if (exact.items.len + partial.items.len >= max_search_items * 4) break;
        if (!std.ascii.eqlIgnoreCase(record.language_code, requested_language)) continue;
        const base_title = stripEpisodeSuffix(record.title, record.season, record.episode);
        const normalized = try common.normalizeTitle(allocator, base_title);
        const is_exact = wanted.len > 0 and std.mem.eql(u8, normalized, wanted);
        const is_partial = wanted.len > 0 and std.mem.indexOf(u8, normalized, wanted) != null;
        if (!is_exact and !is_partial) continue;

        const media_kind: MediaKind = if (parsed_query.episode != null or record.episode != null) .tv else .movie;
        const season = if (media_kind == .tv) parsed_query.season orelse record.season else null;
        const episode = if (media_kind == .tv) parsed_query.episode orelse record.episode else null;

        const candidate: SearchItem = .{
            .title = try allocator.dupe(u8, base_title),
            .year = record.year,
            .media_kind = media_kind,
            .imdb_id = try allocator.dupe(u8, record.imdb_id),
            .season = season,
            .episode = episode,
            .search_query = try allocator.dupe(u8, original_query),
            .page_url = try searchUrl(allocator, original_query),
        };

        if (containsSearchItem(exact.items, candidate) or containsSearchItem(partial.items, candidate)) continue;
        if (is_exact) try exact.append(allocator, candidate) else try partial.append(allocator, candidate);
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

fn containsSearchItem(items: []const SearchItem, candidate: SearchItem) bool {
    for (items) |item| {
        if (!std.ascii.eqlIgnoreCase(item.title, candidate.title)) continue;
        if (item.year != candidate.year or item.media_kind != candidate.media_kind) continue;
        if (item.season != candidate.season or item.episode != candidate.episode) continue;
        if (item.imdb_id.len > 0 and candidate.imdb_id.len > 0 and !std.mem.eql(u8, item.imdb_id, candidate.imdb_id)) continue;
        return true;
    }
    return false;
}

fn recordMatchesItem(record: SubtitleRecord, item: SearchItem) bool {
    if (item.imdb_id.len > 0 and record.imdb_id.len > 0 and !std.mem.eql(u8, item.imdb_id, record.imdb_id)) return false;
    if (item.year != null and record.year != null and item.year.? != record.year.?) return false;

    const base_title = stripEpisodeSuffix(record.title, record.season, record.episode);
    if (!std.ascii.eqlIgnoreCase(base_title, item.title)) return false;

    if (item.media_kind == .tv) {
        if (item.season) |season| if (record.season != season) return false;
        if (item.episode) |episode| if (record.episode != episode) return false;
    }
    return true;
}

fn parseRecords(allocator: Allocator, body: []const u8) ![]const SubtitleRecord {
    var records: std.ArrayListUnmanaged(SubtitleRecord) = .empty;
    var cursor: usize = 0;
    while (findIgnoreCase(body[cursor..], "<subtitle>")) |relative_start| {
        const start = cursor + relative_start + "<subtitle>".len;
        const relative_end = findIgnoreCase(body[start..], "</subtitle>") orelse break;
        const block = body[start .. start + relative_end];
        cursor = start + relative_end + "</subtitle>".len;

        const id_text = extractTag(block, "id") orelse continue;
        const id = std.fmt.parseInt(i64, std.mem.trim(u8, id_text, " \t\r\n"), 10) catch continue;
        if (id <= 0) continue;
        const raw_title = extractTag(block, "title") orelse continue;
        const title = try decodeEntities(allocator, std.mem.trim(u8, raw_title, " \t\r\n"));
        if (title.len == 0) continue;
        const raw_imdb = extractTag(block, "imdb") orelse "";
        const imdb = std.mem.trim(u8, raw_imdb, " \t\r\n");
        const raw_year = extractTag(block, "year") orelse "";
        const year = std.fmt.parseInt(i64, std.mem.trim(u8, raw_year, " \t\r\n"), 10) catch null;
        const raw_language = extractTag(block, "language") orelse "";
        const language = providerLanguageCode(std.mem.trim(u8, raw_language, " \t\r\n")) orelse continue;
        const raw_release = extractTag(block, "release") orelse "";
        const release = try decodeEntities(allocator, std.mem.trim(u8, raw_release, " \t\r\n"));
        const se = parseRecordSeasonEpisode(title);

        try records.append(allocator, .{
            .id = id,
            .title = title,
            .imdb_id = try allocator.dupe(u8, imdb),
            .year = year,
            .language_code = try allocator.dupe(u8, language),
            .release_name = release,
            .season = se.season,
            .episode = se.episode,
        });
    }
    return records.toOwnedSlice(allocator);
}

fn extractTag(block: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const start = findIgnoreCase(block, open) orelse return null;
    const value_start = start + open.len;
    const end_relative = findIgnoreCase(block[value_start..], close) orelse return null;
    return block[value_start .. value_start + end_relative];
}

const findIgnoreCase = std.ascii.findIgnoreCase;

fn searchUrl(allocator: Allocator, query: []const u8) ![]u8 {
    const encoded = try common.encodeUriComponent(allocator, query);
    return std.fmt.allocPrint(allocator, "{s}?title={s}", .{ search_endpoint, encoded });
}

fn downloadUrl(allocator: Allocator, id: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}?napisId={d}&typ=sr", .{ download_endpoint, id });
}

pub fn providerLanguageCode(input: []const u8) ?[]const u8 {
    if (common.normalizeLanguageCode(input)) |normalized| return normalized;
    if (std.ascii.eqlIgnoreCase(input, "eng")) return "en";
    if (std.ascii.eqlIgnoreCase(input, "pol")) return "pl";
    return null;
}

const SeasonEpisode = struct {
    season: ?u16 = null,
    episode: ?u16 = null,
    marker_start: ?usize = null,
};

fn parseRecordSeasonEpisode(value: []const u8) SeasonEpisode {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (!std.ascii.isDigit(value[i])) continue;
        const season_start = i;
        var cursor = i;
        while (cursor < value.len and std.ascii.isDigit(value[cursor]) and cursor - season_start < 2) : (cursor += 1) {}
        if (cursor == season_start or cursor >= value.len or std.ascii.toLower(value[cursor]) != 'x') continue;
        const season = std.fmt.parseInt(u16, value[season_start..cursor], 10) catch continue;
        cursor += 1;
        const episode_start = cursor;
        while (cursor < value.len and std.ascii.isDigit(value[cursor]) and cursor - episode_start < 3) : (cursor += 1) {}
        if (cursor == episode_start) continue;
        const episode = std.fmt.parseInt(u16, value[episode_start..cursor], 10) catch continue;
        return .{ .season = season, .episode = episode, .marker_start = season_start };
    }
    return .{};
}

fn stripEpisodeSuffix(title: []const u8, season: ?u16, episode: ?u16) []const u8 {
    if (season == null or episode == null) return std.mem.trim(u8, title, " \t\r\n");
    const parsed = parseRecordSeasonEpisode(title);
    const marker = parsed.marker_start orelse return std.mem.trim(u8, title, " \t\r\n");
    return std.mem.trimEnd(u8, title[0..marker], " \t\r\n-:._");
}

fn decodeEntities(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '&') {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }
        const tail = input[i..];
        if (std.mem.startsWith(u8, tail, "&amp;")) {
            try out.append(allocator, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, tail, "&quot;")) {
            try out.append(allocator, '"');
            i += 6;
        } else if (std.mem.startsWith(u8, tail, "&apos;")) {
            try out.append(allocator, '\'');
            i += 6;
        } else if (std.mem.startsWith(u8, tail, "&lt;")) {
            try out.append(allocator, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, tail, "&gt;")) {
            try out.append(allocator, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, tail, "&#")) {
            const semicolon = std.mem.indexOfScalar(u8, tail, ';') orelse {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            if (semicolon > 2 and semicolon <= 10) {
                const numeric = tail[2..semicolon];
                const hex = numeric.len > 1 and (numeric[0] == 'x' or numeric[0] == 'X');
                const digits = if (hex) numeric[1..] else numeric;
                const codepoint = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch {
                    try out.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch {
                    try out.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                try out.appendSlice(allocator, encoded[0..encoded_len]);
                i += semicolon + 1;
            } else {
                try out.append(allocator, input[i]);
                i += 1;
            }
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "napisy24 parses movie and episode queries" {
    const movie = parseQuery("Avatar");
    try std.testing.expectEqualStrings("Avatar", movie.title);
    try std.testing.expectEqual(@as(?u16, null), movie.episode);

    const episode = parseQuery("Breaking Bad S01E01");
    try std.testing.expectEqualStrings("Breaking Bad", episode.title);
    try std.testing.expectEqual(@as(?u16, 1), episode.season);
    try std.testing.expectEqual(@as(?u16, 1), episode.episode);
}

test "napisy24 parses record fragments and groups title results" {
    const fixture =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<subtitle><id>30326</id><title>Avatar</title><imdb>tt0499549</imdb><year>2009</year><release>PROPER.TS.XviD-MAXSPEED</release><language>en</language></subtitle>
        \\<subtitle><id>30327</id><title>Avatar</title><imdb>tt0499549</imdb><year>2009</year><release>OTHER</release><language>pl</language></subtitle>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const records = try parseRecords(arena.allocator(), fixture);
    try std.testing.expectEqual(@as(usize, 2), records.len);
    const items = try buildSearchItems(arena.allocator(), records, "Avatar", .{ .title = "Avatar", .season = null, .episode = null }, "en");
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("tt0499549", items[0].imdb_id);
}

test "napisy24 strips 1x01 episode suffix" {
    const se = parseRecordSeasonEpisode("Breaking Bad 1x01");
    try std.testing.expectEqual(@as(?u16, 1), se.season);
    try std.testing.expectEqual(@as(?u16, 1), se.episode);
    try std.testing.expectEqualStrings("Breaking Bad", stripEpisodeSuffix("Breaking Bad 1x01", se.season, se.episode));
}

test "napisy24 decodes named and numeric entities" {
    const decoded = try decodeEntities(std.testing.allocator, "Collector&#039;s &amp; Director&#x27;s");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("Collector's & Director's", decoded);
}

test "live napisy24 movie and tv search plus downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "napisy24.pl")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    const cases = [_]struct {
        query: []const u8,
        language: []const u8,
        imdb: []const u8,
    }{
        .{ .query = "Avatar", .language = "en", .imdb = "tt0499549" },
        .{ .query = "Breaking Bad S01E01", .language = "en", .imdb = "tt0903747" },
    };

    for (cases) |case| {
        var search = try scraper.search(case.query);
        defer search.deinit();
        var chosen: ?SearchItem = null;
        for (search.items) |item| {
            if (std.mem.eql(u8, item.imdb_id, case.imdb)) {
                chosen = item;
                break;
            }
        }
        const item = chosen orelse return error.TestUnexpectedResult;

        var subtitles = try scraper.fetchSubtitlesBySearchItem(item, case.language);
        defer subtitles.deinit();
        try std.testing.expect(subtitles.subtitles.len > 0);
        const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
            .accept = "application/zip,application/octet-stream,*/*",
            .extra_headers = &.{.{ .name = "referer", .value = "https://napisy24.pl/" }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });
        defer std.testing.allocator.free(download.body);
        try std.testing.expect(download.body.len > 32);
        try std.testing.expect(download.body.len >= 4 and std.mem.eql(u8, download.body[0..4], "PK\x03\x04"));
    }
}
