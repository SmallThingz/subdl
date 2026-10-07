const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://subtitri.nekur.net";
const search_url = site ++ "/modules/Subtitles.php";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    imdb_id: ?[]const u8,
    fps: ?[]const u8,
    page_url: []const u8,
    download_url: []const u8,
};

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
        const payload = try std.fmt.allocPrint(a, "ajax=1&sSearch={s}", .{encoded});
        const headers = [_]std.http.Header{
            .{ .name = "origin", .value = site },
            .{ .name = "referer", .value = site ++ "/" },
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
        };
        const response = try common.fetchBytes(self.client, a, search_url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded; charset=UTF-8",
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .allow_non_ok = true,
            .cache = false,
            .max_attempts = 3,
            .retry_on_429 = false,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        // Nekur currently emits a complete search table with HTTP 500. Keep
        // this exception provider-local and reject every other non-OK shape.
        try requireSearchResponse(response.status, response.body);

        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(item.page_url);
        try validateProviderUrl(item.download_url);
        if (!std.mem.eql(u8, item.page_url, item.download_url)) return error.UnsafeHttpTarget;

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = "lv",
            .filename = try safeSubtitleFilename(a, item.title),
            .download_url = try a.dupe(u8, item.download_url),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn safeSubtitleFilename(allocator: Allocator, title: []const u8) ![]u8 {
    const slug = try common.asciiSlug(allocator, title[0..@min(title.len, 160)]);
    defer allocator.free(slug);
    if (slug.len == 0) return allocator.dupe(u8, "nekur-subtitle.zip");
    return std.fmt.allocPrint(allocator, "{s}.zip", .{slug});
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

    var rows = parsed.doc.queryAll("tbody > tr");
    while (rows.next()) |row| {
        const anchor = row.queryOne("td.title > a[href]") orelse continue;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const raw_title = try common.innerTextTrimmedOwned(a, anchor);
        if (raw_title.len == 0) continue;

        const split = common.splitTrailingYear(raw_title);
        const title = try a.dupe(u8, split.title);
        const normalized = try common.normalizeTitle(a, title);
        if (!common.normalizedTitlesRelated(normalized, wanted)) continue;
        const page_url = resolveProviderUrl(a, href) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            continue;
        };
        if (seen.contains(page_url)) continue;
        try seen.put(a, page_url, {});

        const imdb_id = blk: {
            var cells = row.queryAll("td");
            var cell_index: usize = 0;
            var imdb_cell: ?@TypeOf(row) = null;
            while (cells.next()) |cell| : (cell_index += 1) {
                if (cell_index == 3) {
                    imdb_cell = cell;
                    break;
                }
            }
            break :blk try parseImdbIdFromCell(a, imdb_cell orelse break :blk null);
        };
        const fps = if (row.queryOne("td.fps")) |node|
            try common.innerTextTrimmedOwned(a, node)
        else
            null;

        const item: SearchItem = .{
            .title = title,
            .year = split.year,
            .imdb_id = imdb_id,
            .fps = fps,
            .page_url = page_url,
            .download_url = try a.dupe(u8, page_url),
        };

        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn parseImdbIdFromCell(allocator: Allocator, cell: anytype) !?[]const u8 {
    var anchors = cell.queryAll("a[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (try parseImdbId(allocator, href)) |id| return id;
    }
    return null;
}

fn parseImdbId(allocator: Allocator, url: []const u8) !?[]const u8 {
    const prefix = "https://www.imdb.com/title/";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const raw_id = url[prefix.len..];
    const id = if (std.mem.endsWith(u8, raw_id, "/")) raw_id[0 .. raw_id.len - 1] else raw_id;
    if (id.len < 9 or id.len > 12 or !std.mem.startsWith(u8, id, "tt")) return null;
    var any_nonzero = false;
    for (id[2..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        any_nonzero = any_nonzero or c != '0';
    }
    if (!any_nonzero) return null;
    return try allocator.dupe(u8, id);
}

fn hasSearchTable(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "<table id=\"subt_tabula\"") != null and
        std.mem.indexOf(u8, body, "<tbody") != null;
}

fn requireSearchResponse(status: std.http.Status, body: []const u8) !void {
    if (status == .too_many_requests) return error.RateLimited;
    if (status == .ok) return;
    if (status == .internal_server_error and hasSearchTable(body)) return;
    return error.UnexpectedHttpStatus;
}

fn resolveProviderUrl(allocator: Allocator, href: []const u8) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderUrl(resolved);
    return resolved;
}

fn validateProviderUrl(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.query != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "/filmu-subtitri/download/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.UnsafeHttpTarget;
    const download_id = path[prefix.len..];
    if (!isSafeDownloadId(download_id)) return error.UnsafeHttpTarget;
}

fn isSafeDownloadId(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or
        std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~')) return false;
    }
    return true;
}

