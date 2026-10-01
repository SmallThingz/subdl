const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://subtitri.do.am";

pub const SearchItem = common.SearchLink;

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
        const url = try std.fmt.allocPrint(a, "{s}/search/?q={s}", .{ site, encoded });
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

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
        });
        var parsed = try common.parseHtmlStable(a, response.body);
        const link = parsed.doc.queryOne("a.hvr[href]") orelse return error.MissingField;
        const href = common.getAttributeValueSafe(link, "href") orelse return error.MissingField;
        const download_url = try common.resolveUrl(a, site, href);

        const slugged = try common.asciiSlug(a, item.title);
        const filename = try std.fmt.allocPrint(a, "subtitri-{s}.zip", .{slugged});
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = "lv",
            .filename = filename,
            .download_url = download_url,
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
    var seen = std.StringHashMapUnmanaged(void).empty;

    var blocks = parsed.doc.queryAll("table.eBlock");
    while (blocks.next()) |block| {
        const anchor = block.queryOne("div.eTitle a[href]") orelse continue;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const title = try common.innerTextTrimmedOwned(a, anchor);
        if (title.len == 0) continue;

        const normalized = try common.normalizeTitle(a, title);
        if (std.mem.indexOf(u8, normalized, wanted) == null and std.mem.indexOf(u8, wanted, normalized) == null) continue;

        const page_url = try common.resolveUrl(a, site, href);
        if (seen.contains(page_url)) continue;
        try seen.put(a, page_url, {});

        const item: SearchItem = .{
            .title = title,
            .page_url = page_url,
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

test "subtitri parses exact movie search result" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        "<table class=\"eBlock\"><tr><td><div class=\"eTitle\"><a href=\"/load/the_matrix/13-1-0-1301\"><b>The</b> <b>Matrix</b></a></div></td></tr></table>",
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqualStrings("https://subtitri.do.am/load/the_matrix/13-1-0-1301", response.items[0].page_url);
}

test "live subtitri movie download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitri.do.am")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len == 1);

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
