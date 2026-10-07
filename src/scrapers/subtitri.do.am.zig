const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://subtitri.do.am";
const ucoz_search_cookie = "ucz_h=1";

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
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/search/?q={s}", .{ site, encoded });
        const cookie = searchCookieForUrl(url) orelse return error.UnsafeHttpTarget;
        const headers = [_]std.http.Header{.{ .name = "cookie", .value = cookie }};
        const response = try common.fetchBytes(self.client, a, url, searchFetchOptions(&headers));

        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(item.page_url, .detail);
        const expected_entry_id = ucozEntryIdForUrl(item.page_url, .detail) orelse
            return error.UnsafeHttpTarget;

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        const download_url = try parseDownloadUrl(a, response.body, expected_entry_id);

        const slugged = try common.asciiSlug(a, item.title);
        const filename = try std.fmt.allocPrint(a, "subtitri-{s}.zip", .{slugged});
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = "lv",
            .filename = filename,
            .download_url = download_url,
        };

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn parseDownloadUrl(allocator: Allocator, body: []const u8, expected_entry_id: []const u8) ![]const u8 {
    var parsed = try common.parseHtmlStable(allocator, body);
    defer parsed.deinit();
    var links = parsed.doc.queryAll("a.hvr[href]");
    while (links.next()) |link| {
        const href = common.getAttributeValueSafe(link, "href") orelse continue;
        const download_url = resolveProviderDownloadUrl(allocator, href, expected_entry_id) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            continue;
        };
        return download_url;
    }
    return error.MissingField;
}

fn searchFetchOptions(headers: []const std.http.Header) common.FetchOptions {
    return .{
        .accept = "text/html,application/xhtml+xml,*/*",
        // uCoz's search endpoint issues this public, fixed cookie on its first
        // redirect and requires it on the redirected request. The path scope
        // keeps it on /search even if that origin redirects somewhere else.
        .extra_headers = headers,
        .private_headers_path_prefix = "/search",
        .cache = false,
        .max_attempts = 2,
        .require_public_origin = true,
        .require_https = true,
        .require_same_origin = true,
    };
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };
    var parsed = try common.parseHtmlStable(a, body);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var blocks = parsed.doc.queryAll("table.eBlock");
    while (blocks.next()) |block| {
        var anchors = block.queryAll("div.eTitle a[href]");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const title = try common.innerTextTrimmedOwned(a, anchor);
            if (title.len == 0) continue;

            const normalized = try common.normalizeTitle(a, title);
            if (!common.normalizedTitlesRelated(normalized, wanted)) continue;

            const page_url = resolveProviderUrl(a, href, .detail) catch |err| {
                if (err == error.OutOfMemory or err == error.Canceled) return err;
                continue;
            };
            const entry_id = ucozEntryIdForUrl(page_url, .detail) orelse continue;
            const is_exact = std.mem.eql(u8, normalized, wanted);
            if (seen.contains(entry_id)) {
                if (is_exact) _ = try promotePartialByEntryId(a, entry_id, &exact, &partial);
                continue;
            }
            try seen.put(a, entry_id, {});

            const item: SearchItem = .{
                .title = title,
                .page_url = page_url,
            };
            if (is_exact)
                try exact.append(a, item)
            else
                try partial.append(a, item);
            break;
        }
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn promotePartialByEntryId(
    allocator: Allocator,
    entry_id: []const u8,
    exact: *std.ArrayListUnmanaged(SearchItem),
    partial: *std.ArrayListUnmanaged(SearchItem),
) !bool {
    for (partial.items, 0..) |item, index| {
        const partial_entry_id = ucozEntryIdForUrl(item.page_url, .detail) orelse continue;
        if (!std.mem.eql(u8, partial_entry_id, entry_id)) continue;
        try exact.ensureUnusedCapacity(allocator, 1);
        const promoted = partial.orderedRemove(index);
        exact.appendAssumeCapacity(promoted);
        return true;
    }
    return false;
}

