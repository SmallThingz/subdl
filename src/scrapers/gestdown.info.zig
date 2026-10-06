const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://api.gestdown.info";

pub const SearchItem = struct {
    id: []const u8,
    title: []const u8,
    seasons: []const i64,
    tvdb_id: ?i64,
    tmdb_id: ?i64,
    slug: []const u8,
};

pub const SubtitleItem = struct {
    season: i64,
    episode: i64,
    episode_title: []const u8,
    version: []const u8,
    language: []const u8,
    hearing_impaired: bool,
    source: ?[]const u8,
    filename: []const u8,
    download_url: []const u8,
};

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
        if (trimmed.len < 3) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/shows/search/{s}", .{ site, encoded });
        const response = try fetchJson(self.client, a, url);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const root_obj = switch (root) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const shows_value = root_obj.get("shows") orelse return error.MissingField;
        const shows = switch (shows_value) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (shows.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const id = common.jsonString(obj, "id") orelse continue;
            const name = common.jsonString(obj, "name") orelse continue;
            const slug = common.jsonString(obj, "slug") orelse "";
            const seasons_value = obj.get("seasons") orelse continue;
            const seasons_array = switch (seasons_value) {
                .array => |value| value,
                else => continue,
            };
            var seasons: std.ArrayListUnmanaged(i64) = .empty;
            for (seasons_array.items) |season_value| {
                if (common.jsonInt(season_value)) |season| try seasons.append(a, season);
            }

            try items.append(a, .{
                .id = try a.dupe(u8, id),
                .title = try a.dupe(u8, name),
                .seasons = try seasons.toOwnedSlice(a),
                .tvdb_id = if (obj.get("tvDbId")) |value| common.jsonInt(value) else null,
                .tmdb_id = if (obj.get("tmdbId")) |value| common.jsonInt(value) else null,
                .slug = try a.dupe(u8, slug),
            });
        }

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitles(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const encoded_id = try common.encodeUriComponent(a, item.id);

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        for (item.seasons) |season| {
            const url = try std.fmt.allocPrint(a, "{s}/shows/{s}/{d}/English", .{ site, encoded_id, season });
            const response = try fetchJson(self.client, a, url);
            const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
            const obj = switch (root) {
                .object => |value| value,
                else => continue,
            };
            const episodes_value = obj.get("episodes") orelse continue;
            const episodes = switch (episodes_value) {
                .array => |value| value,
                else => continue,
            };

            for (episodes.items) |episode_value| {
                const episode_obj = switch (episode_value) {
                    .object => |value| value,
                    else => continue,
                };
                const episode_number = if (episode_obj.get("number")) |value| common.jsonInt(value) orelse 0 else 0;
                const episode_season = if (episode_obj.get("season")) |value| common.jsonInt(value) orelse season else season;
                const episode_title = common.jsonString(episode_obj, "title") orelse "";
                const subtitles_value = episode_obj.get("subtitles") orelse continue;
                const episode_subtitles = switch (subtitles_value) {
                    .array => |value| value,
                    else => continue,
                };

                for (episode_subtitles.items) |subtitle_value| {
                    const subtitle_obj = switch (subtitle_value) {
                        .object => |value| value,
                        else => continue,
                    };
                    const download_uri = common.jsonString(subtitle_obj, "downloadUri") orelse continue;
                    const version = common.jsonString(subtitle_obj, "version") orelse "subtitle";
                    const language = common.jsonString(subtitle_obj, "language") orelse "English";
                    const source = common.jsonString(subtitle_obj, "source");
                    const hearing_impaired = if (subtitle_obj.get("hearingImpaired")) |value|
                        switch (value) {
                            .bool => |flag| flag,
                            else => false,
                        }
                    else
                        false;
                    const filename = try std.fmt.allocPrint(
                        a,
                        "{s}-S{d}-E{d}-{s}.srt",
                        .{ item.title, episode_season, episode_number, version },
                    );

                    try subtitles.append(a, .{
                        .season = episode_season,
                        .episode = episode_number,
                        .episode_title = try a.dupe(u8, episode_title),
                        .version = try a.dupe(u8, version),
                        .language = try a.dupe(u8, language),
                        .hearing_impaired = hearing_impaired,
                        .source = if (source) |value| try a.dupe(u8, value) else null,
                        .filename = filename,
                        .download_url = (try resolveOptionalPublicDownloadUrl(a, download_uri)) orelse continue,
                    });
                }
            }
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }
};

