const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const api_site = "https://api.subt.is/v1";
const web_site = "https://subtis.io";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    slug: []const u8,
    page_url: []const u8,
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
        if (trimmed.len < 2) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/titles/search/{s}", .{ api_site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .max_attempts = 2,
            .require_public_origin = true,
        });

        return parseSearchJson(common.takeArena(&arena), response.body);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        try validateWebEndpoint(item.page_url);

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .max_attempts = 2,
            .require_public_origin = true,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var anchors = parsed.doc.queryAll("a[href^='https://api.subt.is/v1/subtitle/link/']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            try validateApiEndpoint(href);
            if (seen.contains(href)) continue;
            try seen.put(a, href, {});
            const id = trailingPathSegment(href) orelse "subtitle";
            try subtitles.append(a, .{
                .filename = try std.fmt.allocPrint(a, "subtis-{s}.srt", .{id}),
                .download_url = try a.dupe(u8, href),
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }
};

fn parseSearchJson(arena: std.heap.ArenaAllocator, body: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const obj = switch (root) {
        .object => |value| value,
        else => return error.InvalidFieldType,
    };
    const results_value = obj.get("results") orelse return error.MissingField;
    const results = switch (results_value) {
        .array => |value| value,
        else => return error.InvalidFieldType,
    };

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    for (results.items) |entry| {
        const entry_obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const media_type = common.jsonString(entry_obj, "type") orelse continue;
        if (!std.mem.eql(u8, media_type, "movie")) continue;
        const title = common.jsonString(entry_obj, "title_name") orelse continue;
        const slug = common.jsonString(entry_obj, "slug") orelse continue;
        const year = if (entry_obj.get("year")) |value| common.jsonInt(value) else null;

        const page_url = try std.fmt.allocPrint(a, "{s}/subtitles/movie/{s}", .{ web_site, slug });
        try validateWebEndpoint(page_url);
        try items.append(a, .{
            .title = try a.dupe(u8, title),
            .year = year,
            .slug = try a.dupe(u8, slug),
            .page_url = page_url,
        });
    }

    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn trailingPathSegment(url: []const u8) ?[]const u8 {
    var end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    if (end == 0) return null;
    const slash = std.mem.lastIndexOfScalar(u8, url[0..end], '/') orelse return url[0..end];
    if (slash + 1 >= end) return null;
    return url[slash + 1 .. end];
}

fn validateWebEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(web_site, url))) return error.UnsafeHttpTarget;
}

fn validateApiEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(api_site, url))) return error.UnsafeHttpTarget;
}

test "subtis rejects unsafe web and API endpoints" {
    try std.testing.expectError(error.UnsafeHttpTarget, validateWebEndpoint("http://127.0.0.1/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateWebEndpoint("https://user:pass@subtis.io/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateWebEndpoint("https://subtis.io.evil.com/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateApiEndpoint("https://api.subt.is.evil.com/v1/subtitle/link/1"));
}

test "subtis parses movie search payload" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchJson(arena,
        \\{"total":2,"results":[{"slug":"the-matrix-1999","type":"movie","year":1999,"title_name":"The Matrix"},{"slug":"matrix-show","type":"tv","year":2024,"title_name":"Matrix Show"}]}
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 1999), response.items[0].year);
    try std.testing.expectEqualStrings("https://subtis.io/subtitles/movie/the-matrix-1999", response.items[0].page_url);
}

test "live subtis movie search subtitle listing and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtis.io")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, subtitles.subtitles[0].download_url, "https://api.subt.is/v1/subtitle/link/"));

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,application/x-subrip,*/*",
        .max_attempts = 2,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, download.body, "-->") != null);
}
