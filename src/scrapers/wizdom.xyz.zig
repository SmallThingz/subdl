const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://wizdom.xyz";
const api_site = site ++ "/api";
const tmdb_site = "https://api.tmdb.org/3";
const tmdb_api_key_env = "SUBDL_WIZDOM_TMDB_API_KEY";
// Public key shipped by the current Bazarr+ Wizdom provider.
const legacy_tmdb_api_key = "a51ee051bcd762543373903de296e0a3";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    imdb_id: []const u8,
    season: ?i64,
    episode: ?i64,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    language_code: []const u8,
    filename: []const u8,
    release_info: []const u8,
    download_url: []const u8,
    season: ?i64,
    episode: ?i64,
};

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const QueryParts = struct {
    title: []const u8,
    year: ?i64,
    season: ?i64,
    episode: ?i64,
};

fn releaseFetchOptions() common.FetchOptions {
    return .{
        .accept = "application/json",
        .cache = false,
        .max_attempts = 2,
        .require_public_origin = true,
        .require_https = true,
        .require_same_origin = true,
    };
}

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

        const parts = parseQuery(query);
        const title = std.mem.trim(u8, parts.title, " \t\r\n");
        if (title.len == 0) return .{ .arena = arena, .items = &.{} };
        const tmdb_api_key = try resolveTmdbApiKey(a);

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        if (parts.episode == null) {
            if (try self.resolveCandidate(a, title, .movie, parts.year, parts.season, parts.episode, tmdb_api_key)) |item|
                try items.append(a, item);
        }
        if (try self.resolveCandidate(a, title, .tv, parts.year, parts.season, parts.episode, tmdb_api_key)) |item|
            try items.append(a, item);

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        if (!isImdbTitleId(item.imdb_id)) return error.InvalidDownloadUrl;
        const encoded_imdb = try common.encodeUriComponent(a, item.imdb_id);
        const url = try std.fmt.allocPrint(a, "{s}/releases/{s}", .{ api_site, encoded_imdb });
        const response = try common.fetchBytes(self.client, a, url, releaseFetchOptions());
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const obj = switch (root) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        const subs = obj.get("subs") orelse return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = &.{},
        });

        switch (item.media_kind) {
            .movie => try appendMovieSubtitles(a, subs, &subtitles),
            .tv => try appendTvSubtitles(a, subs, item.season, item.episode, &subtitles),
        }

        const owned = try subtitles.toOwnedSlice(a);
        std.mem.sort(SubtitleItem, owned, {}, subtitleLessThan);
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = owned,
        });
    }

    fn resolveCandidate(
        self: *Scraper,
        allocator: Allocator,
        title: []const u8,
        media_kind: MediaKind,
        requested_year: ?i64,
        requested_season: ?i64,
        requested_episode: ?i64,
        tmdb_api_key: []const u8,
    ) !?SearchItem {
        return self.resolveCandidateWith(allocator, title, media_kind, requested_year, requested_season, requested_episode, tmdb_api_key, common.fetchBytes);
    }

    fn resolveCandidateWith(
        self: *Scraper,
        allocator: Allocator,
        title: []const u8,
        media_kind: MediaKind,
        requested_year: ?i64,
        requested_season: ?i64,
        requested_episode: ?i64,
        tmdb_api_key: []const u8,
        comptime fetch: anytype,
    ) !?SearchItem {
        const encoded_title = try common.encodeUriComponent(allocator, title);
        const search_url = try buildTmdbSearchUrl(allocator, media_kind, tmdb_api_key, encoded_title, requested_year);
        const response = try fetch(self.client, allocator, search_url, common.FetchOptions{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, response.body, .{});
        const root_obj = switch (root) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const results = switch (root_obj.get("results") orelse return error.MissingField) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };
        if (results.items.len == 0) return null;

        const wanted = try common.normalizeTitle(allocator, title);
        var chosen: ?std.json.ObjectMap = null;
        var chosen_score: i32 = -1;
        // Rank exact matches before applying the candidate cap. Both passes
        // inspect the same search response; only the winner needs a detail
        // request. If there is no exact match, retain the bounded fallback.
        for ([_]bool{ true, false }) |exact_pass| {
            var eligible_ids: [10]i64 = undefined;
            var eligible_count: usize = 0;
            for (results.items) |entry| {
                const obj = switch (entry) {
                    .object => |value| value,
                    else => continue,
                };
                const candidate_id = common.jsonIntField(obj, "id") orelse continue;
                if (candidate_id <= 0) continue;
                const candidate_title = switch (media_kind) {
                    .movie => common.jsonString(obj, "title") orelse continue,
                    .tv => common.jsonString(obj, "name") orelse continue,
                };
                const normalized = try common.normalizeTitle(allocator, candidate_title);
                if (!matchesTitle(normalized, wanted)) continue;
                if (std.mem.eql(u8, normalized, wanted) != exact_pass) continue;
                const candidate_date = switch (media_kind) {
                    .movie => common.jsonString(obj, "release_date"),
                    .tv => common.jsonString(obj, "first_air_date"),
                };
                const candidate_year = if (candidate_date) |date| parseYear(date) else null;
                if (requested_year) |year| {
                    if (candidate_year == null or candidate_year.? != year) continue;
                }
                var duplicate = false;
                for (eligible_ids[0..eligible_count]) |eligible_id| {
                    if (eligible_id == candidate_id) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                if (eligible_count == eligible_ids.len) break;
                eligible_ids[eligible_count] = candidate_id;
                eligible_count += 1;

                var score: i32 = if (std.mem.eql(u8, normalized, wanted)) 100 else 30;
                score += @intCast(std.math.clamp(common.jsonIntField(obj, "popularity") orelse 0, 0, 20));
                if (score > chosen_score) {
                    chosen = obj;
                    chosen_score = score;
                }
            }
            if (chosen != null) break;
        }
        const chosen_obj = chosen orelse return null;
        const tmdb_id = common.jsonIntField(chosen_obj, "id") orelse return null;
        if (tmdb_id <= 0) return null;

        const detail_path = switch (media_kind) {
            .movie => try std.fmt.allocPrint(allocator, "movie/{d}", .{tmdb_id}),
            .tv => try std.fmt.allocPrint(allocator, "tv/{d}/external_ids", .{tmdb_id}),
        };
        const detail_url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}?api_key={s}&language=en",
            .{ tmdb_site, detail_path, tmdb_api_key },
        );
        const detail_response = try fetch(self.client, allocator, detail_url, common.FetchOptions{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        if (detail_response.status != .ok) return error.UnexpectedHttpStatus;

        const detail_root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, detail_response.body, .{});
        const detail_obj = switch (detail_root) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const imdb_id = common.jsonString(detail_obj, "imdb_id") orelse return null;
        if (!isImdbTitleId(imdb_id)) return null;

        const candidate_title = switch (media_kind) {
            .movie => common.jsonString(chosen_obj, "title") orelse title,
            .tv => common.jsonString(chosen_obj, "name") orelse title,
        };
        const date = switch (media_kind) {
            .movie => common.jsonString(chosen_obj, "release_date"),
            .tv => common.jsonString(chosen_obj, "first_air_date"),
        };
        const year = if (date) |value| parseYear(value) else null;

        return .{
            .title = try allocator.dupe(u8, candidate_title),
            .year = year,
            .media_kind = media_kind,
            .imdb_id = try allocator.dupe(u8, imdb_id),
            .season = if (media_kind == .tv) requested_season else null,
            .episode = if (media_kind == .tv) requested_episode else null,
            .page_url = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
                site,
                if (media_kind == .movie) "movies" else "tvshows",
                imdb_id,
            }),
        };
    }
};

