const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://api.gestdown.info";
const max_season_requests: usize = 128;

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
        var seen_ids = std.StringHashMapUnmanaged(void).empty;
        for (shows.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const id = common.jsonString(obj, "id") orelse continue;
            const name = common.jsonString(obj, "name") orelse continue;
            if (!isCanonicalUuid(id) or seen_ids.contains(id)) continue;
            const slug = common.jsonString(obj, "slug") orelse "";
            const seasons_value = obj.get("seasons") orelse continue;
            const seasons_array = switch (seasons_value) {
                .array => |value| value,
                else => continue,
            };
            var seasons: std.ArrayListUnmanaged(i64) = .empty;
            var seen_seasons = std.AutoHashMapUnmanaged(i64, void).empty;
            var season_request_count: usize = 0;
            for (seasons_array.items) |season_value| {
                if (common.jsonInt(season_value)) |season| {
                    if (season <= 0 or seen_seasons.contains(season)) continue;
                    try consumeRequestBudget(&season_request_count, max_season_requests);
                    try seen_seasons.put(a, season, {});
                    try seasons.append(a, season);
                }
            }

            try items.append(a, .{
                .id = try a.dupe(u8, id),
                .title = try a.dupe(u8, name),
                .seasons = try seasons.toOwnedSlice(a),
                .tvdb_id = if (obj.get("tvDbId")) |value| common.jsonInt(value) else null,
                .tmdb_id = if (obj.get("tmdbId")) |value| common.jsonInt(value) else null,
                .slug = try a.dupe(u8, slug),
            });
            try seen_ids.put(a, try a.dupe(u8, id), {});
        }

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitles(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesUsing(fetchJson, item);
    }

    fn fetchSubtitlesUsing(self: *Scraper, comptime fetch: anytype, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        if (!isCanonicalUuid(item.id)) return error.InvalidDownloadUrl;
        const encoded_id = try common.encodeUriComponent(a, item.id);

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var seasons: std.ArrayListUnmanaged(i64) = .empty;
        var seen_seasons = std.AutoHashMapUnmanaged(i64, void).empty;
        var season_request_count: usize = 0;
        for (item.seasons) |season| {
            if (season <= 0) continue;
            if (seen_seasons.contains(season)) continue;
            try consumeRequestBudget(&season_request_count, max_season_requests);
            try seen_seasons.put(a, season, {});
            try seasons.append(a, season);
        }

        for (seasons.items) |season| {
            const url = try std.fmt.allocPrint(a, "{s}/shows/{s}/{d}/English", .{ site, encoded_id, season });
            const response = try fetch(self.client, a, url);
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
                if (episode_number <= 0 or episode_season <= 0) continue;
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
                    const download_url = (try resolveOptionalPublicDownloadUrl(a, download_uri)) orelse continue;
                    const dedupe_key = try std.fmt.allocPrint(a, "{d}:{d}:{s}", .{ episode_season, episode_number, download_url });
                    if (seen.contains(dedupe_key)) continue;
                    try seen.put(a, dedupe_key, {});
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
                        .download_url = download_url,
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

fn consumeRequestBudget(count: *usize, limit: usize) !void {
    const next = std.math.add(usize, count.*, 1) catch return error.ResponseTooLarge;
    if (next > limit) return error.ResponseTooLarge;
    count.* = next;
}

fn resolvePublicDownloadUrl(allocator: Allocator, download_uri: []const u8) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, download_uri);
    errdefer allocator.free(resolved);
    try common.validatePublicHttpUrl(resolved);
    if (!(try common.sameOrigin(site, resolved))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(resolved) catch return error.InvalidDownloadUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "/subtitles/download/";
    if (!std.mem.startsWith(u8, path, prefix) or !isCanonicalUuid(path[prefix.len..])) return error.InvalidDownloadUrl;
    return resolved;
}

fn isCanonicalUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
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
            .require_https = true,
            .require_same_origin = true,
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
    try std.testing.expect(isCanonicalUuid("78c56d8e-df30-4354-b65a-b9933b8a70a4"));
    try std.testing.expect(!isCanonicalUuid("../shows/admin"));
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
            try std.testing.expect(options.require_https);
            try std.testing.expect(options.require_same_origin);
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

test "gestdown rejects excessive season fanout before any request" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.UnexpectedRequest;
        }
    };

    var seasons: [max_season_requests + 1]i64 = undefined;
    for (&seasons, 0..) |*season, index| season.* = @intCast(index + 1);

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    try std.testing.expectError(error.ResponseTooLarge, scraper.fetchSubtitlesUsing(Fixture.fetch, .{
        .id = "78c56d8e-df30-4354-b65a-b9933b8a70a4",
        .title = "Fixture",
        .seasons = &seasons,
        .tvdb_id = null,
        .tmdb_id = null,
        .slug = "fixture",
    }));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "gestdown rejects unsafe provider download targets" {
    const allocator = std.testing.allocator;
    const valid = try resolvePublicDownloadUrl(allocator, "/subtitles/download/922e35ad-d27c-4c2e-bdd5-c897e64d6699");
    defer allocator.free(valid);
    try std.testing.expectEqualStrings("https://api.gestdown.info/subtitles/download/922e35ad-d27c-4c2e-bdd5-c897e64d6699", valid);

    for ([_][]const u8{
        "http://127.0.0.1/subtitles/download/922e35ad-d27c-4c2e-bdd5-c897e64d6699",
        "https://user@example.com/subtitles/download/922e35ad-d27c-4c2e-bdd5-c897e64d6699",
        "https://cdn.example.com/subtitles/download/922e35ad-d27c-4c2e-bdd5-c897e64d6699",
        "https://api.gestdown.info/admin/922e35ad-d27c-4c2e-bdd5-c897e64d6699",
        "https://api.gestdown.info/subtitles/download/../admin",
        "https://api.gestdown.info/subtitles/download/a%2fb",
        "https://api.gestdown.info/subtitles/download/922e35ad-d27c-4c2e-bdd5-c897e64d6699?next=/admin",
    }) |url| {
        const unexpected = resolvePublicDownloadUrl(allocator, url) catch continue;
        allocator.free(unexpected);
        return error.TestUnexpectedResult;
    }
}

test "gestdown optional download URL preserves allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, resolveOptionalPublicDownloadUrl(failing.allocator(), "/subtitles/download/922e35ad-d27c-4c2e-bdd5-c897e64d6699"));
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
