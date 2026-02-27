const std = @import("std");
const common = @import("common.zig");
const cf_shared = @import("opensubtitles_com_cf.zig");

const Allocator = std.mem.Allocator;
const api_base = "https://api.subsource.net/v1";
const site = "https://subsource.net";

pub const SearchOptions = struct {
    include_seasons: bool = true,
    page_start: usize = 1,
    max_pages: usize = 1,
    limit_per_page: usize = 5000,
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

pub const SubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    subtitles: []const SubtitleItem,
    page: usize = 1,
    has_prev_page: bool = false,
    has_next_page: bool = false,

    pub fn deinit(self: *SubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Auth = struct {
    cf_clearance: ?[]const u8,
    user_agent: []const u8,
};

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn deinit(_: *Scraper) void {}

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchWithOptions(query, .{});
    }

    pub fn searchWithOptions(self: *Scraper, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const query_trimmed = common.trimAscii(query);
        var query_used = try resolveSearchQuery(self.client, a, query);
        var auth = try resolveAuth(a, options.cf_clearance, options.user_agent, false, options.auto_cloudflare_session);

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.AutoHashMapUnmanaged(i64, void).empty;
        try appendSearchResults(self.client, a, &out, &seen, query_used, options, &auth);
        // SubSource's suggestion endpoint can occasionally return a title that does not
        // map back to the desired result set. Fall back to the raw query when needed.
        if (out.items.len == 0 and query_trimmed.len > 0 and !std.mem.eql(u8, query_trimmed, query_used)) {
            query_used = try a.dupe(u8, query_trimmed);
            try appendSearchResults(self.client, a, &out, &seen, query_used, options, &auth);
        }

        return .{
            .arena = arena,
            .query_used = query_used,
            .items = try out.toOwnedSlice(a),
            .page = 1,
            .has_prev_page = false,
            .has_next_page = false,
        };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemWithOptions(item, .{});
    }

    pub fn fetchSubtitlesBySearchItemWithOptions(self: *Scraper, item: SearchItem, options: SubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var auth = try resolveAuth(a, options.cf_clearance, options.user_agent, false, options.auto_cloudflare_session);

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

        for (endpoints.items) |endpoint| {
            if (seen_endpoint.contains(endpoint)) continue;
            try seen_endpoint.put(a, endpoint, {});

            const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
            var page = if (options.page_start == 0) 1 else options.page_start;
            var traversed: usize = 0;

            while (traversed < max_pages) : (traversed += 1) {
                const endpoint_url = if (page <= 1)
                    try std.fmt.allocPrint(a, "{s}{s}", .{ api_base, endpoint })
                else
                    try std.fmt.allocPrint(a, "{s}{s}?page={d}", .{ api_base, endpoint, page });

                var response = try getJson(self.client, a, endpoint_url, auth, true);
                if (response.status == .forbidden and options.auto_cloudflare_session) {
                    auth = try resolveAuth(a, options.cf_clearance, options.user_agent, true, options.auto_cloudflare_session);
                    response = try getJson(self.client, a, endpoint_url, auth, true);
                }
                if (response.status != .ok) break;

                var parsed = try std.json.parseFromSlice(std.json.Value, a, response.body, .{});
                defer parsed.deinit();

                const root = switch (parsed.value) {
                    .object => |o| o,
                    else => break,
                };
                const subtitles_v = root.get("subtitles") orelse break;
                const subtitles_arr = switch (subtitles_v) {
                    .array => |arr| arr,
                    else => break,
                };

                var new_count: usize = 0;
                for (subtitles_arr.items) |entry| {
                    const obj = switch (entry) {
                        .object => |o| o,
                        else => continue,
                    };

                    const details_path = objString(obj, "link") orelse continue;
                    if (seen_subtitle.contains(details_path)) continue;
                    try seen_subtitle.put(a, details_path, {});
                    new_count += 1;

                    const id = objInt(obj, "id") orelse 0;
                    const language_raw = objString(obj, "language");
                    const language_code = normalizeSubsourceLanguage(language_raw);
                    const release_info = objString(obj, "release_info");
                    const release_type = objString(obj, "release_type");

                    var download_token: ?[]const u8 = null;
                    var download_url: ?[]const u8 = null;
                    if (options.resolve_download_tokens) {
                        const details = self.fetchSubtitleDetails(a, details_path, auth) catch null;
                        if (details) |d| {
                            download_token = d.download_token;
                            download_url = d.download_url;
                        }
                    }

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

                if (new_count == 0) break;
                page += 1;
            }
        }

        const current_page = if (options.page_start == 0) 1 else options.page_start;
        return .{
            .arena = arena,
            .title = item.title,
            .subtitles = try out.toOwnedSlice(a),
            .page = current_page,
            .has_prev_page = current_page > 1,
            .has_next_page = false,
        };
    }

    const SubtitleDetails = struct {
        download_token: ?[]const u8,
        download_url: ?[]const u8,
    };

    fn fetchSubtitleDetails(self: *Scraper, allocator: Allocator, details_path: []const u8, auth: Auth) !SubtitleDetails {
        const trimmed = std.mem.trimLeft(u8, details_path, "/");
        const url = try std.fmt.allocPrint(allocator, "{s}/subtitle/{s}", .{ api_base, trimmed });

        const response = try getJson(self.client, allocator, url, auth, true);
        if (response.status != .ok) return .{ .download_token = null, .download_url = null };

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return .{ .download_token = null, .download_url = null },
        };

        const subtitle_v = root.get("subtitle") orelse return .{ .download_token = null, .download_url = null };
        const subtitle_obj = switch (subtitle_v) {
            .object => |o| o,
            else => return .{ .download_token = null, .download_url = null },
        };

        const token = objString(subtitle_obj, "download_token") orelse return .{ .download_token = null, .download_url = null };
        if (token.len == 0) return .{ .download_token = null, .download_url = null };

        return .{
            .download_token = token,
            .download_url = try std.fmt.allocPrint(allocator, "{s}/subtitle/download/{s}", .{ api_base, token }),
        };
    }
};