fn resolveTmdbApiKey(allocator: Allocator) ![]const u8 {
    const configured = try common.getenvOwned(allocator, tmdb_api_key_env);
    return selectTmdbApiKey(configured);
}

fn selectTmdbApiKey(configured: ?[]const u8) ![]const u8 {
    const key = configured orelse legacy_tmdb_api_key;
    if (key.len != 32) return error.InvalidTmdbApiKey;
    for (key) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f'))
            return error.InvalidTmdbApiKey;
    }
    return key;
}

fn buildTmdbSearchUrl(
    allocator: Allocator,
    media_kind: MediaKind,
    tmdb_api_key: []const u8,
    encoded_title: []const u8,
    requested_year: ?i64,
) ![]u8 {
    const kind_name = switch (media_kind) {
        .movie => "movie",
        .tv => "tv",
    };
    if (requested_year) |year| {
        return std.fmt.allocPrint(
            allocator,
            "{s}/search/{s}?api_key={s}&query={s}&language=en&{s}={d}",
            .{ tmdb_site, kind_name, tmdb_api_key, encoded_title, if (media_kind == .movie) "year" else "first_air_date_year", year },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}/search/{s}?api_key={s}&query={s}&language=en",
        .{ tmdb_site, kind_name, tmdb_api_key, encoded_title },
    );
}

