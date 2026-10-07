const std = @import("std");
const common = @import("common.zig");
const cf_shared = @import("opensubtitles_com_cf.zig");

const Allocator = std.mem.Allocator;
const api_base = "https://api.subsource.net/v1";
const api_host = "api.subsource.net";
const api_session_root = "https://api.subsource.net/";
const site = "https://subsource.net";
const default_subsource_user_agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36";
const max_configured_auth_bytes: usize = 4096;

pub const SearchOptions = struct {
    /// The SubSource search endpoint returns movies and tvseries together. When
    /// enabled, tvseries rows include season links so callers can fetch one
    /// season-specific subtitle page instead of scraping the generic series URL.
    include_seasons: bool = true,
    result_limit: usize = 5000,
    cf_clearance: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    auto_cloudflare_session: bool = false,
};

pub const SubtitlesOptions = struct {
    include_seasons: bool = true,
    page_start: usize = 1,
    max_pages: usize = 1,
    resolve_download_tokens: bool = false,
    cf_clearance: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    auto_cloudflare_session: bool = false,
};

pub const SeasonItem = struct {
    season: i64,
    link: []const u8,
};

pub const SearchItem = struct {
    id: i64,
    title: []const u8,
    media_type: []const u8,
    link: []const u8,
    release_year: ?i64,
    subtitle_count: ?i64,
    seasons: []const SeasonItem,
};

pub const SubtitleItem = struct {
    id: i64,
    language_raw: ?[]const u8,
    language_code: ?[]const u8,
    release_info: ?[]const u8,
    release_type: ?[]const u8,
    details_path: []const u8,
    download_token: ?[]const u8,
    download_url: ?[]const u8,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    query_used: []const u8,
    items: []const SearchItem,
    page: usize = 1,
    has_prev_page: bool = false,
    has_next_page: bool = false,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitlesResponse = common.PagedTitledSubtitlesResponse(SubtitleItem);

const Auth = struct {
    cf_clearance: ?[]const u8,
    user_agent: []const u8,
    browser_session: ?cf_shared.Session = null,
    owned_cf_clearance: ?[]u8 = null,
    owned_user_agent: ?[]u8 = null,

    fn deinit(self: *Auth, allocator: Allocator) void {
        if (self.browser_session) |*session| session.deinit(allocator);
        if (self.owned_cf_clearance) |value| allocator.free(value);
        if (self.owned_user_agent) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchWithOptions(query, .{});
    }

    pub fn searchWithOptions(self: *Scraper, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const query_trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (query_trimmed.len == 0) {
            return common.finishResponse(SearchResponse, &arena, .{
                .arena = arena,
                .query_used = try a.dupe(u8, ""),
                .items = &.{},
                .page = 1,
                .has_prev_page = false,
                .has_next_page = false,
            });
        }
        var auth = try resolveAuth(a, options.cf_clearance, options.user_agent);
        defer auth.deinit(a);

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.AutoHashMapUnmanaged(i64, void).empty;
        var query_used: []const u8 = try a.dupe(u8, query_trimmed);

        // Keep broad queries broad. The browser uses movie/search directly and
        // that endpoint returns both movie and tvseries results; the suggestion
        // endpoint is only a fallback for empty exact searches.
        try appendSearchResults(self.client, a, &out, &seen, query_used, options, &auth);
        if (out.items.len == 0 and query_trimmed.len > 0) {
            const suggested = try resolveSearchQuery(self.client, a, query_trimmed);
            if (!std.mem.eql(u8, suggested, query_used)) {
                query_used = suggested;
                try appendSearchResults(self.client, a, &out, &seen, query_used, options, &auth);
            }
        }
        rankSearchResults(out.items, query_used);

        return common.finishResponse(SearchResponse, &arena, .{
            .arena = arena,
            .query_used = query_used,
            .items = try out.toOwnedSlice(a),
            .page = 1,
            .has_prev_page = false,
            .has_next_page = false,
        });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemWithOptions(item, .{});
    }

    pub fn fetchSubtitlesBySearchItemWithOptions(self: *Scraper, item: SearchItem, options: SubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var auth = try resolveAuth(a, options.cf_clearance, options.user_agent);
        defer auth.deinit(a);

        var endpoints: std.ArrayListUnmanaged([]const u8) = .empty;
        if (try pathToSubtitles(a, item.link)) |path| {
            try endpoints.append(a, path);
        }
        if (options.include_seasons) {
            for (item.seasons) |season| {
                if (try pathToSubtitles(a, season.link)) |path| {
                    try endpoints.append(a, path);
                }
            }
        }

        var seen_endpoint = std.StringHashMapUnmanaged(void).empty;
        var seen_subtitle = std.StringHashMapUnmanaged(void).empty;
        var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var has_next_page = false;

        for (endpoints.items) |endpoint| {
            if (seen_endpoint.contains(endpoint)) continue;
            try seen_endpoint.put(a, endpoint, {});

            const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
            var page = if (options.page_start == 0) 1 else options.page_start;
            var traversed: usize = 0;

            while (traversed < max_pages) {
                const endpoint_url = if (page <= 1)
                    try std.fmt.allocPrint(a, "{s}{s}", .{ api_base, endpoint })
                else
                    try std.fmt.allocPrint(a, "{s}{s}?page={d}", .{ api_base, endpoint, page });
                try validateSubtitlesListingApiUrl(endpoint_url);

                const response = try fetchApiJsonWith(fetchApiJsonRequest, acquireBrowserAuth, self.client, a, endpoint_url, null, &auth, options);

                const parsed = try std.json.parseFromSlice(std.json.Value, a, response.body, .{});

                const root = switch (parsed.value) {
                    .object => |o| o,
                    else => return error.InvalidFieldType,
                };
                const subtitles_v = root.get("subtitles") orelse return error.MissingField;
                const subtitles_arr = switch (subtitles_v) {
                    .array => |arr| arr,
                    else => return error.InvalidFieldType,
                };

                for (subtitles_arr.items) |entry| {
                    const obj = switch (entry) {
                        .object => |o| o,
                        else => continue,
                    };

                    const raw_details_path = objString(obj, "link") orelse
                        objString(obj, "details_path") orelse
                        objString(obj, "path") orelse continue;
                    const details_path = canonicalizeDetailsPath(a, raw_details_path) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        continue;
                    };
                    if (seen_subtitle.contains(details_path)) continue;

                    const id = objInt(obj, "id") orelse 0;
                    const language_raw = objString(obj, "language") orelse objString(obj, "language_name");
                    const language_code = normalizeSubsourceLanguage(language_raw);
                    const release_info = objString(obj, "release_info") orelse objFirstArrayString(obj, "release_info");
                    const release_type = objString(obj, "release_type") orelse objString(obj, "type");

                    var download_token: ?[]const u8 = null;
                    var download_url: ?[]const u8 = null;
                    if (options.resolve_download_tokens) {
                        const details = try self.fetchSubtitleDetails(a, details_path, &auth, options);
                        download_token = details.download_token;
                        download_url = details.download_url;
                    }

                    try seen_subtitle.put(a, details_path, {});
                    try out.append(a, .{
                        .id = id,
                        .language_raw = language_raw,
                        .language_code = language_code,
                        .release_info = release_info,
                        .release_type = release_type,
                        .details_path = details_path,
                        .download_token = download_token,
                        .download_url = download_url,
                    });
                }

                traversed += 1;
                if (subtitlePageMayHaveNext(subtitles_arr.items.len, traversed, max_pages)) has_next_page = true;
                if (shouldStopSubtitlePagination(subtitles_arr.items.len, traversed, max_pages)) break;
                page = try checkedNextPage(page);
            }
        }

        const current_page = if (options.page_start == 0) 1 else options.page_start;
        const response_title = try a.dupe(u8, item.title);
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = response_title,
            .subtitles = try out.toOwnedSlice(a),
            .page = current_page,
            .has_prev_page = current_page > 1,
            .has_next_page = has_next_page,
        });
    }

    const SubtitleDetails = struct {
        download_token: ?[]const u8,
        download_url: ?[]const u8,
    };

    fn fetchSubtitleDetails(self: *Scraper, allocator: Allocator, details_path: []const u8, auth: *Auth, options: SubtitlesOptions) !SubtitleDetails {
        return fetchSubtitleDetailsWith(fetchApiJsonRequest, acquireBrowserAuth, self.client, allocator, details_path, auth, options);
    }

    pub fn fetchDownloadByDetailsPath(self: *Scraper, allocator: Allocator, details_path: []const u8) !common.HttpResponse {
        return self.fetchDownloadByDetailsPathWithOptions(allocator, details_path, .{});
    }

    pub fn fetchDownloadByDetailsPathWithOptions(self: *Scraper, allocator: Allocator, details_path: []const u8, options: SubtitlesOptions) !common.HttpResponse {
        return fetchDownloadByDetailsPathWith(fetchApiJsonRequest, fetchDownloadRequest, acquireBrowserAuth, self.client, allocator, details_path, options);
    }

    pub fn resolveDownloadUrl(self: *Scraper, allocator: Allocator, details_path: []const u8) !?[]u8 {
        return self.resolveDownloadUrlWithOptions(allocator, details_path, .{});
    }

    pub fn resolveDownloadUrlWithOptions(self: *Scraper, allocator: Allocator, details_path: []const u8, options: SubtitlesOptions) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var auth = try resolveAuth(a, options.cf_clearance, options.user_agent);
        defer auth.deinit(a);
        const details = try self.fetchSubtitleDetails(a, details_path, &auth, options);
        return if (details.download_url) |url| try allocator.dupe(u8, url) else null;
    }
};

