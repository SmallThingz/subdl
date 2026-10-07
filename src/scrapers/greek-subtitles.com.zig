const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlNode = HtmlParseOptions.GetNode();
const site = "https://gr.greek-subtitles.com";
const legacy_listing_sites = [_][]const u8{
    "http://subtitles.gr",
    "https://subtitles.gr",
    "http://www.subtitles.gr",
    "https://www.subtitles.gr",
};
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
        return self.searchUsing(common.fetchBytes, query);
    }

    fn searchUsing(self: *Scraper, comptime fetch: anytype, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/search.php?name={s}", .{ site, encoded });
        const response = try fetch(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        return parseSearchHtml(common.takeArena(&arena), response.body);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const listing_target = try canonicalizeOwnedListingTarget(a, try a.dupe(u8, item.page_url));
        const listing_id = listing_target.subtitle_id;
        const download_id = try downloadSubtitleId(item.download_url);
        if (!std.mem.eql(u8, listing_id, download_id)) return error.InvalidDownloadUrl;

        const filename = try a.dupe(u8, item.title);
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try common.dupOptional(a, item.language_code),
            .filename = filename,
            .page_url = listing_target.url,
            .download_url = try a.dupe(u8, item.download_url),
        };
        return .{ .arena = arena, .subtitles = subtitles };
    }
};

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    var parsed = try common.parseHtmlStable(a, body);
    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var rows = parsed.doc.queryAll("tr");
    while (rows.next()) |row| {
        var anchors = row.queryAll("td.latest_name a[href*='/subtitles/']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const target = resolveListingTarget(a, href) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            const title = try common.innerTextTrimmedOwned(a, anchor);
            if (title.len == 0) continue;
            if (seen.contains(target.subtitle_id)) continue;
            try seen.put(a, target.subtitle_id, {});

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
                .page_url = target.url,
                .download_url = try std.fmt.allocPrint(a, "{s}/getp.php?id={s}", .{ download_site, target.subtitle_id }),
                .downloads = downloads,
            });
            break;
        }
    }

    return common.finishResponse(SearchResponse, &owned_arena, .{
        .arena = owned_arena,
        .items = try items.toOwnedSlice(a),
    });
}

fn validateDownloadUrl(url: []const u8) !void {
    _ = try downloadSubtitleId(url);
}

fn downloadSubtitleId(url: []const u8) ![]const u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(download_site, url) catch false)) return error.InvalidDownloadUrl;
    if (uri.fragment != null) return error.InvalidDownloadUrl;

    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/getp.php")) return error.InvalidDownloadUrl;

    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return error.InvalidDownloadUrl;
    const query = url[query_start + 1 ..];
    const prefix = "id=";
    if (!std.mem.startsWith(u8, query, prefix)) return error.InvalidDownloadUrl;
    const id = query[prefix.len..];
    if (!isCanonicalPositiveId(id)) return error.InvalidDownloadUrl;
    return id;
}

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

const ListingTarget = struct {
    url: []u8,
    subtitle_id: []const u8,
};

fn resolveListingTarget(allocator: Allocator, href: []const u8) !ListingTarget {
    // resolveUrl returns a fresh allocator-owned buffer, even though its public
    // type is read-only. Keep the mutable slice as the ownership token passed
    // to the consuming canonicalizer; borrowed URL slices never reach it.
    const resolved: []u8 = @constCast(try common.resolveUrl(allocator, site, href));
    return canonicalizeOwnedListingTarget(allocator, resolved);
}

fn canonicalizeOwnedListingTarget(allocator: Allocator, owned_input: []u8) !ListingTarget {
    var url = owned_input;
    errdefer allocator.free(url);

    // Validate the original origin and route before using its parsed authority
    // to construct the HTTPS equivalent.
    _ = try listingSubtitleId(url);
    if (isLegacyHttpListingOrigin(url)) {
        var uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
        uri.scheme = "https";
        // isLegacyHttpListingOrigin already proved that the effective HTTP
        // port is 80. Do not carry an explicit :80 into the HTTPS origin.
        uri.port = null;
        const canonical = try std.fmt.allocPrint(allocator, "{f}", .{uri});
        allocator.free(url);
        url = canonical;
    }

    return .{ .url = url, .subtitle_id = try listingSubtitleId(url) };
}

fn isLegacyHttpListingOrigin(url: []const u8) bool {
    return (common.sameOrigin(legacy_listing_sites[0], url) catch false) or
        (common.sameOrigin(legacy_listing_sites[2], url) catch false);
}

