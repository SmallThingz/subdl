const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://kitsunekko.net";
const english_catalog = site ++ "/dirlist.php?dir=subtitles%2F";
const japanese_catalog = site ++ "/dirlist.php?dir=subtitles%2Fjapanese%2F";
const max_search_items = 24;
const max_subtitle_items = 100;

pub const SearchItem = struct {
    title: []const u8,
    language_code: []const u8,
    season: ?u16,
    episode: ?u16,
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
        const wanted = try common.normalizeTitle(a, parsed_query.title);

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        try self.appendCatalogMatches(a, english_catalog, "en", parsed_query, wanted, &exact, &partial, &seen);
        try self.appendCatalogMatches(a, japanese_catalog, "ja", parsed_query, wanted, &exact, &partial, &seen);

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        const exact_count = @min(exact.items.len, max_search_items);
        try items.appendSlice(a, exact.items[0..exact_count]);
        if (items.items.len < max_search_items) {
            const remaining = max_search_items - items.items.len;
            try items.appendSlice(a, partial.items[0..@min(remaining, partial.items.len)]);
        }

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    fn appendCatalogMatches(
        self: *Scraper,
        allocator: Allocator,
        catalog_url: []const u8,
        language_code: []const u8,
        parsed_query: ParsedQuery,
        wanted: []const u8,
        exact: *std.ArrayListUnmanaged(SearchItem),
        partial: *std.ArrayListUnmanaged(SearchItem),
        seen: *std.StringHashMapUnmanaged(void),
    ) !void {
        const response = try common.fetchBytes(self.client, allocator, catalog_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = true,
            .max_attempts = 2,
        });

        var parsed = try common.parseHtmlStable(allocator, response.body);
        var anchors = parsed.doc.queryAll("a[href*='dirlist.php?dir=']");
        while (anchors.next()) |anchor| {
            if (exact.items.len + partial.items.len >= max_search_items * 4) break;
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.mem.indexOf(u8, href, "&sort=") != null or std.mem.indexOf(u8, href, "&amp;sort=") != null) continue;

            const raw_title = try common.innerTextTrimmedOwned(allocator, anchor);
            if (raw_title.len == 0) continue;
            const normalized = try common.normalizeTitle(allocator, raw_title);
            if (normalized.len == 0) continue;

            const is_exact = std.mem.eql(u8, normalized, wanted);
            const is_partial = std.mem.indexOf(u8, normalized, wanted) != null or std.mem.indexOf(u8, wanted, normalized) != null;
            if (!is_exact and !is_partial) continue;

            const page_url = try common.resolveUrl(allocator, site, href);
            if (seen.contains(page_url)) continue;
            try seen.put(allocator, page_url, {});

            const item: SearchItem = .{
                .title = try allocator.dupe(u8, raw_title),
                .language_code = language_code,
                .season = parsed_query.season,
                .episode = parsed_query.episode,
                .page_url = page_url,
            };
            if (is_exact)
                try exact.append(allocator, item)
            else
                try partial.append(allocator, item);
        }
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
        });

        const subtitles = try parseSubtitleFiles(a, response.body, item);

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn parseSubtitleFiles(allocator: Allocator, body: []const u8, item: SearchItem) ![]const SubtitleItem {
    var parsed = try common.parseHtmlStable(allocator, body);
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var anchors = parsed.doc.queryAll("a[href]");
    while (anchors.next()) |anchor| {
        if (subtitles.items.len >= max_subtitle_items) break;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const filename = try common.innerTextTrimmedOwned(allocator, anchor);
        if (!isSupportedFilename(filename)) continue;
        if (item.episode) |episode| {
            if (!filenameMatchesEpisode(filename, item.season orelse 1, episode)) continue;
        }
        const download_url = try common.resolveUrl(allocator, site, href);
        if (seen.contains(download_url)) continue;
        try seen.put(allocator, download_url, {});
        try subtitles.append(allocator, .{
            .language_code = try allocator.dupe(u8, item.language_code),
            .filename = filename,
            .download_url = download_url,
        });
    }
    return subtitles.toOwnedSlice(allocator);
}

fn isSupportedFilename(filename: []const u8) bool {
    // Keep the user path on plain subtitle files or ZIP. Kitsunekko also hosts
    // RAR and 7z packs, but those are intentionally not advertised because
    // extraction support is less reliable and equivalent direct/ZIP files exist.
    return std.ascii.endsWithIgnoreCase(filename, ".srt") or
        std.ascii.endsWithIgnoreCase(filename, ".ass") or
        std.ascii.endsWithIgnoreCase(filename, ".ssa") or
        std.ascii.endsWithIgnoreCase(filename, ".vtt") or
        std.ascii.endsWithIgnoreCase(filename, ".zip");
}