fn appendMovieSubtitles(
    allocator: Allocator,
    subs_value: std.json.Value,
    out: *std.ArrayListUnmanaged(SubtitleItem),
) !void {
    const array = switch (subs_value) {
        .array => |value| value,
        else => return error.InvalidFieldType,
    };
    for (array.items) |entry| {
        const obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        try appendRelease(allocator, obj, null, null, out);
    }
}

fn appendTvSubtitles(
    allocator: Allocator,
    subs_value: std.json.Value,
    wanted_season: ?i64,
    wanted_episode: ?i64,
    out: *std.ArrayListUnmanaged(SubtitleItem),
) !void {
    const seasons_obj = switch (subs_value) {
        .object => |value| value,
        else => return error.InvalidFieldType,
    };
    var season_it = seasons_obj.iterator();
    while (season_it.next()) |season_entry| {
        const season = std.fmt.parseInt(i64, season_entry.key_ptr.*, 10) catch continue;
        if (season < 0 or season > 200) continue;
        if (wanted_season) |wanted| if (season != wanted) continue;

        const episodes_obj = switch (season_entry.value_ptr.*) {
            .object => |value| value,
            else => continue,
        };
        var episode_it = episodes_obj.iterator();
        while (episode_it.next()) |episode_entry| {
            const episode = std.fmt.parseInt(i64, episode_entry.key_ptr.*, 10) catch continue;
            if (episode <= 0 or episode > 1000) continue;
            if (wanted_episode) |wanted| if (episode != wanted) continue;

            const releases = switch (episode_entry.value_ptr.*) {
                .array => |value| value,
                else => continue,
            };
            for (releases.items) |release| {
                const obj = switch (release) {
                    .object => |value| value,
                    else => continue,
                };
                try appendRelease(allocator, obj, season, episode, out);
            }
        }
    }
}

fn appendRelease(
    allocator: Allocator,
    obj: std.json.ObjectMap,
    season: ?i64,
    episode: ?i64,
    out: *std.ArrayListUnmanaged(SubtitleItem),
) !void {
    const id = common.jsonIntField(obj, "id") orelse return;
    if (id <= 0) return;
    const release = common.jsonString(obj, "version") orelse return;
    const filename = try std.fmt.allocPrint(allocator, "wizdom-{d}.zip", .{id});
    try out.append(allocator, .{
        .language_code = "he",
        .filename = filename,
        .release_info = try allocator.dupe(u8, release),
        .download_url = try std.fmt.allocPrint(allocator, "{s}/files/sub/{d}", .{ api_site, id }),
        .season = season,
        .episode = episode,
    });
}

fn subtitleLessThan(_: void, lhs: SubtitleItem, rhs: SubtitleItem) bool {
    const lhs_season = lhs.season orelse 0;
    const rhs_season = rhs.season orelse 0;
    if (lhs_season != rhs_season) return lhs_season < rhs_season;
    const lhs_episode = lhs.episode orelse 0;
    const rhs_episode = rhs.episode orelse 0;
    if (lhs_episode != rhs_episode) return lhs_episode < rhs_episode;
    return std.mem.lessThan(u8, lhs.release_info, rhs.release_info);
}