fn fetchSubtitleDetailsWith(
    comptime fetch: anytype,
    comptime acquire: anytype,
    client: *std.http.Client,
    allocator: Allocator,
    details_path: []const u8,
    auth: *Auth,
    options: SubtitlesOptions,
) !Scraper.SubtitleDetails {
    const canonical_path = try canonicalizeDetailsPath(allocator, details_path);
    defer allocator.free(canonical_path);
    const url = try std.fmt.allocPrint(allocator, "{s}/subtitle/{s}", .{ api_base, canonical_path });
    try validateSubsourceApiUrl(url);

    const response = try fetchApiJsonWith(fetch, acquire, client, allocator, url, null, auth, options);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidFieldType,
    };

    const subtitle_obj = blk: {
        if (root.get("subtitle")) |subtitle_v| {
            break :blk switch (subtitle_v) {
                .object => |o| o,
                else => root,
            };
        }
        break :blk root;
    };

    const token = objString(subtitle_obj, "download_token") orelse return .{ .download_token = null, .download_url = null };
    if (token.len == 0) return .{ .download_token = null, .download_url = null };
    const encoded_token = try canonicalizeApiPathSegment(allocator, token, false);

    return .{
        .download_token = encoded_token,
        .download_url = try std.fmt.allocPrint(allocator, "{s}/subtitle/download/{s}", .{ api_base, encoded_token }),
    };
}

fn fetchDownloadByDetailsPathWith(
    comptime fetch_details: anytype,
    comptime fetch_download: anytype,
    comptime acquire: anytype,
    client: *std.http.Client,
    allocator: Allocator,
    details_path: []const u8,
    options: SubtitlesOptions,
) !common.HttpResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var auth = try resolveAuth(a, options.cf_clearance, options.user_agent);
    defer auth.deinit(a);
    const details = try fetchSubtitleDetailsWith(fetch_details, acquire, client, a, details_path, &auth, options);
    const download_url = details.download_url orelse return error.InvalidDownloadUrl;
    try validateSubsourceApiUrl(download_url);

    const response = try fetchAuthenticatedWithAllocators(fetch_download, acquire, client, allocator, a, download_url, null, &auth, options);
    errdefer allocator.free(response.body);
    try validateDownloadBody(response.body);
    return response;
}

const RankedQuery = common.TitleYear;

fn parseRankedQuery(raw: []const u8) RankedQuery {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len < 5) return .{ .title = trimmed, .year = null };

    const year_start = trimmed.len - 4;
    for (trimmed[year_start..]) |c| {
        if (!std.ascii.isDigit(c)) return .{ .title = trimmed, .year = null };
    }
    if (year_start == 0 or !std.ascii.isWhitespace(trimmed[year_start - 1])) {
        return .{ .title = trimmed, .year = null };
    }
    const title = std.mem.trimEnd(u8, trimmed[0 .. year_start - 1], " \t");
    if (title.len == 0) return .{ .title = trimmed, .year = null };
    return .{
        .title = title,
        .year = std.fmt.parseInt(i64, trimmed[year_start..], 10) catch null,
    };
}

fn searchItemRank(item: SearchItem, query: RankedQuery) u16 {
    var score: u16 = 0;
    const candidate = std.mem.trim(u8, item.title, " \t\r\n");

    if (std.ascii.eqlIgnoreCase(candidate, query.title)) {
        score += 1000;
    } else if (std.ascii.findIgnoreCase(candidate, query.title) != null) {
        score += 200;
    }

    if (query.year) |year| {
        if (item.release_year == year) score += 100;
    }

    if (item.subtitle_count) |count| {
        score += @intCast(@min(@as(i64, 50), @max(@as(i64, 0), count)));
    }
    return score;
}

fn rankSearchResults(items: []SearchItem, raw_query: []const u8) void {
    const query = parseRankedQuery(raw_query);
    if (query.title.len == 0 or items.len < 2) return;

    // Stable insertion sort: preserve upstream ordering when our title/year rank ties.
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const lhs_rank = searchItemRank(items[j], query);
            const rhs_rank = searchItemRank(items[j - 1], query);
            if (lhs_rank <= rhs_rank) break;
            std.mem.swap(SearchItem, &items[j], &items[j - 1]);
            j -= 1;
        }
    }
}

fn resolveSearchQuery(client: *std.http.Client, allocator: Allocator, query: []const u8) ![]const u8 {
    return resolveSearchQueryWith(common.fetchBytes, client, allocator, query);
}

fn resolveSearchQueryWith(comptime fetch: anytype, client: *std.http.Client, allocator: Allocator, query: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return try allocator.dupe(u8, query);

    const encoded = try common.encodeUriComponent(allocator, trimmed);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(allocator, "https://subttsearch.com/wp-content/themes/subttsearch/suggestions.php?q={s}", .{encoded});
    defer allocator.free(url);

    const response = fetch(client, allocator, url, .{
        .accept = "application/json",
        .max_attempts = 2,
        .allow_non_ok = true,
        .require_public_origin = true,
        .retry_on_429 = false,
        .cache = false,
    }) catch |err| {
        try allowOptionalSuggestionFallback(err);
        return try allocator.dupe(u8, trimmed);
    };
    defer allocator.free(response.body);
    if (!try shouldParseOptionalSuggestion(response.status, response.body)) return try allocator.dupe(u8, trimmed);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch |err| {
        try allowOptionalSuggestionFallback(err);
        return try allocator.dupe(u8, trimmed);
    };
    defer parsed.deinit();

    const results = switch (parsed.value) {
        .object => |o| blk: {
            const results_v = o.get("results") orelse return try allocator.dupe(u8, trimmed);
            break :blk switch (results_v) {
                .array => |arr| arr,
                else => return try allocator.dupe(u8, trimmed),
            };
        },
        .array => |arr| arr,
        else => return try allocator.dupe(u8, trimmed),
    };

    if (results.items.len == 0) return try allocator.dupe(u8, trimmed);
    const first = switch (results.items[0]) {
        .object => |o| o,
        else => return try allocator.dupe(u8, trimmed),
    };

    const candidate = firstNonEmptyObjString(first, "title") orelse
        firstNonEmptyObjString(first, "name") orelse
        firstNonEmptyObjString(first, "original_title") orelse
        firstNonEmptyObjString(first, "original_name") orelse
        trimmed;

    return try allocator.dupe(u8, candidate);
}

fn allowOptionalSuggestionFallback(err: anyerror) !void {
    if (common.mustPropagateOptionalFailure(err)) return err;
}

fn shouldParseOptionalSuggestion(status: std.http.Status, body: []const u8) !bool {
    if (status == .too_many_requests) return error.RateLimited;
    if (cf_shared.isChallengeBody(body)) return error.CloudflareChallenge;
    if (status == .unauthorized or status == .forbidden) return error.ProviderAccessBlocked;
    return status == .ok;
}

fn appendSearchResults(
    client: *std.http.Client,
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SearchItem),
    seen: *std.AutoHashMapUnmanaged(i64, void),
    query: []const u8,
    options: SearchOptions,
    auth: *Auth,
) !void {
    const payload = try buildSearchPayload(allocator, query, options.include_seasons, options.result_limit);

    const response = try fetchApiJsonWith(fetchApiJsonRequest, acquireBrowserAuth, client, allocator, api_base ++ "/movie/search", payload, auth, options);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidFieldType,
    };
    const results_v = root.get("results") orelse return error.MissingField;
    const results = switch (results_v) {
        .array => |arr| arr,
        else => return error.InvalidFieldType,
    };

    try appendSearchResultValues(allocator, out, seen, results.items);
}

