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
        });

        // Nekur currently emits a complete search table with HTTP 500. Keep
        // this exception provider-local and reject every other non-OK shape.
        if (response.status != .ok and
            !(response.status == .internal_server_error and hasSearchTable(response.body)))
        {
            return error.UnexpectedHttpStatus;
        }

        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = "lv",
            .filename = try std.fmt.allocPrint(a, "{s}.zip", .{item.title}),
            .download_url = try a.dupe(u8, item.download_url),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
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

    var rows = parsed.doc.queryAll("tbody > tr");
    while (rows.next()) |row| {
        const anchor = row.queryOne("td.title > a[href]") orelse continue;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const raw_title = try common.innerTextTrimmedOwned(a, anchor);
        if (raw_title.len == 0) continue;

        const split = common.splitTrailingYear(raw_title);
        const title = try a.dupe(u8, split.title);
        const page_url = try common.resolveUrl(a, site, href);

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
            const imdb_anchor = (imdb_cell orelse break :blk null).queryOne("a[href]") orelse break :blk null;
            const imdb_href = common.getAttributeValueSafe(imdb_anchor, "href") orelse break :blk null;
            break :blk try parseImdbId(a, imdb_href);
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

        const normalized = try common.normalizeTitle(a, title);
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

fn parseImdbId(allocator: Allocator, url: []const u8) !?[]const u8 {
    const marker = "/title/";
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    const rest = url[start + marker.len ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const id = rest[0..slash];
    if (id.len < 3 or !std.mem.startsWith(u8, id, "tt")) return null;
    for (id[2..]) |c| if (!std.ascii.isDigit(c)) return null;
    return try allocator.dupe(u8, id);
}

fn hasSearchTable(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "<table id=\"subt_tabula\"") != null and
        std.mem.indexOf(u8, body, "<tbody") != null;
}

test "nekur parses exact movie result" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<table><tbody><tr>
        \\<td class="title"><a href="/filmu-subtitri/download/abc">The Matrix <span class="year">(1999)</span></a></td>
        \\<td class="fps">23.976</td><td>tester</td>
        \\<td><a href="http://www.imdb.com/title/tt0133093/">imdb</a></td>
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

test "nekur recognizes valid search table on upstream error response" {
    try std.testing.expect(hasSearchTable(
        \\<table id="subt_tabula" class="sTable"><tbody><tr></tr></tbody></table>
    ));
    try std.testing.expect(!hasSearchTable("<html><h1>Internal Server Error</h1></html>"));
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
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