const ProviderRoute = enum { detail, download };

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderUrl(resolved, route);
    return resolved;
}

fn resolveProviderDownloadUrl(allocator: Allocator, href: []const u8, expected_entry_id: []const u8) ![]const u8 {
    const resolved = try resolveProviderUrl(allocator, href, .download);
    errdefer allocator.free(resolved);
    const entry_id = ucozEntryIdForUrl(resolved, .download) orelse return error.UnsafeHttpTarget;
    if (!std.mem.eql(u8, entry_id, expected_entry_id)) return error.UnsafeHttpTarget;
    return resolved;
}

fn validateProviderOrigin(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

fn validateProviderUrl(url: []const u8, route: ProviderRoute) !void {
    try validateProviderOrigin(url);
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.query != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (std.mem.indexOfScalar(u8, path, '%') != null or
        std.mem.indexOfScalar(u8, path, '\\') != null) return error.UnsafeHttpTarget;

    var segments = std.mem.splitScalar(u8, path, '/');
    if (!std.mem.eql(u8, segments.next() orelse return error.UnsafeHttpTarget, "")) return error.UnsafeHttpTarget;
    if (!std.mem.eql(u8, segments.next() orelse return error.UnsafeHttpTarget, "load")) return error.UnsafeHttpTarget;
    switch (route) {
        .detail => {
            const category = segments.next() orelse return error.UnsafeHttpTarget;
            const title = segments.next() orelse return error.UnsafeHttpTarget;
            const id = segments.next() orelse return error.UnsafeHttpTarget;
            if (segments.next() != null or
                !isSafeSlug(category) or
                !isSafeSlug(title) or
                !isUcozDetailRouteId(id)) return error.UnsafeHttpTarget;
        },
        .download => {
            const id = segments.next() orelse return error.UnsafeHttpTarget;
            if (segments.next() != null or !isUcozDownloadRouteId(id)) return error.UnsafeHttpTarget;
        },
    }
}

fn isSafeSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    return true;
}

fn isUcozDetailRouteId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    var fields = std.mem.splitScalar(u8, value, '-');
    var field_count: usize = 0;
    while (fields.next()) |field| {
        if (field_count == 3) {
            if (!isCanonicalPositiveRouteInt(field)) return false;
        } else if (!isCanonicalRouteInt(field)) return false;
        field_count += 1;
    }
    return field_count == 4;
}

fn isUcozDownloadRouteId(value: []const u8) bool {
    const prefix = "0-0-0-";
    const suffix = "-20";
    if (value.len <= prefix.len + suffix.len or value.len > 128 or
        !std.mem.startsWith(u8, value, prefix) or
        !std.mem.endsWith(u8, value, suffix)) return false;
    return isCanonicalPositiveRouteInt(value[prefix.len .. value.len - suffix.len]);
}

fn isCanonicalRouteInt(value: []const u8) bool {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    _ = std.fmt.parseInt(u64, value, 10) catch return false;
    return true;
}

fn isCanonicalPositiveRouteInt(value: []const u8) bool {
    return isCanonicalRouteInt(value) and !std.mem.eql(u8, value, "0");
}

fn ucozEntryIdForUrl(url: []const u8, route: ProviderRoute) ?[]const u8 {
    validateProviderUrl(url, route) catch return null;
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    var fields = std.mem.splitScalar(u8, path[slash + 1 ..], '-');
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == 3) return field;
    }
    return null;
}

fn searchCookieForUrl(url: []const u8) ?[]const u8 {
    validateProviderOrigin(url) catch return null;
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| if (value.len == 0) "/" else value,
    };
    if (!cookiePathMatches("/search", path)) return null;
    return ucoz_search_cookie;
}

fn cookiePathMatches(cookie_path: []const u8, request_path: []const u8) bool {
    if (std.mem.eql(u8, cookie_path, request_path)) return true;
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;
    if (cookie_path[cookie_path.len - 1] == '/') return true;
    return request_path.len > cookie_path.len and request_path[cookie_path.len] == '/';
}