fn appendSearchResultValues(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SearchItem),
    seen: *std.AutoHashMapUnmanaged(i64, void),
    entries: []const std.json.Value,
) !void {
    for (entries) |entry| {
        const obj = switch (entry) {
            .object => |o| o,
            else => continue,
        };

        const id = objInt(obj, "id") orelse continue;
        if (id <= 0 or seen.contains(id)) continue;

        const title = objString(obj, "title") orelse objString(obj, "name") orelse continue;
        const media_type = objString(obj, "type") orelse objString(obj, "media_type") orelse "unknown";
        const raw_link = objString(obj, "link") orelse objString(obj, "url") orelse continue;
        const link = toAbsoluteSiteLink(allocator, raw_link) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        const release_year = objInt(obj, "releaseYear") orelse objInt(obj, "release_year");
        const subtitle_count = objInt(obj, "subtitleCount") orelse objInt(obj, "subtitle_count");

        var seasons_out: std.ArrayListUnmanaged(SeasonItem) = .empty;
        var seen_seasons = std.AutoHashMapUnmanaged(i64, void).empty;
        defer seen_seasons.deinit(allocator);
        if (obj.get("seasons")) |seasons_v| {
            if (seasons_v == .array) {
                for (seasons_v.array.items) |season_v| {
                    const season_obj = switch (season_v) {
                        .object => |o| o,
                        else => continue,
                    };
                    const season_num = objInt(season_obj, "season") orelse objInt(season_obj, "number") orelse continue;
                    if (season_num <= 0 or seen_seasons.contains(season_num)) continue;
                    const season_link_raw = objString(season_obj, "link") orelse objString(season_obj, "url") orelse continue;
                    const season_link = toAbsoluteSiteLink(allocator, season_link_raw) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        continue;
                    };
                    if (!(try siteLinkBindsSeason(allocator, season_link, link, season_num))) {
                        allocator.free(season_link);
                        continue;
                    }
                    try seasons_out.append(allocator, .{ .season = season_num, .link = season_link });
                    try seen_seasons.put(allocator, season_num, {});
                }
            }
        }

        try seen.put(allocator, id, {});
        try out.append(allocator, .{
            .id = id,
            .title = title,
            .media_type = media_type,
            .link = link,
            .release_year = release_year,
            .subtitle_count = subtitle_count,
            .seasons = try seasons_out.toOwnedSlice(allocator),
        });
    }
}

fn buildSearchPayload(allocator: Allocator, query: []const u8, include_seasons: bool, limit: usize) ![]const u8 {
    const escaped_query = try escapeJson(allocator, query);
    defer allocator.free(escaped_query);

    const effective_limit = if (limit == 0) 5000 else limit;

    return std.fmt.allocPrint(
        allocator,
        "{{\"query\":\"{s}\",\"includeSeasons\":{s},\"limit\":{d}}}",
        .{
            escaped_query,
            if (include_seasons) "true" else "false",
            effective_limit,
        },
    );
}

fn requireApiResponse(response: common.HttpResponse) !void {
    if (response.status == .too_many_requests) return error.RateLimited;
    if (cf_shared.isChallengeBody(response.body)) return error.CloudflareChallenge;
    if (response.status == .unauthorized or response.status == .forbidden) return error.ProviderAccessBlocked;
    if (response.status != .ok) return error.UnexpectedHttpStatus;
}

fn validateDownloadBody(body: []const u8) !void {
    if (body.len < 4) return error.UnexpectedResponseType;
    const signature = body[0..4];
    if (!std.mem.eql(u8, signature, "PK\x03\x04") and
        !std.mem.eql(u8, signature, "PK\x05\x06") and
        !std.mem.eql(u8, signature, "PK\x07\x08"))
    {
        return error.UnexpectedResponseType;
    }
}

fn validateSubsourceApiUrl(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(api_base, url))) return error.InvalidDownloadUrl;
}

fn validateSubtitlesListingApiUrl(url: []const u8) !void {
    try validateSubsourceApiUrl(url);
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "/v1/subtitles/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidDownloadUrl;

    var segments = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const slug = segments.next() orelse return error.InvalidDownloadUrl;
    if (!isCanonicalEncodedListingSlug(slug)) return error.InvalidDownloadUrl;
    if (segments.next()) |season_segment| {
        const season_prefix = "season-";
        if (!std.mem.startsWith(u8, season_segment, season_prefix) or
            !isCanonicalPositiveDecimal(season_segment[season_prefix.len..])) return error.InvalidDownloadUrl;
    }
    if (segments.next() != null) return error.InvalidDownloadUrl;

    if (uri.query) |component| {
        const query = switch (component) {
            .raw, .percent_encoded => |value| value,
        };
        const page_prefix = "page=";
        if (!std.mem.startsWith(u8, query, page_prefix) or
            !isCanonicalPositiveDecimal(query[page_prefix.len..])) return error.InvalidDownloadUrl;
    }
}

/// Normalize the provider's subtitle-detail route to exactly
/// `<title>/<language>/<numeric id>`. The returned value never has a leading
/// slash, so callers can append it only beneath `/v1/subtitle/`.
pub fn canonicalizeDetailsPath(allocator: Allocator, details_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, details_path, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfAny(u8, trimmed, "?#") != null) return error.InvalidDownloadUrl;

    const path = if (trimmed[0] == '/') trimmed[1..] else trimmed;
    if (path.len == 0 or path[0] == '/') return error.InvalidDownloadUrl;

    var split = std.mem.splitScalar(u8, path, '/');
    var encoded: [3][]u8 = undefined;
    var initialized: usize = 0;
    errdefer for (encoded[0..initialized]) |segment| allocator.free(segment);

    while (initialized < encoded.len) : (initialized += 1) {
        const raw_segment = split.next() orelse return error.InvalidDownloadUrl;
        encoded[initialized] = try canonicalizeApiPathSegment(allocator, raw_segment, initialized == encoded.len - 1);
    }
    if (split.next() != null) return error.InvalidDownloadUrl;

    defer for (encoded) |segment| allocator.free(segment);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ encoded[0], encoded[1], encoded[2] });
}

fn canonicalizeApiPathSegment(allocator: Allocator, raw_segment: []const u8, require_digits: bool) ![]u8 {
    if (raw_segment.len == 0) return error.InvalidDownloadUrl;
    const decoded = try decodeApiPathSegment(allocator, raw_segment);
    defer allocator.free(decoded);

    if (decoded.len == 0 or std.mem.eql(u8, decoded, ".") or std.mem.eql(u8, decoded, ".."))
        return error.InvalidDownloadUrl;
    for (decoded) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\' or byte == '?' or byte == '#')
            return error.InvalidDownloadUrl;
        if (require_digits and !std.ascii.isDigit(byte)) return error.InvalidDownloadUrl;
    }
    if (require_digits and decoded[0] == '0') return error.InvalidDownloadUrl;

    return common.encodeUriComponent(allocator, decoded);
}

fn decodeApiPathSegment(allocator: Allocator, raw_segment: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < raw_segment.len) {
        if (raw_segment[index] != '%') {
            try out.append(allocator, raw_segment[index]);
            index += 1;
            continue;
        }
        if (raw_segment.len - index < 3) return error.InvalidDownloadUrl;
        const high = std.fmt.charToDigit(raw_segment[index + 1], 16) catch return error.InvalidDownloadUrl;
        const low = std.fmt.charToDigit(raw_segment[index + 2], 16) catch return error.InvalidDownloadUrl;
        try out.append(allocator, @intCast(high * 16 + low));
        index += 3;
    }

    return out.toOwnedSlice(allocator);
}

fn fetchApiJsonRequest(client: *std.http.Client, allocator: Allocator, url: []const u8, payload: ?[]const u8, auth: Auth) !common.HttpResponse {
    return if (payload) |body| postJson(client, allocator, url, body, auth, true) else getJson(client, allocator, url, auth, true);
}

fn fetchDownloadRequest(client: *std.http.Client, allocator: Allocator, url: []const u8, payload: ?[]const u8, auth: Auth) !common.HttpResponse {
    if (payload != null) return error.InvalidField;
    return getWithAuth(common.fetchBytes, client, allocator, url, auth, "application/zip, application/octet-stream, */*", true);
}

fn fetchApiJsonWith(comptime fetch: anytype, comptime acquire: anytype, client: *std.http.Client, allocator: Allocator, url: []const u8, payload: ?[]const u8, auth: *Auth, options: anytype) !common.HttpResponse {
    return fetchAuthenticatedWithAllocators(fetch, acquire, client, allocator, allocator, url, payload, auth, options);
}

fn fetchAuthenticatedWithAllocators(
    comptime fetch: anytype,
    comptime acquire: anytype,
    client: *std.http.Client,
    response_allocator: Allocator,
    auth_allocator: Allocator,
    url: []const u8,
    payload: ?[]const u8,
    auth: *Auth,
    options: anytype,
) !common.HttpResponse {
    var response = try fetch(client, response_allocator, url, payload, auth.*);
    errdefer response_allocator.free(response.body);
    // Try a cached browser session before replacing it. A session that was
    // actually rejected may be refreshed once for this request.
    const max_recoveries: usize = if (auth.browser_session == null) 2 else 1;
    var recoveries: usize = 0;
    while (cf_shared.isChallengeBody(response.body) and options.auto_cloudflare_session and recoveries < max_recoveries) : (recoveries += 1) {
        // A rate limit is terminal even when it contains challenge markup.
        if (response.status == .too_many_requests) return error.RateLimited;
        const rejected_generation = if (auth.browser_session) |session| session.generation else null;
        var refreshed = try acquire(auth_allocator, url, rejected_generation, rejected_generation != null);
        const retry = fetch(client, response_allocator, url, payload, refreshed) catch |err| {
            refreshed.deinit(auth_allocator);
            return err;
        };
        response_allocator.free(response.body);
        response = retry;
        auth.deinit(auth_allocator);
        auth.* = refreshed;
    }
    try requireApiResponse(response);
    return response;
}

