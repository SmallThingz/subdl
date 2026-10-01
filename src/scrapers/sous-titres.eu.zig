const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://www.sous-titres.eu";

pub const MediaKind = common.MediaKind;

pub const SearchItem = common.MediaSearchLink;

pub const SubtitleItem = struct {
    language_code: ?[]const u8,
    filename: []const u8,
    download_url: []const u8,
};

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
        const url = try std.fmt.allocPrint(a, "{s}/search.html?q={s}", .{ site, encoded });
        const headers = [_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }};
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .max_attempts = 2,
        });

        return parseSearchHtml(arena, response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const headers = [_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }};
        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .max_attempts = 2,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var anchors = parsed.doc.queryAll("a.subList");
        const section = switch (item.media_kind) {
            .movie => site ++ "/films",
            .tv => site ++ "/series",
        };
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const filename_node = anchor.queryOne("span.filenameSerie") orelse
                anchor.queryOne("span.filenameFilm") orelse continue;
            const filename = try common.innerTextTrimmedOwned(a, filename_node);
            if (filename.len == 0) continue;
            const language_code = if (anchor.queryOne("span.lang img[alt]")) |img|
                try common.dupOptional(a, common.getAttributeValueSafe(img, "alt"))
            else
                null;

            try subtitles.append(a, .{
                .language_code = language_code,
                .filename = filename,
                .download_url = try common.resolveUrl(a, section, href),
            });
        }

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }
};

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);

    const wanted = try common.normalizeTitle(a, query);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var other: std.ArrayListUnmanaged(SearchItem) = .empty;

    var rows = parsed.doc.queryAll("li");
    while (rows.next()) |row| {
        const classes = common.getAttributeValueSafe(row, "class") orelse continue;
        const media_kind: MediaKind = if (hasClassToken(classes, "film"))
            .movie
        else if (hasClassToken(classes, "serie"))
            .tv
        else
            continue;

        const title_anchor = row.queryOne("h3 a[href]") orelse continue;
        const href = common.getAttributeValueSafe(title_anchor, "href") orelse continue;
        const title = if (row.queryOne("img[alt]")) |img|
            try a.dupe(u8, common.getAttributeValueSafe(img, "alt") orelse "")
        else
            try common.innerTextTrimmedOwned(a, title_anchor);
        if (title.len == 0) continue;

        const item: SearchItem = .{
            .title = title,
            .media_kind = media_kind,
            .page_url = try common.resolveUrl(a, site, href),
        };
        const normalized = try common.normalizeTitle(a, title);
        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(a, item)
        else
            try other.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, other.items);
    return .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) };
}

fn hasClassToken(classes: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, classes, " \t\r\n");
    while (it.next()) |value| if (std.mem.eql(u8, value, token)) return true;
    return false;
}

test "sous-titres parses exact movie and series rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<ul>" ++
        "<li class=\"film exact\"><img alt=\"The Matrix\"/><h3><a href=\"films/the_matrix.html\">The Matrix (1999)</a></h3></li>" ++
        "<li class=\"serie exact\"><img alt=\"Chernobyl\"/><h3><a href=\"series/chernobyl.html\">Chernobyl</a></h3></li>" ++
        "</ul>";
    var response = try parseSearchHtml(
        arena,
        fixture,
        "Chernobyl",
    );
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings("Chernobyl", response.items[0].title);
    try std.testing.expect(response.items[0].media_kind == .tv);
    try std.testing.expectEqualStrings("https://www.sous-titres.eu/series/chernobyl.html", response.items[0].page_url);
}

test "live sous-titres movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "sous-titres.eu")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    try std.testing.expect(movie.items[0].media_kind == .movie);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    try std.testing.expect(movie_subtitles.subtitles.len > 0);

    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Chernobyl");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    try std.testing.expect(tv.items[0].media_kind == .tv);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    try std.testing.expect(tv_subtitles.subtitles.len > 0);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(tv_subtitles.subtitles[0].filename, "Chernobyl") != null);
}
