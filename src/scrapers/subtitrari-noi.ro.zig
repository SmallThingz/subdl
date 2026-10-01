const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://www.subtitrari-noi.ro";
const search_url = site ++ "/paginare_filme.php";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    page_url: []const u8,
    download_url: []const u8,
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

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const payload = try std.fmt.allocPrint(
            a,
            "search_q=1&tip=2&an=Toti%20anii&gen=Toate&cautare={s}&query_q={s}",
            .{ encoded, encoded },
        );
        const headers = [_]std.http.Header{
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
            .{ .name = "origin", .value = site },
            .{ .name = "referer", .value = site ++ "/" },
        };
        const response = try common.fetchBytes(self.client, a, search_url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded; charset=UTF-8",
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .cache = false,
            .max_attempts = 3,
        });

        return parseSearchHtml(arena, response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const filename = try filenameFromDownloadUrl(a, item.download_url, item.title);
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = "ro",
            .filename = filename,
            .download_url = try a.dupe(u8, item.download_url),
        };
        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
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
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    var rounds = parsed.doc.queryAll("div#round");
    while (rounds.next()) |round| {
        const title_anchor = round.queryOne("div#content-main a[href]") orelse continue;
        const download_anchor = round.queryOne("p.buton a[href]") orelse continue;
        const page_href = common.getAttributeValueSafe(title_anchor, "href") orelse continue;
        const download_href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
        const raw_title = try common.innerTextTrimmedOwned(a, title_anchor);
        if (raw_title.len == 0) continue;

        const split = common.splitTrailingYear(raw_title);
        const title = try a.dupe(u8, split.title);
        const normalized = try common.normalizeTitle(a, title);
        const item: SearchItem = .{
            .title = title,
            .year = split.year,
            .page_url = try common.resolveUrl(a, site, page_href),
            .download_url = try normalizeDownloadUrl(a, download_href),
        };

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

fn normalizeDownloadUrl(allocator: Allocator, href: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, href, "https://")) |idx| return allocator.dupe(u8, href[idx..]);
    if (std.mem.indexOf(u8, href, "http://")) |idx| return allocator.dupe(u8, href[idx..]);
    return common.resolveUrl(allocator, site, href);
}

fn filenameFromDownloadUrl(allocator: Allocator, url: []const u8, title: []const u8) ![]u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..end];
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const filename = path[slash + 1 ..];
        if (filename.len > 0 and std.ascii.endsWithIgnoreCase(filename, ".zip"))
            return allocator.dupe(u8, filename);
    }
    return std.fmt.allocPrint(allocator, "{s}.zip", .{title});
}

test "subtitrari-noi parses exact result and prefixed absolute archive url" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<div id="round"><div id="content">
        \\<div id="content-main"><p><a href="https://www.subtitrari-noi.ro/index.php?page=movie_details&amp;id=87170">Reacher (2022)</a></p></div>
        \\<div id="content-right"><p class="buton"><a href="87170-https://subtitrari-noi.ro/Arhive/Reacher.zip">Descarca</a></p></div>
        \\</div></div>
    ,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Reacher", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 2022), response.items[0].year);
    try std.testing.expectEqualStrings("https://subtitrari-noi.ro/Arhive/Reacher.zip", response.items[0].download_url);
}

test "live subtitrari-noi movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitrari-noi.ro")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix Resurrections");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Reacher");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}