fn listingSubtitleId(url: []const u8) ![]const u8 {
    common.validatePublicHttpUrl(url) catch return error.UnsafeHttpTarget;
    var allowed_origin = common.sameOrigin(site, url) catch false;
    for (legacy_listing_sites) |origin| {
        if (common.sameOrigin(origin, url) catch false) {
            allowed_origin = true;
            break;
        }
    }
    if (!allowed_origin) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    var path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (path.len < 2 or path[path.len - 1] == '/') return error.UnsafeHttpTarget;

    var segments = std.mem.splitScalar(u8, path[1..], '/');
    const route = segments.next() orelse return error.UnsafeHttpTarget;
    const slug = segments.next() orelse return error.UnsafeHttpTarget;
    const subtitle_id = segments.next() orelse return error.UnsafeHttpTarget;
    if (segments.next() != null or !std.mem.eql(u8, route, "subtitles") or
        !isSafeListingSlug(slug) or !isCanonicalPositiveId(subtitle_id))
    {
        return error.UnsafeHttpTarget;
    }
    return subtitle_id;
}

fn isSafeListingSlug(value: []const u8) bool {
    if (value.len == 0 or isDotListingSegment(value)) return false;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') continue;
        if (c != '%' or value.len - i < 3 or !isHex(value[i + 1]) or !isHex(value[i + 2])) return false;
        const high = std.ascii.toLower(value[i + 1]);
        const low = std.ascii.toLower(value[i + 2]);
        if (high == '2' and low == 'f') return false;
        if (high == '5' and low == 'c') return false;
        i += 2;
    }
    return true;
}

fn isDotListingSegment(value: []const u8) bool {
    var dots: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '.') {
            dots += 1;
            i += 1;
            continue;
        }
        if (value.len - i >= 3 and value[i] == '%' and value[i + 1] == '2' and std.ascii.toLower(value[i + 2]) == 'e') {
            dots += 1;
            i += 3;
            continue;
        }
        return false;
    }
    return dots == 1 or dots == 2;
}

fn isHex(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isCanonicalPositiveId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn parseOptionalInt(value: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

test "greeksubtitles parses result rows" {
    const fixture =
        \\<table><tr>
        \\<td class="latest_name">1</td>
        \\<td class="latest_name"><img src="http://www.subtitles.gr/flags/el.gif"/><a href="http://subtitles.gr/subtitles/The-Matrix/196900/">The Matrix 1999 BluRay</a></td>
        \\<td class="latest_downloads">475</td>
        \\</tr></table>
    ;
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(arena, fixture);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("el", response.items[0].language_code.?);
    try std.testing.expectEqual(@as(?i64, 475), response.items[0].downloads);
    try std.testing.expectEqualStrings("https://subtitles.gr/subtitles/The-Matrix/196900/", response.items[0].page_url);
    try std.testing.expectEqualStrings("https://www.greeksubtitles.info/getp.php?id=196900", response.items[0].download_url);
}

test "greeksubtitles scans past malformed same-row listing candidates" {
    const fixture =
        \\<table><tr>
        \\<td class="latest_name">
        \\  <a href="/subtitles/not-a-listing">decoy</a>
        \\  <a href="/subtitles/The-Matrix/196900/">The Matrix</a>
        \\</td>
        \\</tr></table>
    ;
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(arena, fixture);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqualStrings(site ++ "/subtitles/The-Matrix/196900/", response.items[0].page_url);
}

test "greeksubtitles deduplicates canonical subtitle ids in first-row order" {
    const fixture =
        \\<table>
        \\<tr><td class="latest_name"><a href="http://subtitles.gr/subtitles/First-Slug/196900/">First title</a></td></tr>
        \\<tr><td class="latest_name"><a href="https://www.subtitles.gr/subtitles/Other-Slug/196900/">Duplicate title</a></td></tr>
        \\<tr><td class="latest_name"><a href="/subtitles/Second-Slug/196901/">Second title</a></td></tr>
        \\</table>
    ;
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(arena, fixture);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings("First title", response.items[0].title);
    try std.testing.expectEqualStrings("196900", try downloadSubtitleId(response.items[0].download_url));
    try std.testing.expectEqualStrings("Second title", response.items[1].title);
    try std.testing.expectEqualStrings("196901", try downloadSubtitleId(response.items[1].download_url));
}

test "greeksubtitles trims queries and does not fetch empty searches" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(site ++ "/search.php?name=Matrix", url);
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);
            try std.testing.expect(options.require_same_origin);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<html></html>") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);

    var empty = try scraper.searchUsing(Fixture.fetch, " \t\r\n ");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    var trimmed = try scraper.searchUsing(Fixture.fetch, "  Matrix\t");
    defer trimmed.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "greeksubtitles restricts generated download targets" {
    try validateDownloadUrl("https://www.greeksubtitles.info/getp.php?id=1");
    for ([_][]const u8{
        "http://127.0.0.1/getp.php?id=1",
        "https://www.greeksubtitles.info.example/getp.php?id=1",
        "https://user@www.greeksubtitles.info/getp.php?id=1",
        "https://www.greeksubtitles.info/admin?id=1",
        "https://www.greeksubtitles.info/getp.php",
        "https://www.greeksubtitles.info/getp.php?next=id=1",
        "https://www.greeksubtitles.info/getp.php?id=",
        "https://www.greeksubtitles.info/getp.php?id=0",
        "https://www.greeksubtitles.info/getp.php?id=01",
        "https://www.greeksubtitles.info/getp.php?id=abc",
        "https://www.greeksubtitles.info/getp.php?id=1&next=/admin",
        "https://www.greeksubtitles.info/getp.php?id=1#fragment",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateDownloadUrl(url));
    }
}

test "greeksubtitles accepts only allowlisted exact listing routes" {
    inline for (.{
        "https://gr.greek-subtitles.com/subtitles/title/196900/?from=search#row",
        "https://gr.greek-subtitles.com/subtitles/The-Matrix/196900#row",
        "https://gr.greek-subtitles.com/subtitles/Title%2ePart/196900",
        "http://subtitles.gr/subtitles/The-Matrix/196900/",
        "https://subtitles.gr/subtitles/The-Matrix/196900/",
        "http://www.subtitles.gr/subtitles/The-Matrix/196900/",
        "https://www.subtitles.gr/subtitles/The-Matrix/196900/",
    }) |url| try std.testing.expectEqualStrings("196900", try listingSubtitleId(url));

    const relative = try resolveListingTarget(std.testing.allocator, "/subtitles/title/196900/?from=search");
    defer std.testing.allocator.free(relative.url);
    try std.testing.expectEqualStrings("196900", relative.subtitle_id);

    inline for (.{
        "https://evil.example/subtitles/title/196900",
        "https://subtitles.gr.evil.example/subtitles/title/196900",
        "https://www.subtitles.gr.evil.example/subtitles/title/196900",
        "https://evilsubtitles.gr/subtitles/title/196900",
        "https://subtitles.gr:444/subtitles/title/196900",
        "https://user@subtitles.gr/subtitles/title/196900",
        "http://gr.greek-subtitles.com/subtitles/title/196900",
        "https://gr.greek-subtitles.com/admin/196900",
        "https://gr.greek-subtitles.com/subtitles/title/0",
        "https://gr.greek-subtitles.com/subtitles/title/0196900",
        "https://gr.greek-subtitles.com/subtitles/title/not-an-id/",
        "https://gr.greek-subtitles.com/subtitles/title/196900/extra",
        "https://gr.greek-subtitles.com/subtitles/%2e%2e/196900",
        "https://gr.greek-subtitles.com/subtitles/.%2e/196900",
    }) |url| try std.testing.expectError(error.UnsafeHttpTarget, listingSubtitleId(url));
}

test "greeksubtitles frees rejected resolved listing targets" {
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        resolveListingTarget(std.testing.allocator, "https://evil.example/subtitles/title/196900"),
    );
}