fn parseQuery(query: []const u8) QueryParts {
    var i: usize = 0;
    while (i + 4 < query.len) : (i += 1) {
        if (query[i] != 's' and query[i] != 'S') continue;
        if (i > 0 and std.ascii.isAlphanumeric(query[i - 1])) continue;
        var p = i + 1;
        const season_start = p;
        while (p < query.len and std.ascii.isDigit(query[p])) : (p += 1) {}
        if (p == season_start or p >= query.len or (query[p] != 'e' and query[p] != 'E')) continue;
        const season = std.fmt.parseInt(i64, query[season_start..p], 10) catch continue;
        p += 1;
        const episode_start = p;
        while (p < query.len and std.ascii.isDigit(query[p])) : (p += 1) {}
        if (p == episode_start) continue;
        if (p < query.len and std.ascii.isAlphanumeric(query[p])) continue;
        const episode = std.fmt.parseInt(i64, query[episode_start..p], 10) catch continue;

        var title_end = i;
        while (title_end > 0 and (std.ascii.isWhitespace(query[title_end - 1]) or
            query[title_end - 1] == '-' or query[title_end - 1] == '.' or query[title_end - 1] == '_'))
        {
            title_end -= 1;
        }
        const prefix = queryPartsWithYear(query[0..title_end], season, episode);
        if (prefix.year != null) return prefix;
        const suffix = std.mem.trim(u8, query[p..], " \t\r\n-._");
        const suffix_year = common.splitTrailingYear(suffix);
        if (suffix_year.year != null and suffix_year.title.len == 0) {
            return .{
                .title = prefix.title,
                .year = suffix_year.year,
                .season = season,
                .episode = episode,
            };
        }
        return prefix;
    }
    return queryPartsWithYear(query, null, null);
}

fn queryPartsWithYear(raw_title: []const u8, season: ?i64, episode: ?i64) QueryParts {
    const title_year = common.splitTrailingYear(raw_title);
    return .{ .title = title_year.title, .year = title_year.year, .season = season, .episode = episode };
}

