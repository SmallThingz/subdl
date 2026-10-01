const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.subclub.eu";
const search_endpoint = site ++ "/jutud.php";
const archive_endpoint = site ++ "/subtitles_archivecontent.php";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    season: ?i64,
    episode: ?i64,
    archive_id: []const u8,
    page_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

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
        const url = try std.fmt.allocPrint(a, "{s}?otsing={s}", .{ search_endpoint, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
        });
        return parseSearchHtml(arena, response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const encoded_id = try common.encodeUriComponent(a, item.archive_id);
        const url = try std.fmt.allocPrint(a, "{s}?id={s}", .{ archive_endpoint, encoded_id });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        var anchors = parsed.doc.queryAll("a[href*='down.php'][href*='filename=']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const filename = try common.innerTextTrimmedOwned(a, anchor);
            if (filename.len == 0 or !common.isSubtitleFilename(filename)) continue;

            const download_url = try resolveSubclubHref(a, href);
            if (seen.contains(download_url)) continue;
            try seen.put(a, download_url, {});

            try out.append(a, .{
                .language_code = "et",
                .filename = filename,
                .download_url = download_url,
            });
        }

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try out.toOwnedSlice(a),
        };
    }
};

const ParsedTitle = struct {
    title: []const u8,
    year: ?i64,
    season: ?i64,
    episode: ?i64,
};

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    var parsed = try common.parseHtmlStable(a, body);
    const wanted = try common.normalizeTitle(a, query);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var rows = parsed.doc.queryAll("table#tale_list tbody tr");
    while (rows.next()) |row| {
        const anchor = row.queryOne("a.sc_link[href*='down.php?id=']") orelse continue;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const archive_id = parseArchiveId(href) orelse continue;
        if (seen.contains(archive_id)) continue;
        try seen.put(a, archive_id, {});

        const raw_title = try common.innerTextTrimmedOwned(a, anchor);
        const meta = parseTitle(raw_title);
        if (meta.title.len == 0) continue;

        const title = try a.dupe(u8, meta.title);
        const page_url = try std.fmt.allocPrint(a, "{s}/down.php?id={s}", .{ site, archive_id });
        const item: SearchItem = .{
            .title = title,
            .year = meta.year,
            .media_kind = if (meta.season != null or meta.episode != null) .tv else .movie,
            .season = meta.season,
            .episode = meta.episode,
            .archive_id = try a.dupe(u8, archive_id),
            .page_url = page_url,
        };

        const normalized = try common.normalizeTitle(a, title);
        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) };
}

fn parseArchiveId(href: []const u8) ?[]const u8 {
    const marker = "down.php?id=";
    const start = (std.mem.indexOf(u8, href, marker) orelse return null) + marker.len;
    const tail = href[start..];
    const end = std.mem.indexOfAny(u8, tail, "&#") orelse tail.len;
    if (end == 0) return null;
    for (tail[0..end]) |c| if (!std.ascii.isDigit(c)) return null;
    return tail[0..end];
}

fn parseTitle(input: []const u8) ParsedTitle {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return .{
        .title = trimmed,
        .year = null,
        .season = null,
        .episode = null,
    };
    const close_rel = std.mem.indexOfScalar(u8, trimmed[open + 1 ..], ')') orelse return .{
        .title = std.mem.trim(u8, trimmed[0..open], " \t"),
        .year = null,
        .season = null,
        .episode = null,
    };
    const close = open + 1 + close_rel;
    const year_text = std.mem.trim(u8, trimmed[open + 1 .. close], " \t");
    const year = if (year_text.len == 4)
        std.fmt.parseInt(i64, year_text, 10) catch null
    else
        null;

    var season: ?i64 = null;
    var episode: ?i64 = null;
    if (close + 1 < trimmed.len) {
        const tail = trimmed[close + 1 ..];
        if (std.mem.indexOfScalar(u8, tail, '[')) |lb| {
            if (std.mem.indexOfScalarPos(u8, tail, lb + 1, ']')) |rb| {
                const token = tail[lb + 1 .. rb];
                if (std.mem.indexOfScalar(u8, token, 'x')) |x| {
                    season = std.fmt.parseInt(i64, std.mem.trim(u8, token[0..x], " \t"), 10) catch null;
                    episode = std.fmt.parseInt(i64, std.mem.trim(u8, token[x + 1 ..], " \t"), 10) catch null;
                }
            }
        }
    }

    return .{
        .title = std.mem.trim(u8, trimmed[0..open], " \t"),
        .year = year,
        .season = season,
        .episode = episode,
    };
}

