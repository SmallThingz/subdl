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

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
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
            .require_https = true,
        });

        return parseSearchHtml(common.takeArena(&arena), response.body);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const page_route = try validateProviderEndpoint(item.page_url, .page);
        const listing_route = try validateProviderEndpoint(item.download_page_url, .listing);
        if (!std.mem.eql(u8, page_route.slug, listing_route.slug) or
            !std.mem.eql(u8, page_route.id, listing_route.id)) return error.UnsafeHttpTarget;

        const headers = [_]std.http.Header{.{ .name = "referer", .value = search_url }};
        const response = try common.fetchBytes(self.client, a, item.download_page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .max_attempts = 2,
            .cache = false,
            .require_public_origin = true,
            .require_https = true,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var anchors = parsed.doc.queryAll("a[href*='getentry.php']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const filename = try common.innerTextTrimmedOwned(a, anchor);
            if (!isSubtitleFilename(filename)) continue;
            const download_url = resolveProviderUrl(a, href, .entry) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            const entry_route = validateProviderEndpoint(download_url, .entry) catch unreachable;
            if (!std.mem.eql(u8, page_route.id, entry_route.id)) continue;
            try subtitles.append(a, .{ .filename = filename, .download_url = download_url });
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

        const page_url = resolveProviderUrl(a, href, .page) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
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
        _ = validateProviderEndpoint(download_page_url, .listing) catch continue;

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
    if (filename.len == 0 or filename.len > 512 or
        std.mem.eql(u8, filename, ".") or std.mem.eql(u8, filename, "..")) return false;
    for (filename) |c| {
        if (c < 0x20 or c == 0x7f or c == '/' or c == '\\') return false;
    }
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

const ProviderRoute = enum { page, listing, entry };

const ProviderRouteParts = struct {
    slug: []const u8 = "",
    id: []const u8,
    entry_index: []const u8 = "",
};

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    _ = try validateProviderEndpoint(resolved, route);
    return resolved;
}

fn validateProviderEndpoint(url: []const u8, route: ProviderRoute) !ProviderRouteParts {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const query = if (uri.query) |component| switch (component) {
        .raw, .percent_encoded => |value| value,
    } else null;

    if (route == .entry) {
        if (!std.mem.eql(u8, path, "/getentry.php") or query == null) return error.UnsafeHttpTarget;
        var id: ?[]const u8 = null;
        var entry_index: ?[]const u8 = null;
        var fields = std.mem.splitScalar(u8, query.?, '&');
        while (fields.next()) |field| {
            const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.UnsafeHttpTarget;
            const key = field[0..equals];
            const value = field[equals + 1 ..];
            if (std.mem.eql(u8, key, "id")) {
                if (id != null or !isCanonicalPositiveId(value)) return error.UnsafeHttpTarget;
                id = value;
            } else if (std.mem.eql(u8, key, "ei")) {
                if (entry_index != null or !isCanonicalNonNegativeInteger(value)) return error.UnsafeHttpTarget;
                entry_index = value;
            } else return error.UnsafeHttpTarget;
        }
        return .{ .id = id orelse return error.UnsafeHttpTarget, .entry_index = entry_index orelse return error.UnsafeHttpTarget };
    }

    if (query != null) return error.UnsafeHttpTarget;
    const prefix = "/subtitles/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.UnsafeHttpTarget;
    const route_suffix = switch (route) {
        .page => "/",
        .listing => "/!",
        .entry => unreachable,
    };
    if (!std.mem.endsWith(u8, path, route_suffix)) return error.UnsafeHttpTarget;
    const core = path[prefix.len .. path.len - route_suffix.len];
    const separator = std.mem.lastIndexOfScalar(u8, core, '-') orelse return error.UnsafeHttpTarget;
    const slug = core[0..separator];
    const id = core[separator + 1 ..];
    if (!isSafeEncodedSegment(slug) or !isCanonicalPositiveId(id)) return error.UnsafeHttpTarget;
    return .{ .slug = slug, .id = id };
}

fn isCanonicalPositiveId(value: []const u8) bool {
    return isCanonicalNonNegativeInteger(value) and value[0] != '0';
}

fn isCanonicalNonNegativeInteger(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or (value.len > 1 and value[0] == '0')) return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isSafeEncodedSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 512 or
        std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    var index: usize = 0;
    while (index < segment.len) {
        const c = segment[index];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            index += 1;
            continue;
        }
        if (c != '%' or segment.len - index < 3 or
            !std.ascii.isHex(segment[index + 1]) or !std.ascii.isHex(segment[index + 2])) return false;
        const decoded = std.fmt.parseInt(u8, segment[index + 1 .. index + 3], 16) catch return false;
        if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
            decoded == '?' or decoded == '#' or decoded == '%') return false;
        index += 3;
    }
    return true;
}

test "subsunacs rejects unsafe provider links" {
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/private", .page));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@subsunacs.net/private", .page));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://subsunacs.net.evil.com/private", .page));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/subtitles/The_Matrix-0/", .page));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/subtitles/The_Matrix-103573/?next=/", .page));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/subtitles/The%252fMatrix-103573/", .page));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/getentry.php?id=103573&ei=0&next=/", .entry));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/getentry.php?id=103574&ei=-1", .entry));
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

test "subsunacs empty search does not acquire the provider" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.search(" \t\r\n");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
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
        .require_https = true,
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
