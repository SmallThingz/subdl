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
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/titles/search/{s}", .{ api_site, encoded });
        const response = try common.fetchBytes(self.client, a, url, fixedFetchOptions("application/json"));

        return parseSearchJson(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        try validateWebEndpoint(item.page_url, item.slug);

        const response = try common.fetchBytes(self.client, a, item.page_url, fixedFetchOptions("text/html,application/xhtml+xml,*/*"));

        const subtitles = try parseSubtitleLinks(a, response.body);

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn fixedFetchOptions(accept: []const u8) common.FetchOptions {
    return .{
        .accept = accept,
        .max_attempts = 2,
        .require_public_origin = true,
        .require_https = true,
        .require_same_origin = true,
    };
}

fn parseSearchJson(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };

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

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    for (results.items) |entry| {
        const entry_obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const media_type = common.jsonString(entry_obj, "type") orelse continue;
        if (!std.mem.eql(u8, media_type, "movie")) continue;
        const title = common.jsonString(entry_obj, "title_name") orelse continue;
        const normalized = try common.normalizeTitle(a, title);
        const exact_match = std.mem.eql(u8, normalized, wanted);
        if (!exact_match and !common.normalizedTitlesRelated(normalized, wanted)) continue;
        const slug = common.jsonString(entry_obj, "slug") orelse continue;
        if (!isCanonicalSlug(slug)) continue;
        const year = if (entry_obj.get("year")) |value| common.jsonInt(value) else null;

        const page_url = try std.fmt.allocPrint(a, "{s}/subtitles/movie/{s}", .{ web_site, slug });
        validateWebEndpoint(page_url, slug) catch continue;
        const item: SearchItem = .{
            .title = try a.dupe(u8, title),
            .year = year,
            .slug = try a.dupe(u8, slug),
            .page_url = page_url,
        };
        if (exact_match) try exact.append(a, item) else try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn parseSubtitleLinks(allocator: Allocator, body: []const u8) ![]const SubtitleItem {
    var parsed = try common.parseHtmlStable(allocator, body);
    defer parsed.deinit();
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    errdefer {
        for (subtitles.items) |item| {
            allocator.free(item.filename);
            allocator.free(item.download_url);
        }
        subtitles.deinit(allocator);
    }
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);
    var anchors = parsed.doc.queryAll("a[href^='https://api.subt.is/v1/subtitle/link/']");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const id = subtitleLinkId(href) orelse continue;
        if (seen.contains(href)) continue;
        try seen.put(allocator, href, {});
        const filename = try std.fmt.allocPrint(allocator, "subtis-{s}.srt", .{id});
        const download_url = allocator.dupe(u8, href) catch |err| {
            allocator.free(filename);
            return err;
        };
        subtitles.append(allocator, .{
            .filename = filename,
            .download_url = download_url,
        }) catch |err| {
            allocator.free(filename);
            allocator.free(download_url);
            return err;
        };
    }
    return subtitles.toOwnedSlice(allocator);
}

fn validateWebEndpoint(url: []const u8, expected_slug: []const u8) !void {
    if (!isCanonicalSlug(expected_slug)) return error.UnsafeHttpTarget;
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(web_site, url))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.query != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "/subtitles/movie/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.UnsafeHttpTarget;
    const slug = path[prefix.len..];
    if (!std.mem.eql(u8, slug, expected_slug)) return error.UnsafeHttpTarget;
}

fn validateApiEndpoint(url: []const u8) !void {
    if (subtitleLinkId(url) == null) return error.UnsafeHttpTarget;
}

fn subtitleLinkId(url: []const u8) ?[]const u8 {
    common.validatePublicHttpUrl(url) catch return null;
    if (!(common.sameOrigin(api_site, url) catch false)) return null;
    const uri = std.Uri.parse(url) catch return null;
    if (uri.query != null or uri.fragment != null) return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "/v1/subtitle/link/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const id = path[prefix.len..];
    if (!isCanonicalLinkId(id)) return null;
    return id;
}

fn isCanonicalSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or value[0] == '-' or value[value.len - 1] == '-') return false;
    var previous_dash = false;
    for (value) |c| {
        if (c == '-') {
            if (previous_dash) return false;
            previous_dash = true;
        } else {
            if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
            previous_dash = false;
        }
    }
    return true;
}

fn isCanonicalLinkId(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

test "subtis rejects unsafe web and API endpoints" {
    try validateWebEndpoint("https://subtis.io/subtitles/movie/the-matrix-1999", "the-matrix-1999");
    try validateApiEndpoint("https://api.subt.is/v1/subtitle/link/1");
    for ([_][]const u8{
        "http://127.0.0.1/private",
        "https://user:pass@subtis.io/subtitles/movie/the-matrix-1999",
        "https://subtis.io.evil.com/subtitles/movie/the-matrix-1999",
        "https://subtis.io/subtitles/movie/the-matrix-1999/extra",
        "https://subtis.io/subtitles/movie/the-matrix-1999?next=/admin",
    }) |url| try std.testing.expectError(error.UnsafeHttpTarget, validateWebEndpoint(url, "the-matrix-1999"));
    for ([_][]const u8{
        "https://api.subt.is.evil.com/v1/subtitle/link/1",
        "https://api.subt.is/v1/subtitle/link/1/extra",
        "https://api.subt.is/v1/subtitle/link/1?next=/admin",
        "https://api.subt.is/v1/subtitle/link/%2e%2e",
        "https://api.subt.is/v1/subtitle/link/..",
    }) |url| try std.testing.expectError(error.UnsafeHttpTarget, validateApiEndpoint(url));
}

test "subtis parses movie search payload" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchJson(arena,
        \\{"total":3,"results":[{"slug":"../admin?x=1","type":"movie","year":1999,"title_name":"Malformed"},{"slug":"the-matrix-1999","type":"movie","year":1999,"title_name":"The Matrix"},{"slug":"matrix-show","type":"tv","year":2024,"title_name":"Matrix Show"}]}
    , "The Matrix");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 1999), response.items[0].year);
    try std.testing.expectEqualStrings("https://subtis.io/subtitles/movie/the-matrix-1999", response.items[0].page_url);
}

test "subtis fixed fetches stay on their HTTPS origin" {
    const options = fixedFetchOptions("application/json");
    try std.testing.expect(options.require_public_origin);
    try std.testing.expect(options.require_https);
    try std.testing.expect(options.require_same_origin);
}

test "subtis search relevance uses the returned title field" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchJson(
        arena,
        \\{"results":[{"slug":"preacher-2016","type":"movie","title_name":"Preacher"},{"slug":"jack-reacher-2012","type":"movie","title_name":"Jack Reacher"},{"slug":"matrix-1999","type":"movie","title_name":"The Matrix"}]}
    ,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Jack Reacher", response.items[0].title);
}

test "subtis skips malformed selector links without dropping valid siblings" {
    const allocator = std.testing.allocator;
    const subtitles = try parseSubtitleLinks(allocator, "<a href='https://api.subt.is/v1/subtitle/link/../admin'>bad</a>" ++
        "<a href='https://api.subt.is/v1/subtitle/link/1?next=/admin'>bad query</a>" ++
        "<a href='https://api.subt.is/v1/subtitle/link/valid-2'>good</a>");
    defer {
        for (subtitles) |item| {
            allocator.free(item.filename);
            allocator.free(item.download_url);
        }
        allocator.free(subtitles);
    }

    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings("subtis-valid-2.srt", subtitles[0].filename);
    try std.testing.expectEqualStrings("https://api.subt.is/v1/subtitle/link/valid-2", subtitles[0].download_url);
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