fn resolveSearchQuery(client: *std.http.Client, allocator: Allocator, query: []const u8) ![]const u8 {
    const trimmed = common.trimAscii(query);
    if (trimmed.len == 0) return try allocator.dupe(u8, query);

    const encoded = try common.encodeUriComponent(allocator, trimmed);
    const url = try std.fmt.allocPrint(allocator, "https://subttsearch.com/wp-content/themes/subttsearch/suggestions.php?q={s}", .{encoded});

    const response = common.fetchBytes(client, allocator, url, .{ .accept = "application/json", .max_attempts = 2, .allow_non_ok = true }) catch {
        return try allocator.dupe(u8, trimmed);
    };
    if (response.status != .ok) return try allocator.dupe(u8, trimmed);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
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

fn appendSearchResults(
    client: *std.http.Client,
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SearchItem),
    seen: *std.AutoHashMapUnmanaged(i64, void),
    query: []const u8,
    options: SearchOptions,
    auth: *Auth,
) !void {
    _ = options.include_seasons;
    _ = options.limit_per_page;

    const payload = try buildSearchPayload(allocator, query);

    var response = try postJson(client, allocator, api_base ++ "/movie/search", payload, auth.*, true);
    if (response.status == .forbidden and options.auto_cloudflare_session) {
        auth.* = try resolveAuth(allocator, options.cf_clearance, options.user_agent, true, options.auto_cloudflare_session);
        response = try postJson(client, allocator, api_base ++ "/movie/search", payload, auth.*, true);
    }
    if (response.status != .ok) return;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const results_v = root.get("results") orelse return;
    const results = switch (results_v) {
        .array => |arr| arr,
        else => return,
    };

    for (results.items) |entry| {
        const obj = switch (entry) {
            .object => |o| o,
            else => continue,
        };

        const id = objInt(obj, "id") orelse continue;
        if (seen.contains(id)) continue;
        try seen.put(allocator, id, {});

        const title = objString(obj, "title") orelse continue;
        const media_type = objString(obj, "type") orelse "unknown";
        const raw_link = objString(obj, "link") orelse continue;
        const link = try toAbsoluteSiteLink(allocator, raw_link);
        const release_year = objInt(obj, "releaseYear");
        const subtitle_count = objInt(obj, "subtitleCount");

        var seasons_out: std.ArrayListUnmanaged(SeasonItem) = .empty;
        if (obj.get("seasons")) |seasons_v| {
            if (seasons_v == .array) {
                for (seasons_v.array.items) |season_v| {
                    const season_obj = switch (season_v) {
                        .object => |o| o,
                        else => continue,
                    };
                    const season_num = objInt(season_obj, "season") orelse continue;
                    const season_link_raw = objString(season_obj, "link") orelse continue;
                    const season_link = try toAbsoluteSiteLink(allocator, season_link_raw);
                    try seasons_out.append(allocator, .{ .season = season_num, .link = season_link });
                }
            }
        }

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

fn buildSearchPayload(allocator: Allocator, query: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"query\":\"{s}\",\"signal\":{{}},\"includeSeasons\":false,\"limit\":9999}}",
        .{
            try escapeJson(allocator, query),
        },
    );
}

fn resolveAuth(allocator: Allocator, cf_clearance_opt: ?[]const u8, user_agent_opt: ?[]const u8, force_refresh: bool, auto_cloudflare_session: bool) !Auth {
    var cf_clearance = cf_clearance_opt;
    if (cf_clearance == null) {
        cf_clearance = std.posix.getenv("SUBSOURCE_CF_CLEARANCE");
    }

    var user_agent = user_agent_opt orelse std.posix.getenv("SUBSOURCE_USER_AGENT") orelse common.default_user_agent;

    if (cf_clearance == null and auto_cloudflare_session and force_refresh) {
        const session = try cf_shared.ensureDomainSession(allocator, .{
            .domain = "subsource.net",
            .challenge_url = site,
            .force_refresh = force_refresh,
        });
        cf_clearance = session.cf_clearance;
        user_agent = session.user_agent;
    }

    return .{ .cf_clearance = cf_clearance, .user_agent = user_agent };
}

fn getJson(client: *std.http.Client, allocator: Allocator, url: []const u8, auth: Auth, allow_non_ok: bool) !common.HttpResponse {
    var headers_buf: [2]std.http.Header = undefined;
    var headers_len: usize = 0;

    if (auth.cf_clearance) |token| {
        const cookie = try std.fmt.allocPrint(allocator, "cf_clearance={s}", .{token});
        headers_buf[headers_len] = .{ .name = "cookie", .value = cookie };
        headers_len += 1;
    }

    headers_buf[headers_len] = .{ .name = "user-agent", .value = auth.user_agent };
    headers_len += 1;

    return common.fetchBytes(client, allocator, url, .{
        .accept = "application/json, text/plain, */*",
        .extra_headers = headers_buf[0..headers_len],
        .allow_non_ok = allow_non_ok,
        .max_attempts = 2,
    });
}

fn postJson(client: *std.http.Client, allocator: Allocator, url: []const u8, payload: []const u8, auth: Auth, allow_non_ok: bool) !common.HttpResponse {
    var headers_buf: [3]std.http.Header = undefined;
    var headers_len: usize = 0;

    if (auth.cf_clearance) |token| {
        const cookie = try std.fmt.allocPrint(allocator, "cf_clearance={s}", .{token});
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
    });
}

