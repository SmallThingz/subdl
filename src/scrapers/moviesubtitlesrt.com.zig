const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

const Allocator = std.mem.Allocator;
const site = "https://moviesubtitlesrt.com";
const max_pagination_page: usize = 128;

pub const SearchItem = common.SearchLink;

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

pub const SearchResponse = common.NextSearchResponse(SearchItem);

pub const SubtitleResponse = struct {
    arena: std.heap.ArenaAllocator,
    subtitle: SubtitleInfo,

    pub fn deinit(self: *SubtitleResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Scraper = struct {
    pub const SearchOptions = common.PageOptions;

    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchWithOptions(query, .{});
    }

    pub fn searchWithOptions(self: *Scraper, query: []const u8, options: SearchOptions) !SearchResponse {
        return self.searchWithOptionsUsing(common.fetchBytes, query, options);
    }

    fn searchWithOptionsUsing(self: *Scraper, comptime fetch: anytype, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const page_start = if (options.page_start == 0) 1 else options.page_start;
        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{}, .has_next_page = false };
        if (page_start > max_pagination_page) return error.ResponseTooLarge;

        const encoded_query = try common.encodeUriComponent(a, trimmed);
        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var has_next_page = false;

        var page: usize = page_start;
        var fetched_pages: usize = 0;
        while (fetched_pages < max_pages) : (fetched_pages += 1) {
            const url = try buildSearchUrl(a, encoded_query, page);
            const html_resp = try fetch(self.client, a, url, .{
                .accept = "text/html",
                .max_attempts = 2,
                .require_public_origin = true,
                .require_https = true,
                .require_same_origin = true,
            });
            var parsed = try common.parseHtmlStable(a, html_resp.body);

            const len_before = items.items.len;
            var links = parsed.doc.queryAll("div.inside-article header h2 a");
            while (links.next()) |link| {
                const href = common.getAttributeValueSafe(link, "href") orelse continue;
                const text = try common.innerTextTrimmedOwned(a, link);
                const page_url = resolveProviderUrl(a, href) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                try items.append(a, .{ .title = text, .page_url = page_url });
            }

            if (items.items.len == len_before) {
                var fallback = parsed.doc.queryAll("article h2 a");
                while (fallback.next()) |link| {
                    const href = common.getAttributeValueSafe(link, "href") orelse continue;
                    const text = try common.innerTextTrimmedOwned(a, link);
                    const page_url = resolveProviderUrl(a, href) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    try items.append(a, .{ .title = text, .page_url = page_url });
                }
            }

            has_next_page = try hasNextSearchPage(a, &parsed.doc, url, page);
            if (!has_next_page) break;
            if (fetched_pages + 1 >= max_pages) break;
            page = (try checkedNextPage(page)) orelse {
                has_next_page = false;
                break;
            };
        }

        return common.finishResponse(SearchResponse, &arena, .{
            .arena = arena,
            .items = try items.toOwnedSlice(a),
            .has_next_page = has_next_page,
        });
    }

    pub fn fetchSubtitleByLink(self: *Scraper, page_url: []const u8) !SubtitleResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderEndpoint(page_url);
        const html_resp = try common.fetchBytes(self.client, a, page_url, .{
            .accept = "text/html",
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        var parsed = try common.parseHtmlStable(a, html_resp.body);

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
            const label = try std.ascii.allocLowerString(a, label_raw);
            const value = try common.innerTextTrimmedOwned(a, value_node);

            if (std.mem.indexOf(u8, label, "language") != null) language_raw = value;
            if (std.mem.indexOf(u8, label, "release") != null) release_date = value;
            if (std.mem.indexOf(u8, label, "running") != null or std.mem.indexOf(u8, label, "duration") != null) running_time = value;
            if (std.mem.indexOf(u8, label, "file") != null and std.mem.indexOf(u8, label, "type") != null) file_type = value;
            if (std.mem.indexOf(u8, label, "author") != null or std.mem.indexOf(u8, label, "uploader") != null) author = value;
            if (std.mem.indexOf(u8, label, "date") != null and posted_date == null) posted_date = value;
        }

        const download_url = blk: {
            if (try resolveFirstProviderLink(a, &parsed.doc, hasZipHref)) |url| break :blk url;
            if (try resolveFirstProviderLink(a, &parsed.doc, hasDownloadHref)) |url| break :blk url;
            return error.MissingField;
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

fn firstAndLastTd(row: HtmlNode) ?struct { first: HtmlNode, last: HtmlNode } {
    var children = row.children();
    var first: ?HtmlNode = null;
    var last: ?HtmlNode = null;
    while (children.next()) |child| {
        if (!std.mem.eql(u8, child.tagName(), "td")) continue;
        if (first == null) first = child;
        last = child;
    }
    const first_td = first orelse return null;
    const last_td = last orelse return null;
    return .{ .first = first_td, .last = last_td };
}

fn resolveFirstProviderLink(allocator: Allocator, doc: *const HtmlDocument, predicate: fn ([]const u8) bool) !?[]const u8 {
    var links = doc.queryAll("a");
    while (links.next()) |link| {
        const href = common.getAttributeValueSafe(link, "href") orelse continue;
        if (!predicate(href)) continue;
        const resolved = resolveProviderUrl(allocator, href) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        validateDownloadEndpoint(resolved) catch {
            allocator.free(resolved);
            continue;
        };
        return resolved;
    }
    return null;
}

fn validateDownloadEndpoint(url: []const u8) !void {
    try validateProviderEndpoint(url);
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };

    const segment = if (std.mem.startsWith(u8, path, "/files/")) blk: {
        const value = path["/files/".len..];
        if (!hasZipHref(value)) return error.UnsafeHttpTarget;
        break :blk value;
    } else if (std.mem.startsWith(u8, path, "/download/"))
        path["/download/".len..]
    else if (std.mem.startsWith(u8, path, "/download-") and std.mem.endsWith(u8, path, ".html"))
        path["/download-".len .. path.len - ".html".len]
    else
        return error.UnsafeHttpTarget;
    if (!isSafeDownloadSegment(segment)) return error.UnsafeHttpTarget;
}

fn isSafeDownloadSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 2048 or
        std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
    {
        return false;
    }

    var index: usize = 0;
    while (index < segment.len) {
        const byte = segment[index];
        if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\' or byte == '?' or byte == '#')
            return false;
        if (byte != '%') {
            index += 1;
            continue;
        }
        if (segment.len - index < 3) return false;
        const high = hexNibble(segment[index + 1]) orelse return false;
        const low = hexNibble(segment[index + 2]) orelse return false;
        const decoded = high * 16 + low;
        if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
            decoded == '?' or decoded == '#' or decoded == '%' or decoded == '.')
        {
            return false;
        }
        index += 3;
    }
    return true;
}

