const std = @import("std");
const common = @import("common.zig");
const cloudflare = @import("opensubtitles_com_cf.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://animekalesi.com";
const browser_cookie_scope_url = site ++ "/";
const series_index_url = site ++ "/tum-anime-serileri.html";
const max_token_route_segment_bytes = 240;
pub const download_token_prefix = "animekalesi-session:";

pub const SearchItem = common.SearchLink;

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
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const normalized_query = try common.normalizeTitle(a, trimmed);
        if (normalized_query.len == 0) return .{ .arena = arena, .items = &.{} };

        const response = try fetchProviderHtml(self.client, a, series_index_url, null);
        return parseSeriesIndex(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateListingUrl(item.page_url);

        const response = try fetchProviderHtml(self.client, a, item.page_url, series_index_url);
        const owned = try parseSubtitleListing(a, response.body, item);
        std.mem.sort(SubtitleItem, owned, {}, common.seasonEpisodeLessThan(SubtitleItem));
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = owned,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateListingUrl(parts.listing_url);
        try validateEpisodeUrl(parts.episode_url);

        var asp_cookies: AspSessionCookies = .empty;
        defer asp_cookies.deinit(allocator);

        var browser_session: ?cloudflare.Session = null;
        defer if (browser_session) |*session| session.deinit(allocator);
        var refreshed_rejected_session = false;

        var index = try fetchRawProviderStep(
            self.client,
            allocator,
            series_index_url,
            &asp_cookies,
            null,
            &browser_session,
            &refreshed_rejected_session,
        );
        defer index.deinit(allocator);

        var listing = try fetchRawProviderStep(
            self.client,
            allocator,
            parts.listing_url,
            &asp_cookies,
            series_index_url,
            &browser_session,
            &refreshed_rejected_session,
        );
        defer listing.deinit(allocator);

        if (!try listingContainsEpisodeUrl(allocator, listing.body, parts.episode_url))
            return error.InvalidDownloadUrl;

        var episode = try fetchRawProviderStep(
            self.client,
            allocator,
            parts.episode_url,
            &asp_cookies,
            parts.listing_url,
            &browser_session,
            &refreshed_rejected_session,
        );
        defer episode.deinit(allocator);

        const first_url = try parseEpisodeDownloadUrl(allocator, episode.body);
        defer allocator.free(first_url);
        return fetchPublicDownload(
            self.client,
            allocator,
            first_url,
            &asp_cookies,
            parts.episode_url,
            &browser_session,
            &refreshed_rejected_session,
        );
    }
};

fn parseSubtitleListing(allocator: Allocator, body: []const u8, item: SearchItem) ![]SubtitleItem {
    var parsed = try common.parseHtmlStable(allocator, body);
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var anchors = parsed.doc.queryAll("td#ayazi_indir a[href^='indir_bolum-']");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const title_attr = common.getAttributeValueSafe(anchor, "title") orelse "";
        const episode = parseLastPositiveInt(title_attr) orelse continue;
        const season: i64 = parseSeason(title_attr) orelse 1;
        if (seen.contains(href)) continue;

        try subtitles.ensureUnusedCapacity(allocator, 1);
        try seen.ensureUnusedCapacity(allocator, 1);

        const episode_url = common.resolveUrl(allocator, site, href) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer allocator.free(episode_url);
        validateEpisodeUrl(episode_url) catch continue;
        const slugged = try common.asciiSlug(allocator, item.title);
        defer allocator.free(slugged);
        const filename = try std.fmt.allocPrint(allocator, "animekalesi-{s}-s{d}e{d}.zip", .{ slugged, season, episode });
        errdefer allocator.free(filename);
        const download_url = try makeDownloadToken(allocator, item.page_url, episode_url);
        errdefer allocator.free(download_url);
        const subtitle: SubtitleItem = .{
            .language_code = "tr",
            .filename = filename,
            .download_url = download_url,
            .season = season,
            .episode = episode,
        };

        seen.putAssumeCapacityNoClobber(href, {});
        subtitles.appendAssumeCapacity(subtitle);
    }
    return subtitles.toOwnedSlice(allocator);
}

fn parseSeriesIndex(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);

    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    var anchors = parsed.doc.queryAll("td#bolumler a[href^='bolumler-']");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const raw_title = try common.innerTextTrimmedOwned(a, anchor);
        const title = trimDisplaySpace(raw_title);
        if (title.len == 0) continue;

        const normalized = try common.normalizeTitle(a, title);
        if (normalized.len == 0) continue;
        if (std.mem.indexOf(u8, normalized, wanted) == null and
            std.mem.indexOf(u8, wanted, normalized) == null) continue;

        const series_url = common.resolveUrl(a, site, href) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const listing_url = subtitleListingUrl(a, series_url) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        validateListingUrl(listing_url) catch continue;

        const item: SearchItem = .{
            .title = title,
            .page_url = listing_url,
        };
        if (std.mem.eql(u8, normalized, wanted)) {
            if (searchLinkIndex(exact.items, listing_url) != null) continue;
            if (searchLinkIndex(partial.items, listing_url)) |index| {
                _ = partial.orderedRemove(index);
            }
            try exact.append(a, item);
        } else {
            if (searchLinkIndex(exact.items, listing_url) != null or
                searchLinkIndex(partial.items, listing_url) != null) continue;
            try partial.append(a, item);
        }
    }

    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    try out.appendSlice(a, exact.items);
    try out.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try out.toOwnedSlice(a) });
}

fn searchLinkIndex(items: []const SearchItem, page_url: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.page_url, page_url)) return index;
    }
    return null;
}

fn subtitleListingUrl(allocator: Allocator, series_url: []const u8) ![]u8 {
    const marker = "bolumler-";
    const pos = std.mem.lastIndexOf(u8, series_url, marker) orelse return error.MissingField;
    return std.fmt.allocPrint(
        allocator,
        "{s}altyazib-{s}",
        .{ series_url[0..pos], series_url[pos + marker.len ..] },
    );
}

fn parseLastPositiveInt(value: []const u8) ?i64 {
    var result: ?i64 = null;
    var i: usize = 0;
    while (i < value.len) {
        if (!std.ascii.isDigit(value[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
        const number = std.fmt.parseInt(i64, value[start..i], 10) catch continue;
        if (number > 0) result = number;
    }
    return result;
}

fn parseSeason(value: []const u8) ?i64 {
    const lower_marker = "sezon";
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (!std.ascii.isDigit(value[i])) continue;
        const start = i;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
        var p = i;
        while (p < value.len and (value[p] == ' ' or value[p] == '.' or value[p] == '-')) : (p += 1) {}
        if (p + lower_marker.len > value.len) continue;
        if (!std.ascii.eqlIgnoreCase(value[p .. p + lower_marker.len], lower_marker)) continue;
        return std.fmt.parseInt(i64, value[start..i], 10) catch null;
    }
    return null;
}

pub fn makeDownloadToken(allocator: Allocator, listing_url: []const u8, episode_url: []const u8) ![]u8 {
    try validateListingUrl(listing_url);
    try validateEpisodeUrl(episode_url);
    return std.fmt.allocPrint(allocator, "{s}{s}|{s}", .{ download_token_prefix, listing_url, episode_url });
}

const DownloadToken = struct {
    listing_url: []const u8,
    episode_url: []const u8,
};

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    const sep = std.mem.indexOfScalar(u8, payload, '|') orelse return null;
    if (sep == 0 or sep + 1 >= payload.len) return null;
    const result: DownloadToken = .{ .listing_url = payload[0..sep], .episode_url = payload[sep + 1 ..] };
    validateListingUrl(result.listing_url) catch return null;
    validateEpisodeUrl(result.episode_url) catch return null;
    return result;
}

fn listingContainsEpisodeUrl(allocator: Allocator, body: []const u8, expected_url: []const u8) !bool {
    try validateEpisodeUrl(expected_url);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);
    var anchors = parsed.doc.queryAll("td#ayazi_indir a[href^='indir_bolum-']");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const resolved = common.resolveUrl(a, site, href) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        validateEpisodeUrl(resolved) catch continue;
        if (std.mem.eql(u8, resolved, expected_url)) return true;
    }
    return false;
}

fn parseEpisodeDownloadUrl(allocator: Allocator, body: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);
    var anchors = parsed.doc.queryAll("div#altyazi_indir a[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const resolved = common.resolveUrl(a, site, href) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        validateInitialDownloadUrl(resolved) catch continue;
        return allocator.dupe(u8, resolved);
    }
    return error.MissingField;
}

fn trimDisplaySpace(value: []const u8) []const u8 {
    var start: usize = 0;
    while (start < value.len) {
        if (std.ascii.isWhitespace(value[start])) {
            start += 1;
            continue;
        }
        if (start + 1 < value.len and value[start] == 0xC2 and value[start + 1] == 0xA0) {
            start += 2;
            continue;
        }
        break;
    }

    var end = value.len;
    while (end > start) {
        if (std.ascii.isWhitespace(value[end - 1])) {
            end -= 1;
            continue;
        }
        if (end >= start + 2 and value[end - 2] == 0xC2 and value[end - 1] == 0xA0) {
            end -= 2;
            continue;
        }
        break;
    }
    return value[start..end];
}

const RawResponse = struct {
    status: std.http.Status,
    body: []u8,
    cookie_headers: ?[]u8,
    location: ?[]u8,

    fn deinit(self: *RawResponse, allocator: Allocator) void {
        allocator.free(self.body);
        if (self.cookie_headers) |value| allocator.free(value);
        if (self.location) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn fetchRaw(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    cookie: ?[]const u8,
    referer: ?[]const u8,
    user_agent: ?[]const u8,
) !RawResponse {
    // Each raw network attempt is bounded from DNS through body read. A retry
    // after the separately bounded manual browser handoff receives a fresh
    // transport budget instead of truncating the user's challenge window.
    const now_ms = common.compatMilliTimestamp();
    return fetchRawUntil(
        client,
        allocator,
        url,
        cookie,
        referer,
        user_agent,
        now_ms +| common.default_fetch_timeout_ms,
    );
}

fn fetchRawUntil(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    cookie: ?[]const u8,
    referer: ?[]const u8,
    user_agent: ?[]const u8,
    deadline_ms: i64,
) !RawResponse {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;

    const FetchTask = struct {
        fn run(
            result: *?RawResponse,
            task_client: *std.http.Client,
            task_allocator: Allocator,
            task_url: []const u8,
            task_cookie: ?[]const u8,
            task_referer: ?[]const u8,
            task_user_agent: ?[]const u8,
        ) !void {
            result.* = try fetchRawUnbounded(
                task_client,
                task_allocator,
                task_url,
                task_cookie,
                task_referer,
                task_user_agent,
            );
        }
    };
    const FetchResult = @typeInfo(@TypeOf(FetchTask.run)).@"fn".return_type.?;
    const TimeoutResult = @typeInfo(@TypeOf(std.Io.Timeout.sleep)).@"fn".return_type.?;
    const Selection = union(enum) {
        fetch: FetchResult,
        timeout: TimeoutResult,
    };
    var selection_buffer: [2]Selection = undefined;
    var selection = std.Io.Select(Selection).init(client.io, &selection_buffer);
    var owned_response: ?RawResponse = null;
    defer {
        selection.cancelDiscard();
        if (owned_response) |*response| response.deinit(allocator);
    }

    const remaining_ms: i64 = deadline_ms -| now_ms;
    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(client.io, .{
        .raw = std.Io.Duration.fromMilliseconds(remaining_ms),
        .clock = .awake,
    }) };
    try selection.concurrent(.fetch, FetchTask.run, .{
        &owned_response,
        client,
        allocator,
        url,
        cookie,
        referer,
        user_agent,
    });
    try selection.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, client.io });

    switch (try selection.await()) {
        .fetch => |result| {
            try result;
            const response = owned_response orelse return error.MissingHttpResponse;
            owned_response = null;
            return response;
        },
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}