fn filenameMatchesEpisode(filename: []const u8, season: u16, episode: u16) bool {
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

fn filenameMatchesEpisode(filename: []const u8, season: u16, episode: u16) bool {
    var sxe_buf: [16]u8 = undefined;
    const sxe = std.fmt.bufPrint(&sxe_buf, "S{d:0>2}E{d:0>2}", .{ season, episode }) catch return false;
    if (containsNumericToken(filename, sxe)) return true;

    var x_buf: [16]u8 = undefined;
    const x = std.fmt.bufPrint(&x_buf, "{d:0>2}x{d:0>2}", .{ season, episode }) catch return false;
    if (containsNumericToken(filename, x)) return true;

    var episode_buf: [24]u8 = undefined;
    const episode_text = std.fmt.bufPrint(&episode_buf, "episode {d}", .{episode}) catch return false;
    return containsNumericToken(filename, episode_text);
}
fn findResult(items: []const SearchItem, title: []const u8, language_code: []const u8) ?usize {
    for (items, 0..) |item, idx| {
        if (std.ascii.eqlIgnoreCase(item.title, title) and std.mem.eql(u8, item.language_code, language_code))
            return idx;
    }
    return null;
}

fn firstDirectSubtitle(items: []const SubtitleItem) ?usize {
    for (items, 0..) |item, idx| {
        if (!std.ascii.endsWithIgnoreCase(item.filename, ".zip")) return idx;
    }
    return if (items.len > 0) 0 else null;
}

test "kitsunekko parses episode query and filters unsafe archive formats" {
    const parsed = parseQuery("Death Note S01E01");
    try std.testing.expectEqualStrings("Death Note", parsed.title);
    try std.testing.expectEqual(@as(?u16, 1), parsed.season);
    try std.testing.expectEqual(@as(?u16, 1), parsed.episode);

    try std.testing.expect(filenameMatchesEpisode("Death Note Episode 1 - Animelon.ass", 1, 1));
    try std.testing.expect(filenameMatchesEpisode("Death.Note.S01E01.en.srt", 1, 1));
    try std.testing.expect(!filenameMatchesEpisode("Death.Note.S01E02.en.srt", 1, 1));

    try std.testing.expect(isSupportedFilename("episode.srt"));
    try std.testing.expect(isSupportedFilename("series.zip"));
    try std.testing.expect(!isSupportedFilename("series.rar"));
    try std.testing.expect(!isSupportedFilename("series.7z"));
}

test "live kitsunekko english and japanese movie plus tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "kitsunekko.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Spirited Away");
    defer movie.deinit();

    const en_idx = findResult(movie.items, "Spirited Away", "en") orelse return error.TestUnexpectedResult;
    var en_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[en_idx]);
    defer en_subtitles.deinit();
    const en_sub_idx = firstDirectSubtitle(en_subtitles.subtitles) orelse return error.TestUnexpectedResult;
    const en_download = try common.fetchBytes(&client, std.testing.allocator, en_subtitles.subtitles[en_sub_idx].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(en_download.body);
    try std.testing.expect(en_download.body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, en_download.body, "-->") != null);

    const ja_idx = findResult(movie.items, "Spirited Away (Sen to Chihiro no Kamikakushi)", "ja") orelse
        return error.TestUnexpectedResult;
    var ja_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[ja_idx]);
    defer ja_subtitles.deinit();
    const ja_sub_idx = firstDirectSubtitle(ja_subtitles.subtitles) orelse return error.TestUnexpectedResult;
    const ja_download = try common.fetchBytes(&client, std.testing.allocator, ja_subtitles.subtitles[ja_sub_idx].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(ja_download.body);
    try std.testing.expect(ja_download.body.len > 100);
    try std.testing.expect(ja_download.body.len >= 2);
    try std.testing.expect(ja_download.body[0] == 0xff and ja_download.body[1] == 0xfe);

    var tv = try scraper.search("Death Note S01E01");
    defer tv.deinit();
    const tv_idx = findResult(tv.items, "Death Note", "en") orelse return error.TestUnexpectedResult;
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[tv_idx]);
    defer tv_subtitles.deinit();
    if (tv_subtitles.subtitles.len == 0) return error.TestUnexpectedResult;
    try std.testing.expect(filenameMatchesEpisode(tv_subtitles.subtitles[0].filename, 1, 1));

    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, tv_download.body, "[Script Info]") != null);
}