fn hexNibble(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

fn hasZipHref(href: []const u8) bool {
    const query = std.mem.indexOfScalar(u8, href, '?') orelse href.len;
    const fragment = std.mem.indexOfScalar(u8, href, '#') orelse href.len;
    const path_end = @min(query, fragment);
    return path_end >= ".zip".len and std.ascii.eqlIgnoreCase(href[path_end - ".zip".len .. path_end], ".zip");
}

fn hasDownloadHref(href: []const u8) bool {
    return std.ascii.findIgnoreCase(href, "download") != null;
}

fn buildSearchUrl(allocator: Allocator, encoded_query: []const u8, page: usize) ![]const u8 {
    if (page <= 1) return std.fmt.allocPrint(allocator, "{s}/?s={s}", .{ site, encoded_query });
    return std.fmt.allocPrint(allocator, "{s}/page/{d}/?s={s}", .{ site, page, encoded_query });
}

fn checkedNextPage(page: usize) !?usize {
    if (page >= max_pagination_page) return null;
    return try std.math.add(usize, page, 1);
}

fn hasNextSearchPage(
    allocator: Allocator,
    doc: *const HtmlDocument,
    current_url: []const u8,
    current_page: usize,
) !bool {
    const selectors = [_][]const u8{
        "link[rel='next'][href]",
        "a.next.page-numbers[href]",
        "a.page-numbers.next[href]",
        ".nav-links a.next[href]",
        "a[aria-label='Next'][href]",
        "a[aria-label*='Next'][href]",
        "a[href*='/page/']",
    };
    inline for (selectors) |selector| {
        var links = doc.queryAll(selector);
        while (links.next()) |link| {
            const href = common.getAttributeValueSafe(link, "href") orelse continue;
            if (try isCanonicalSearchSuccessor(allocator, current_url, href, current_page)) return true;
        }
    }

    return false;
}

fn isCanonicalSearchSuccessor(
    allocator: Allocator,
    current_url: []const u8,
    href: []const u8,
    current_page: usize,
) !bool {
    const next_page = (try checkedNextPage(current_page)) orelse return false;
    const expected_query = rawQuery(current_url) orelse return false;
    const resolved = common.resolveUrl(allocator, current_url, href) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer allocator.free(resolved);

    common.validatePublicHttpUrl(resolved) catch return false;
    if (!(common.sameOrigin(site, resolved) catch false)) return false;
    const uri = std.Uri.parse(resolved) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.fragment != null) return false;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const candidate_page = canonicalPageFromPath(path) orelse return false;
    if (candidate_page != next_page) return false;
    const candidate_query = rawQuery(resolved) orelse return false;
    return std.mem.eql(u8, candidate_query, expected_query);
}