fn fetchRawUnbounded(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    cookie: ?[]const u8,
    referer: ?[]const u8,
    user_agent: ?[]const u8,
) !RawResponse {
    try validateProviderUrl(url);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

    var extra_storage: [3]std.http.Header = undefined;
    var extra_count: usize = 0;
    if (cookie) |value| {
        extra_storage[extra_count] = .{ .name = "cookie", .value = value };
        extra_count += 1;
    }
    if (referer) |value| {
        extra_storage[extra_count] = .{ .name = "referer", .value = value };
        extra_count += 1;
    }
    extra_storage[extra_count] = .{ .name = "accept", .value = "text/html,application/xhtml+xml,application/zip,application/octet-stream,*/*" };
    extra_count += 1;
    try common.validateHttpHeaders(extra_storage[0..extra_count]);
    if (!common.validHttpHeaderValue(user_agent orelse common.default_user_agent)) return error.InvalidHttpHeader;

    var public_client: std.http.Client = undefined;
    try common.initPublicOriginClient(client, &public_client);
    defer public_client.deinit();
    const pinned_connection = try common.connectPinnedPublicHttpUrl(&public_client, allocator, normalized);
    pinned_connection.closing = true;

    var req = public_client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .handle_continue = false,
        .keep_alive = false,
        .connection = pinned_connection,
        .headers = .{
            .user_agent = .{ .override = user_agent orelse common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra_storage[0..extra_count],
    }) catch |err| {
        public_client.connection_pool.release(pinned_connection, public_client.io);
        return err;
    };
    defer req.deinit();
    errdefer req.connection.?.closing = true;
    req.sendBodiless() catch |err| return common.normalizeRequestWriteError(&req, err);

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    var interim_count: usize = 0;
    while (response.head.status.class() == .informational) {
        if (response.head.status == .switching_protocols) return error.UnsupportedProtocolUpgrade;
        try validateRawSessionResponseHead(response.head);
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    try validateRawSessionResponseHead(response.head);
    const cookie_headers = try extractSessionCookieHeaders(allocator, response.head.bytes);
    errdefer if (cookie_headers) |value| allocator.free(value);
    const location = if (response.head.location) |value| try allocator.dupe(u8, value) else null;
    errdefer if (location) |value| allocator.free(value);

    const body = try common.readStrictResponseBody(&req, &response, allocator, max_raw_response_bytes);
    errdefer allocator.free(body);

    return .{
        .status = response.head.status,
        .body = body,
        .cookie_headers = cookie_headers,
        .location = location,
    };
}

fn validateRawSessionResponseHead(head: std.http.Client.Response.Head) !void {
    try common.validateResponseFraming(head);
}

fn extractSessionCookieHeaders(allocator: Allocator, headers: []const u8) !?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const equals = std.mem.indexOfScalar(u8, value, '=') orelse continue;
        if (!isAspSessionCookieName(std.mem.trim(u8, value[0..equals], " \t"))) continue;
        if (out.items.len != 0) try out.appendSlice(allocator, "\r\n");
        try out.appendSlice(allocator, line);
    }
    return if (out.items.len == 0) null else try out.toOwnedSlice(allocator);
}

const AspSessionCookie = struct {
    name: []u8,
    value: []u8,
    domain: []u8,
    path: []u8,
    secure: bool,
    host_only: bool,
    expires_unix_seconds: ?i64,

    fn deinit(self: AspSessionCookie, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        allocator.free(self.domain);
        allocator.free(self.path);
    }
};

const CookieRequestTarget = struct {
    secure: bool,
    host: []const u8,
    path: []const u8,
};

const ParsedAspSessionCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    secure: bool,
    host_only: bool,
    expires_unix_seconds: ?i64,
};

const AspSessionCookies = struct {
    const empty: @This() = .{};

    cookies: std.ArrayListUnmanaged(AspSessionCookie) = .empty,

    fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.cookies.items) |cookie| cookie.deinit(allocator);
        self.cookies.deinit(allocator);
        self.* = .empty;
    }

    fn updateFromResponseHeaders(
        self: *@This(),
        allocator: Allocator,
        request_url: []const u8,
        headers: ?[]const u8,
        now: i64,
    ) !void {
        const source = headers orelse return;
        const target = parseCookieRequestTarget(request_url) orelse return error.InvalidDownloadUrl;
        var lines = std.mem.splitSequence(u8, source, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(header_name, "set-cookie")) continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            const parsed = parseAspSessionSetCookie(value, target, now) orelse continue;
            try self.apply(allocator, parsed, now);
        }
    }

    fn updateFromBrowserCookies(
        self: *@This(),
        allocator: Allocator,
        browser_cookies: []const cloudflare.Cookie,
        now: i64,
    ) !void {
        for (browser_cookies) |cookie| {
            if (!isAspSessionCookieName(cookie.name) or
                !validCookieName(cookie.name) or
                !validCookieValue(cookie.value) or
                !validCookiePath(cookie.path)) continue;
            const domain = stripLeadingDots(cookie.domain);
            if (!std.ascii.eqlIgnoreCase(domain, "animekalesi.com")) continue;
            const expires = if (cookie.expires_unix_seconds) |value|
                if (value < 0) null else value
            else
                null;
            try self.apply(allocator, .{
                .name = cookie.name,
                .value = cookie.value,
                .domain = domain,
                .path = cookie.path,
                .secure = cookie.secure,
                .host_only = cookie.host_only,
                .expires_unix_seconds = expires,
            }, now);
        }
    }

    fn apply(self: *@This(), allocator: Allocator, parsed: ParsedAspSessionCookie, now: i64) !void {
        var existing: ?usize = null;
        for (self.cookies.items, 0..) |cookie, index| {
            if (!std.mem.eql(u8, cookie.name, parsed.name)) continue;
            if (!std.ascii.eqlIgnoreCase(cookie.domain, parsed.domain)) continue;
            if (!std.mem.eql(u8, cookie.path, parsed.path)) continue;
            existing = index;
            break;
        }

        const expired = if (parsed.expires_unix_seconds) |expires| expires <= now else false;
        if (expired) {
            if (existing) |index| {
                self.cookies.items[index].deinit(allocator);
                _ = self.cookies.orderedRemove(index);
            }
            return;
        }

        const owned: AspSessionCookie = .{
            .name = try allocator.dupe(u8, parsed.name),
            .value = undefined,
            .domain = undefined,
            .path = undefined,
            .secure = parsed.secure,
            .host_only = parsed.host_only,
            .expires_unix_seconds = parsed.expires_unix_seconds,
        };
        var complete = owned;
        errdefer allocator.free(complete.name);
        complete.value = try allocator.dupe(u8, parsed.value);
        errdefer allocator.free(complete.value);
        complete.domain = try allocator.dupe(u8, parsed.domain);
        errdefer allocator.free(complete.domain);
        complete.path = try allocator.dupe(u8, parsed.path);
        errdefer allocator.free(complete.path);

        if (existing) |index| {
            self.cookies.items[index].deinit(allocator);
            self.cookies.items[index] = complete;
        } else {
            try self.cookies.append(allocator, complete);
        }
    }

    fn cookieHeaderForUrl(self: *const @This(), allocator: Allocator, url: []const u8, now: i64) !?[]u8 {
        const target = parseCookieRequestTarget(url) orelse return null;
        var selected: std.ArrayListUnmanaged(usize) = .empty;
        defer selected.deinit(allocator);
        for (self.cookies.items, 0..) |cookie, index| {
            if (!aspCookieApplies(cookie, target, now)) continue;
            try selected.append(allocator, index);
            var position = selected.items.len - 1;
            while (position > 0 and self.cookies.items[selected.items[position]].path.len > self.cookies.items[selected.items[position - 1]].path.len) : (position -= 1) {
                std.mem.swap(usize, &selected.items[position], &selected.items[position - 1]);
            }
        }
        if (selected.items.len == 0) return null;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        for (selected.items, 0..) |index, output_index| {
            const cookie = self.cookies.items[index];
            if (output_index != 0) try out.appendSlice(allocator, "; ");
            try out.appendSlice(allocator, cookie.name);
            try out.append(allocator, '=');
            try out.appendSlice(allocator, cookie.value);
        }
        return try out.toOwnedSlice(allocator);
    }
};

fn installBrowserSession(
    allocator: Allocator,
    asp_cookies: *AspSessionCookies,
    destination: *?cloudflare.Session,
    session: cloudflare.Session,
) !void {
    var acquired = session;
    errdefer acquired.deinit(allocator);
    try asp_cookies.updateFromBrowserCookies(allocator, acquired.cookies, common.compatUnixTimestamp());
    if (destination.*) |*owned| owned.deinit(allocator);
    destination.* = acquired;
}

fn parseCookieRequestTarget(url: []const u8) ?CookieRequestTarget {
    const uri = std.Uri.parse(url) catch return null;
    if (uri.user != null or uri.password != null) return null;
    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!secure and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    const host_component = uri.host orelse return null;
    const host = switch (host_component) {
        .raw => |bytes| bytes,
        .percent_encoded => |bytes| if (std.mem.indexOfScalar(u8, bytes, '%') == null) bytes else return null,
    };
    if (host.len == 0) return null;
    const path_component = switch (uri.path) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    return .{
        .secure = secure,
        .host = host,
        .path = if (path_component.len == 0) "/" else path_component,
    };
}