test "subtitri parses exact movie search result" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        "<table class=\"eBlock\"><tr><td><div class=\"eTitle\"><a href=\"/load/subtitri_zem_2000_gada/the_matrix_1999/13-1-0-1301\"><b>The</b> <b>Matrix</b></a></div></td></tr></table>",
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqualStrings("https://subtitri.do.am/load/subtitri_zem_2000_gada/the_matrix_1999/13-1-0-1301", response.items[0].page_url);
}

test "subtitri scans past malformed same-block detail candidates" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        "<table class=\"eBlock\"><tr><td><div class=\"eTitle\"><a href=\"/load/not-a-detail\">The Matrix</a><a href=\"/load/category/the_matrix/13-1-0-0\">The Matrix</a><a href=\"/load/subtitri_zem_2000_gada/the_matrix_1999/13-1-0-1301\">The Matrix</a></div></td></tr></table>",
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings(
        "https://subtitri.do.am/load/subtitri_zem_2000_gada/the_matrix_1999/13-1-0-1301",
        response.items[0].page_url,
    );
}

test "subtitri deduplicates entry identities and promotes later exact matches" {
    const fixture =
        \\<table class="eBlock"><tr><td><div class="eTitle"><a href="/load/category/the_matrix_reloaded/13-1-0-1301">The Matrix Reloaded</a></div></td></tr></table>
        \\<table class="eBlock"><tr><td><div class="eTitle"><a href="/load/category/the_matrix/13-1-0-1302">The Matrix</a></div></td></tr></table>
        \\<table class="eBlock"><tr><td><div class="eTitle"><a href="https://SUBTITRI.DO.AM:443/load/other_category/the_matrix/13-1-0-1301">The Matrix</a></div></td></tr></table>
        \\<table class="eBlock"><tr><td><div class="eTitle"><a href="/load/category/the_matrix_revolutions/13-1-0-1303">The Matrix Revolutions</a></div></td></tr></table>
    ;
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(arena, fixture, "The Matrix");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 3), response.items.len);
    try std.testing.expectEqualStrings("1302", ucozEntryIdForUrl(response.items[0].page_url, .detail).?);
    try std.testing.expectEqualStrings("1301", ucozEntryIdForUrl(response.items[1].page_url, .detail).?);
    try std.testing.expectEqualStrings("The Matrix Reloaded", response.items[1].title);
    try std.testing.expectEqualStrings("1303", ucozEntryIdForUrl(response.items[2].page_url, .detail).?);
}

test "subtitri rejects unsafe provider urls before fetch" {
    try validateProviderUrl("https://subtitri.do.am/load/subtitri_zem_2000_gada/the_matrix_1999/13-1-0-1301", .detail);
    try validateProviderUrl("https://subtitri.do.am/load/0-0-0-1301-20", .download);
    const invalid = [_]struct { url: []const u8, route: ProviderRoute }{
        .{ .url = "http://127.0.0.1/load/x", .route = .detail },
        .{ .url = "https://user@subtitri.do.am/load/x", .route = .detail },
        .{ .url = "https://subtitri.do.am.attacker.example/load/x", .route = .detail },
        .{ .url = "https://subtitri.do.am/admin", .route = .detail },
        .{ .url = "https://subtitri.do.am/load/the_matrix/13-1-0-1301", .route = .detail },
        .{ .url = "https://subtitri.do.am/load/subtitri_zem_2000_gada/the_matrix_1999/13-1-0-1301?next=/admin", .route = .detail },
        .{ .url = "https://subtitri.do.am/load/subtitri_zem_2000_gada/../admin/13-1-0-1301", .route = .detail },
        .{ .url = "https://subtitri.do.am/load/subtitri_zem_2000_gada/the_matrix%2fadmin/13-1-0-1301", .route = .detail },
        .{ .url = "https://subtitri.do.am/load/subtitri_zem_2000_gada/the_matrix_1999/13-1-1301", .route = .detail },
        .{ .url = "https://subtitri.do.am/load/subtitri_zem_2000_gada/the_matrix_1999/13-01-0-1301", .route = .detail },
        .{ .url = "https://subtitri.do.am/load/subtitri_zem_2000_gada/the_matrix_1999/13-1-0-0", .route = .detail },
        .{ .url = "https://subtitri.do.am/load/0-0-1301-20", .route = .download },
        .{ .url = "https://subtitri.do.am/load/0-0-0-0-20", .route = .download },
        .{ .url = "https://subtitri.do.am/load/9-8-7-1301-6", .route = .download },
        .{ .url = "https://subtitri.do.am/load/0-0-0-1301-21", .route = .download },
        .{ .url = "https://subtitri.do.am/load/0-0-0-1301-020", .route = .download },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(case.url, case.route));
    }
}

