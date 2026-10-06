const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://subsunacs.net";
const search_url = site ++ "/search.php";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    page_url: []const u8,
    download_page_url: []const u8,
};

pub const SubtitleItem = common.DownloadSubtitleFile;

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

        const encoded = try common.encodeUriComponent(a, std.mem.trim(u8, query, " \t\r\n"));
        const payload = try std.fmt.allocPrint(a, "m={s}&l=1&c=&y=&a=&d=&u=&g=&t=&imdbcheck=1", .{encoded});
        const headers = [_]std.http.Header{.{ .name = "referer", .value = site ++ "/index.php" }};
        const response = try common.fetchBytes(self.client, a, search_url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .max_attempts = 2,
            .cache = false,
            .require_public_origin = true,
        });

        return parseSearchHtml(common.takeArena(&arena), response.body);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        try validateProviderEndpoint(item.page_url);
        try validateProviderEndpoint(item.download_page_url);

        const headers = [_]std.http.Header{.{ .name = "referer", .value = search_url }};
        const response = try common.fetchBytes(self.client, a, item.download_page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .max_attempts = 2,
            .cache = false,
            .require_public_origin = true,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var anchors = parsed.doc.queryAll("a[href*='getentry.php']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const filename = try common.innerTextTrimmedOwned(a, anchor);
            if (!isSubtitleFilename(filename)) continue;
            try subtitles.append(a, .{
                .filename = filename,
                .download_url = try resolveProviderUrl(a, href),
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }
};

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var anchors = parsed.doc.queryAll("td.tdMovie a[href^='/subtitles/']");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (std.mem.endsWith(u8, href, "/!")) continue;
        const title = try common.innerTextTrimmedOwned(a, anchor);
        if (title.len == 0) continue;

        const page_url = try resolveProviderUrl(a, href);
        if (seen.contains(page_url)) continue;
        try seen.put(a, page_url, {});

        const cell = anchor.parentNode();
        const year = if (cell) |node|
            if (node.queryOne("span.smGray")) |year_node|
                parseYear(try common.innerTextTrimmedOwned(a, year_node))
            else
                null
        else
            null;
        const download_page_url = if (std.mem.endsWith(u8, page_url, "/"))
            try std.fmt.allocPrint(a, "{s}!", .{page_url})
        else
            try std.fmt.allocPrint(a, "{s}/!", .{page_url});

        try items.append(a, .{
            .title = title,
            .year = year,
            .page_url = page_url,
            .download_page_url = download_page_url,
        });
    }

    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn parseYear(value: []const u8) ?i64 {
    var start: ?usize = null;
    var end: usize = 0;
    for (value, 0..) |c, idx| {
        if (std.ascii.isDigit(c)) {
            if (start == null) start = idx;
            end = idx + 1;
        } else if (start != null) {
            break;
        }
    }
    const from = start orelse return null;
    if (end <= from) return null;
    return std.fmt.parseInt(i64, value[from..end], 10) catch null;
}

fn isSubtitleFilename(filename: []const u8) bool {
    if (filename.len == 0) return false;
    if (std.ascii.endsWithIgnoreCase(filename, ".srt")) return true;
    if (std.ascii.endsWithIgnoreCase(filename, ".sub")) return true;
    if (std.ascii.endsWithIgnoreCase(filename, ".ass")) return true;
    if (std.ascii.endsWithIgnoreCase(filename, ".ssa")) return true;
    if (std.ascii.endsWithIgnoreCase(filename, ".vtt")) return true;
    if (std.ascii.endsWithIgnoreCase(filename, ".txt")) {
        return std.ascii.findIgnoreCase(filename, "subsunacs") == null and
            std.ascii.findIgnoreCase(filename, "readme") == null;
    }
    return false;
}

fn resolveProviderUrl(allocator: Allocator, href: []const u8) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderEndpoint(resolved);
    return resolved;
}

fn validateProviderEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

test "subsunacs rejects unsafe provider links" {
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@subsunacs.net/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://subsunacs.net.evil.com/private"));
}

test "subsunacs parses movie search and direct entries" {
    const search_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var search = try parseSearchHtml(search_arena,
        \\<table><tr onmouseover="x"><td class="tdMovie"><a href="/subtitles/The_Matrix-103573/">The Matrix</a><span class="smGray">&nbsp;(1999)</span></td></tr></table>
    );
    defer search.deinit();
    try std.testing.expectEqual(@as(usize, 1), search.items.len);
    try std.testing.expectEqualStrings("The Matrix", search.items[0].title);
    try std.testing.expectEqual(@as(?i64, 1999), search.items[0].year);
    try std.testing.expectEqualStrings("https://subsunacs.net/subtitles/The_Matrix-103573/!", search.items[0].download_page_url);

    try std.testing.expect(isSubtitleFilename("The.Matrix.1999.srt"));
    try std.testing.expect(!isSubtitleFilename("subsunacs.net_103573.txt"));
}

test "live subsunacs movie search, listing and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subsunacs.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);

    const response = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(response.body);
    try std.testing.expect(response.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "-->") != null);
}

test "live subsunacs episode search" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subsunacs.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Game of Thrones 01 01");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
}