fn resolveAuth(allocator: Allocator, cf_clearance_opt: ?[]const u8, user_agent_opt: ?[]const u8) !Auth {
    var auth: Auth = .{
        .cf_clearance = cf_clearance_opt,
        .user_agent = user_agent_opt orelse default_subsource_user_agent,
    };
    errdefer auth.deinit(allocator);

    if (cf_clearance_opt == null) {
        auth.owned_cf_clearance = try common.getenvOwned(allocator, "SUBSOURCE_CF_CLEARANCE");
        auth.cf_clearance = auth.owned_cf_clearance;
    }
    if (user_agent_opt == null) {
        auth.owned_user_agent = try common.getenvOwned(allocator, "SUBSOURCE_USER_AGENT");
        if (auth.owned_user_agent) |value| auth.user_agent = value;
    }
    try validateInitialAuth(auth);
    return auth;
}

fn resolveAuthWith(comptime get_env: anytype, cf_clearance_opt: ?[]const u8, user_agent_opt: ?[]const u8) !Auth {
    const auth: Auth = .{
        .cf_clearance = cf_clearance_opt orelse get_env("SUBSOURCE_CF_CLEARANCE"),
        .user_agent = user_agent_opt orelse get_env("SUBSOURCE_USER_AGENT") orelse default_subsource_user_agent,
    };
    try validateInitialAuth(auth);
    return auth;
}

fn validateInitialAuth(auth: Auth) !void {
    if (!validConfiguredUserAgent(auth.user_agent)) return error.InvalidSessionPayload;
    if (auth.cf_clearance) |value| {
        if (!validConfiguredClearance(value)) return error.InvalidSessionPayload;
    }
}

fn validConfiguredUserAgent(value: []const u8) bool {
    if (value.len == 0 or value.len > max_configured_auth_bytes) return false;
    if (std.mem.trim(u8, value, " \t").len == 0) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn validConfiguredClearance(value: []const u8) bool {
    if (value.len == 0 or value.len > max_configured_auth_bytes) return false;
    for (value) |byte| {
        if (byte < 0x21 or byte > 0x7e or byte == '"' or byte == ',' or byte == ';' or byte == '\\') return false;
    }
    return true;
}

fn acquireBrowserAuth(allocator: Allocator, request_url: []const u8, rejected_generation: ?u64, force_refresh: bool) !Auth {
    return acquireBrowserAuthWith(cf_shared.ensureDomainSession, allocator, request_url, rejected_generation, force_refresh);
}

fn acquireBrowserAuthWith(comptime ensure_session: anytype, allocator: Allocator, request_url: []const u8, rejected_generation: ?u64, force_refresh: bool) !Auth {
    // Recovery replaces any challenged configured cookie with a coherent
    // browser session, preserving the session's matching user agent.
    const session = try ensure_session(allocator, .{
        .domain = api_host,
        .challenge_url = request_url,
        .force_refresh = force_refresh,
        .rejected_generation = rejected_generation,
    });
    return .{ .cf_clearance = null, .user_agent = session.user_agent, .browser_session = session };
}

fn getJson(client: *std.http.Client, allocator: Allocator, url: []const u8, auth: Auth, allow_non_ok: bool) !common.HttpResponse {
    return getWithAuth(common.fetchBytes, client, allocator, url, auth, "application/json, text/plain, */*", allow_non_ok);
}

fn getWithAuth(comptime fetch: anytype, client: *std.http.Client, allocator: Allocator, url: []const u8, auth: Auth, accept: []const u8, allow_non_ok: bool) !common.HttpResponse {
    var headers_buf: [2]std.http.Header = undefined;
    var headers_len: usize = 0;
    var owned_cookie: ?[]u8 = null;
    defer if (owned_cookie) |cookie| allocator.free(cookie);

    if (auth.browser_session) |session| {
        owned_cookie = try browserSessionCookieHeader(allocator, session);
    } else if (auth.cf_clearance) |token| {
        owned_cookie = try std.fmt.allocPrint(allocator, "cf_clearance={s}", .{token});
    }
    if (owned_cookie) |cookie| {
        headers_buf[headers_len] = .{ .name = "cookie", .value = cookie };
        headers_len += 1;
    }

    headers_buf[headers_len] = .{ .name = "user-agent", .value = auth.user_agent };
    headers_len += 1;

    return fetch(client, allocator, url, .{
        .accept = accept,
        .extra_headers = headers_buf[0..headers_len],
        .allow_non_ok = allow_non_ok,
        .max_attempts = 2,
        .retry_on_429 = false,
        .cache = false,
        .require_public_origin = true,
        .require_https = true,
        .require_same_origin = true,
    });
}

fn postJson(client: *std.http.Client, allocator: Allocator, url: []const u8, payload: []const u8, auth: Auth, allow_non_ok: bool) !common.HttpResponse {
    var headers_buf: [3]std.http.Header = undefined;
    var headers_len: usize = 0;
    var owned_cookie: ?[]u8 = null;
    defer if (owned_cookie) |cookie| allocator.free(cookie);

    if (auth.browser_session) |session| {
        owned_cookie = try browserSessionCookieHeader(allocator, session);
    } else if (auth.cf_clearance) |token| {
        owned_cookie = try std.fmt.allocPrint(allocator, "cf_clearance={s}", .{token});
    }
    if (owned_cookie) |cookie| {
        headers_buf[headers_len] = .{ .name = "cookie", .value = cookie };
        headers_len += 1;
    }

    headers_buf[headers_len] = .{ .name = "user-agent", .value = auth.user_agent };
    headers_len += 1;

    headers_buf[headers_len] = .{ .name = "x-requested-with", .value = "XMLHttpRequest" };
    headers_len += 1;

    return common.fetchBytes(client, allocator, url, .{
        .method = .POST,
        .payload = payload,
        .content_type = "application/json",
        .accept = "application/json, text/plain, */*",
        .extra_headers = headers_buf[0..headers_len],
        .allow_non_ok = allow_non_ok,
        .max_attempts = 2,
        .retry_on_429 = false,
        .cache = false,
        .require_public_origin = true,
        .require_https = true,
        .require_same_origin = true,
    });
}

fn browserSessionCookieHeader(allocator: Allocator, session: cf_shared.Session) !?[]u8 {
    // Requests can redirect within the API origin. Attach only cookies that
    // apply at the origin root so a path-scoped credential is never replayed
    // onto an unrelated same-origin redirect target.
    return session.cookieHeaderForUrl(allocator, api_session_root);
}

fn normalizeSubsourceLanguage(raw: ?[]const u8) ?[]const u8 {
    const lang = raw orelse return null;
    if (std.ascii.eqlIgnoreCase(lang, "farsi/persian")) return "fa";
    if (std.ascii.eqlIgnoreCase(lang, "chinese traditional")) return "zh-tw";
    return common.normalizeLanguageCode(lang);
}

fn pathToSubtitles(allocator: Allocator, link: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, link, " \t\r\n");
    if (trimmed.len == 0) return null;

    var path = trimmed;
    if (std.mem.indexOf(u8, trimmed, "://") != null) {
        common.validatePublicHttpUrl(trimmed) catch return null;
        if (!(common.sameOrigin(site, trimmed) catch false)) return null;
        const uri = std.Uri.parse(trimmed) catch return null;
        if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return null;
        path = switch (uri.path) {
            .raw, .percent_encoded => |value| value,
        };
    } else if (std.mem.indexOfAny(u8, trimmed, "?#\\") != null) {
        return null;
    }

    const tail = if (std.mem.startsWith(u8, path, "/subtitles/"))
        path["/subtitles/".len..]
    else if (std.mem.startsWith(u8, path, "/series/"))
        path["/series/".len..]
    else if (path.len > 0 and path[0] != '/')
        path
    else
        return null;

    var parts = std.mem.splitScalar(u8, tail, '/');
    const raw_slug = parts.next() orelse return null;
    const raw_season = parts.next();
    if (parts.next() != null) return null;

    const slug = canonicalizeListingSlug(allocator, raw_slug) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer allocator.free(slug);

    if (raw_season) |season_segment| {
        const season = if (std.mem.startsWith(u8, season_segment, "season="))
            season_segment["season=".len..]
        else if (std.mem.startsWith(u8, season_segment, "season-"))
            season_segment["season-".len..]
        else
            return null;
        if (!isCanonicalPositiveDecimal(season)) return null;
        return try std.fmt.allocPrint(allocator, "/subtitles/{s}/season-{s}", .{ slug, season });
    }

    return try std.fmt.allocPrint(allocator, "/subtitles/{s}", .{slug});
}

fn toAbsoluteSiteLink(allocator: Allocator, link: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, link, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidDownloadUrl;
    const resolved = try common.resolveUrl(allocator, site, trimmed);
    errdefer allocator.free(resolved);
    const listing_path = (try pathToSubtitles(allocator, resolved)) orelse return error.InvalidDownloadUrl;
    allocator.free(listing_path);
    return resolved;
}

