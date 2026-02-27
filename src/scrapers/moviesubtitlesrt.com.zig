const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();
const suite = @import("test_suite.zig");

const Allocator = std.mem.Allocator;
const site = "https://moviesubtitlesrt.com";

pub const SearchItem = struct {
    title: []const u8,
    page_url: []const u8,
};

pub const SubtitleInfo = struct {
    title: []const u8,
    language_raw: ?[]const u8,
    language_code: ?[]const u8,
    release_date: ?[]const u8,
    running_time: ?[]const u8,
    file_type: ?[]const u8,
    author: ?[]const u8,
    posted_date: ?[]const u8,
    download_url: []const u8,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SearchItem,
    has_next_page: bool = false,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitleResponse = struct {
    arena: std.heap.ArenaAllocator,
    subtitle: SubtitleInfo,

    pub fn deinit(self: *SubtitleResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Scraper = struct {
    pub const SearchOptions = struct {
        page_start: usize = 1,
        max_pages: usize = 1,
    };

    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn deinit(_: *Scraper) void {}

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchWithOptions(query, .{});
    }

    pub fn searchWithOptions(self: *Scraper, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const page_start = if (options.page_start == 0) 1 else options.page_start;
        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;

        const encoded_query = try common.encodeUriComponent(a, query);
        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var has_next_page = false;

        var page: usize = page_start;
        var fetched_pages: usize = 0;
        while (fetched_pages < max_pages) : ({
            fetched_pages += 1;
            if (has_next_page) page += 1;
        }) {
            const url = try buildSearchUrl(a, encoded_query, page);
            const html_resp = try common.fetchBytes(self.client, a, url, .{ .accept = "text/html", .max_attempts = 2 });
            var parsed = try common.parseHtmlStable(a, html_resp.body);
            defer parsed.deinit();

            const len_before = items.items.len;
            var links = parsed.doc.queryAll("div.inside-article header h2 a");
            while (links.next()) |link| {
                const href = common.getAttributeValueSafe(link, "href") orelse continue;
                const text = try common.innerTextTrimmedOwned(a, link);
                const page_url = try common.resolveUrl(a, site, href);
                try items.append(a, .{ .title = text, .page_url = page_url });
            }

            if (items.items.len == len_before) {
                var fallback = parsed.doc.queryAll("article h2 a");
                while (fallback.next()) |link| {
                    const href = common.getAttributeValueSafe(link, "href") orelse continue;
                    const text = try common.innerTextTrimmedOwned(a, link);
                    const page_url = try common.resolveUrl(a, site, href);
                    try items.append(a, .{ .title = text, .page_url = page_url });
                }
            }

            has_next_page = hasNextSearchPage(&parsed.doc, page);
            if (!has_next_page) break;
        }

        return .{
            .arena = arena,
            .items = try items.toOwnedSlice(a),
            .has_next_page = has_next_page,
        };
    }

    pub fn fetchSubtitleByLink(self: *Scraper, page_url: []const u8) !SubtitleResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const html_resp = try common.fetchBytes(self.client, a, page_url, .{ .accept = "text/html", .max_attempts = 2 });
        var parsed = try common.parseHtmlStable(a, html_resp.body);
        defer parsed.deinit();

        const title_node = parsed.doc.queryOne("h1") orelse parsed.doc.queryOne("title") orelse return error.MissingField;
        const title = try common.innerTextTrimmedOwned(a, title_node);

        var language_raw: ?[]const u8 = null;
        var release_date: ?[]const u8 = null;
        var running_time: ?[]const u8 = null;
        var file_type: ?[]const u8 = null;
        var author: ?[]const u8 = null;
        var posted_date: ?[]const u8 = null;

        var rows = parsed.doc.queryAll("tbody tr");
        while (rows.next()) |row| {
            const pair = firstAndLastTd(row) orelse continue;
            const label_node = pair.first;
            const value_node = pair.last;
            const label_raw = try common.innerTextTrimmedOwned(a, label_node);
            const label = try asciiLowerDup(a, label_raw);
            const value = try common.innerTextTrimmedOwned(a, value_node);

            if (std.mem.indexOf(u8, label, "language") != null) language_raw = value;
            if (std.mem.indexOf(u8, label, "release") != null) release_date = value;
            if (std.mem.indexOf(u8, label, "running") != null or std.mem.indexOf(u8, label, "duration") != null) running_time = value;
            if (std.mem.indexOf(u8, label, "file") != null and std.mem.indexOf(u8, label, "type") != null) file_type = value;
            if (std.mem.indexOf(u8, label, "author") != null or std.mem.indexOf(u8, label, "uploader") != null) author = value;
            if (std.mem.indexOf(u8, label, "date") != null and posted_date == null) posted_date = value;
        }

        const download_url = try blk: {
            if (findFirstLinkByPredicate(&parsed.doc, hasZipHref)) |zip_link| {
                const href = common.getAttributeValueSafe(zip_link, "href") orelse break :blk error.MissingField;
                break :blk try common.resolveUrl(a, site, href);
            }
            if (findFirstLinkByPredicate(&parsed.doc, hasDownloadHref)) |download_link| {
                const href = common.getAttributeValueSafe(download_link, "href") orelse break :blk error.MissingField;
                break :blk try common.resolveUrl(a, site, href);
            }
            break :blk error.MissingField;
        };

        return .{
            .arena = arena,
            .subtitle = .{
                .title = title,
                .language_raw = language_raw,
                .language_code = if (language_raw) |lang| common.normalizeLanguageCode(lang) else null,
                .release_date = release_date,
                .running_time = running_time,
                .file_type = file_type,
                .author = author,
                .posted_date = posted_date,
                .download_url = download_url,
            },
        };
    }
};

fn asciiLowerDup(allocator: Allocator, input: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, input);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn firstAndLastTd(row: HtmlNode) ?struct { first: HtmlNode, last: HtmlNode } {
    const children = row.children();
    var first: ?HtmlNode = null;
    var last: ?HtmlNode = null;
    for (children) |child_idx| {
        const child = row.doc.nodeAt(child_idx) orelse continue;
        if (!std.mem.eql(u8, child.tagName(), "td")) continue;
        if (first == null) first = child;
        last = child;
    }
    const first_td = first orelse return null;
    const last_td = last orelse return null;
    return .{ .first = first_td, .last = last_td };
}

fn findFirstLinkByPredicate(doc: *const HtmlDocument, predicate: fn ([]const u8) bool) ?HtmlNode {
    var links = doc.queryAll("a");
    while (links.next()) |link| {
        const href = common.getAttributeValueSafe(link, "href") orelse continue;
        if (predicate(href)) return link;
    }
    return null;
}

fn hasZipHref(href: []const u8) bool {
    return std.mem.endsWith(u8, href, ".zip");
}

fn hasDownloadHref(href: []const u8) bool {
    return std.mem.indexOf(u8, href, "download") != null;
}

fn buildSearchUrl(allocator: Allocator, encoded_query: []const u8, page: usize) ![]const u8 {
    if (page <= 1) return std.fmt.allocPrint(allocator, "{s}/?s={s}", .{ site, encoded_query });
    return std.fmt.allocPrint(allocator, "{s}/page/{d}/?s={s}", .{ site, page, encoded_query });
}

fn hasNextSearchPage(doc: *const HtmlDocument, current_page: usize) bool {
    if (doc.queryOne("link[rel='next'][href]")) |_| return true;
    if (doc.queryOne("a.next.page-numbers[href]")) |_| return true;
    if (doc.queryOne("a.page-numbers.next[href]")) |_| return true;
    if (doc.queryOne(".nav-links a.next[href]")) |_| return true;
    if (doc.queryOne("a[aria-label='Next'][href]")) |_| return true;
    if (doc.queryOne("a[aria-label*='Next'][href]")) |_| return true;

    var links = doc.queryAll("a[href*='/page/']");
    while (links.next()) |link| {
        const href = common.getAttributeValueSafe(link, "href") orelse continue;
        const page_num = parsePageFromUrl(href) orelse continue;
        if (page_num > current_page) return true;
    }

    return false;
}

fn parsePageFromUrl(url: []const u8) ?usize {
    const marker = "/page/";
    const idx = std.mem.indexOf(u8, url, marker) orelse return null;
    const rest = url[idx + marker.len ..];
    if (rest.len == 0) return null;

    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

test "moviesubtitlesrt parse key language" {
    const code = common.normalizeLanguageCode("English");
    try std.testing.expectEqualStrings("en", code.?);
}

test "moviesubtitlesrt parse page number from url" {
    try std.testing.expectEqual(@as(?usize, 2), parsePageFromUrl("https://moviesubtitlesrt.com/page/2/?s=matrix"));
    try std.testing.expectEqual(@as(?usize, 15), parsePageFromUrl("/foo/page/15/"));
    try std.testing.expect(parsePageFromUrl("https://moviesubtitlesrt.com/?s=matrix") == null);
}

test "moviesubtitlesrt has next page detection" {
    const allocator = std.testing.allocator;
    const html_text =
        \\<html><head><link rel="next" href="https://moviesubtitlesrt.com/page/3/?s=matrix"></head>
        \\<body><a class="page-numbers" href="/page/2/?s=matrix">2</a></body></html>
    ;

    var parsed = try common.parseHtmlStable(allocator, html_text);
    defer parsed.deinit();
    try std.testing.expect(hasNextSearchPage(&parsed.doc, 2));
}

test "live moviesubtitlesrt search and details" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "MOVIESUBTITLESRT_COM")) return error.SkipZigTest;
    if (suite.shouldRunExtensiveLiveSuite(std.testing.allocator)) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var results = try scraper.search("The Matrix");
    defer results.deinit();
    try std.testing.expect(results.items.len > 0);
    for (results.items, 0..) |item, idx| {
        std.debug.print("[live][moviesubtitlesrt.com][search][{d}]\n", .{idx});
        try common.livePrintField(std.testing.allocator, "title", item.title);
        try common.livePrintField(std.testing.allocator, "page_url", item.page_url);
    }

    var details = try scraper.fetchSubtitleByLink(results.items[0].page_url);
    defer details.deinit();
    try std.testing.expect(details.subtitle.download_url.len > 0);
    std.debug.print("[live][moviesubtitlesrt.com][subtitle]\n", .{});
    try common.livePrintField(std.testing.allocator, "title", details.subtitle.title);
    try common.livePrintOptionalField(std.testing.allocator, "language_raw", details.subtitle.language_raw);
    try common.livePrintOptionalField(std.testing.allocator, "language_code", details.subtitle.language_code);
    try common.livePrintOptionalField(std.testing.allocator, "release_date", details.subtitle.release_date);
    try common.livePrintOptionalField(std.testing.allocator, "running_time", details.subtitle.running_time);
    try common.livePrintOptionalField(std.testing.allocator, "file_type", details.subtitle.file_type);
    try common.livePrintOptionalField(std.testing.allocator, "author", details.subtitle.author);
    try common.livePrintOptionalField(std.testing.allocator, "posted_date", details.subtitle.posted_date);
    try common.livePrintField(std.testing.allocator, "download_url", details.subtitle.download_url);
}