fn parseAspSessionSetCookie(value: []const u8, target: CookieRequestTarget, now: i64) ?ParsedAspSessionCookie {
    var attributes = std.mem.splitScalar(u8, value, ';');
    const pair = std.mem.trim(u8, attributes.next() orelse return null, " \t");
    const equals = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
    const name = std.mem.trim(u8, pair[0..equals], " \t");
    const cookie_value = std.mem.trim(u8, pair[equals + 1 ..], " \t");
    if (!isAspSessionCookieName(name) or !validCookieName(name) or !validCookieValue(cookie_value)) return null;

    var domain = target.host;
    var host_only = true;
    var path = defaultCookiePath(target.path);
    var secure = false;
    var expires_attribute: ?i64 = null;
    var max_age_attribute: ?i64 = null;
    while (attributes.next()) |raw_attribute| {
        const attribute = std.mem.trim(u8, raw_attribute, " \t");
        if (attribute.len == 0) continue;
        const attribute_equals = std.mem.indexOfScalar(u8, attribute, '=');
        const attribute_name = std.mem.trim(u8, attribute[0 .. attribute_equals orelse attribute.len], " \t");
        const attribute_value = if (attribute_equals) |position|
            std.mem.trim(u8, attribute[position + 1 ..], " \t")
        else
            "";

        if (std.ascii.eqlIgnoreCase(attribute_name, "secure")) {
            secure = true;
        } else if (std.ascii.eqlIgnoreCase(attribute_name, "path")) {
            if (validCookiePath(attribute_value)) path = attribute_value;
        } else if (std.ascii.eqlIgnoreCase(attribute_name, "domain")) {
            const candidate = stripLeadingDots(attribute_value);
            if (candidate.len == 0 or candidate[candidate.len - 1] == '.') return null;
            // Raw provider requests never leave this exact host. Refuse a
            // broader Domain attribute instead of creating a super-cookie.
            if (!std.ascii.eqlIgnoreCase(candidate, target.host)) return null;
            domain = candidate;
            host_only = false;
        } else if (std.ascii.eqlIgnoreCase(attribute_name, "max-age")) {
            if (std.fmt.parseInt(i64, attribute_value, 10) catch null) |parsed| max_age_attribute = parsed;
        } else if (std.ascii.eqlIgnoreCase(attribute_name, "expires")) {
            if (parseCookieDate(attribute_value)) |parsed| expires_attribute = parsed;
        }
    }

    const expires = if (max_age_attribute) |max_age|
        if (max_age <= 0)
            now
        else
            saturatingAddSeconds(now, max_age)
    else
        expires_attribute;
    return .{
        .name = name,
        .value = cookie_value,
        .domain = domain,
        .path = path,
        .secure = secure,
        .host_only = host_only,
        .expires_unix_seconds = expires,
    };
}

fn validCookieName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={} ", byte) != null) return false;
    }
    return true;
}

fn validCookieValue(value: []const u8) bool {
    const content = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
        value[1 .. value.len - 1]
    else
        value;
    for (content) |byte| {
        if (byte < 0x21 or byte >= 0x7f or byte == '"' or byte == ',' or byte == ';' or byte == '\\') return false;
    }
    return true;
}

fn validCookiePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f or byte == ';') return false;
    return true;
}

fn defaultCookiePath(request_path: []const u8) []const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return "/";
    const last_slash = std.mem.lastIndexOfScalar(u8, request_path, '/') orelse return "/";
    return if (last_slash == 0) "/" else request_path[0..last_slash];
}

fn aspCookieApplies(cookie: AspSessionCookie, target: CookieRequestTarget, now: i64) bool {
    if (cookie.secure and !target.secure) return false;
    if (cookie.expires_unix_seconds) |expires| if (expires <= now) return false;
    if (cookie.host_only) {
        if (!std.ascii.eqlIgnoreCase(cookie.domain, target.host)) return false;
    } else if (!domainMatches(target.host, cookie.domain)) return false;
    return cookiePathMatches(cookie.path, target.path);
}

fn domainMatches(host: []const u8, domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len or !std.ascii.endsWithIgnoreCase(host, domain)) return false;
    return host[host.len - domain.len - 1] == '.';
}

fn cookiePathMatches(cookie_path: []const u8, request_path: []const u8) bool {
    if (std.mem.eql(u8, cookie_path, request_path)) return true;
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;
    if (cookie_path[cookie_path.len - 1] == '/') return true;
    return request_path.len > cookie_path.len and request_path[cookie_path.len] == '/';
}

fn stripLeadingDots(value: []const u8) []const u8 {
    var result = value;
    while (result.len > 0 and result[0] == '.') result = result[1..];
    return result;
}

fn saturatingAddSeconds(now: i64, delta: i64) i64 {
    const sum = @as(i128, now) + @as(i128, delta);
    return if (sum > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(sum);
}

const CookieTime = struct { hour: u8, minute: u8, second: u8 };

fn parseCookieDate(value: []const u8) ?i64 {
    var month: ?u8 = null;
    var time: ?CookieTime = null;
    var day: ?u8 = null;
    var year: ?u16 = null;

    // RFC 6265 cookie-date delimiters: HTAB, SP through '/', ';' through
    // '@', '[' through '`', and '{' through '~'. A colon is deliberately not
    // a delimiter because it separates the time fields.
    var tokens = std.mem.tokenizeAny(u8, value, "\x09 !\"#$%&'()*+,-./;<=>?@[\\]^_`{|}~");
    while (tokens.next()) |token| {
        if (time == null) if (parseCookieTime(token)) |parsed_time| {
            time = parsed_time;
            continue;
        };
        if (day == null) if (parseCookieDay(token)) |parsed_day| {
            day = parsed_day;
            continue;
        };
        if (month == null) if (parseCookieMonth(token)) |parsed_month| {
            month = parsed_month;
            continue;
        };
        if (year == null) if (parseCookieYear(token)) |parsed_year| {
            year = parsed_year;
            continue;
        };
    }
    if (month == null or time == null or day == null or year == null) return null;
    var full_year = year.?;
    if (full_year <= 69) full_year += 2000 else if (full_year <= 99) full_year += 1900;
    if (full_year < 1601) return null;
    if (day.? > daysInMonth(full_year, month.?)) return null;
    if (full_year < 1970) return 0;

    var days: i64 = 0;
    var cursor_year: u16 = 1970;
    while (cursor_year < full_year) : (cursor_year += 1) days += if (isLeapYear(cursor_year)) 366 else 365;
    var cursor_month: u8 = 1;
    while (cursor_month < month.?) : (cursor_month += 1) days += daysInMonth(full_year, cursor_month);
    days += day.? - 1;
    return days * 86400 + @as(i64, time.?.hour) * 3600 + @as(i64, time.?.minute) * 60 + time.?.second;
}

fn leadingCookieDigits(value: []const u8, max_digits: usize) ?struct { value: u16, len: usize } {
    var len: usize = 0;
    while (len < value.len and len < max_digits and std.ascii.isDigit(value[len])) : (len += 1) {}
    if (len == 0 or (len < value.len and std.ascii.isDigit(value[len]))) return null;
    return .{ .value = std.fmt.parseInt(u16, value[0..len], 10) catch return null, .len = len };
}

fn parseCookieDay(value: []const u8) ?u8 {
    const parsed = leadingCookieDigits(value, 2) orelse return null;
    if (parsed.value < 1 or parsed.value > 31) return null;
    return @intCast(parsed.value);
}

fn parseCookieYear(value: []const u8) ?u16 {
    const parsed = leadingCookieDigits(value, 4) orelse return null;
    if (parsed.len < 2) return null;
    return parsed.value;
}

fn parseCookieMonth(value: []const u8) ?u8 {
    if (value.len < 3) return null;
    inline for (.{
        .{ "jan", 1 }, .{ "feb", 2 },  .{ "mar", 3 },  .{ "apr", 4 },
        .{ "may", 5 }, .{ "jun", 6 },  .{ "jul", 7 },  .{ "aug", 8 },
        .{ "sep", 9 }, .{ "oct", 10 }, .{ "nov", 11 }, .{ "dec", 12 },
    }) |entry| if (std.ascii.eqlIgnoreCase(value[0..3], entry[0])) return entry[1];
    return null;
}

fn parseCookieTime(value: []const u8) ?CookieTime {
    const first_colon = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    const second_colon_relative = std.mem.indexOfScalar(u8, value[first_colon + 1 ..], ':') orelse return null;
    const second_colon = first_colon + 1 + second_colon_relative;
    const hour = leadingCookieDigits(value[0..first_colon], 2) orelse return null;
    const minute = leadingCookieDigits(value[first_colon + 1 .. second_colon], 2) orelse return null;
    const second = leadingCookieDigits(value[second_colon + 1 ..], 2) orelse return null;
    if (hour.len != first_colon or minute.len != second_colon - first_colon - 1) return null;
    if (hour.value > 23 or minute.value > 59 or second.value > 59) return null;
    return .{ .hour = @intCast(hour.value), .minute = @intCast(minute.value), .second = @intCast(second.value) };
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isProviderOrigin(url: []const u8) !bool {
    const uri = try std.Uri.parse(url);
    if (uri.user != null or uri.password != null) return false;
    return common.sameOrigin(site, url);
}

fn validateProviderUrl(url: []const u8) !void {
    if (!(isProviderOrigin(url) catch false)) return error.InvalidDownloadUrl;
}

fn validateInitialDownloadUrl(url: []const u8) !void {
    try validateProviderUrl(url);
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "/download/";
    if (!std.mem.startsWith(u8, path, prefix) or
        !isSafeDownloadPathSegment(path[prefix.len..]))
    {
        return error.InvalidDownloadUrl;
    }
}

fn isSafeDownloadPathSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 2048 or
        std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
    {
        return false;
    }

    var index: usize = 0;
    while (index < segment.len) {
        const byte = segment[index];
        if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\' or byte == '?' or byte == '#')
            return false;
        if (byte != '%') {
            index += 1;
            continue;
        }
        if (segment.len - index < 3) return false;
        const high = downloadHexNibble(segment[index + 1]) orelse return false;
        const low = downloadHexNibble(segment[index + 2]) orelse return false;
        const decoded = high * 16 + low;
        if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
            decoded == '?' or decoded == '#' or decoded == '%' or decoded == '.')
        {
            return false;
        }
        index += 3;
    }
    return true;
}

fn downloadHexNibble(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

fn validateListingUrl(url: []const u8) !void {
    try validateTokenRoute(url, "/altyazib-");
}

fn validateEpisodeUrl(url: []const u8) !void {
    try validateTokenRoute(url, "/indir_bolum-");
}

fn validateTokenRoute(url: []const u8, prefix: []const u8) !void {
    try validateProviderUrl(url);
    if (url.len <= site.len or !std.mem.eql(u8, url[0..site.len], site) or url[site.len] != '/')
        return error.InvalidDownloadUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const suffix = ".html";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix))
        return error.InvalidDownloadUrl;
    const segment = path[prefix.len .. path.len - suffix.len];
    if (segment.len == 0 or segment.len > max_token_route_segment_bytes)
        return error.InvalidDownloadUrl;

    var id_end: usize = 0;
    while (id_end < segment.len and std.ascii.isDigit(segment[id_end])) : (id_end += 1) {}
    if (id_end == 0 or segment[0] == '0' or
        id_end + 1 >= segment.len or segment[id_end] != '-')
    {
        return error.InvalidDownloadUrl;
    }
    const slug = segment[id_end + 1 ..];
    if (slug[0] == '-' or slug[slug.len - 1] == '-') return error.InvalidDownloadUrl;
    for (slug) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidDownloadUrl;
    }
}