test "subtitri binds attachment routes to their detail entry id" {
    const allocator = std.testing.allocator;
    const matching = try resolveProviderDownloadUrl(allocator, "/load/0-0-0-1301-20", "1301");
    defer allocator.free(matching);
    try std.testing.expectEqualStrings("https://subtitri.do.am/load/0-0-0-1301-20", matching);

    try std.testing.expectError(
        error.UnsafeHttpTarget,
        resolveProviderDownloadUrl(allocator, "/load/0-0-0-9999-20", "1301"),
    );
}

test "subtitri scans past malformed and mismatched download candidates" {
    const body =
        \\<a class="hvr" href="/load/not-a-download">malformed</a>
        \\<a class="hvr" href="/load/0-0-0-0-20">zero entry</a>
        \\<a class="hvr" href="/load/9-8-7-1301-6">wrong route grammar</a>
        \\<a class="hvr" href="/load/0-0-0-9999-20">wrong entry</a>
        \\<a class="hvr" href="/load/0-0-0-1301-20">download</a>
    ;
    const download_url = try parseDownloadUrl(std.testing.allocator, body, "1301");
    defer std.testing.allocator.free(download_url);
    try std.testing.expectEqualStrings("https://subtitri.do.am/load/0-0-0-1301-20", download_url);
}

test "subtitri scopes the uCoz search cookie across expected redirects" {
    const a = std.testing.allocator;
    const start = "https://subtitri.do.am/search/?q=The%20Matrix";
    try std.testing.expectEqualStrings(ucoz_search_cookie, searchCookieForUrl(start).?);
    const headers = [_]std.http.Header{.{ .name = "cookie", .value = ucoz_search_cookie }};
    const options = searchFetchOptions(&headers);
    try std.testing.expectEqualStrings("/search", options.private_headers_path_prefix.?);
    try std.testing.expectEqualStrings(ucoz_search_cookie, options.extra_headers[0].value);

    const redirected = try common.resolveUrl(a, start, "/search/?q=The%20Matrix&_ck=1");
    defer a.free(redirected);
    try std.testing.expectEqualStrings(ucoz_search_cookie, searchCookieForUrl(redirected).?);

    for ([_][]const u8{
        "https://subtitri.do.am/load/0-0-0-1301-20",
        "https://subtitri.do.am/searching?q=The%20Matrix",
        "http://subtitri.do.am/search/?q=The%20Matrix&_ck=1",
        "https://cdn.subtitri.do.am/search/?q=The%20Matrix&_ck=1",
        "https://subtitri.do.am.example/search/?q=The%20Matrix&_ck=1",
        "https://user@subtitri.do.am/search/?q=The%20Matrix&_ck=1",
        "https://subtitri.do.am:444/search/?q=The%20Matrix&_ck=1",
    }) |url| try std.testing.expectEqual(@as(?[]const u8, null), searchCookieForUrl(url));
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
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