test "explicit kitsunekko episode queries do not return unrelated fallback files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "<a href='/2.srt'>Show.S01E02.srt</a><a href='/pack.zip'>Show.zip</a>";
    var item: SearchItem = .{
        .title = "Show",
        .language_code = "en",
        .season = 1,
        .episode = 1,
        .page_url = "https://kitsunekko.net/dirlist.php?dir=subtitles%2FShow%2F",
    };
    const missing = try parseSubtitleFiles(a, body, item);
    try std.testing.expectEqual(@as(usize, 0), missing.len);
    item.episode = 2;
    const matching = try parseSubtitleFiles(a, body, item);
    try std.testing.expectEqual(@as(usize, 1), matching.len);
    try std.testing.expectEqualStrings("Show.S01E02.srt", matching[0].filename);
    item.episode = null;
    const series = try parseSubtitleFiles(a, body, item);
    try std.testing.expectEqual(@as(usize, 2), series.len);
}

test "episode tokens do not match longer episode numbers" {
    for ([_][]const u8{ "Show Episode 10.ass", "Show.S01E010.ass", "Show.01x010.ass", "Show - 010.ass", "010.ass", "Show 1080p.ass" }) |name| try std.testing.expect(!filenameMatchesEpisode(name, 1, 1));
    for ([_][]const u8{ "Show Episode 1.ass", "Show.S01E01.ass", "Show.01x01.ass", "Show - 01.ass", "Show 01v2.ass", "01.ass" }) |name| try std.testing.expect(filenameMatchesEpisode(name, 1, 1));
    try std.testing.expect(!filenameMatchesEpisode("Show - 01.ass", 2, 1));

    for ([_][]const u8{
        "Show - 03 [FLAC 2.0].ass",
        "Show - 03 [02].ass",
        "Show S01E03 [02].ass",
        "Show Episode 3 [02].ass",
        "Show 01x03 [02].ass",
        "Show S02E02 [02].ass",
        "Show [FLAC 2.0].ass",
    }) |name| try std.testing.expect(!filenameMatchesEpisode(name, 1, 2));
    for ([_][]const u8{ "Show S1E2.ass", "Show 1x2.ass", "Show Episode 02.ass", "Show - 02 [FLAC 2.0].ass" }) |name| try std.testing.expect(filenameMatchesEpisode(name, 1, 2));
}

test "kitsunekko later-season selection requires a season-qualified episode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        "<a href='/ambiguous.srt'>Show Episode 02.srt</a>" ++
        "<a href='/short.srt'>Show E02.srt</a>" ++
        "<a href='/first.srt'>Show S01E02.srt</a>" ++
        "<a href='/second.srt'>Show S02E02.srt</a>";
    const subtitles = try parseSubtitleFiles(arena.allocator(), body, .{
        .title = "Show",
        .language_code = "en",
        .season = 2,
        .episode = 2,
        .page_url = site ++ "/dirlist.php?dir=subtitles%2FShow%2F",
    });
    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings("Show S02E02.srt", subtitles[0].filename);
    try std.testing.expect(filenameMatchesEpisode("Show 2x02.srt", 2, 2));
}

test "kitsunekko E-only markers respect separated season context" {
    for ([_][]const u8{
        "Show S02 E02.ass",
        "Show Season 2 Episode 02.ass",
        "Show Season.2.Episode.02.ass",
        "Show E02 S02.ass",
        "Show 2x03 E02.ass",
        "Show E02 2x03.ass",
    }) |name| {
        try std.testing.expect(!filenameMatchesEpisode(name, 1, 2));
        try std.testing.expect(filenameMatchesEpisode(name, 2, 2));
    }
    for ([_][]const u8{ "Show E02.ass", "Show Episode 02.ass", "Show S01 E02.ass", "Show Season 1 Episode 02.ass" }) |name| {
        try std.testing.expect(filenameMatchesEpisode(name, 1, 2));
        try std.testing.expect(!filenameMatchesEpisode(name, 2, 2));
    }
    try std.testing.expect(!filenameMatchesEpisode("Show S01 Season 2 Episode 02.ass", 1, 2));
    try std.testing.expect(!filenameMatchesEpisode("Show S01 Season 2 Episode 02.ass", 2, 2));
    try std.testing.expect(!filenameMatchesEpisode("Show S02E03 E02.ass", 1, 2));
    try std.testing.expect(filenameMatchesEpisode("Show S02E02.ass", 2, 2));
    try std.testing.expect(filenameMatchesEpisode("Show 100x03 E02.ass", 1, 2));
    try std.testing.expect(filenameMatchesEpisode("Show 2x1000 E02.ass", 1, 2));
    try std.testing.expect(filenameMatchesEpisode("Show 2x03audio E02.ass", 1, 2));
}