test "greeksubtitles canonicalizes exact legacy HTTP origins to HTTPS" {
    inline for (.{
        .{ "http://subtitles.gr/subtitles/The-Matrix/196900/?from=search", "https://subtitles.gr/subtitles/The-Matrix/196900/?from=search" },
        .{ "http://subtitles.gr:80/subtitles/The-Matrix/196900/", "https://subtitles.gr/subtitles/The-Matrix/196900/" },
        .{ "http://www.subtitles.gr/subtitles/The-Matrix/196900/", "https://www.subtitles.gr/subtitles/The-Matrix/196900/" },
        .{ "http://www.subtitles.gr:80/subtitles/The-Matrix/196900/", "https://www.subtitles.gr/subtitles/The-Matrix/196900/" },
        .{ "//subtitles.gr/subtitles/The-Matrix/196900/", "https://subtitles.gr/subtitles/The-Matrix/196900/" },
    }) |case| {
        const target = try resolveListingTarget(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(target.url);
        try std.testing.expectEqualStrings(case[1], target.url);
        try std.testing.expectEqualStrings("196900", target.subtitle_id);
    }

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.fetchSubtitlesBySearchItem(.{
        .title = "The Matrix",
        .language_code = "el",
        .page_url = "http://www.subtitles.gr/subtitles/The-Matrix/196900/",
        .download_url = "https://www.greeksubtitles.info/getp.php?id=196900",
        .downloads = null,
    });
    defer response.deinit();
    try std.testing.expectEqualStrings("https://www.subtitles.gr/subtitles/The-Matrix/196900/", response.subtitles[0].page_url);
}

test "greeksubtitles rejects listing and download ID mismatches" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    try std.testing.expectError(error.InvalidDownloadUrl, scraper.fetchSubtitlesBySearchItem(.{
        .title = "The Matrix",
        .language_code = "el",
        .page_url = "https://gr.greek-subtitles.com/subtitles/The-Matrix/196900/",
        .download_url = "https://www.greeksubtitles.info/getp.php?id=196901",
        .downloads = null,
    }));
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