const DownloadDisposition = enum {
    success,
    redirect,
    rate_limited,
    challenge,
    access_blocked,
    unexpected_status,
};

fn downloadDisposition(response: RawResponse) DownloadDisposition {
    // A provider rate limit remains terminal even if its body is a challenge
    // page. Opening a browser cannot turn a quota response into success.
    if (response.status == .too_many_requests) return .rate_limited;
    if (cloudflare.isChallengeBody(response.body)) return .challenge;
    if (response.status == .forbidden) return .access_blocked;
    if (common.isRedirectStatus(response.status)) return .redirect;
    return if (response.status == .ok) .success else .unexpected_status;
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

fn fetchProviderHtml(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    referer: ?[]const u8,
) !common.HttpResponse {
    return fetchProviderHtmlWith(common.fetchBytes, cloudflare.ensureDomainSession, client, allocator, url, referer);
}

fn fetchProviderHtmlWith(
    comptime fetch: anytype,
    comptime ensure_session: anytype,
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    referer: ?[]const u8,
) !common.HttpResponse {
    try validateProviderUrl(url);
    if (referer) |value| try validateProviderUrl(value);

    var browser_session: ?cloudflare.Session = null;
    defer if (browser_session) |*session| session.deinit(allocator);
    var refreshed_rejected_session = false;

    while (true) {
        var cookie_header: ?[]u8 = null;
        defer if (cookie_header) |value| allocator.free(value);
        var headers: [3]std.http.Header = undefined;
        var headers_len: usize = 0;
        if (browser_session) |session| {
            // common.fetchBytes may follow same-origin redirects while keeping
            // this static header. Attach only cookies valid for every path on
            // the origin; manual-hop downloads recalculate cookies per URL.
            cookie_header = try session.cookieHeaderForUrl(allocator, browser_cookie_scope_url);
            if (cookie_header) |value| {
                headers[headers_len] = .{ .name = "cookie", .value = value };
                headers_len += 1;
            }
            headers[headers_len] = .{ .name = "user-agent", .value = session.user_agent };
            headers_len += 1;
        }
        if (referer) |value| {
            headers[headers_len] = .{ .name = "referer", .value = value };
            headers_len += 1;
        }

        const response = try fetch(client, allocator, url, common.FetchOptions{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = headers[0..headers_len],
            .allow_non_ok = true,
            .retry_on_429 = false,
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });

        const disposition = downloadDisposition(.{
            .status = response.status,
            .body = response.body,
            .cookie_headers = null,
            .location = null,
        });
        switch (disposition) {
            .success => return response,
            .rate_limited => {
                allocator.free(response.body);
                return error.RateLimited;
            },
            .challenge => {
                allocator.free(response.body);
                if (browser_session) |session| {
                    if (refreshed_rejected_session) return error.CloudflareChallenge;
                    const refreshed = try ensure_session(allocator, .{
                        .domain = "animekalesi.com",
                        .challenge_url = url,
                        .force_refresh = true,
                        .rejected_generation = session.generation,
                    });
                    if (browser_session) |*owned| owned.deinit(allocator);
                    browser_session = refreshed;
                    refreshed_rejected_session = true;
                } else {
                    browser_session = try ensure_session(allocator, .{
                        .domain = "animekalesi.com",
                        .challenge_url = url,
                    });
                }
            },
            .access_blocked => {
                allocator.free(response.body);
                return error.ProviderAccessBlocked;
            },
            .redirect, .unexpected_status => {
                allocator.free(response.body);
                return error.UnexpectedHttpStatus;
            },
        }
    }
}

fn fetchRawProviderStep(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    asp_cookies: *AspSessionCookies,
    referer: ?[]const u8,
    browser_session: *?cloudflare.Session,
    refreshed_rejected_session: *bool,
) !RawResponse {
    return fetchRawProviderStepWith(
        fetchRaw,
        cloudflare.ensureDomainSession,
        client,
        allocator,
        url,
        asp_cookies,
        referer,
        browser_session,
        refreshed_rejected_session,
    );
}

fn fetchRawProviderStepWith(
    comptime fetch: anytype,
    comptime ensure_session: anytype,
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    asp_cookies: *AspSessionCookies,
    referer: ?[]const u8,
    browser_session: *?cloudflare.Session,
    refreshed_rejected_session: *bool,
) !RawResponse {
    while (true) {
        var browser_cookie: ?[]u8 = null;
        defer if (browser_cookie) |value| allocator.free(value);
        if (browser_session.*) |session| browser_cookie = try session.cookieHeaderForUrl(allocator, url);
        const asp_cookie = try asp_cookies.cookieHeaderForUrl(allocator, url, common.compatUnixTimestamp());
        defer if (asp_cookie) |value| allocator.free(value);
        const request_cookie = try mergeProviderCookies(allocator, browser_cookie, asp_cookie);
        defer if (request_cookie) |value| allocator.free(value);
        const request_user_agent = if (browser_session.*) |session| session.user_agent else common.default_user_agent;

        var response = try fetch(client, allocator, url, request_cookie, referer, request_user_agent);
        const response_cookie_time = common.compatUnixTimestamp();
        asp_cookies.updateFromResponseHeaders(allocator, url, response.cookie_headers, response_cookie_time) catch |err| {
            response.deinit(allocator);
            return err;
        };
        switch (downloadDisposition(response)) {
            .success => return response,
            .rate_limited => {
                response.deinit(allocator);
                return error.RateLimited;
            },
            .challenge => {
                defer response.deinit(allocator);
                if (browser_session.*) |session| {
                    if (refreshed_rejected_session.*) return error.CloudflareChallenge;
                    const refreshed = try ensure_session(allocator, .{
                        .domain = "animekalesi.com",
                        .challenge_url = url,
                        .force_refresh = true,
                        .rejected_generation = session.generation,
                    });
                    try installBrowserSession(allocator, asp_cookies, browser_session, refreshed);
                    refreshed_rejected_session.* = true;
                } else {
                    const acquired = try ensure_session(allocator, .{
                        .domain = "animekalesi.com",
                        .challenge_url = url,
                    });
                    try installBrowserSession(allocator, asp_cookies, browser_session, acquired);
                }
                // The raw challenge response is newer than the browser
                // snapshot. Reapply it after importing browser cookies so a
                // fresh ASP session value (or deletion tombstone) wins over a
                // stale value captured by the browser.
                try asp_cookies.updateFromResponseHeaders(
                    allocator,
                    url,
                    response.cookie_headers,
                    response_cookie_time,
                );
            },
            .access_blocked => {
                response.deinit(allocator);
                return error.ProviderAccessBlocked;
            },
            .redirect, .unexpected_status => {
                response.deinit(allocator);
                return error.UnexpectedHttpStatus;
            },
        }
    }
}

fn mergeProviderCookies(allocator: Allocator, browser_cookie: ?[]const u8, asp_cookie: ?[]const u8) !?[]u8 {
    if (browser_cookie == null and asp_cookie == null) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (browser_cookie) |header| {
        var pairs = std.mem.splitScalar(u8, header, ';');
        while (pairs.next()) |raw_pair| {
            const pair = std.mem.trim(u8, raw_pair, " \t");
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const name = std.mem.trim(u8, pair[0..eq], " \t");
            if (isAspSessionCookieName(name)) continue;
            if (out.items.len > 0) try out.appendSlice(allocator, "; ");
            try out.appendSlice(allocator, pair);
        }
    }
    if (asp_cookie) |header| {
        const asp = std.mem.trim(u8, header, " \t\r\n;");
        const asp_eq = std.mem.indexOfScalar(u8, asp, '=') orelse return error.InvalidSessionPayload;
        const asp_name = std.mem.trim(u8, asp[0..asp_eq], " \t");
        if (!isAspSessionCookieName(asp_name)) return error.InvalidSessionPayload;
        if (out.items.len > 0) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, asp);
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn isAspSessionCookieName(name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, "ASPSESSIONID");
}

fn fetchPublicDownload(
    client: *std.http.Client,
    allocator: Allocator,
    start_url: []const u8,
    asp_cookies: *AspSessionCookies,
    initial_referer: []const u8,
    browser_session: *?cloudflare.Session,
    refreshed_rejected_session: *bool,
) !common.HttpResponse {
    return fetchPublicDownloadWithState(
        fetchRaw,
        cloudflare.ensureDomainSession,
        common.fetchBytes,
        client,
        allocator,
        start_url,
        asp_cookies,
        initial_referer,
        6,
        browser_session,
        refreshed_rejected_session,
    );
}

fn fetchPublicDownloadWith(
    comptime fetch: anytype,
    comptime ensure_session: anytype,
    comptime fetch_external: anytype,
    client: *std.http.Client,
    allocator: Allocator,
    start_url: []const u8,
    initial_cookie: ?[]const u8,
    initial_referer: []const u8,
    max_redirects: usize,
) !common.HttpResponse {
    var asp_cookies: AspSessionCookies = .empty;
    defer asp_cookies.deinit(allocator);
    if (initial_cookie) |cookie| {
        const header = try std.fmt.allocPrint(allocator, "Set-Cookie: {s}; Path=/; Secure", .{cookie});
        defer allocator.free(header);
        try asp_cookies.updateFromResponseHeaders(allocator, start_url, header, common.compatUnixTimestamp());
    }
    var browser_session: ?cloudflare.Session = null;
    defer if (browser_session) |*session| session.deinit(allocator);
    var refreshed_rejected_session = false;
    return fetchPublicDownloadWithState(
        fetch,
        ensure_session,
        fetch_external,
        client,
        allocator,
        start_url,
        &asp_cookies,
        initial_referer,
        max_redirects,
        &browser_session,
        &refreshed_rejected_session,
    );
}

fn fetchPublicDownloadWithState(
    comptime fetch: anytype,
    comptime ensure_session: anytype,
    comptime fetch_external: anytype,
    client: *std.http.Client,
    allocator: Allocator,
    start_url: []const u8,
    asp_cookies: *AspSessionCookies,
    initial_referer: []const u8,
    max_redirects: usize,
    browser_session: *?cloudflare.Session,
    refreshed_rejected_session: *bool,
) !common.HttpResponse {
    // Every URL carrying provider session state is constrained to the exact
    // HTTPS provider origin. This also makes an absolute cross-origin href or
    // redirect fail closed before any ASP or browser cookie can be attached.
    try validateProviderUrl(start_url);
    try validateProviderUrl(initial_referer);

    var current_url: []const u8 = try allocator.dupe(u8, start_url);
    defer allocator.free(current_url);
    var referer: []const u8 = try allocator.dupe(u8, initial_referer);
    defer allocator.free(referer);

    var redirects: usize = 0;

    while (true) {
        var browser_cookie: ?[]u8 = null;
        defer if (browser_cookie) |value| allocator.free(value);

        if (browser_session.*) |session| browser_cookie = try session.cookieHeaderForUrl(allocator, current_url);
        const asp_cookie = try asp_cookies.cookieHeaderForUrl(allocator, current_url, common.compatUnixTimestamp());
        defer if (asp_cookie) |value| allocator.free(value);
        const owned_request_cookie = try mergeProviderCookies(allocator, browser_cookie, asp_cookie);
        defer if (owned_request_cookie) |value| allocator.free(value);
        const request_cookie: ?[]const u8 = owned_request_cookie;
        const request_user_agent = if (browser_session.*) |session| session.user_agent else common.default_user_agent;

        var response = try fetch(client, allocator, current_url, request_cookie, referer, request_user_agent);
        var response_owned = true;
        errdefer if (response_owned) response.deinit(allocator);
        const response_cookie_time = common.compatUnixTimestamp();
        try asp_cookies.updateFromResponseHeaders(allocator, current_url, response.cookie_headers, response_cookie_time);

        switch (downloadDisposition(response)) {
            .rate_limited => {
                response.deinit(allocator);
                response_owned = false;
                return error.RateLimited;
            },
            .challenge => {
                if (browser_session.*) |session| {
                    if (refreshed_rejected_session.*) return error.CloudflareChallenge;
                    const refreshed = try ensure_session(allocator, .{
                        .domain = "animekalesi.com",
                        .challenge_url = current_url,
                        .force_refresh = true,
                        .rejected_generation = session.generation,
                    });
                    try installBrowserSession(allocator, asp_cookies, browser_session, refreshed);
                    refreshed_rejected_session.* = true;
                } else {
                    const acquired = try ensure_session(allocator, .{
                        .domain = "animekalesi.com",
                        .challenge_url = current_url,
                    });
                    try installBrowserSession(allocator, asp_cookies, browser_session, acquired);
                }
                // The challenge response is the newest cookie source. Browser
                // acquisition can return an older ASP snapshot, so reapply
                // both value updates and deletion tombstones before retrying.
                try asp_cookies.updateFromResponseHeaders(
                    allocator,
                    current_url,
                    response.cookie_headers,
                    response_cookie_time,
                );
                response.deinit(allocator);
                response_owned = false;
                continue;
            },
            .access_blocked => {
                response.deinit(allocator);
                response_owned = false;
                return error.ProviderAccessBlocked;
            },
            .redirect => {
                if (redirects >= max_redirects) {
                    response.deinit(allocator);
                    response_owned = false;
                    return error.TooManyRedirects;
                }
                const location = response.location orelse {
                    response.deinit(allocator);
                    response_owned = false;
                    return error.MissingField;
                };
                const next_url = try common.resolveUrl(allocator, current_url, location);
                var next_url_owned = true;
                defer if (next_url_owned) allocator.free(next_url);
                // The provider's final hop is currently a public CDN
                // subdomain. Hand cross-origin redirects to the DNS-pinned
                // transport without any ASP/browser cookies or referer.
                if (!(try isProviderOrigin(next_url))) {
                    try common.validateFetchTarget(next_url, .{
                        .require_public_origin = true,
                        .require_https = true,
                    });
                    response.deinit(allocator);
                    response_owned = false;
                    const external = try fetch_external(client, allocator, next_url, .{
                        .accept = "application/zip,application/octet-stream,*/*",
                        .cache = false,
                        .max_attempts = 2,
                        .retry_on_429 = false,
                        .require_public_origin = true,
                        .require_https = true,
                    });
                    validateDownloadBody(external.body) catch |err| {
                        allocator.free(external.body);
                        return err;
                    };
                    return external;
                }
                response.deinit(allocator);
                response_owned = false;

                allocator.free(referer);
                referer = current_url;
                current_url = next_url;
                next_url_owned = false;
                redirects += 1;
                continue;
            },
            .unexpected_status => {
                response.deinit(allocator);
                response_owned = false;
                return error.UnexpectedHttpStatus;
            },
            .success => {},
        }

        validateDownloadBody(response.body) catch |err| {
            response.deinit(allocator);
            response_owned = false;
            return err;
        };

        const body = response.body;
        if (response.cookie_headers) |value| allocator.free(value);
        if (response.location) |value| allocator.free(value);
        return .{ .status = response.status, .body = body };
    }
}

fn readBoundedBody(allocator: Allocator, reader: *std.Io.Reader, max_bytes: usize) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var received: usize = 0;
    while (true) {
        if (received == max_bytes) {
            _ = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            return error.ResponseTooLarge;
        }
        const count = reader.stream(&writer.writer, .limited(max_bytes - received)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return common.normalizeAllocatingWriterError(err),
        };
        received += count;
    }
    var body = writer.toArrayList();
    errdefer body.deinit(allocator);
    return body.toOwnedSlice(allocator);
}