fn isCanonicalPositiveDecimal(value: []const u8) bool {
    if (value.len == 0 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn canonicalizeListingSlug(allocator: Allocator, raw_slug: []const u8) ![]u8 {
    const decoded = try decodeApiPathSegment(allocator, raw_slug);
    defer allocator.free(decoded);
    if (decoded.len == 0 or std.mem.eql(u8, decoded, ".") or std.mem.eql(u8, decoded, ".."))
        return error.InvalidDownloadUrl;
    for (decoded) |byte| {
        if (byte >= 0x80) continue;
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~'))
            return error.InvalidDownloadUrl;
    }
    return common.encodeUriComponent(allocator, decoded);
}

fn isCanonicalEncodedListingSlug(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    var index: usize = 0;
    while (index < value.len) {
        const c = value[index];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            index += 1;
            continue;
        }
        if (c != '%' or value.len - index < 3 or
            !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return false;
        const high = std.fmt.charToDigit(value[index + 1], 16) catch return false;
        const low = std.fmt.charToDigit(value[index + 2], 16) catch return false;
        const decoded: u8 = @intCast(high * 16 + low);
        if (decoded < 0x80) return false;
        index += 3;
    }
    return true;
}

fn siteLinkBindsSeason(
    allocator: Allocator,
    link: []const u8,
    base_link: []const u8,
    expected_season: i64,
) !bool {
    if (expected_season <= 0) return false;
    const listing_path = (try pathToSubtitles(allocator, link)) orelse return false;
    defer allocator.free(listing_path);
    const base_path = (try pathToSubtitles(allocator, base_link)) orelse return false;
    defer allocator.free(base_path);
    const marker = "/season-";
    const marker_index = std.mem.lastIndexOf(u8, listing_path, marker) orelse return false;
    if (std.mem.indexOf(u8, base_path, marker) != null or marker_index != base_path.len or
        !std.mem.eql(u8, listing_path[0..marker_index], base_path)) return false;
    const season = std.fmt.parseInt(i64, listing_path[marker_index + marker.len ..], 10) catch return false;
    return season == expected_season;
}

fn objString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn firstNonEmptyObjString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = objString(obj, key) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn objInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| common.jsonInt(.{ .float = f }),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn objFirstArrayString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    const arr = switch (v) {
        .array => |a| a,
        else => return null,
    };
    for (arr.items) |entry| {
        switch (entry) {
            .string => |s| {
                const trimmed = std.mem.trim(u8, s, " \t\r\n");
                if (trimmed.len > 0) return trimmed;
            },
            else => {},
        }
    }
    return null;
}

fn escapeJson(allocator: Allocator, input: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8Data;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                const escaped = [_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try out.appendSlice(allocator, &escaped);
            } else {
                try out.append(allocator, c);
            },
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn checkedNextPage(page: usize) !usize {
    return std.math.add(usize, page, 1) catch error.PageOverflow;
}

fn shouldStopSubtitlePagination(page_item_count: usize, traversed: usize, max_pages: usize) bool {
    return page_item_count == 0 or traversed >= max_pages;
}

fn subtitlePageMayHaveNext(page_item_count: usize, traversed: usize, max_pages: usize) bool {
    return page_item_count > 0 and traversed >= max_pages;
}

fn makeFixtureBrowserSession(allocator: Allocator, generation: u64) !cf_shared.Session {
    const cookies = try allocator.alloc(cf_shared.Cookie, 1);
    errdefer allocator.free(cookies);
    const name = try allocator.dupe(u8, "cf_clearance");
    errdefer allocator.free(name);
    const value = try allocator.dupe(u8, "fixture-clearance");
    errdefer allocator.free(value);
    const domain = try allocator.dupe(u8, api_host);
    errdefer allocator.free(domain);
    const path = try allocator.dupe(u8, "/");
    errdefer allocator.free(path);
    cookies[0] = .{
        .name = name,
        .value = value,
        .domain = domain,
        .path = path,
        .secure = true,
        .host_only = true,
        .expires_unix_seconds = null,
    };

    const clearance = try allocator.dupe(u8, "fixture-clearance");
    errdefer allocator.free(clearance);
    const user_agent = try allocator.dupe(u8, "fixture-browser-agent");
    return .{
        .cookies = cookies,
        .cf_clearance = clearance,
        .user_agent = user_agent,
        .acquired_at_unix = 0,
        .generation = generation,
    };
}

fn makeFixtureBrowserAuth(allocator: Allocator, generation: u64) !Auth {
    const session = try makeFixtureBrowserSession(allocator, generation);
    return .{
        .cf_clearance = null,
        .user_agent = session.user_agent,
        .browser_session = session,
    };
}

test "subsource path to subtitles" {
    const allocator = std.testing.allocator;
    const a = (try pathToSubtitles(allocator, "/subtitles/the-matrix-1999")).?;
    defer allocator.free(a);
    try std.testing.expectEqualStrings("/subtitles/the-matrix-1999", a);

    const b = (try pathToSubtitles(allocator, "/series/the-matrix-1999")).?;
    defer allocator.free(b);
    try std.testing.expectEqualStrings("/subtitles/the-matrix-1999", b);

    const c = (try pathToSubtitles(allocator, "/subtitles/friends/season=1")).?;
    defer allocator.free(c);
    try std.testing.expectEqualStrings("/subtitles/friends/season-1", c);

    const d = (try pathToSubtitles(allocator, "https://subsource.net/subtitles/friends/season=10")).?;
    defer allocator.free(d);
    try std.testing.expectEqualStrings("/subtitles/friends/season-10", d);

    const e = (try pathToSubtitles(allocator, "the-matrix-1999")).?;
    defer allocator.free(e);
    try std.testing.expectEqualStrings("/subtitles/the-matrix-1999", e);

    for ([_][]const u8{
        "",
        "https://evil.example/subtitles/the-matrix-1999",
        "https://user@subsource.net/subtitles/the-matrix-1999",
        "http://subsource.net/subtitles/the-matrix-1999",
        "/admin/the-matrix-1999",
        "/subtitles/../admin",
        "/subtitles/the-matrix-1999?next=/admin",
        "/subtitles/the-matrix-1999#fragment",
        "/subtitles/the-matrix-1999/extra",
        "/subtitles/friends/season=0",
        "/subtitles/friends/season=01",
        "/subtitles/friends/season=one",
        "/subtitles/the%2fmatrix",
        "javascript:alert(1)",
    }) |invalid| {
        try std.testing.expect((try pathToSubtitles(allocator, invalid)) == null);
    }
}

test "subsource language normalization" {
    try std.testing.expectEqualStrings("fa", normalizeSubsourceLanguage("farsi/persian").?);
    try std.testing.expectEqualStrings("zh-tw", normalizeSubsourceLanguage("chinese traditional").?);
}

test "subsource optional suggestion failures preserve terminal policy errors" {
    try allowOptionalSuggestionFallback(error.ConnectionRefused);
    inline for (.{
        error.Canceled,
        error.OutOfMemory,
        error.RateLimited,
        error.ProviderAccessBlocked,
        error.CloudflareChallenge,
        error.UnsafeHttpTarget,
        error.InvalidDownloadUrl,
        error.PublicOriginProxyUnsupported,
    }) |err| try std.testing.expectError(err, allowOptionalSuggestionFallback(err));
}

test "subsource optional suggestion responses preserve terminal status" {
    const challenge = "<html><script>window._cf_chl_opt = {};</script></html>";
    try std.testing.expectError(error.RateLimited, shouldParseOptionalSuggestion(.too_many_requests, "slow down"));
    try std.testing.expectError(error.ProviderAccessBlocked, shouldParseOptionalSuggestion(.forbidden, "denied"));
    try std.testing.expectError(error.ProviderAccessBlocked, shouldParseOptionalSuggestion(.unauthorized, "denied"));
    try std.testing.expectError(error.CloudflareChallenge, shouldParseOptionalSuggestion(.forbidden, challenge));
    try std.testing.expectError(error.CloudflareChallenge, shouldParseOptionalSuggestion(.ok, challenge));
    try std.testing.expect(!(try shouldParseOptionalSuggestion(.service_unavailable, "maintenance")));
    try std.testing.expect(try shouldParseOptionalSuggestion(.ok, "{\"results\":[]}"));
}

test "subsource optional suggestion owns terminal retry and cache policy" {
    const Mock = struct {
        var calls: usize = 0;

        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) !common.HttpResponse {
            calls += 1;
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expect(!options.cache);
            try std.testing.expect(options.allow_non_ok);
            try std.testing.expect(options.require_public_origin);
            return .{ .status = .too_many_requests, .body = try allocator.dupe(u8, "slow down") };
        }
    };

    Mock.calls = 0;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(error.RateLimited, resolveSearchQueryWith(Mock.fetch, &client, std.testing.allocator, "Matrix"));
    try std.testing.expectEqual(@as(usize, 1), Mock.calls);
}

test "subsource API recovery distinguishes rate limits challenges and failed pages" {
    const Mock = struct {
        var fetch_calls: usize = 0;
        var acquire_calls: usize = 0;
        var initial_status: std.http.Status = .ok;
        var retry_status: std.http.Status = .ok;
        var refreshed_status: std.http.Status = .ok;
        var initial_body: []const u8 = "";
        var retry_body: []const u8 = "";
        var refreshed_body: []const u8 = "";
        var initial_browser_session: bool = false;
        var acquire_error: bool = false;
        var retry_fetch_error: bool = false;

        fn browserAuth(allocator: Allocator, generation: u64) !Auth {
            return makeFixtureBrowserAuth(allocator, generation);
        }

        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, _: ?[]const u8, auth: Auth) !common.HttpResponse {
            fetch_calls += 1;
            if (acquire_calls > 0) {
                try std.testing.expect(auth.cf_clearance == null);
                try std.testing.expectEqualStrings("fixture-browser-agent", auth.user_agent);
                const expected_generation: u64 = if (initial_browser_session or acquire_calls == 2) 42 else 41;
                try std.testing.expectEqual(expected_generation, auth.browser_session.?.generation);
            }
            if (retry_fetch_error and fetch_calls > 1) return error.ConnectionRefused;
            return .{
                .status = switch (fetch_calls) {
                    1 => initial_status,
                    2 => retry_status,
                    else => refreshed_status,
                },
                .body = try allocator.dupe(u8, switch (fetch_calls) {
                    1 => initial_body,
                    2 => retry_body,
                    else => refreshed_body,
                }),
            };
        }

        fn acquire(allocator: Allocator, request_url: []const u8, rejected_generation: ?u64, force_refresh: bool) !Auth {
            try std.testing.expect(std.mem.startsWith(u8, request_url, "https://fixture.invalid/"));
            const expected_force = initial_browser_session or acquire_calls > 0;
            try std.testing.expectEqual(expected_force, force_refresh);
            try std.testing.expectEqual(if (expected_force) @as(?u64, 41) else null, rejected_generation);
            acquire_calls += 1;
            if (acquire_error) return error.CloudflareSessionUnavailable;
            return browserAuth(allocator, if (expected_force) 42 else 41);
        }
    };
    const challenge = "<html><body><script>window._cf_chl_opt = {};</script></body></html>";
    const valid = "{\"results\":[],\"subtitles\":[]}";
    const Case = struct {
        initial_status: std.http.Status,
        initial_body: []const u8,
        retry_status: std.http.Status = .ok,
        retry_body: []const u8 = valid,
        refreshed_status: std.http.Status = .ok,
        refreshed_body: []const u8 = valid,
        initial_browser_session: bool = false,
        acquire_error: bool = false,
        retry_fetch_error: bool = false,
        automatic: bool = true,
        expected_error: ?anyerror = null,
        expected_fetches: usize = 1,
        expected_acquisitions: usize = 0,
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    for ([_]Case{
        .{ .initial_status = .too_many_requests, .initial_body = challenge, .expected_error = error.RateLimited },
        .{ .initial_status = .forbidden, .initial_body = "{\"error\":\"permission denied\"}", .expected_error = error.ProviderAccessBlocked },
        .{ .initial_status = .internal_server_error, .initial_body = valid, .expected_error = error.UnexpectedHttpStatus },
        .{ .initial_status = .ok, .initial_body = challenge, .automatic = false, .expected_error = error.CloudflareChallenge },
        .{ .initial_status = .forbidden, .initial_body = challenge, .automatic = false, .expected_error = error.CloudflareChallenge },
        .{ .initial_status = .ok, .initial_body = valid },
        .{ .initial_status = .ok, .initial_body = challenge, .expected_fetches = 2, .expected_acquisitions = 1 },
        .{ .initial_status = .forbidden, .initial_body = challenge, .retry_status = .forbidden, .retry_body = challenge, .expected_fetches = 3, .expected_acquisitions = 2 },
        .{ .initial_status = .forbidden, .initial_body = challenge, .retry_status = .forbidden, .retry_body = challenge, .refreshed_status = .forbidden, .refreshed_body = challenge, .expected_error = error.CloudflareChallenge, .expected_fetches = 3, .expected_acquisitions = 2 },
        .{ .initial_status = .forbidden, .initial_body = challenge, .retry_status = .too_many_requests, .retry_body = challenge, .expected_error = error.RateLimited, .expected_fetches = 2, .expected_acquisitions = 1 },
        .{ .initial_status = .forbidden, .initial_body = challenge, .retry_status = .forbidden, .retry_body = challenge, .refreshed_status = .too_many_requests, .refreshed_body = challenge, .expected_error = error.RateLimited, .expected_fetches = 3, .expected_acquisitions = 2 },
        .{ .initial_status = .forbidden, .initial_body = challenge, .initial_browser_session = true, .expected_fetches = 2, .expected_acquisitions = 1 },
        .{ .initial_status = .forbidden, .initial_body = challenge, .initial_browser_session = true, .retry_status = .forbidden, .retry_body = challenge, .expected_error = error.CloudflareChallenge, .expected_fetches = 2, .expected_acquisitions = 1 },
        .{ .initial_status = .forbidden, .initial_body = challenge, .acquire_error = true, .expected_error = error.CloudflareSessionUnavailable, .expected_acquisitions = 1 },
        .{ .initial_status = .forbidden, .initial_body = challenge, .retry_fetch_error = true, .expected_error = error.ConnectionRefused, .expected_fetches = 2, .expected_acquisitions = 1 },
    }) |case| {
        Mock.fetch_calls = 0;
        Mock.acquire_calls = 0;
        Mock.initial_status = case.initial_status;
        Mock.initial_body = case.initial_body;
        Mock.retry_status = case.retry_status;
        Mock.retry_body = case.retry_body;
        Mock.refreshed_status = case.refreshed_status;
        Mock.refreshed_body = case.refreshed_body;
        Mock.initial_browser_session = case.initial_browser_session;
        Mock.acquire_error = case.acquire_error;
        Mock.retry_fetch_error = case.retry_fetch_error;
        var auth: Auth = if (case.initial_browser_session) try Mock.browserAuth(std.testing.allocator, 41) else .{ .cf_clearance = "configured-clearance", .user_agent = "fixture-agent" };
        defer auth.deinit(std.testing.allocator);
        const result = fetchApiJsonWith(Mock.fetch, Mock.acquire, &client, std.testing.allocator, "https://fixture.invalid/search", null, &auth, SearchOptions{ .auto_cloudflare_session = case.automatic });
        if (case.expected_error) |err| {
            try std.testing.expectError(err, result);
        } else {
            const response = try result;
            defer std.testing.allocator.free(response.body);
            try std.testing.expectEqualStrings(valid, response.body);
        }
        try std.testing.expectEqual(case.expected_fetches, Mock.fetch_calls);
        try std.testing.expectEqual(case.expected_acquisitions, Mock.acquire_calls);
    }

    // A successful first page cannot make a later unavailable page successful.
    Mock.fetch_calls = 0;
    Mock.acquire_calls = 0;
    Mock.initial_status = .ok;
    Mock.initial_body = valid;
    Mock.retry_status = .service_unavailable;
    Mock.retry_body = "unavailable";
    Mock.initial_browser_session = false;
    Mock.acquire_error = false;
    Mock.retry_fetch_error = false;
    var auth: Auth = .{ .cf_clearance = null, .user_agent = "fixture-agent" };
    defer auth.deinit(std.testing.allocator);
    const first_page = try fetchApiJsonWith(Mock.fetch, Mock.acquire, &client, std.testing.allocator, "https://fixture.invalid/subtitles", null, &auth, SubtitlesOptions{});
    defer std.testing.allocator.free(first_page.body);
    try std.testing.expectError(error.UnexpectedHttpStatus, fetchApiJsonWith(Mock.fetch, Mock.acquire, &client, std.testing.allocator, "https://fixture.invalid/subtitles?page=2", null, &auth, SubtitlesOptions{}));
    try std.testing.expectEqual(@as(usize, 2), Mock.fetch_calls);
    try std.testing.expectEqual(@as(usize, 0), Mock.acquire_calls);

    // Detail requests use the same recovery contract with subtitle options.
    Mock.fetch_calls = 0;
    Mock.acquire_calls = 0;
    Mock.initial_status = .forbidden;
    Mock.initial_body = challenge;
    Mock.retry_status = .ok;
    Mock.retry_body = "{\"subtitle\":{\"download_token\":\"fixture-download\"}}";
    const detail = try fetchApiJsonWith(Mock.fetch, Mock.acquire, &client, std.testing.allocator, "https://fixture.invalid/subtitle/fixture", null, &auth, SubtitlesOptions{ .auto_cloudflare_session = true });
    defer std.testing.allocator.free(detail.body);
    try std.testing.expectEqualStrings(Mock.retry_body, detail.body);
    try std.testing.expect(auth.cf_clearance == null);
    try std.testing.expectEqualStrings("fixture-clearance", auth.browser_session.?.cf_clearance);
    try std.testing.expectEqual(@as(usize, 2), Mock.fetch_calls);
    try std.testing.expectEqual(@as(usize, 1), Mock.acquire_calls);
}

test "subsource authenticated download keeps recovered auth for the archive" {
    const Mock = struct {
        var detail_calls: usize = 0;
        var download_calls: usize = 0;
        var acquire_calls: usize = 0;

        fn fetchDetails(_: *std.http.Client, allocator: Allocator, url: []const u8, payload: ?[]const u8, auth: Auth) !common.HttpResponse {
            detail_calls += 1;
            try std.testing.expectEqualStrings(api_base ++ "/subtitle/fixture-title/english/42", url);
            try std.testing.expect(payload == null);
            if (detail_calls == 1) {
                try std.testing.expect(auth.browser_session == null);
                return .{
                    .status = .forbidden,
                    .body = try allocator.dupe(u8, "<script>window._cf_chl_opt = {};</script>"),
                };
            }
            try std.testing.expectEqual(@as(u64, 41), auth.browser_session.?.generation);
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "{\"subtitle\":{\"download_token\":\"fixture-download\"}}"),
            };
        }

        fn fetchDownload(_: *std.http.Client, allocator: Allocator, url: []const u8, payload: ?[]const u8, auth: Auth) !common.HttpResponse {
            download_calls += 1;
            try std.testing.expectEqualStrings(api_base ++ "/subtitle/download/fixture-download", url);
            try std.testing.expect(payload == null);
            try std.testing.expectEqual(@as(u64, 41), auth.browser_session.?.generation);
            try std.testing.expectEqualStrings("fixture-browser-agent", auth.user_agent);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "PK\x03\x04fixture archive") };
        }

        fn acquire(allocator: Allocator, request_url: []const u8, rejected_generation: ?u64, force_refresh: bool) !Auth {
            acquire_calls += 1;
            try std.testing.expectEqualStrings(api_base ++ "/subtitle/fixture-title/english/42", request_url);
            try std.testing.expect(rejected_generation == null);
            try std.testing.expect(!force_refresh);
            return makeFixtureBrowserAuth(allocator, 41);
        }
    };

    Mock.detail_calls = 0;
    Mock.download_calls = 0;
    Mock.acquire_calls = 0;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const response = try fetchDownloadByDetailsPathWith(
        Mock.fetchDetails,
        Mock.fetchDownload,
        Mock.acquire,
        &client,
        std.testing.allocator,
        "fixture-title/english/42",
        .{
            .cf_clearance = "configured-clearance",
            .user_agent = "configured-agent",
            .auto_cloudflare_session = true,
        },
    );
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("PK\x03\x04fixture archive", response.body);
    try std.testing.expectEqual(@as(usize, 2), Mock.detail_calls);
    try std.testing.expectEqual(@as(usize, 1), Mock.download_calls);
    try std.testing.expectEqual(@as(usize, 1), Mock.acquire_calls);
}

