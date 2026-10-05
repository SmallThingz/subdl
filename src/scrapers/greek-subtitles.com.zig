const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlNode = HtmlParseOptions.GetNode();
const site = "https://gr.greek-subtitles.com";
const download_site = "https://www.greeksubtitles.info";

pub const SearchItem = struct {
    title: []const u8,
    language_code: ?[]const u8,
    page_url: []const u8,
    download_url: []const u8,
    downloads: ?i64,
};

pub const SubtitleItem = struct {
    language_code: ?[]const u8,
    filename: []const u8,
    page_url: []const u8,
    download_url: []const u8,
};

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.SubtitlesResponse(SubtitleItem);

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
        const url = try std.fmt.allocPrint(a, "{s}/search.php?name={s}", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .max_attempts = 2,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var rows = parsed.doc.queryAll("tr");
        while (rows.next()) |row| {
            const anchor = row.queryOne("td.latest_name a[href*='/subtitles/']") orelse continue;
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const subtitle_id = trailingNumericPathSegment(href) orelse continue;
            const title = try common.innerTextTrimmedOwned(a, anchor);
            if (title.len == 0) continue;

            const language_code = if (row.queryOne("td.latest_name img[src*='/flags/']")) |img|
                try languageFromFlag(a, common.getAttributeValueSafe(img, "src") orelse "")
            else
                null;
            const downloads = if (row.queryOne("td.latest_downloads")) |node|
                parseOptionalInt(try common.innerTextTrimmedOwned(a, node))
            else
                null;

            try items.append(a, .{
                .title = title,
                .language_code = language_code,
                .page_url = try common.resolveUrl(a, site, href),
                .download_url = try std.fmt.allocPrint(a, "{s}/getp.php?id={s}", .{ download_site, subtitle_id }),
                .downloads = downloads,
            });
        }

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const filename = try a.dupe(u8, item.title);
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try common.dupOptional(a, item.language_code),
            .filename = filename,
            .page_url = try a.dupe(u8, item.page_url),
            .download_url = try a.dupe(u8, item.download_url),
        };
        return .{ .arena = arena, .subtitles = subtitles };
    }
};

fn languageFromFlag(allocator: Allocator, src: []const u8) !?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, src, '/') orelse return null;
    const name = src[slash + 1 ..];
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    if (dot == 0) return null;
    const raw = name[0..dot];
    if (std.ascii.eqlIgnoreCase(raw, "el") or std.ascii.eqlIgnoreCase(raw, "gr")) return try allocator.dupe(u8, "el");
    if (std.ascii.eqlIgnoreCase(raw, "en")) return try allocator.dupe(u8, "en");
    return null;
}

fn trailingNumericPathSegment(value: []const u8) ?[]const u8 {
    var trimmed = std.mem.trimEnd(u8, value, "/");
    const query = std.mem.indexOfAny(u8, trimmed, "?#");
    if (query) |idx| trimmed = trimmed[0..idx];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
    const id = trimmed[slash + 1 ..];
    if (id.len == 0) return null;
    for (id) |c| if (!std.ascii.isDigit(c)) return null;
    return id;
}

fn parseOptionalInt(value: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn parseSearchFixture(allocator: Allocator, body: []const u8) ![]const SearchItem {
    var parsed = try common.parseHtmlStable(allocator, body);
    defer parsed.deinit();
    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    var rows = parsed.doc.queryAll("tr");
    while (rows.next()) |row| {
        const anchor = row.queryOne("td.latest_name a[href*='/subtitles/']") orelse continue;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const subtitle_id = trailingNumericPathSegment(href) orelse continue;
        const title = try common.innerTextTrimmedOwned(allocator, anchor);
        const language_code = if (row.queryOne("td.latest_name img[src*='/flags/']")) |img|
            try languageFromFlag(allocator, common.getAttributeValueSafe(img, "src") orelse "")
        else
            null;
        try items.append(allocator, .{
            .title = title,
            .language_code = language_code,
            .page_url = try common.resolveUrl(allocator, site, href),
            .download_url = try std.fmt.allocPrint(allocator, "{s}/getp.php?id={s}", .{ download_site, subtitle_id }),
            .downloads = null,
        });
    }
    return items.toOwnedSlice(allocator);
}

test "greeksubtitles parses result rows" {
    const allocator = std.testing.allocator;
    const fixture =
        \\<table><tr>
        \\<td class="latest_name">1</td>
        \\<td class="latest_name"><img src="http://www.subtitles.gr/flags/el.gif"/><a href="http://subtitles.gr/subtitles/The-Matrix/196900/">The Matrix 1999 BluRay</a></td>
        \\<td class="latest_downloads">475</td>
        \\</tr></table>
    ;
    const items = try parseSearchFixture(allocator, fixture);
    defer {
        for (items) |item| {
            allocator.free(item.title);
            if (item.language_code) |value| allocator.free(value);
            allocator.free(item.page_url);
            allocator.free(item.download_url);
        }
        allocator.free(items);
    }
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("el", items[0].language_code.?);
    try std.testing.expectEqualStrings("https://www.greeksubtitles.info/getp.php?id=196900", items[0].download_url);
}

test "live greeksubtitles movie search" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "greek-subtitles.com")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("The Matrix 1999");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, search.items[0].download_url, "https://www.greeksubtitles.info/getp.php?id="));
}

test "live greeksubtitles episode search" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "greek-subtitles.com")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Chernobyl S01E01");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
}
