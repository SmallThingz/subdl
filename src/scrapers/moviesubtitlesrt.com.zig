const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

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

        const encoded_query = try common.encodeUriComponent(a, query);
        const url = try std.fmt.allocPrint(a, "{s}/?s={s}", .{ site, encoded_query });
        const html_resp = try common.fetchBytes(self.client, a, url, .{ .accept = "text/html", .max_attempts = 2 });
        var parsed = try common.parseHtmlStable(a, html_resp.body);
        defer parsed.deinit();

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var links = parsed.doc.queryAll("div.inside-article header h2 a");
        while (links.next()) |link| {
            const href = common.getAttributeValueSafe(link, "href") orelse continue;
            const text = try link.innerTextWithOptions(a, .{ .normalize_whitespace = true });
            const page_url = try common.resolveUrl(a, site, href);
            try items.append(a, .{ .title = common.trimAscii(text), .page_url = page_url });
        }

        if (items.items.len == 0) {
            var fallback = parsed.doc.queryAll("article h2 a");
            while (fallback.next()) |link| {
                const href = common.getAttributeValueSafe(link, "href") orelse continue;
                const text = try link.innerTextWithOptions(a, .{ .normalize_whitespace = true });
                const page_url = try common.resolveUrl(a, site, href);
                try items.append(a, .{ .title = common.trimAscii(text), .page_url = page_url });
            }
        }

        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn fetchSubtitleByLink(self: *Scraper, page_url: []const u8) !SubtitleResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const html_resp = try common.fetchBytes(self.client, a, page_url, .{ .accept = "text/html", .max_attempts = 2 });
        var parsed = try common.parseHtmlStable(a, html_resp.body);
        defer parsed.deinit();

        const title_node = parsed.doc.queryOne("h1") orelse parsed.doc.queryOne("title") orelse return error.MissingField;
        const title = common.trimAscii(try title_node.innerTextWithOptions(a, .{ .normalize_whitespace = true }));

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
            const label_raw = common.trimAscii(try label_node.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
            const label = try asciiLowerDup(a, label_raw);
            const value = common.trimAscii(try value_node.innerTextWithOptions(a, .{ .normalize_whitespace = true }));

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

fn firstAndLastTd(row: html.Node) ?struct { first: html.Node, last: html.Node } {
    const children = row.children();
    var first: ?html.Node = null;
    var last: ?html.Node = null;
    for (children) |child_idx| {
        const child = row.doc.nodeAt(child_idx) orelse continue;
        if (!std.mem.eql(u8, child.tagName(), "td")) continue;
        if (first == null) first = child;
        last = child;
    }
    if (first == null or last == null) return null;
    return .{ .first = first.?, .last = last.? };
}

fn findFirstLinkByPredicate(doc: *const html.Document, predicate: fn ([]const u8) bool) ?html.Node {
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

test "moviesubtitlesrt parse key language" {
    const code = common.normalizeLanguageCode("English");
    try std.testing.expectEqualStrings("en", code.?);
}

test "live moviesubtitlesrt search and details" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var results = try scraper.search("The Matrix");
    defer results.deinit();
    try std.testing.expect(results.items.len > 0);

    var details = try scraper.fetchSubtitleByLink(results.items[0].page_url);
    defer details.deinit();
    try std.testing.expect(details.subtitle.download_url.len > 0);
}