fn rawQuery(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const query = uri.query orelse return null;
    return switch (query) {
        .raw, .percent_encoded => |value| value,
    };
}

fn canonicalPageFromPath(path: []const u8) ?usize {
    const prefix = "/page/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var value = path[prefix.len..];
    if (value.len > 0 and value[value.len - 1] == '/') value = value[0 .. value.len - 1];
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '/') != null) return null;
    if (value[0] == '0') return null;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseInt(usize, value, 10) catch null;
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

test "moviesubtitlesrt trims queries and does not fetch empty searches" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(site ++ "/?s=Matrix", url);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<html></html>") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);

    var empty = try scraper.searchWithOptionsUsing(Fixture.fetch, " \t\r\n ", .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expect(!empty.has_next_page);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    var trimmed = try scraper.searchWithOptionsUsing(Fixture.fetch, "  Matrix\t", .{});
    defer trimmed.deinit();
    try std.testing.expectEqual(@as(usize, 0), trimmed.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
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

test "moviesubtitlesrt validates the same-query immediate next page" {
    const allocator = std.testing.allocator;
    const html_text =
        \\<html><head><link rel="next" href="https://moviesubtitlesrt.com/page/3/?s=matrix"></head>
        \\<body><a class="page-numbers" href="/page/2/?s=matrix">2</a></body></html>
    ;

    var parsed = try common.parseHtmlStable(allocator, html_text);
    defer parsed.deinit();
    try std.testing.expect(try hasNextSearchPage(
        allocator,
        &parsed.doc,
        site ++ "/page/2/?s=matrix",
        2,
    ));

    const unsafe_html =
        \\<link rel="next" href="https://example.com/page/3/?s=matrix">
        \\<a class="next page-numbers" href="/page/4/?s=matrix">skip</a>
        \\<a aria-label="Next" href="/page/3/?s=other">other query</a>
    ;
    var unsafe_parsed = try common.parseHtmlStable(allocator, unsafe_html);
    defer unsafe_parsed.deinit();
    try std.testing.expect(!(try hasNextSearchPage(
        allocator,
        &unsafe_parsed.doc,
        site ++ "/page/2/?s=matrix",
        2,
    )));
}

test "moviesubtitlesrt rejects page starts beyond its request ceiling" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.UnexpectedRequest;
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    try std.testing.expectError(error.ResponseTooLarge, scraper.searchWithOptionsUsing(Fixture.fetch, "Matrix", .{
        .page_start = max_pagination_page + 1,
        .max_pages = 2,
    }));

    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "moviesubtitlesrt rejects unsafe provider links before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/subtitle.zip"));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@moviesubtitlesrt.com/subtitle.zip"));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://www.google.com/subtitle.zip"));
}

test "moviesubtitlesrt skips unsafe download candidates and accepts signed zip links" {
    const allocator = std.testing.allocator;
    var parsed = try common.parseHtmlStable(
        allocator,
        "<a href=\"https://www.google.com/bad.zip\">bad</a>" ++
            "<a href=\"/unrelated.zip\">unrelated</a>" ++
            "<a href=\"/files/good.ZIP?token=public\">good</a>",
    );
    defer parsed.deinit();

    const url = (try resolveFirstProviderLink(allocator, &parsed.doc, hasZipHref)) orelse return error.MissingField;
    defer allocator.free(url);
    try std.testing.expectEqualStrings(site ++ "/files/good.ZIP?token=public", url);

    var fallback_parsed = try common.parseHtmlStable(
        allocator,
        "<a href=\"/download-admin\">bad</a>" ++
            "<a href=\"/download/archive.zip?token=public\">good</a>",
    );
    defer fallback_parsed.deinit();

    const fallback_url = (try resolveFirstProviderLink(allocator, &fallback_parsed.doc, hasDownloadHref)) orelse return error.MissingField;
    defer allocator.free(fallback_url);
    try std.testing.expectEqualStrings(site ++ "/download/archive.zip?token=public", fallback_url);
}

test "live moviesubtitlesrt search and details" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "MOVIESUBTITLESRT_COM")) return error.SkipZigTest;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
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