fn makeFixtureBrowserSession(
    allocator: Allocator,
    clearance_source: []const u8,
    agent_source: []const u8,
    generation: u64,
    cookie_path: []const u8,
) !cloudflare.Session {
    return makeFixtureBrowserSessionWithAsp(
        allocator,
        clearance_source,
        agent_source,
        generation,
        cookie_path,
        null,
    );
}

const FixtureAspCookie = struct {
    name: []const u8,
    value: []const u8,
    path: []const u8,
};

fn makeFixtureBrowserSessionWithAsp(
    allocator: Allocator,
    clearance_source: []const u8,
    agent_source: []const u8,
    generation: u64,
    cookie_path: []const u8,
    asp_cookie: ?FixtureAspCookie,
) !cloudflare.Session {
    const cookies = try allocator.alloc(
        cloudflare.Cookie,
        1 + @as(usize, @intFromBool(asp_cookie != null)),
    );
    errdefer allocator.free(cookies);
    const name = try allocator.dupe(u8, "cf_clearance");
    errdefer allocator.free(name);
    const value = try allocator.dupe(u8, clearance_source);
    errdefer allocator.free(value);
    const domain = try allocator.dupe(u8, "animekalesi.com");
    errdefer allocator.free(domain);
    const path = try allocator.dupe(u8, cookie_path);
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
    if (asp_cookie) |asp| {
        const asp_name = try allocator.dupe(u8, asp.name);
        errdefer allocator.free(asp_name);
        const asp_value = try allocator.dupe(u8, asp.value);
        errdefer allocator.free(asp_value);
        const asp_domain = try allocator.dupe(u8, "animekalesi.com");
        errdefer allocator.free(asp_domain);
        const asp_path = try allocator.dupe(u8, asp.path);
        errdefer allocator.free(asp_path);
        cookies[1] = .{
            .name = asp_name,
            .value = asp_value,
            .domain = asp_domain,
            .path = asp_path,
            .secure = true,
            .host_only = true,
            .expires_unix_seconds = null,
        };
    }

    const clearance = try allocator.dupe(u8, clearance_source);
    errdefer allocator.free(clearance);
    const user_agent = try allocator.dupe(u8, agent_source);
    return .{
        .cookies = cookies,
        .cf_clearance = clearance,
        .user_agent = user_agent,
        .acquired_at_unix = 0,
        .generation = generation,
    };
}

test "raw response body limit accepts exact bounds and rejects excess" {
    const a = std.testing.allocator;
    var exact: std.Io.Reader = .fixed("1234");
    const body = try readBoundedBody(a, &exact, 4);
    defer a.free(body);
    try std.testing.expectEqualStrings("1234", body);
    var oversized: std.Io.Reader = .fixed("12345");
    try std.testing.expectError(error.ResponseTooLarge, readBoundedBody(a, &oversized, 4));
    var empty: std.Io.Reader = .fixed("");
    const empty_body = try readBoundedBody(a, &empty, 0);
    defer a.free(empty_body);
    try std.testing.expectEqual(@as(usize, 0), empty_body.len);
    var zero_limit: std.Io.Reader = .fixed("1");
    try std.testing.expectError(error.ResponseTooLarge, readBoundedBody(a, &zero_limit, 0));
}

test "animekalesi raw request rejects an expired deadline before I/O" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const now_ms = common.compatMilliTimestamp();
    try std.testing.expectError(
        error.Timeout,
        fetchRawUntil(
            &client,
            std.testing.allocator,
            site ++ "/",
            null,
            null,
            null,
            now_ms,
        ),
    );
}

test "animekalesi response cookie extraction preserves every ASP attribute" {
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Set-Cookie: ordinary=ignored; Path=/\r\n" ++
        "Set-Cookie: ASPSESSIONIDONE=first; Path=/one; Secure\r\n" ++
        "set-cookie: ASPSESSIONIDTWO=second; Domain=animekalesi.com; Max-Age=10\r\n";
    const selected = (try extractSessionCookieHeaders(std.testing.allocator, headers)).?;
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings(
        "Set-Cookie: ASPSESSIONIDONE=first; Path=/one; Secure\r\n" ++
            "set-cookie: ASPSESSIONIDTWO=second; Domain=animekalesi.com; Max-Age=10",
        selected,
    );
}