test "subsource accepts ZIP signatures and rejects non-archives" {
    for ([_][]const u8{
        "PK\x03\x04local file",
        "PK\x05\x06empty archive",
        "PK\x07\x08spanning archive",
    }) |body| try validateDownloadBody(body);

    for ([_][]const u8{
        "<html><body>provider error</body></html>",
        "  <!DOCTYPE html><title>provider error</title>",
        "\xef\xbb\xbf<script>window._cf_chl_opt = {};</script>",
        "{\"error\":\"archive unavailable\"}",
        "archive temporarily unavailable",
        "PK fixture is not a ZIP signature",
    }) |body| try std.testing.expectError(error.UnexpectedResponseType, validateDownloadBody(body));
}

test "subsource API URL validation rejects alternate and unsafe origins" {
    try validateSubsourceApiUrl(api_base ++ "/subtitle/download/fixture");
    try std.testing.expectError(error.InvalidDownloadUrl, validateSubsourceApiUrl("https://example.com/archive.zip"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateSubsourceApiUrl("http://127.0.0.1/archive.zip"));
}

test "subsource listing credentials are confined to canonical API routes" {
    try validateSubtitlesListingApiUrl(api_base ++ "/subtitles/the-matrix-1999");
    try validateSubtitlesListingApiUrl(api_base ++ "/subtitles/friends/season-10?page=2");

    for ([_][]const u8{
        api_base ++ "/admin",
        api_base ++ "/subtitles/the-matrix-1999/extra",
        api_base ++ "/subtitles/friends/season-01",
        api_base ++ "/subtitles/friends/season-1?next=/admin",
        api_base ++ "/subtitles/friends/season-1?page=02",
        api_base ++ "/subtitles/the%2fmatrix",
        api_base ++ "/subtitles/the-matrix-1999#fragment",
    }) |invalid| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateSubtitlesListingApiUrl(invalid));
    }
}

