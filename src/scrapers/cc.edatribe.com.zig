const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://cc.edatribe.com";

pub const MediaKind = common.MediaKind;

pub const SearchItem = common.MediaSearchLink;

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const Catalog = struct {
    path: []const u8,
    media_kind: MediaKind,
};

const catalogs = [_]Catalog{
    .{ .path = "/files/Movie/", .media_kind = .movie },
    .{ .path = "/files/TV%20series/", .media_kind = .tv },
    .{ .path = "/files/TV%20series(Incomplete)/", .media_kind = .tv },
};

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

        const wanted = try common.normalizeTitle(a, query);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        for (catalogs) |catalog| {
            const catalog_url = try std.fmt.allocPrint(a, "{s}{s}", .{ site, catalog.path });
            const response = try common.fetchBytes(self.client, a, catalog_url, .{
                .accept = "application/json",
                .max_attempts = 2,
            });
            try appendCatalogMatches(a, response.body, wanted, catalog_url, catalog.media_kind, &seen, &exact, &partial);
        }

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        try items.appendSlice(a, exact.items);
        try items.appendSlice(a, partial.items);
        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "application/json",
            .max_attempts = 2,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const entries = switch (root) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        for (entries.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const entry_type = common.jsonString(obj, "type") orelse continue;
            if (!std.mem.eql(u8, entry_type, "file")) continue;
            const filename = common.jsonString(obj, "name") orelse continue;
            if (!common.isSubtitleFilename(filename)) continue;
            const encoded_filename = try common.encodeUriComponent(a, filename);
            const download_url = try std.fmt.allocPrint(a, "{s}{s}", .{ item.page_url, encoded_filename });

            try subtitles.append(a, .{
                .language_code = "en",
                .filename = try a.dupe(u8, filename),
                .download_url = download_url,
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }
};

fn appendCatalogMatches(
    allocator: Allocator,
    body: []const u8,
    wanted: []const u8,
    catalog_url: []const u8,
    media_kind: MediaKind,
    seen: *std.StringHashMapUnmanaged(void),
    exact: *std.ArrayListUnmanaged(SearchItem),
    partial: *std.ArrayListUnmanaged(SearchItem),
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const entries = switch (parsed.value) {
        .array => |value| value,
        else => return error.InvalidFieldType,
    };

    for (entries.items) |entry| {
        const obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const entry_type = common.jsonString(obj, "type") orelse continue;
        if (!std.mem.eql(u8, entry_type, "directory") and !std.mem.eql(u8, entry_type, "other")) continue;
        const raw_name = common.jsonString(obj, "name") orelse continue;
        const title = stripCatalogPrefix(raw_name);
        if (title.len == 0) continue;

        const normalized = try common.normalizeTitle(allocator, title);
        defer allocator.free(normalized);
        if (std.mem.indexOf(u8, normalized, wanted) == null and std.mem.indexOf(u8, wanted, normalized) == null) continue;

        const encoded_name = try common.encodeUriComponent(allocator, raw_name);
        defer allocator.free(encoded_name);
        const page_url = try std.fmt.allocPrint(allocator, "{s}{s}/", .{ catalog_url, encoded_name });
        if (seen.contains(page_url)) continue;
        try seen.put(allocator, page_url, {});

        const item: SearchItem = .{
            .title = try allocator.dupe(u8, title),
            .media_kind = media_kind,
            .page_url = page_url,
        };
        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(allocator, item)
        else
            try partial.append(allocator, item);
    }
}

fn stripCatalogPrefix(name: []const u8) []const u8 {
    if (name.len < 3 or name[0] != '[') return std.mem.trim(u8, name, " \t\r\n");
    const close = std.mem.indexOfScalar(u8, name, ']') orelse return std.mem.trim(u8, name, " \t\r\n");
    if (close + 1 >= name.len) return "";
    return std.mem.trim(u8, name[close + 1 ..], " \t\r\n");
}

test "closed caption browser parses catalog prefixes and exact matches" {
    try std.testing.expectEqualStrings("Spirited Away", stripCatalogPrefix("[M008]Spirited Away"));
    try std.testing.expectEqualStrings("Attack on Titan", stripCatalogPrefix("[0010]Attack on Titan"));

    const allocator = std.testing.allocator;
    const wanted = try common.normalizeTitle(allocator, "Attack on Titan");
    defer allocator.free(wanted);
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    defer {
        for (exact.items) |item| {
            allocator.free(item.title);
            allocator.free(item.page_url);
        }
        exact.deinit(allocator);
    }
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    defer {
        for (partial.items) |item| {
            allocator.free(item.title);
            allocator.free(item.page_url);
        }
        partial.deinit(allocator);
    }

    try appendCatalogMatches(
        allocator,
        \\[
        \\{"name":"[0010]Attack on Titan","type":"directory"},
        \\{"name":"[0011]Attack on Titan S2","type":"directory"}
        \\]
    ,
        wanted,
        site ++ "/files/TV%20series/",
        .tv,
        &seen,
        &exact,
        &partial,
    );
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqual(@as(usize, 1), partial.items.len);
    try std.testing.expectEqualStrings("Attack on Titan", exact.items[0].title);
}

test "live closed caption browser movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "cc.edatribe.com")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Spirited Away");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    try std.testing.expect(movie.items[0].media_kind == .movie);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    try std.testing.expect(movie_subtitles.subtitles.len > 0);
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, movie_download.body, "-->") != null);

    var tv = try scraper.search("Attack on Titan");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    try std.testing.expect(tv.items[0].media_kind == .tv);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    try std.testing.expect(tv_subtitles.subtitles.len >= 20);
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, tv_download.body, "-->") != null);
}