test "animekalesi ASP session cookies preserve scope expiry and deletion" {
    const allocator = std.testing.allocator;
    const now: i64 = 1_623_233_895;
    var jar: AspSessionCookies = .empty;
    defer jar.deinit(allocator);
    try jar.updateFromResponseHeaders(
        allocator,
        site ++ "/download/start.asp",
        "Set-Cookie: ASPSESSIONIDFIXTURE=root; Domain=.animekalesi.com; Path=/; Secure\r\n" ++
            "Set-Cookie: ASPSESSIONIDFIXTURE=scoped; Path=/download; Secure\r\n" ++
            "Set-Cookie: ASPSESSIONIDDEFAULT=default; Secure\r\n" ++
            "Set-Cookie: ASPSESSIONIDFOREIGN=bad; Domain=cdn.example.com; Path=/; Secure\r\n" ++
            "Set-Cookie: ASPSESSIONIDEXPIRED=old; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Path=/; Secure\r\n" ++
            "Set-Cookie: ordinary=ignored; Path=/",
        now,
    );

    const download = (try jar.cookieHeaderForUrl(allocator, site ++ "/download/archive.zip", now)).?;
    defer allocator.free(download);
    try std.testing.expectEqualStrings(
        "ASPSESSIONIDFIXTURE=scoped; ASPSESSIONIDDEFAULT=default; ASPSESSIONIDFIXTURE=root",
        download,
    );
    const root = (try jar.cookieHeaderForUrl(allocator, site ++ "/other", now)).?;
    defer allocator.free(root);
    try std.testing.expectEqualStrings("ASPSESSIONIDFIXTURE=root", root);
    const subdomain = (try jar.cookieHeaderForUrl(allocator, "https://cdn.animekalesi.com/download/archive.zip", now)).?;
    defer allocator.free(subdomain);
    try std.testing.expectEqualStrings("ASPSESSIONIDFIXTURE=root", subdomain);
    try std.testing.expect((try jar.cookieHeaderForUrl(allocator, "http://animekalesi.com/download/archive.zip", now)) == null);
    const boundary = (try jar.cookieHeaderForUrl(allocator, site ++ "/downloader", now)).?;
    defer allocator.free(boundary);
    try std.testing.expectEqualStrings("ASPSESSIONIDFIXTURE=root", boundary);

    try jar.updateFromResponseHeaders(
        allocator,
        site ++ "/download/start.asp",
        "Set-Cookie: ASPSESSIONIDFIXTURE=deleted; Path=/download; Max-Age=0; Secure",
        now,
    );
    const after_delete = (try jar.cookieHeaderForUrl(allocator, site ++ "/download/archive.zip", now)).?;
    defer allocator.free(after_delete);
    try std.testing.expectEqualStrings("ASPSESSIONIDDEFAULT=default; ASPSESSIONIDFIXTURE=root", after_delete);

    try jar.updateFromResponseHeaders(
        allocator,
        site ++ "/index.asp",
        "Set-Cookie: ASPSESSIONIDTTL=short; Path=/; Max-Age=10; Secure",
        now,
    );
    const before_expiry = (try jar.cookieHeaderForUrl(allocator, site ++ "/other", now + 9)).?;
    defer allocator.free(before_expiry);
    try std.testing.expectEqualStrings("ASPSESSIONIDFIXTURE=root; ASPSESSIONIDTTL=short", before_expiry);
    const after_expiry = (try jar.cookieHeaderForUrl(allocator, site ++ "/other", now + 10)).?;
    defer allocator.free(after_expiry);
    try std.testing.expectEqualStrings("ASPSESSIONIDFIXTURE=root", after_expiry);

    try std.testing.expectEqual(@as(?i64, 1_623_233_894), parseCookieDate("Wed, 09 Jun 2021 10:18:14 GMT"));
    try std.testing.expectEqual(@as(?i64, 1_623_233_894), parseCookieDate("Wednesday, 09-Jun-21 10:18:14 GMT"));
    try std.testing.expectEqual(@as(?i64, 1_623_233_894), parseCookieDate("Wed, 09/Jun/2021 10:18:14 GMT"));
    try std.testing.expectEqual(@as(?i64, 1_623_233_894), parseCookieDate("Wed, 09th Jun 2021 10:18:14GMT"));

    const target = parseCookieRequestTarget(site ++ "/download/file.zip").?;
    const deleted = parseAspSessionSetCookie(
        "ASPSESSIONIDDUP=value; Path=/; Max-Age=0; Max-Age=bogus",
        target,
        now,
    ).?;
    try std.testing.expectEqual(@as(?i64, now), deleted.expires_unix_seconds);
    const valid_expires = parseAspSessionSetCookie(
        "ASPSESSIONIDDUP=value; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Expires=not-a-date",
        target,
        now,
    ).?;
    try std.testing.expectEqual(@as(?i64, 1_623_233_894), valid_expires.expires_unix_seconds);
}

test "animekalesi treats cookie names as case sensitive identities" {
    const allocator = std.testing.allocator;
    var jar: AspSessionCookies = .empty;
    defer jar.deinit(allocator);
    try jar.updateFromResponseHeaders(
        allocator,
        site ++ "/",
        "Set-Cookie: ASPSESSIONIDCASE=upper; Path=/; Secure\r\n" ++
            "Set-Cookie: aspsessionidcase=lower; Path=/; Secure",
        100,
    );
    const header = (try jar.cookieHeaderForUrl(allocator, site ++ "/", 100)).?;
    defer allocator.free(header);
    try std.testing.expectEqualStrings(
        "ASPSESSIONIDCASE=upper; aspsessionidcase=lower",
        header,
    );
}

test "animekalesi imports browser ASP cookies without flattening their scope" {
    const now: i64 = 100;
    const cookies = [_]cloudflare.Cookie{
        .{
            .name = "ASPSESSIONIDBROWSER",
            .value = "scoped",
            .domain = "animekalesi.com",
            .path = "/download",
            .secure = true,
            .host_only = true,
            .expires_unix_seconds = 200,
        },
        .{
            .name = "ASPSESSIONIDFOREIGN",
            .value = "blocked",
            .domain = "cdn.example.com",
            .path = "/",
            .secure = true,
            .host_only = false,
            .expires_unix_seconds = null,
        },
    };
    var jar: AspSessionCookies = .empty;
    defer jar.deinit(std.testing.allocator);
    try jar.updateFromBrowserCookies(std.testing.allocator, &cookies, now);
    const selected = (try jar.cookieHeaderForUrl(std.testing.allocator, site ++ "/download/file.zip", now)).?;
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("ASPSESSIONIDBROWSER=scoped", selected);
    try std.testing.expect((try jar.cookieHeaderForUrl(std.testing.allocator, site ++ "/other", now)) == null);
    try std.testing.expect((try jar.cookieHeaderForUrl(std.testing.allocator, site ++ "/download/file.zip", 200)) == null);
}

test "animekalesi final downloads require the exact HTTPS provider origin" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var browser_session: ?cloudflare.Session = null;
    defer if (browser_session) |*session| session.deinit(std.testing.allocator);
    var refreshed_rejected_session = false;
    var asp_cookies: AspSessionCookies = .empty;
    defer asp_cookies.deinit(std.testing.allocator);
    for ([_][]const u8{
        "http://127.0.0.1/archive.zip",
        "https://user@example.com/archive.zip",
        "https://animekalesi.com@example.com/archive.zip",
        "https://cdn.animekalesi.com/archive.zip",
        "https://cdn.example.com/archive.zip",
        "http://animekalesi.com/archive.zip",
    }) |url| {
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            fetchPublicDownload(
                &client,
                std.testing.allocator,
                url,
                &asp_cookies,
                site ++ "/episode",
                &browser_session,
                &refreshed_rejected_session,
            ),
        );
    }
}

test "animekalesi final response classification keeps rate limits terminal" {
    const challenge = "<html><script>window._cf_chl_opt = {};</script></html>";
    const Case = struct {
        status: std.http.Status,
        body: []const u8,
        expected: DownloadDisposition,
    };
    for ([_]Case{
        .{ .status = .ok, .body = "PK fixture", .expected = .success },
        .{ .status = .ok, .body = challenge, .expected = .challenge },
        .{ .status = .forbidden, .body = "", .expected = .access_blocked },
        .{ .status = .service_unavailable, .body = "", .expected = .unexpected_status },
        .{ .status = .too_many_requests, .body = challenge, .expected = .rate_limited },
        .{ .status = .found, .body = "", .expected = .redirect },
        .{ .status = .internal_server_error, .body = "", .expected = .unexpected_status },
    }) |case| {
        try std.testing.expectEqual(case.expected, downloadDisposition(.{
            .status = case.status,
            .body = @constCast(case.body),
            .cookie_headers = null,
            .location = null,
        }));
    }
}

test "animekalesi accepts ZIP signatures and rejects non-archives" {
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

test "animekalesi merges browser cookies with the latest ASP session" {
    const merged = (try mergeProviderCookies(
        std.testing.allocator,
        "cf_clearance=fixture; ASPSESSIONIDOLD=stale; theme=dark",
        "ASPSESSIONIDNEW=fresh",
    )).?;
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqualStrings(
        "cf_clearance=fixture; theme=dark; ASPSESSIONIDNEW=fresh",
        merged,
    );

    const filtered = (try mergeProviderCookies(
        std.testing.allocator,
        "cf_clearance=fixture; ASPSESSIONIDOLD=stale; theme=dark",
        null,
    )).?;
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqualStrings("cf_clearance=fixture; theme=dark", filtered);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try mergeProviderCookies(std.testing.allocator, "ASPSESSIONIDOLD=stale", null),
    );

    try std.testing.expectEqual(@as(?[]u8, null), try mergeProviderCookies(std.testing.allocator, null, null));
    try std.testing.expectError(
        error.InvalidSessionPayload,
        mergeProviderCookies(std.testing.allocator, "cf_clearance=fixture", "other=value"),
    );
}

test "animekalesi HTML transport excludes path-scoped browser cookies" {
    var scoped = try makeFixtureBrowserSession(
        std.testing.allocator,
        "scoped-clearance",
        "fixture-browser",
        1,
        "/tum-anime-serileri.html",
    );
    defer scoped.deinit(std.testing.allocator);
    const scoped_header = try scoped.cookieHeaderForUrl(std.testing.allocator, browser_cookie_scope_url);
    defer if (scoped_header) |value| std.testing.allocator.free(value);
    try std.testing.expect(scoped_header == null);

    var root = try makeFixtureBrowserSession(
        std.testing.allocator,
        "root-clearance",
        "fixture-browser",
        2,
        "/",
    );
    defer root.deinit(std.testing.allocator);
    const root_header = (try root.cookieHeaderForUrl(std.testing.allocator, browser_cookie_scope_url)).?;
    defer std.testing.allocator.free(root_header);
    try std.testing.expectEqualStrings("cf_clearance=root-clearance", root_header);
}

test "animekalesi HTML fetch recovers one browser challenge" {
    const Mock = struct {
        var fetch_calls: usize = 0;
        var session_calls: usize = 0;

        fn fetch(
            _: *std.http.Client,
            allocator: Allocator,
            url: []const u8,
            options: common.FetchOptions,
        ) !common.HttpResponse {
            fetch_calls += 1;
            try std.testing.expectEqualStrings(series_index_url, url);
            try std.testing.expect(options.allow_non_ok);
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);
            if (fetch_calls == 1) {
                try std.testing.expectEqual(@as(usize, 0), options.extra_headers.len);
                return .{
                    .status = .ok,
                    .body = try allocator.dupe(u8, "<script>window._cf_chl_opt = {};</script>"),
                };
            }
            if (fetch_calls == 2) {
                var saw_cookie = false;
                var saw_user_agent = false;
                for (options.extra_headers) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
                        saw_cookie = true;
                        try std.testing.expectEqualStrings("cf_clearance=clearance", header.value);
                    }
                    if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
                        saw_user_agent = true;
                        try std.testing.expectEqualStrings("fixture-browser", header.value);
                    }
                }
                try std.testing.expect(saw_cookie);
                try std.testing.expect(saw_user_agent);
                return .{ .status = .ok, .body = try allocator.dupe(u8, "<html>series</html>") };
            }
            return error.TooManyMockRequests;
        }

        fn ensureSession(allocator: Allocator, options: cloudflare.EnsureDomainOptions) !cloudflare.Session {
            session_calls += 1;
            try std.testing.expectEqual(@as(usize, 1), session_calls);
            try std.testing.expectEqualStrings("animekalesi.com", options.domain);
            try std.testing.expectEqualStrings(series_index_url, options.challenge_url.?);
            return makeFixtureBrowserSession(allocator, "clearance", "fixture-browser", 9, "/");
        }
    };

    Mock.fetch_calls = 0;
    Mock.session_calls = 0;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const response = try fetchProviderHtmlWith(
        Mock.fetch,
        Mock.ensureSession,
        &client,
        std.testing.allocator,
        series_index_url,
        null,
    );
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("<html>series</html>", response.body);
    try std.testing.expectEqual(@as(usize, 2), Mock.fetch_calls);
    try std.testing.expectEqual(@as(usize, 1), Mock.session_calls);
}