test "subsource initial auth resolution does not acquire a browser session" {
    const Mock = struct {
        var env_reads: usize = 0;
        var has_environment: bool = true;

        fn getEnv(name: []const u8) ?[]const u8 {
            env_reads += 1;
            if (!has_environment) return null;
            if (std.mem.eql(u8, name, "SUBSOURCE_CF_CLEARANCE")) return "environment-token";
            if (std.mem.eql(u8, name, "SUBSOURCE_USER_AGENT")) return "environment-agent";
            return null;
        }
    };
    const configured = try resolveAuthWith(Mock.getEnv, "explicit-token", "explicit-agent");
    try std.testing.expectEqualStrings("explicit-token", configured.cf_clearance.?);
    try std.testing.expectEqualStrings("explicit-agent", configured.user_agent);
    try std.testing.expect(configured.browser_session == null);
    try std.testing.expectEqual(@as(usize, 0), Mock.env_reads);

    const environment = try resolveAuthWith(Mock.getEnv, null, null);
    try std.testing.expectEqualStrings("environment-token", environment.cf_clearance.?);
    try std.testing.expectEqualStrings("environment-agent", environment.user_agent);
    try std.testing.expect(environment.browser_session == null);
    try std.testing.expectEqual(@as(usize, 2), Mock.env_reads);

    Mock.has_environment = false;
    const defaults = try resolveAuthWith(Mock.getEnv, null, null);
    try std.testing.expect(defaults.cf_clearance == null);
    try std.testing.expectEqualStrings(default_subsource_user_agent, defaults.user_agent);
    try std.testing.expect(defaults.browser_session == null);
}

test "subsource configured auth rejects header and cookie injection" {
    const noEnvironment = struct {
        fn getEnv(_: []const u8) ?[]const u8 {
            return null;
        }
    }.getEnv;

    try std.testing.expectError(error.InvalidSessionPayload, resolveAuthWith(noEnvironment, "token; injected=1", "agent"));
    try std.testing.expectError(error.InvalidSessionPayload, resolveAuthWith(noEnvironment, "token", "agent\r\nX-Injected: yes"));
    try std.testing.expectError(error.InvalidSessionPayload, resolveAuthWith(noEnvironment, "", "agent"));
    try std.testing.expectError(error.InvalidSessionPayload, resolveAuthWith(noEnvironment, "token", " \t"));
    try std.testing.expectError(
        error.InvalidSessionPayload,
        resolveAuthWith(noEnvironment, &@as([max_configured_auth_bytes + 1]u8, @splat('x')), "agent"),
    );
    try std.testing.expectError(
        error.InvalidSessionPayload,
        resolveAuthWith(noEnvironment, "token", &@as([max_configured_auth_bytes + 1]u8, @splat('x'))),
    );
}

test "subsource browser acquisition reuses cache before generation aware refresh" {
    const Mock = struct {
        var session_calls: usize = 0;
        var session_error: bool = false;
        var expected_force: bool = false;
        fn ensureSession(allocator: Allocator, options: cf_shared.EnsureDomainOptions) !cf_shared.Session {
            session_calls += 1;
            try std.testing.expectEqual(expected_force, options.force_refresh);
            try std.testing.expectEqualStrings(api_host, options.domain);
            try std.testing.expectEqualStrings(api_base ++ "/movie/search", options.challenge_url.?);
            try std.testing.expectEqual(if (expected_force) @as(?u64, 41) else null, options.rejected_generation);
            if (session_error) return error.CloudflareSessionUnavailable;
            return makeFixtureBrowserSession(allocator, 42);
        }
    };
    for ([_]bool{ false, true }) |force_refresh| {
        Mock.session_calls = 0;
        Mock.expected_force = force_refresh;
        var refreshed = try acquireBrowserAuthWith(Mock.ensureSession, std.testing.allocator, api_base ++ "/movie/search", if (force_refresh) 41 else null, force_refresh);
        defer refreshed.deinit(std.testing.allocator);
        try std.testing.expect(refreshed.cf_clearance == null);
        try std.testing.expectEqualStrings("fixture-clearance", refreshed.browser_session.?.cf_clearance);
        try std.testing.expectEqualStrings("fixture-browser-agent", refreshed.user_agent);
        try std.testing.expectEqual(@as(usize, 1), Mock.session_calls);
    }

    Mock.session_error = true;
    try std.testing.expectError(error.CloudflareSessionUnavailable, acquireBrowserAuthWith(Mock.ensureSession, std.testing.allocator, api_base ++ "/movie/search", 41, true));
}

