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

pub const SubtitleItem = struct {
    language_code: []const u8,
    filename: []const u8,
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
        if (parsed_query.title.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted = try normalizeTitle(a, parsed_query.title);

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

        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
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
            const normalized = try normalizeTitle(allocator, raw_title);
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

        var parsed = try common.parseHtmlStable(a, response.body);
        var episode_matches: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var fallback: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        var anchors = parsed.doc.queryAll("a[href]");
        while (anchors.next()) |anchor| {
            if (episode_matches.items.len + fallback.items.len >= max_subtitle_items * 2) break;
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const filename = try common.innerTextTrimmedOwned(a, anchor);
            if (!isSupportedFilename(filename)) continue;

            const download_url = try common.resolveUrl(a, site, href);
            if (seen.contains(download_url)) continue;
            try seen.put(a, download_url, {});

            const subtitle: SubtitleItem = .{
                .language_code = try a.dupe(u8, item.language_code),
                .filename = filename,
                .download_url = download_url,
            };
            if (item.episode) |episode| {
                if (filenameMatchesEpisode(filename, item.season orelse 1, episode))
                    try episode_matches.append(a, subtitle)
                else
                    try fallback.append(a, subtitle);
            } else {
                try fallback.append(a, subtitle);
            }
        }

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        if (episode_matches.items.len > 0) {
            try subtitles.appendSlice(a, episode_matches.items[0..@min(max_subtitle_items, episode_matches.items.len)]);
        } else {
            try subtitles.appendSlice(a, fallback.items[0..@min(max_subtitle_items, fallback.items.len)]);
        }

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }
};

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
    var sxe_buf: [16]u8 = undefined;
    const sxe = std.fmt.bufPrint(&sxe_buf, "S{d:0>2}E{d:0>2}", .{ season, episode }) catch return false;
    if (indexOfIgnoreCase(filename, sxe) != null) return true;

    var x_buf: [16]u8 = undefined;
    const x = std.fmt.bufPrint(&x_buf, "{d:0>2}x{d:0>2}", .{ season, episode }) catch return false;
    if (indexOfIgnoreCase(filename, x) != null) return true;

    var episode_buf: [24]u8 = undefined;
    const episode_text = std.fmt.bufPrint(&episode_buf, "episode {d}", .{episode}) catch return false;
    return indexOfIgnoreCase(filename, episode_text) != null;
}

fn parseQuery(input: []const u8) ParsedQuery {
    const trimmed = std.mem.trim(u8, input, " \\t\\r\\n");
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
        const title = std.mem.trim(u8, trimmed[0..i], " \\t\\r\\n-._");
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

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                matches = false;
                break;
            }
        }
        if (matches) return i;
    }
    return null;
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