test "nekur parses exact movie result" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<table><tbody><tr>
        \\<td class="title"><a href="/filmu-subtitri/download/abc">The Matrix <span class="year">(1999)</span></a></td>
        \\<td class="fps">23.976</td><td>tester</td>
        \\<td><a href="https://www.imdb.com/title/tt0133093/">imdb</a></td>
        \\<td class="notes"></td><td class="notes"></td>
        \\</tr></tbody></table>
    ,
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 1999), response.items[0].year);
    try std.testing.expectEqualStrings("tt0133093", response.items[0].imdb_id.?);
    try std.testing.expectEqualStrings("23.976", response.items[0].fps.?);
    try std.testing.expectEqualStrings("https://subtitri.nekur.net/filmu-subtitri/download/abc", response.items[0].download_url);
}

test "nekur skips malformed and unrelated rows before a valid result" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<table><tbody>
        \\<tr><td class="title"><a href="https://attacker.example/archive.zip">The Matrix (1999)</a></td></tr>
        \\<tr><td class="title"><a href="/filmu-subtitri/download/unrelated">Unrelated Film (2001)</a></td></tr>
        \\<tr><td class="title"><a href="/filmu-subtitri/download/valid-42">The Matrix (1999)</a></td></tr>
        \\</tbody></table>
    ,
        "The Matrix",
    );
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("https://subtitri.nekur.net/filmu-subtitri/download/valid-42", response.items[0].download_url);
}

test "nekur imdb metadata scans later canonical anchors without dropping rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<table><tbody>
        \\<tr><td class="title"><a href="/filmu-subtitri/download/valid-1">The Matrix (1999)</a></td>
        \\<td class="fps">23.976</td><td>tester</td><td>
        \\<a href="https://attacker.example/title/tt9999999/">bad origin</a>
        \\<a href="https://www.imdb.com/title/tt0000000/">zero</a>
        \\<a href="https://www.imdb.com/title/tt0133093/">valid</a></td></tr>
        \\<tr><td class="title"><a href="/filmu-subtitri/download/valid-2">The Matrix (2000)</a></td>
        \\<td class="fps">24</td><td>tester</td><td>
        \\<a href="https://www.imdb.com/name/nm0000001/">not a title</a></td></tr>
        \\</tbody></table>
    ,
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings("tt0133093", response.items[0].imdb_id.?);
    try std.testing.expect(response.items[1].imdb_id == null);
}

test "nekur accepts only canonical IMDb title URLs" {
    const allocator = std.testing.allocator;
    const valid = (try parseImdbId(allocator, "https://www.imdb.com/title/tt1234567890/")) orelse
        return error.TestUnexpectedResult;
    defer allocator.free(valid);
    try std.testing.expectEqualStrings("tt1234567890", valid);

    for ([_][]const u8{
        "http://www.imdb.com/title/tt0133093/",
        "https://imdb.com/title/tt0133093/",
        "https://www.imdb.com.evil.example/title/tt0133093/",
        "https://www.imdb.com/name/tt0133093/",
        "https://www.imdb.com/title/tt123456/",
        "https://www.imdb.com/title/tt0000000/",
        "https://www.imdb.com/title/tt0133093/?ref_=x",
        "https://www.imdb.com/title/tt0133093/extra",
    }) |url| try std.testing.expect((try parseImdbId(allocator, url)) == null);
}

test "nekur recognizes valid search table on upstream error response" {
    try std.testing.expect(hasSearchTable(
        \\<table id="subt_tabula" class="sTable"><tbody><tr></tr></tbody></table>
    ));
    try std.testing.expect(!hasSearchTable("<html><h1>Internal Server Error</h1></html>"));
    try requireSearchResponse(.internal_server_error, "<table id=\"subt_tabula\"><tbody></tbody></table>");
    try std.testing.expectError(error.RateLimited, requireSearchResponse(.too_many_requests, "busy"));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireSearchResponse(.internal_server_error, "<h1>Internal Server Error</h1>"));
}

test "nekur rejects unsafe provider urls before fetch" {
    try validateProviderUrl("https://subtitri.nekur.net/filmu-subtitri/download/abc-123.zip");
    for ([_][]const u8{
        "http://127.0.0.1/file.zip",
        "https://user@subtitri.nekur.net/file.zip",
        "https://subtitri.nekur.net.attacker.example/file.zip",
        "https://subtitri.nekur.net/admin",
        "https://subtitri.nekur.net/filmu-subtitri/download/abc?next=/admin",
        "https://subtitri.nekur.net/filmu-subtitri/download/abc#fragment",
        "https://subtitri.nekur.net/filmu-subtitri/download/..",
        "https://subtitri.nekur.net/filmu-subtitri/download/a%2fb",
        "https://subtitri.nekur.net/filmu-subtitri/download/a/b",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(url));
    }
}

test "live nekur movie download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitri.nekur.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