fn isImdbTitleId(value: []const u8) bool {
    if (value.len < 3 or value.len > 16 or value[0] != 't' or value[1] != 't') return false;
    for (value[2..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn matchesTitle(candidate: []const u8, wanted: []const u8) bool {
    if (wanted.len == 0) return false;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, candidate, cursor, wanted)) |start| {
        const end = start + wanted.len;
        if ((start == 0 or candidate[start - 1] == ' ') and
            (end == candidate.len or candidate[end] == ' ')) return true;
        cursor = start + 1;
    }
    return false;
}

const fixture_tmdb_api_key = "0123456789abcdef0123456789abcdef";

test "wizdom TMDB key override is strict and precedes the legacy fallback" {
    try std.testing.expectEqualStrings(fixture_tmdb_api_key, try selectTmdbApiKey(fixture_tmdb_api_key));
    try std.testing.expectEqualStrings(legacy_tmdb_api_key, try selectTmdbApiKey(null));

    for ([_][]const u8{
        "",
        "0123456789abcdef0123456789abcde",
        "0123456789abcdef0123456789abcdef0",
        "0123456789abcdef0123456789abcdeg",
        " 0123456789abcdef0123456789abcdef",
        "0123456789abcdef0123456789abcde\n",
        "ABCDEF0123456789ABCDEF0123456789",
    }) |invalid| {
        try std.testing.expectError(error.InvalidTmdbApiKey, selectTmdbApiKey(invalid));
    }
}

test "wizdom TMDB URL diagnostics redact the key and query" {
    const url = try buildTmdbSearchUrl(
        std.testing.allocator,
        .movie,
        fixture_tmdb_api_key,
        "The%20Matrix",
        1999,
    );
    defer std.testing.allocator.free(url);
    const safe = try common.redactUrlForLog(std.testing.allocator, url);
    defer std.testing.allocator.free(safe);

    try std.testing.expectEqualStrings("https://api.tmdb.org/<redacted>", safe);
    try std.testing.expect(std.mem.indexOf(u8, safe, fixture_tmdb_api_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "The%20Matrix") == null);
}

test "wizdom pins release metadata and validates IMDb title identifiers" {
    const options = releaseFetchOptions();
    try std.testing.expect(options.require_public_origin);
    try std.testing.expect(options.require_https);
    try std.testing.expect(options.require_same_origin);
    try std.testing.expect(!options.cache);

    try std.testing.expect(isImdbTitleId("tt0133093"));
    for ([_][]const u8{
        "",
        "tt",
        "TT0133093",
        "ttabc",
        "tt123?x",
        "tt123\n",
        "tt123456789012345",
    }) |invalid| try std.testing.expect(!isImdbTitleId(invalid));

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    try std.testing.expectError(error.InvalidDownloadUrl, scraper.fetchSubtitlesBySearchItem(.{
        .title = "invalid",
        .year = null,
        .media_kind = .movie,
        .imdb_id = "tt?",
        .season = null,
        .episode = null,
        .page_url = "https://wizdom.xyz/movies/tt?",
    }));
}

test "wizdom propagates acquisition failures and rejects unrelated candidates" {
    const Mock = struct {
        fn canceled(_: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            return error.Canceled;
        }
        fn oom(_: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            return error.OutOfMemory;
        }
        fn badContract(_: *std.http.Client, a: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{ .status = .ok, .body = try a.dupe(u8, "{}") };
        }
        fn forbidden(_: *std.http.Client, a: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{ .status = .forbidden, .body = try a.dupe(u8, "Forbidden") };
        }
        fn invalidJson(_: *std.http.Client, a: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{ .status = .ok, .body = try a.dupe(u8, "<html>challenge</html>") };
        }
        fn unrelated(_: *std.http.Client, a: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{ .status = .ok, .body = try a.dupe(u8, "{\"results\":[{\"id\":1,\"title\":\"Unrelated\",\"popularity\":100}]}") };
        }
        fn matching(_: *std.http.Client, a: Allocator, url: []const u8, opts: common.FetchOptions) !common.HttpResponse {
            if (!opts.require_https or !opts.require_public_origin or !opts.require_same_origin or opts.cache)
                return error.TestUnexpectedResult;
            if (std.mem.indexOf(u8, url, "api_key=" ++ fixture_tmdb_api_key) == null)
                return error.TestUnexpectedResult;
            return .{ .status = .ok, .body = try a.dupe(u8, if (std.mem.indexOf(u8, url, "/search/") != null)
                "{\"results\":[{\"id\":1,\"title\":\"Unrelated\",\"popularity\":100},{\"id\":2,\"title\":\"The Matrix\",\"popularity\":1}]}"
            else
                "{\"imdb_id\":\"tt0133093\"}") };
        }
        fn yearQualified(_: *std.http.Client, a: Allocator, url: []const u8, _: common.FetchOptions) !common.HttpResponse {
            if (std.mem.indexOf(u8, url, "/search/") != null) {
                if (std.mem.indexOf(u8, url, "&year=1999") == null) return error.TestUnexpectedResult;
                return .{ .status = .ok, .body = try a.dupe(
                    u8,
                    "{\"results\":[{\"id\":1,\"title\":\"The Matrix\",\"release_date\":\"2021-12-16\",\"popularity\":20},{\"id\":2,\"title\":\"The Matrix\",\"release_date\":\"1999-03-31\",\"popularity\":1}]}",
                ) };
            }
            return .{ .status = .ok, .body = try a.dupe(u8, "{\"imdb_id\":\"tt0133093\"}") };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    const a = arena.allocator();
    try std.testing.expectError(error.Canceled, scraper.resolveCandidateWith(a, "The Matrix", .movie, null, null, null, fixture_tmdb_api_key, Mock.canceled));
    try std.testing.expectError(error.OutOfMemory, scraper.resolveCandidateWith(a, "The Matrix", .movie, null, null, null, fixture_tmdb_api_key, Mock.oom));
    try std.testing.expectError(error.MissingField, scraper.resolveCandidateWith(a, "The Matrix", .movie, null, null, null, fixture_tmdb_api_key, Mock.badContract));
    try std.testing.expectError(error.UnexpectedHttpStatus, scraper.resolveCandidateWith(a, "The Matrix", .movie, null, null, null, fixture_tmdb_api_key, Mock.forbidden));
    try std.testing.expectError(error.SyntaxError, scraper.resolveCandidateWith(a, "The Matrix", .movie, null, null, null, fixture_tmdb_api_key, Mock.invalidJson));
    try std.testing.expect((try scraper.resolveCandidateWith(a, "The Matrix", .movie, null, null, null, fixture_tmdb_api_key, Mock.unrelated)) == null);
    const chosen = (try scraper.resolveCandidateWith(a, "The Matrix", .movie, null, null, null, fixture_tmdb_api_key, Mock.matching)).?;
    try std.testing.expectEqualStrings("tt0133093", chosen.imdb_id);
    const year_chosen = (try scraper.resolveCandidateWith(a, "The Matrix", .movie, 1999, null, null, fixture_tmdb_api_key, Mock.yearQualified)).?;
    try std.testing.expectEqual(@as(?i64, 1999), year_chosen.year);
    try std.testing.expect(!matchesTitle("matrixed", "matrix"));
}

test "wizdom malformed TMDB identifiers do not shadow a valid candidate" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            const body = if (self.calls == 1) blk: {
                try std.testing.expect(std.mem.indexOf(u8, url, "/search/movie?") != null);
                break :blk
                \\{"results":[
                \\  {"title":"The Matrix","popularity":20},
                \\  {"id":0,"title":"The Matrix","popularity":20},
                \\  {"id":-1,"title":"The Matrix","popularity":20},
                \\  {"id":{},"title":"The Matrix","popularity":20},
                \\  {"id":"603","title":"The Matrix","popularity":20},
                \\  {"id":null,"title":"The Matrix","popularity":20},
                \\  {"id":true,"title":"The Matrix","popularity":20},
                \\  {"id":[],"title":"The Matrix","popularity":20},
                \\  {"id":0,"title":"The Matrix","popularity":20},
                \\  {"id":-99,"title":"The Matrix","popularity":20},
                \\  {"id":603,"title":"The Matrix","popularity":1}
                \\]}
                ;
            } else blk: {
                try std.testing.expectEqual(@as(usize, 2), self.calls);
                try std.testing.expect(std.mem.startsWith(u8, url, tmdb_site ++ "/movie/603?"));
                break :blk "{\"imdb_id\":\"tt0133093\"}";
            };
            return .{ .status = .ok, .body = try allocator.dupe(u8, body) };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    const candidate = try scraper.resolveCandidateWith(arena.allocator(), "The Matrix", .movie, null, null, null, fixture_tmdb_api_key, Fixture.fetch);
    try std.testing.expect(candidate != null);
    try std.testing.expectEqualStrings("tt0133093", candidate.?.imdb_id);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

const CandidateCapFixture = struct {
    client: std.http.Client,
    calls: usize = 0,
    partial_count: usize,
    tail_exact: bool,
    expected_id: i64,

    fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
        const self: *@This() = @fieldParentPtr("client", client);
        self.calls += 1;
        try std.testing.expect(options.require_public_origin and options.require_https and options.require_same_origin);
        try std.testing.expect(!options.cache);
        try std.testing.expectEqual(@as(usize, 2), options.max_attempts);
        if (self.calls == 1) {
            try std.testing.expect(std.mem.startsWith(u8, url, tmdb_site ++ "/search/movie?"));
            var body: std.ArrayListUnmanaged(u8) = .empty;
            errdefer body.deinit(allocator);
            try body.appendSlice(allocator, "{\"results\":[");
            for (0..self.partial_count) |index| {
                const row = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"title\":\"Target Part {d}\",\"popularity\":0}},", .{ index + 1, index + 1 });
                defer allocator.free(row);
                try body.appendSlice(allocator, row);
            }
            const tail = if (self.tail_exact)
                "{\"id\":603,\"title\":\"Target\",\"popularity\":20}]}"
            else
                "{\"id\":603,\"title\":\"Target Extra\",\"popularity\":20}]}";
            try body.appendSlice(allocator, tail);
            return .{ .status = .ok, .body = try body.toOwnedSlice(allocator) };
        }
        try std.testing.expectEqual(@as(usize, 2), self.calls);
        const expected_path = try std.fmt.allocPrint(allocator, "{s}/movie/{d}?", .{ tmdb_site, self.expected_id });
        defer allocator.free(expected_path);
        try std.testing.expect(std.mem.startsWith(u8, url, expected_path));
        return .{ .status = .ok, .body = try allocator.dupe(u8, "{\"imdb_id\":\"tt0133093\"}") };
    }

    fn verify(partial_count: usize, tail_exact: bool, expected_id: i64, expected_title: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fixture: @This() = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .partial_count = partial_count,
            .tail_exact = tail_exact,
            .expected_id = expected_id,
        };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        const result = (try scraper.resolveCandidateWith(arena.allocator(), "Target", .movie, null, null, null, fixture_tmdb_api_key, fetch)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_title, result.title);
        try std.testing.expectEqualStrings("tt0133093", result.imdb_id);
        // Selection only examines the already fetched search page: one search
        // request plus one detail request, including when the cap is crossed.
        try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    }
};