fn resolvePublicDownloadUrl(allocator: Allocator, download_uri: []const u8) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, download_uri);
    errdefer allocator.free(resolved);
    try common.validatePublicHttpUrl(resolved);
    return resolved;
}

fn resolveOptionalPublicDownloadUrl(allocator: Allocator, download_uri: []const u8) !?[]const u8 {
    return resolvePublicDownloadUrl(allocator, download_uri) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        return null;
    };
}

fn fetchJson(client: *std.http.Client, allocator: Allocator, url: []const u8) !common.HttpResponse {
    return fetchJsonWith(common.fetchBytes, common.sleepMillisecondsCancelable, client, allocator, url);
}

fn fetchJsonWith(
    comptime fetch: anytype,
    comptime sleep: anytype,
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
) !common.HttpResponse {
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        const response = try fetch(client, allocator, url, .{
            .accept = "application/json",
            .allow_non_ok = true,
            .max_attempts = 2,
            // This helper classifies rate limiting itself, so it must see the
            // first 429 instead of letting the transport retry or cache it.
            .retry_on_429 = false,
            .cache = false,
            .require_public_origin = true,
        });
        if (response.status == .ok) return response;
        if (@backingInt(response.status) == 423 and attempt + 1 < 3) {
            allocator.free(response.body);
            try sleep(500);
            continue;
        }
        if (response.status == .too_many_requests) {
            allocator.free(response.body);
            return error.RateLimited;
        }
        allocator.free(response.body);
        return error.UnexpectedHttpStatus;
    }
    return error.UnexpectedHttpStatus;
}

test "gestdown parses show and episode payloads" {
    const allocator = std.testing.allocator;
    var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    const show_json =
        \\{"shows":[{"id":"78c56d8e-df30-4354-b65a-b9933b8a70a4","name":"Chernobyl","nbSeasons":1,"seasons":[1],"tvDbId":360893,"tmdbId":87108,"slug":"chernobyl"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, show_json, .{});
    defer parsed.deinit();
    const shows = parsed.value.object.get("shows").?.array;
    try std.testing.expectEqual(@as(usize, 1), shows.items.len);
    try std.testing.expectEqualStrings("Chernobyl", shows.items[0].object.get("name").?.string);
}

test "gestdown treats rate limits as uncached terminal responses" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(options.allow_non_ok);
            try std.testing.expectEqual(@as(usize, 2), options.max_attempts);
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expect(!options.cache);
            try std.testing.expect(options.require_public_origin);
            return .{ .status = .too_many_requests, .body = try allocator.dupe(u8, "limited") };
        }

        fn noSleep(_: u64) !void {
            return error.UnexpectedSleep;
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    try std.testing.expectError(error.RateLimited, fetchJsonWith(
        Fixture.fetch,
        Fixture.noSleep,
        &fixture.client,
        std.testing.allocator,
        site ++ "/shows/search/matrix",
    ));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "gestdown rejects unsafe provider download targets" {
    const allocator = std.testing.allocator;
    const valid = try resolvePublicDownloadUrl(allocator, "/subtitles/episode.srt");
    defer allocator.free(valid);
    try std.testing.expectEqualStrings("https://api.gestdown.info/subtitles/episode.srt", valid);

    for ([_][]const u8{
        "http://127.0.0.1/subtitles/episode.srt",
        "https://user@example.com/subtitles/episode.srt",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, resolvePublicDownloadUrl(allocator, url));
    }
}

test "gestdown optional download URL preserves allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, resolveOptionalPublicDownloadUrl(failing.allocator(), "/subtitles/episode.srt"));
    try std.testing.expect(failing.has_induced_failure);

    try std.testing.expect((try resolveOptionalPublicDownloadUrl(std.testing.allocator, "http://127.0.0.1/subtitles/episode.srt")) == null);
}

test "live gestdown search, subtitles and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "gestdown.info")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("Chernobyl");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitles(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, download.body, "-->") != null);
}