test "subsource does not replay an apex host-only browser cookie to the API" {
    const cookies = [_]cf_shared.Cookie{.{
        .name = "cf_clearance",
        .value = "apex-only",
        .domain = "subsource.net",
        .path = "/",
        .secure = true,
        .host_only = true,
        .expires_unix_seconds = null,
    }};
    const session: cf_shared.Session = .{
        .cookies = &cookies,
        .cf_clearance = "apex-only",
        .user_agent = "fixture",
        .acquired_at_unix = 0,
        .generation = 1,
    };
    try std.testing.expect((try session.cookieHeaderForUrl(std.testing.allocator, api_base ++ "/movie/search")) == null);
}

test "subsource browser auth forwards only API root cookies" {
    const cookies = [_]cf_shared.Cookie{
        .{ .name = "cf_clearance", .value = "root-token", .domain = api_host, .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "path-secret", .value = "scoped-token", .domain = api_host, .path = "/v1/movie", .secure = true, .host_only = true, .expires_unix_seconds = null },
    };
    const session: cf_shared.Session = .{
        .cookies = &cookies,
        .cf_clearance = "root-token",
        .user_agent = "fixture",
        .acquired_at_unix = 0,
        .generation = 1,
    };
    const header = (try browserSessionCookieHeader(std.testing.allocator, session)).?;
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("cf_clearance=root-token", header);
}

test "subsource absolute site link normalization" {
    const allocator = std.testing.allocator;

    const a = try toAbsoluteSiteLink(allocator, "/series/the-matrix-1999");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("https://subsource.net/series/the-matrix-1999", a);

    const b = try toAbsoluteSiteLink(allocator, "series/the-matrix-1999");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("https://subsource.net/series/the-matrix-1999", b);

    const c = try toAbsoluteSiteLink(allocator, "https://subsource.net/series/the-matrix-1999");
    defer allocator.free(c);
    try std.testing.expectEqualStrings("https://subsource.net/series/the-matrix-1999", c);
}

test "subsource search payload is fixed schema" {
    const allocator = std.testing.allocator;
    const payload = try buildSearchPayload(allocator, "The Matrix", true, 5000);
    defer allocator.free(payload);
    try std.testing.expectEqualStrings(
        "{\"query\":\"The Matrix\",\"includeSeasons\":true,\"limit\":5000}",
        payload,
    );
}

test "subsource whitespace search is an owned empty response before auth or network" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    // The deliberately invalid configured cookie proves the empty-query return
    // happens before auth validation. Any network attempt would also make this
    // deterministic unit test fail instead of returning immediately.
    var response = try scraper.searchWithOptions(" \t\r\n", .{
        .cf_clearance = "invalid;cookie",
    });
    defer response.deinit();
    try std.testing.expectEqualStrings("", response.query_used);
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
    try std.testing.expect(!response.has_prev_page);
    try std.testing.expect(!response.has_next_page);
}

test "subsource detail and download route segments are canonical" {
    const allocator = std.testing.allocator;
    const canonical = try canonicalizeDetailsPath(
        allocator,
        "/malcolm%20in-the-middle-season-1/eng%6Cish/123",
    );
    defer allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "malcolm%20in-the-middle-season-1/english/123",
        canonical,
    );

    for ([_][]const u8{
        "",
        "title/language",
        "title/language/123/extra",
        "title//123",
        "../language/123",
        "%2e%2e/language/123",
        "title/%2f/123",
        "title/language/not-a-number",
        "title/language/0",
        "title/language/01",
        "title/language/123?next=1",
        "title/language/123#fragment",
        "title/language/%",
    }) |invalid| {
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            canonicalizeDetailsPath(allocator, invalid),
        );
    }

    const token = try canonicalizeApiPathSegment(allocator, "token%20value", false);
    defer allocator.free(token);
    try std.testing.expectEqualStrings("token%20value", token);
    try std.testing.expectError(
        error.InvalidDownloadUrl,
        canonicalizeApiPathSegment(allocator, "token%2fother", false),
    );
}

test "subsource search payload defaults limit when zero" {
    const allocator = std.testing.allocator;
    const payload = try buildSearchPayload(allocator, "The Matrix", false, 0);
    defer allocator.free(payload);
    try std.testing.expectEqualStrings(
        "{\"query\":\"The Matrix\",\"includeSeasons\":false,\"limit\":5000}",
        payload,
    );
}

test "subsource search payload escapes every JSON control byte" {
    const allocator = std.testing.allocator;
    const query = "quote:\" slash:\\ back:\x08 form:\x0c nul:\x00 unit:\x1f\n\r\t";
    const payload = try buildSearchPayload(allocator, query, true, 25);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOfScalar(u8, payload, 0) == null);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    const parsed_query = switch (root.get("query") orelse return error.TestUnexpectedResult) {
        .string => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(query, parsed_query);

    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8Data, buildSearchPayload(allocator, &invalid_utf8, true, 25));
}

test "subsource valid duplicate result is not shadowed by a malformed one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        "{\"results\":[" ++
            "{\"id\":0,\"title\":\"Zero\",\"type\":\"movie\",\"link\":\"/subtitles/zero\"}," ++
            "{\"id\":-1,\"title\":\"Negative\",\"type\":\"movie\",\"link\":\"/subtitles/negative\"}," ++
            "{\"id\":7,\"title\":\"Evil sibling\",\"type\":\"movie\",\"link\":\"https://evil.example/subtitles/the-matrix\"}," ++
            "{\"id\":7,\"title\":\"The Matrix\",\"type\":\"movie\",\"link\":\"/subtitles/the-matrix\"," ++
            "\"seasons\":[{\"season\":1,\"link\":\"/subtitles/other-show/season=1\"}," ++
            "{\"season\":1,\"link\":\"/subtitles/the-matrix/season=2\"}," ++
            "{\"season\":1,\"link\":\"/subtitles/the-matrix/season=1\"}," ++
            "{\"season\":1,\"link\":\"/subtitles/the-matrix/season=1\"}]}]}",
        .{},
    );
    const object = switch (root) {
        .object => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const results = switch (object.get("results") orelse return error.TestUnexpectedResult) {
        .array => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.AutoHashMapUnmanaged(i64, void).empty;
    try appendSearchResultValues(a, &out, &seen, results.items);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("The Matrix", out.items[0].title);
    try std.testing.expectEqualStrings(site ++ "/subtitles/the-matrix", out.items[0].link);
    try std.testing.expectEqual(@as(usize, 1), out.items[0].seasons.len);
    try std.testing.expectEqual(@as(i64, 1), out.items[0].seasons[0].season);
}

test "subsource authenticated requests pin redirects to the request origin" {
    const Mock = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) !common.HttpResponse {
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);
            try std.testing.expect(options.require_same_origin);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "{}") };
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const response = try getWithAuth(
        Mock.fetch,
        &client,
        std.testing.allocator,
        api_base ++ "/movie/search",
        .{ .cf_clearance = "fixture", .user_agent = "fixture-agent" },
        "application/json",
        true,
    );
    defer std.testing.allocator.free(response.body);
}

test "subsource subtitle page increment is checked" {
    try std.testing.expectEqual(@as(usize, 2), try checkedNextPage(1));
    try std.testing.expectError(error.PageOverflow, checkedNextPage(std.math.maxInt(usize)));
}

test "subsource raw page emptiness and traversal bound drive pagination" {
    try std.testing.expect(!shouldStopSubtitlePagination(3, 1, 2));
    try std.testing.expect(shouldStopSubtitlePagination(0, 1, 2));
    try std.testing.expect(shouldStopSubtitlePagination(3, 2, 2));
    try std.testing.expect(!subtitlePageMayHaveNext(0, 1, 1));
    try std.testing.expect(!subtitlePageMayHaveNext(3, 1, 2));
    try std.testing.expect(subtitlePageMayHaveNext(3, 1, 1));
    try std.testing.expect(subtitlePageMayHaveNext(3, 2, 2));
}

test "subsource ranks exact title ahead of containing titles" {
    var items = [_]SearchItem{
        .{
            .id = 1,
            .title = "Escape The Matrix",
            .media_type = "tvseries",
            .link = "/series/escape-the-matrix-2020",
            .release_year = 2020,
            .subtitle_count = 10,
            .seasons = &.{},
        },
        .{
            .id = 2,
            .title = "The Matrix",
            .media_type = "movie",
            .link = "/subtitles/the-matrix-1999",
            .release_year = 1999,
            .subtitle_count = 403,
            .seasons = &.{},
        },
    };
    rankSearchResults(&items, "The Matrix");
    try std.testing.expectEqual(@as(i64, 2), items[0].id);
}

test "subsource ranking honors an explicit query year" {
    var items = [_]SearchItem{
        .{
            .id = 1,
            .title = "The Matrix",
            .media_type = "movie",
            .link = "/subtitles/the-matrix-2021",
            .release_year = 2021,
            .subtitle_count = 500,
            .seasons = &.{},
        },
        .{
            .id = 2,
            .title = "The Matrix",
            .media_type = "movie",
            .link = "/subtitles/the-matrix-1999",
            .release_year = 1999,
            .subtitle_count = 1,
            .seasons = &.{},
        },
    };
    rankSearchResults(&items, "The Matrix 1999");
    try std.testing.expectEqual(@as(i64, 2), items[0].id);
}