test "animekalesi preflight challenge recovery merges and rotates session cookies" {
    const Mock = struct {
        var fetch_calls: usize = 0;
        var session_calls: usize = 0;

        fn fetch(
            _: *std.http.Client,
            allocator: Allocator,
            url: []const u8,
            cookie: ?[]const u8,
            referer: ?[]const u8,
            user_agent: ?[]const u8,
        ) !RawResponse {
            fetch_calls += 1;
            try std.testing.expectEqualStrings(site ++ "/episode", url);
            try std.testing.expectEqualStrings(site ++ "/listing", referer.?);
            if (fetch_calls == 1) {
                try std.testing.expectEqualStrings("ASPSESSIONIDFIXTURE=one", cookie.?);
                try std.testing.expectEqualStrings(common.default_user_agent, user_agent.?);
                return .{
                    .status = .forbidden,
                    .body = try allocator.dupe(u8, "<html><script>window._cf_chl_opt = {};</script></html>"),
                    .cookie_headers = try allocator.dupe(u8, "Set-Cookie: ASPSESSIONIDFIXTURE=two; Path=/; Secure"),
                    .location = null,
                };
            }
            if (fetch_calls == 2) {
                try std.testing.expectEqualStrings(
                    "cf_clearance=clearance; ASPSESSIONIDFIXTURE=two",
                    cookie.?,
                );
                try std.testing.expectEqualStrings("fixture-browser", user_agent.?);
                return .{
                    .status = .ok,
                    .body = try allocator.dupe(u8, "episode payload"),
                    .cookie_headers = try allocator.dupe(u8, "Set-Cookie: ASPSESSIONIDFIXTURE=three; Path=/; Secure"),
                    .location = null,
                };
            }
            return error.TooManyMockRequests;
        }

        fn ensureSession(allocator: Allocator, options: cloudflare.EnsureDomainOptions) !cloudflare.Session {
            session_calls += 1;
            try std.testing.expectEqual(@as(usize, 1), session_calls);
            try std.testing.expectEqualStrings("animekalesi.com", options.domain);
            try std.testing.expectEqualStrings(site ++ "/episode", options.challenge_url.?);
            try std.testing.expect(!options.force_refresh);
            return makeFixtureBrowserSessionWithAsp(
                allocator,
                "clearance",
                "fixture-browser",
                7,
                "/",
                .{
                    .name = "ASPSESSIONIDFIXTURE",
                    .value = "browser-stale",
                    .path = "/",
                },
            );
        }
    };

    Mock.fetch_calls = 0;
    Mock.session_calls = 0;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var asp_cookies: AspSessionCookies = .empty;
    defer asp_cookies.deinit(std.testing.allocator);
    try asp_cookies.updateFromResponseHeaders(
        std.testing.allocator,
        site ++ "/episode",
        "Set-Cookie: ASPSESSIONIDFIXTURE=one; Path=/; Secure",
        common.compatUnixTimestamp(),
    );
    var browser_session: ?cloudflare.Session = null;
    defer if (browser_session) |*session| session.deinit(std.testing.allocator);
    var refreshed_rejected_session = false;

    var response = try fetchRawProviderStepWith(
        Mock.fetch,
        Mock.ensureSession,
        &client,
        std.testing.allocator,
        site ++ "/episode",
        &asp_cookies,
        site ++ "/listing",
        &browser_session,
        &refreshed_rejected_session,
    );
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("episode payload", response.body);
    const final_cookie = (try asp_cookies.cookieHeaderForUrl(
        std.testing.allocator,
        site ++ "/episode",
        common.compatUnixTimestamp(),
    )).?;
    defer std.testing.allocator.free(final_cookie);
    try std.testing.expectEqualStrings("ASPSESSIONIDFIXTURE=three", final_cookie);
    try std.testing.expect(browser_session != null);
    try std.testing.expect(!refreshed_rejected_session);
    try std.testing.expectEqual(@as(usize, 2), Mock.fetch_calls);
    try std.testing.expectEqual(@as(usize, 1), Mock.session_calls);
}

test "animekalesi challenge tombstone overrides stale browser ASP cookie" {
    const Mock = struct {
        var fetch_calls: usize = 0;

        fn fetch(
            _: *std.http.Client,
            allocator: Allocator,
            _: []const u8,
            cookie: ?[]const u8,
            _: ?[]const u8,
            _: ?[]const u8,
        ) !RawResponse {
            fetch_calls += 1;
            if (fetch_calls == 1) {
                try std.testing.expectEqualStrings("ASPSESSIONIDFIXTURE=one", cookie.?);
                return .{
                    .status = .forbidden,
                    .body = try allocator.dupe(u8, "<script>window._cf_chl_opt = {};</script>"),
                    .cookie_headers = try allocator.dupe(
                        u8,
                        "Set-Cookie: ASPSESSIONIDFIXTURE=deleted; Path=/; Max-Age=0; Secure",
                    ),
                    .location = null,
                };
            }
            if (fetch_calls == 2) {
                try std.testing.expectEqualStrings("cf_clearance=clearance", cookie.?);
                return .{
                    .status = .ok,
                    .body = try allocator.dupe(u8, "episode payload"),
                    .cookie_headers = null,
                    .location = null,
                };
            }
            return error.TooManyMockRequests;
        }

        fn ensureSession(allocator: Allocator, _: cloudflare.EnsureDomainOptions) !cloudflare.Session {
            return makeFixtureBrowserSessionWithAsp(
                allocator,
                "clearance",
                "fixture-browser",
                8,
                "/",
                .{
                    .name = "ASPSESSIONIDFIXTURE",
                    .value = "browser-stale",
                    .path = "/",
                },
            );
        }
    };

    Mock.fetch_calls = 0;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var asp_cookies: AspSessionCookies = .empty;
    defer asp_cookies.deinit(std.testing.allocator);
    try asp_cookies.updateFromResponseHeaders(
        std.testing.allocator,
        site ++ "/episode",
        "Set-Cookie: ASPSESSIONIDFIXTURE=one; Path=/; Secure",
        common.compatUnixTimestamp(),
    );
    var browser_session: ?cloudflare.Session = null;
    defer if (browser_session) |*session| session.deinit(std.testing.allocator);
    var refreshed_rejected_session = false;

    var response = try fetchRawProviderStepWith(
        Mock.fetch,
        Mock.ensureSession,
        &client,
        std.testing.allocator,
        site ++ "/episode",
        &asp_cookies,
        null,
        &browser_session,
        &refreshed_rejected_session,
    );
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("episode payload", response.body);
    try std.testing.expect((try asp_cookies.cookieHeaderForUrl(
        std.testing.allocator,
        site ++ "/episode",
        common.compatUnixTimestamp(),
    )) == null);
    try std.testing.expectEqual(@as(usize, 2), Mock.fetch_calls);
}

test "animekalesi challenge recovery refreshes one rejected browser session" {
    const Mock = struct {
        var fetch_calls: usize = 0;
        var session_calls: usize = 0;

        fn fetch(
            _: *std.http.Client,
            allocator: Allocator,
            url: []const u8,
            cookie: ?[]const u8,
            referer: ?[]const u8,
            user_agent: ?[]const u8,
        ) !RawResponse {
            fetch_calls += 1;
            try std.testing.expectEqualStrings(site ++ "/download/archive.zip", url);
            try std.testing.expectEqualStrings(site ++ "/episode", referer.?);
            switch (fetch_calls) {
                1 => {
                    try std.testing.expectEqualStrings("ASPSESSIONID=fixture", cookie.?);
                    try std.testing.expectEqualStrings(common.default_user_agent, user_agent.?);
                    return .{
                        .status = .forbidden,
                        .body = try allocator.dupe(u8, "<html><script>window._cf_chl_opt = {};</script></html>"),
                        .cookie_headers = try allocator.dupe(u8, "Set-Cookie: ASPSESSIONID=two; Path=/; Secure"),
                        .location = null,
                    };
                },
                2 => {
                    try std.testing.expectEqualStrings("cf_clearance=first-clearance; ASPSESSIONID=two", cookie.?);
                    try std.testing.expectEqualStrings("fixture-browser-1", user_agent.?);
                    return .{
                        .status = .ok,
                        .body = try allocator.dupe(u8, "<html><script>window._cf_chl_opt = {};</script></html>"),
                        .cookie_headers = try allocator.dupe(
                            u8,
                            "Set-Cookie: ASPSESSIONID=deleted; Path=/; Max-Age=0; Secure",
                        ),
                        .location = null,
                    };
                },
                3 => {
                    try std.testing.expectEqualStrings("cf_clearance=second-clearance", cookie.?);
                    try std.testing.expectEqualStrings("fixture-browser-2", user_agent.?);
                    return .{
                        .status = .ok,
                        .body = try allocator.dupe(u8, "PK\x03\x04fixture archive"),
                        .cookie_headers = null,
                        .location = null,
                    };
                },
                else => return error.TooManyMockRequests,
            }
        }

        fn ensureSession(allocator: Allocator, options: cloudflare.EnsureDomainOptions) !cloudflare.Session {
            session_calls += 1;
            try std.testing.expectEqualStrings("animekalesi.com", options.domain);
            try std.testing.expectEqualStrings(site ++ "/download/archive.zip", options.challenge_url.?);
            if (session_calls == 1) {
                try std.testing.expect(!options.force_refresh);
                try std.testing.expectEqual(@as(?u64, null), options.rejected_generation);
                return makeFixtureBrowserSessionWithAsp(
                    allocator,
                    "first-clearance",
                    "fixture-browser-1",
                    41,
                    "/download/",
                    .{
                        .name = "ASPSESSIONID",
                        .value = "first-browser-stale",
                        .path = "/",
                    },
                );
            }
            if (session_calls == 2) {
                try std.testing.expect(options.force_refresh);
                try std.testing.expectEqual(@as(?u64, 41), options.rejected_generation);
                return makeFixtureBrowserSessionWithAsp(
                    allocator,
                    "second-clearance",
                    "fixture-browser-2",
                    42,
                    "/download/",
                    .{
                        .name = "ASPSESSIONID",
                        .value = "second-browser-stale",
                        .path = "/",
                    },
                );
            }
            return error.TooManyMockSessions;
        }
    };

    Mock.fetch_calls = 0;
    Mock.session_calls = 0;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const response = try fetchPublicDownloadWith(
        Mock.fetch,
        Mock.ensureSession,
        common.fetchBytes,
        &client,
        std.testing.allocator,
        site ++ "/download/archive.zip",
        "ASPSESSIONID=fixture",
        site ++ "/episode",
        1,
    );
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("PK\x03\x04fixture archive", response.body);
    try std.testing.expectEqual(@as(usize, 3), Mock.fetch_calls);
    try std.testing.expectEqual(@as(usize, 2), Mock.session_calls);
}

