const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.prijevodi-online.org";
const api = site ++ "/api/v1";

pub const SearchItem = struct {
    title: []const u8,
    series_id: i64,
    slug: []const u8,
    page_url: []const u8,
};

pub const SubtitleItem = common.EpisodeSubtitleFile;

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
        const url = try std.fmt.allocPrint(
            a,
            "{s}/search/results?q={s}&type=series&page=1&perPage=20",
            .{ api, encoded },
        );
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const root_obj = switch (root) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const results_obj = switch (root_obj.get("results") orelse return error.MissingField) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const items_value = switch (results_obj.get("items") orelse return error.MissingField) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        const wanted = try common.normalizeTitle(a, trimmed);
        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var other: std.ArrayListUnmanaged(SearchItem) = .empty;

        for (items_value.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const item_type = common.jsonString(obj, "type") orelse continue;
            if (!std.mem.eql(u8, item_type, "series")) continue;
            const title = common.jsonString(obj, "title") orelse continue;
            const slug = common.jsonString(obj, "slug") orelse continue;
            const series_id = common.jsonIntField(obj, "id") orelse continue;
            if (series_id <= 0) continue;

            const normalized = try common.normalizeTitle(a, title);
            if (normalized.len == 0) continue;
            if (std.mem.indexOf(u8, normalized, wanted) == null and
                std.mem.indexOf(u8, wanted, normalized) == null) continue;

            const item: SearchItem = .{
                .title = try a.dupe(u8, title),
                .series_id = series_id,
                .slug = try a.dupe(u8, slug),
                .page_url = try std.fmt.allocPrint(a, "{s}/series/view/{s}", .{ site, slug }),
            };
            const match_kind = common.jsonString(obj, "matchKind");
            if ((match_kind != null and std.mem.eql(u8, match_kind.?, "exact")) or std.mem.eql(u8, normalized, wanted))
                try exact.append(a, item)
            else
                try other.append(a, item);
        }

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        try out.appendSlice(a, exact.items);
        try out.appendSlice(a, other.items);
        return .{ .arena = arena, .items = try out.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const url = try std.fmt.allocPrint(
            a,
            "{s}/translations/series?seriesId={d}&page=1&perPage=1000&publishedRowsOnly=true&hasFile=true",
            .{ api, item.series_id },
        );
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const root_obj = switch (root) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const translations_obj = switch (root_obj.get("translations") orelse return error.MissingField) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const items_value = switch (translations_obj.get("items") orelse return error.MissingField) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        for (items_value.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const translation_id = common.jsonIntField(obj, "id") orelse continue;
            const season = common.jsonIntField(obj, "seasonNumber") orelse continue;
            const episode = common.jsonIntField(obj, "episodeNumber") orelse continue;
            const language_code = common.jsonString(obj, "languageCode") orelse continue;
            const filename = common.jsonString(obj, "fileName") orelse continue;
            if (translation_id <= 0 or season < 0 or episode <= 0 or filename.len == 0) continue;
            if (obj.get("isPublished")) |published| {
                if (published == .bool and !published.bool) continue;
            }

            try subtitles.append(a, .{
                .language_code = try a.dupe(u8, language_code),
                .filename = try a.dupe(u8, filename),
                .download_url = try std.fmt.allocPrint(a, "{s}/translations/series/{d}/download", .{ api, translation_id }),
                .season = season,
                .episode = episode,
            });
        }

        const owned = try subtitles.toOwnedSlice(a);
        std.mem.sort(SubtitleItem, owned, {}, subtitleLessThan);

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = owned,
        };
    }
};

fn subtitleLessThan(_: void, lhs: SubtitleItem, rhs: SubtitleItem) bool {
    if (lhs.season != rhs.season) return lhs.season < rhs.season;
    if (lhs.episode != rhs.episode) return lhs.episode < rhs.episode;
    const language_order = std.mem.order(u8, lhs.language_code, rhs.language_code);
    if (language_order != .eq) return language_order == .lt;
    return std.mem.lessThan(u8, lhs.filename, rhs.filename);
}

test "prijevodi orders episode subtitles deterministically" {
    var values = [_]SubtitleItem{
        .{ .language_code = "sr", .filename = "b.zip", .download_url = "b", .season = 2, .episode = 1 },
        .{ .language_code = "sr", .filename = "a.zip", .download_url = "a", .season = 1, .episode = 2 },
        .{ .language_code = "hr", .filename = "c.zip", .download_url = "c", .season = 1, .episode = 1 },
    };
    std.mem.sort(SubtitleItem, &values, {}, subtitleLessThan);
    try std.testing.expectEqual(@as(i64, 1), values[0].season);
    try std.testing.expectEqual(@as(i64, 1), values[0].episode);
    try std.testing.expectEqualStrings("hr", values[0].language_code);
}

test "live prijevodi online tv search listing and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "prijevodi-online.org")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Chernobyl");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    try std.testing.expectEqualStrings("Chernobyl", search.items[0].title);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len >= 5);
    try std.testing.expectEqual(@as(i64, 1), subtitles.subtitles[0].season);
    try std.testing.expectEqual(@as(i64, 1), subtitles.subtitles[0].episode);

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