fn normalizeSubsourceLanguage(raw: ?[]const u8) ?[]const u8 {
    const lang = raw orelse return null;
    if (std.ascii.eqlIgnoreCase(lang, "farsi/persian")) return "fa";
    if (std.ascii.eqlIgnoreCase(lang, "chinese traditional")) return "zh-tw";
    return common.normalizeLanguageCode(lang);
}

fn pathToSubtitles(allocator: Allocator, link: []const u8) !?[]const u8 {
    var normalized = common.trimAscii(link);
    if (normalized.len == 0) return null;

    if (std.mem.startsWith(u8, normalized, "http://") or std.mem.startsWith(u8, normalized, "https://")) {
        const start = std.mem.indexOf(u8, normalized, "/subtitles/") orelse
            std.mem.indexOf(u8, normalized, "/series/") orelse return null;
        normalized = normalized[start..];
    }

    if (std.mem.startsWith(u8, normalized, "/subtitles/")) return try allocator.dupe(u8, normalized);
    if (std.mem.startsWith(u8, normalized, "/series/")) {
        return try std.fmt.allocPrint(allocator, "/subtitles/{s}", .{normalized["/series/".len..]});
    }

    if (!std.mem.startsWith(u8, normalized, "/")) {
        return try std.fmt.allocPrint(allocator, "/subtitles/{s}", .{normalized});
    }

    return try std.fmt.allocPrint(allocator, "/subtitles{s}", .{normalized});
}

fn toAbsoluteSiteLink(allocator: Allocator, link: []const u8) ![]const u8 {
    const trimmed = common.trimAscii(link);
    if (trimmed.len == 0) return try allocator.dupe(u8, trimmed);
    if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://")) {
        return try allocator.dupe(u8, trimmed);
    }
    if (std.mem.startsWith(u8, trimmed, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ site, trimmed });
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ site, trimmed });
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
    const trimmed = common.trimAscii(value);
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn objInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn escapeJson(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "subsource path to subtitles" {
    const allocator = std.testing.allocator;
    const a = (try pathToSubtitles(allocator, "/subtitles/the-matrix-1999")).?;
    defer allocator.free(a);
    try std.testing.expectEqualStrings("/subtitles/the-matrix-1999", a);

    const b = (try pathToSubtitles(allocator, "/series/the-matrix-1999")).?;
    defer allocator.free(b);
    try std.testing.expectEqualStrings("/subtitles/the-matrix-1999", b);

    try std.testing.expect((try pathToSubtitles(allocator, "")) == null);
}

test "subsource language normalization" {
    try std.testing.expectEqualStrings("fa", normalizeSubsourceLanguage("farsi/persian").?);
    try std.testing.expectEqualStrings("zh-tw", normalizeSubsourceLanguage("chinese traditional").?);
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
    const payload = try buildSearchPayload(allocator, "The Matrix");
    defer allocator.free(payload);
    try std.testing.expectEqualStrings(
        "{\"query\":\"The Matrix\",\"signal\":{},\"includeSeasons\":false,\"limit\":9999}",
        payload,
    );
}