test "animekalesi cross-origin download failure releases redirect ownership once" {
    const Mock = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, _: ?[]const u8, _: ?[]const u8, _: ?[]const u8) !RawResponse {
            const body = try allocator.dupe(u8, "");
            errdefer allocator.free(body);
            return .{
                .status = .found,
                .body = body,
                .cookie_headers = null,
                .location = try allocator.dupe(u8, "https://cdn.example.com/archive.zip"),
            };
        }

        fn ensureSession(_: Allocator, _: cloudflare.EnsureDomainOptions) !cloudflare.Session {
            return error.UnexpectedBrowserAcquisition;
        }

        fn fetchExternal(_: *std.http.Client, _: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            try std.testing.expectEqualStrings("https://cdn.example.com/archive.zip", url);
            try std.testing.expectEqual(@as(usize, 0), options.extra_headers.len);
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expect(!options.cache);
            return error.FixtureDownloadFailure;
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(error.FixtureDownloadFailure, fetchPublicDownloadWith(
        Mock.fetch,
        Mock.ensureSession,
        Mock.fetchExternal,
        &client,
        std.testing.allocator,
        site ++ "/download/archive.zip",
        "ASPSESSIONID=fixture",
        site ++ "/episode",
        1,
    ));
}

test "animekalesi rejects external HTTP redirect before the CDN fetch" {
    const Mock = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, _: ?[]const u8, _: ?[]const u8, _: ?[]const u8) !RawResponse {
            const body = try allocator.dupe(u8, "");
            errdefer allocator.free(body);
            const location = try allocator.dupe(u8, "http://cdn.example.com/archive.zip");
            errdefer allocator.free(location);
            return .{
                .status = .found,
                .body = body,
                .cookie_headers = null,
                .location = location,
            };
        }

        fn ensureSession(_: Allocator, _: cloudflare.EnsureDomainOptions) !cloudflare.Session {
            return error.UnexpectedBrowserAcquisition;
        }

        fn fetchExternal(_: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return error.UnexpectedExternalFetch;
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(error.UnsafeHttpTarget, fetchPublicDownloadWith(
        Mock.fetch,
        Mock.ensureSession,
        Mock.fetchExternal,
        &client,
        std.testing.allocator,
        site ++ "/download/archive.zip",
        "ASPSESSIONID=fixture",
        site ++ "/episode",
        1,
    ));
}

test "animekalesi builds subtitle listing URL and token" {
    const allocator = std.testing.allocator;
    const url = try subtitleListingUrl(allocator, "https://animekalesi.com/bolumler-82-death-note.html");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://animekalesi.com/altyazib-82-death-note.html", url);

    const token = try makeDownloadToken(allocator, url, "https://animekalesi.com/indir_bolum-71-death-note-1-bolum.html");
    defer allocator.free(token);
    const parsed = parseDownloadToken(token).?;
    try std.testing.expectEqualStrings(url, parsed.listing_url);
    try std.testing.expectEqualStrings("https://animekalesi.com/indir_bolum-71-death-note-1-bolum.html", parsed.episode_url);

    const tampered = download_token_prefix ++
        "https://animekalesi.com/listing\r\nx-injected: yes|https://animekalesi.com/episode";
    try std.testing.expect(parseDownloadToken(tampered) == null);
}

test "animekalesi punctuation-only normalized query yields no search results" {
    var response = try parseSeriesIndex(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<table><tr><td id=\"bolumler\"><a href=\"bolumler-82-death-note.html\">Death Note</a></td></tr></table>",
        "... !!! ---",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "animekalesi series index skips malformed hrefs before a valid result" {
    var response = try parseSeriesIndex(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<table><tr><td id=\"bolumler\">" ++
            "<a href=\"bolumler-%ZZ\">Death Note</a>" ++
            "<a href=\"bolumler-82-death-note.html\">Death Note</a>" ++
            "</td></tr></table>",
        "Death Note",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings(site ++ "/altyazib-82-death-note.html", response.items[0].page_url);
}

test "animekalesi later exact representation replaces a partial duplicate" {
    var response = try parseSeriesIndex(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<table><tr><td id=\"bolumler\">" ++
            "<a href=\"bolumler-82-death-note.html\">Death Note Extra</a>" ++
            "<a href=\"bolumler-82-death-note.html\">Death Note</a>" ++
            "</td></tr></table>",
        "Death Note",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Death Note", response.items[0].title);
}

test "animekalesi token routes are exact canonical provider paths" {
    const listing = "https://animekalesi.com/altyazib-82-death-note.html";
    const episode = "https://animekalesi.com/indir_bolum-71-death-note-1-bolum.html";
    try validateListingUrl(listing);
    try validateEpisodeUrl(episode);

    for ([_][]const u8{
        download_token_prefix ++ "https://animekalesi.com/altyazib-82-death-note.html?next=/private|" ++ episode,
        download_token_prefix ++ "https://animekalesi.com/altyazib-82-death-note.html#fragment|" ++ episode,
        download_token_prefix ++ "https://animekalesi.com/altyazib-82/death-note.html|" ++ episode,
        download_token_prefix ++ "https://animekalesi.com/altyazib-82-%2fadmin.html|" ++ episode,
        download_token_prefix ++ "https://animekalesi.com/altyazib-death-note.html|" ++ episode,
        download_token_prefix ++ "https://animekalesi.com/altyazib-0-death-note.html|" ++ episode,
        download_token_prefix ++ "https://animekalesi.com/altyazib-082-death-note.html|" ++ episode,
        download_token_prefix ++ "https://ANIMEKALESI.com/altyazib-82-death-note.html|" ++ episode,
        download_token_prefix ++ "https://animekalesi.com:443/altyazib-82-death-note.html|" ++ episode,
        download_token_prefix ++ listing ++ "|https://animekalesi.com/indir_bolum-71-death-note.html?x=1",
        download_token_prefix ++ listing ++ "|https://animekalesi.com/indir_bolum-71-death-note.html#x",
        download_token_prefix ++ listing ++ "|https://animekalesi.com/episode/indir_bolum-71-death-note.html",
        download_token_prefix ++ listing ++ "|https://animekalesi.com/indir_bolum-71-..html",
    }) |invalid| {
        try std.testing.expect(parseDownloadToken(invalid) == null);
    }
    try std.testing.expectError(
        error.InvalidDownloadUrl,
        makeDownloadToken(std.testing.allocator, site ++ "/listing", episode),
    );
    const oversized_slug: [max_token_route_segment_bytes]u8 = @splat('a');
    const oversized_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/altyazib-1-{s}.html",
        .{ site, &oversized_slug },
    );
    defer std.testing.allocator.free(oversized_url);
    try std.testing.expectError(error.InvalidDownloadUrl, validateListingUrl(oversized_url));
}

test "animekalesi skips malformed download anchors before a valid route" {
    const body =
        "<div id=\"altyazi_indir\">" ++
        "<a href=\"https://www.google.com/download/decoy.zip\">external</a>" ++
        "<a href=\"/admin/archive.zip\">wrong route</a>" ++
        "<a href=\"/download/archive.zip?token=public\">valid</a>" ++
        "</div>";
    const url = try parseEpisodeDownloadUrl(std.testing.allocator, body);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(site ++ "/download/archive.zip?token=public", url);

    try std.testing.expectError(
        error.MissingField,
        parseEpisodeDownloadUrl(
            std.testing.allocator,
            "<div id=\"altyazi_indir\"><a href=\"/download-admin\">bad</a></div>",
        ),
    );
}

test "animekalesi listing must contain the token episode before handoff" {
    const expected = site ++ "/indir_bolum-71-death-note-1-bolum.html";
    const other = site ++ "/indir_bolum-72-death-note-2-bolum.html";
    const body =
        "<table><tr><td id=\"ayazi_indir\">" ++
        "<a href=\"indir_bolum-71-death-note-1-bolum.html\">one</a>" ++
        "<a href=\"indir_bolum-bad.html\">bad</a>" ++
        "</td></tr></table>";
    try std.testing.expect(try listingContainsEpisodeUrl(std.testing.allocator, body, expected));
    try std.testing.expect(!try listingContainsEpisodeUrl(std.testing.allocator, body, other));
}

test "animekalesi malformed duplicate does not suppress a valid episode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const subtitles = try parseSubtitleListing(
        arena.allocator(),
        "<table><tr><td id=\"ayazi_indir\">" ++
            "<a href=\"indir_bolum-7-death-note.html\">missing title</a>" ++
            "<a href=\"indir_bolum-7-death-note.html\" title=\"Death Note 2 Sezon 3 Bolum\">valid</a>" ++
            "<a href=\"indir_bolum-7-death-note.html\" title=\"Death Note 9 Sezon 9 Bolum\">duplicate</a>" ++
            "</td></tr></table>",
        .{ .title = "Death Note", .page_url = "https://animekalesi.com/altyazib-82-death-note.html" },
    );

    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqual(@as(i64, 2), subtitles[0].season);
    try std.testing.expectEqual(@as(i64, 3), subtitles[0].episode);
}

test "animekalesi raw session transport rejects ambiguous response framing" {
    for ([_][]const u8{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
    }) |raw_head| {
        const head = try std.http.Client.Response.Head.parse(raw_head);
        try std.testing.expectError(error.AmbiguousHttpFraming, validateRawSessionResponseHead(head));
    }
}

test "live animekalesi search listing and session download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "animekalesi.com")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Death Note");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    try std.testing.expectEqualStrings("Death Note", search.items[0].title);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len >= 30);
    try std.testing.expectEqual(@as(i64, 1), subtitles.subtitles[0].episode);

    const download = try scraper.fetchDownloadByToken(std.testing.allocator, subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