test "wizdom later exact candidate survives ten eligible partial matches" {
    try CandidateCapFixture.verify(10, true, 603, "Target");
}

test "wizdom candidate cap preserves its boundary and bounded partial fallback" {
    try CandidateCapFixture.verify(9, true, 603, "Target");
    // Without an exact match, preserve the first-ten candidate budget and
    // stable ties: an eleventh, more popular partial must not displace ID1.
    try CandidateCapFixture.verify(10, false, 1, "Target Part 1");
}

fn parseYear(date: []const u8) ?i64 {
    if (date.len < 4) return null;
    for (date[0..4]) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, date[0..4], 10) catch null;
}

test "wizdom parses SxxExx query and release ordering" {
    const parts = parseQuery("Chernobyl S01E05");
    try std.testing.expectEqualStrings("Chernobyl", parts.title);
    try std.testing.expectEqual(@as(?i64, 1), parts.season);
    try std.testing.expectEqual(@as(?i64, 5), parts.episode);

    const movie_year = parseQuery("The Matrix (1999)");
    try std.testing.expectEqualStrings("The Matrix", movie_year.title);
    try std.testing.expectEqual(@as(?i64, 1999), movie_year.year);
    const episode_year = parseQuery("Chernobyl (2019) S01E05");
    try std.testing.expectEqualStrings("Chernobyl", episode_year.title);
    try std.testing.expectEqual(@as(?i64, 2019), episode_year.year);
    const trailing_episode_year = parseQuery("Chernobyl S01E05 (2019)");
    try std.testing.expectEqualStrings("Chernobyl", trailing_episode_year.title);
    try std.testing.expectEqual(@as(?i64, 2019), trailing_episode_year.year);
    try std.testing.expectEqual(@as(?i64, 1), trailing_episode_year.season);
    try std.testing.expectEqual(@as(?i64, 5), trailing_episode_year.episode);

    const embedded_token = parseQuery("Mass1E2");
    try std.testing.expectEqualStrings("Mass1E2", embedded_token.title);
    try std.testing.expectEqual(@as(?i64, null), embedded_token.season);
    const trailing_text = parseQuery("Show S1E2foo");
    try std.testing.expectEqualStrings("Show S1E2foo", trailing_text.title);
    try std.testing.expectEqual(@as(?i64, null), trailing_text.season);

    const numeric_title = parseQuery("Class of 1999");
    try std.testing.expectEqualStrings("Class of 1999", numeric_title.title);
    try std.testing.expectEqual(@as(?i64, null), numeric_title.year);

    var values = [_]SubtitleItem{
        .{ .language_code = "he", .filename = "b.zip", .release_info = "b", .download_url = "b", .season = 1, .episode = 2 },
        .{ .language_code = "he", .filename = "a.zip", .release_info = "a", .download_url = "a", .season = 1, .episode = 1 },
    };
    std.mem.sort(SubtitleItem, &values, {}, subtitleLessThan);
    try std.testing.expectEqual(@as(?i64, 1), values[0].episode);
}