fn resolveSubclubHref(allocator: Allocator, href: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, href, "https://") or std.mem.startsWith(u8, href, "http://"))
        return allocator.dupe(u8, href);
    if (std.mem.startsWith(u8, href, "../"))
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ site, href[3..] });
    if (std.mem.startsWith(u8, href, "./"))
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ site, href[2..] });
    if (std.mem.startsWith(u8, href, "/"))
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ site, href });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ site, href });
}

test "subclub parses movie and episode rows and archive files" {
    const search_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var search = try parseSearchHtml(
        search_arena,
        \\<table id="tale_list"><tbody>
        \\<tr><td></td><td><a class="sc_link" href="../down.php?id=10100">Inception (2010)</a></td></tr>
        \\<tr><td></td><td><a class="sc_link" href="../down.php?id=18128">Chernobyl (2019) [01x01]</a></td></tr>
        \\</tbody></table>
    ,
        "Inception",
    );
    defer search.deinit();

    try std.testing.expectEqual(@as(usize, 2), search.items.len);
    try std.testing.expectEqualStrings("Inception", search.items[0].title);
    try std.testing.expect(search.items[0].media_kind == .movie);
    try std.testing.expectEqual(@as(?i64, 2010), search.items[0].year);
    try std.testing.expect(search.items[1].media_kind == .tv);
    try std.testing.expectEqual(@as(?i64, 1), search.items[1].season);
    try std.testing.expectEqual(@as(?i64, 1), search.items[1].episode);

    try std.testing.expectEqualStrings("10100", parseArchiveId("../down.php?id=10100").?);
    const resolved = try resolveSubclubHref(std.testing.allocator, "../down.php?id=10100&filename=YWJjLnNydA==");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(
        "https://www.subclub.eu/down.php?id=10100&filename=YWJjLnNydA==",
        resolved,
    );
}

test "live subclub movie and tv direct downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subclub.eu")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Inception");
    defer movie.deinit();
    const movie_idx = findMovie(movie.items, "Inception", 2010) orelse return error.TestUnexpectedResult;
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[movie_idx]);
    defer movie_subtitles.deinit();
    if (movie_subtitles.subtitles.len == 0) return error.TestUnexpectedResult;
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, movie_download.body, "-->") != null);

    var tv = try scraper.search("Chernobyl");
    defer tv.deinit();
    const tv_idx = findEpisode(tv.items, "Chernobyl", 1, 1) orelse return error.TestUnexpectedResult;
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[tv_idx]);
    defer tv_subtitles.deinit();
    if (tv_subtitles.subtitles.len == 0) return error.TestUnexpectedResult;
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, tv_download.body, "-->") != null);
}

fn findMovie(items: []const SearchItem, title: []const u8, year: i64) ?usize {
    for (items, 0..) |item, idx| {
        if (item.media_kind == .movie and item.year == year and std.ascii.eqlIgnoreCase(item.title, title))
            return idx;
    }
    return null;
}

fn findEpisode(items: []const SearchItem, title: []const u8, season: i64, episode: i64) ?usize {
    for (items, 0..) |item, idx| {
        if (item.media_kind == .tv and item.season == season and item.episode == episode and std.ascii.eqlIgnoreCase(item.title, title))
            return idx;
    }
    return null;
}