test "live wizdom movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "wizdom.xyz")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix");
    defer movie.deinit();
    const movie_item = for (movie.items) |item| {
        if (item.media_kind == .movie and std.mem.eql(u8, item.imdb_id, "tt0133093")) break item;
    } else return error.TestUnexpectedResult;
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie_item);
    defer movie_subtitles.deinit();
    try std.testing.expect(movie_subtitles.subtitles.len > 0);
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
        .require_https = true,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Chernobyl S01E01");
    defer tv.deinit();
    const tv_item = for (tv.items) |item| {
        if (item.media_kind == .tv and std.mem.eql(u8, item.imdb_id, "tt7366338")) break item;
    } else return error.TestUnexpectedResult;
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv_item);
    defer tv_subtitles.deinit();
    try std.testing.expect(tv_subtitles.subtitles.len > 0);
    try std.testing.expectEqual(@as(?i64, 1), tv_subtitles.subtitles[0].episode);
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
        .require_https = true,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}

test "Wizdom query accepts season zero specials" {
    const parsed = parseQuery("House S00E01");
    try std.testing.expectEqualStrings("House", parsed.title);
    try std.testing.expectEqual(@as(?i64, 0), parsed.season);
    try std.testing.expectEqual(@as(?i64, 1), parsed.episode);
}
