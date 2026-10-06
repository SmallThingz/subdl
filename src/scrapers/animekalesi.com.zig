const std = @import("std");
const common = @import("common.zig");
const cloudflare = @import("opensubtitles_com_cf.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://animekalesi.com";
const series_index_url = site ++ "/tum-anime-serileri.html";
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

        const response = try common.fetchBytes(self.client, a, series_index_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });
        return parseSeriesIndex(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(item.page_url);

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = series_index_url }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });
        var parsed = try common.parseHtmlStable(a, response.body);

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var anchors = parsed.doc.queryAll("td#ayazi_indir a[href^='indir_bolum-']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (seen.contains(href)) continue;
            try seen.put(a, try a.dupe(u8, href), {});

            const title_attr = common.getAttributeValueSafe(anchor, "title") orelse "";
            const episode = parseLastPositiveInt(title_attr) orelse continue;
            const season: i64 = parseSeason(title_attr) orelse 1;
            const episode_url = try common.resolveUrl(a, site, href);
            const slugged = try common.asciiSlug(a, item.title);

            try subtitles.append(a, .{
                .language_code = "tr",
                .filename = try std.fmt.allocPrint(a, "animekalesi-{s}-s{d}e{d}.zip", .{ slugged, season, episode }),
                .download_url = try makeDownloadToken(a, item.page_url, episode_url),
                .season = season,
                .episode = episode,
            });
        }

        const owned = try subtitles.toOwnedSlice(a);
        std.mem.sort(SubtitleItem, owned, {}, common.seasonEpisodeLessThan(SubtitleItem));
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = owned,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        if (!try isProviderOrigin(parts.listing_url) or !try isProviderOrigin(parts.episode_url)) return error.InvalidDownloadUrl;

        var cookie: ?[]u8 = null;
        defer if (cookie) |value| allocator.free(value);

        var index = try fetchRaw(self.client, allocator, series_index_url, null, null, null);
        defer index.deinit(allocator);
        try updateSessionCookie(allocator, &cookie, index.cookie);
        if (index.status != .ok) return error.UnexpectedHttpStatus;

        var listing = try fetchRaw(self.client, allocator, parts.listing_url, cookie, series_index_url, null);
        defer listing.deinit(allocator);
        try updateSessionCookie(allocator, &cookie, listing.cookie);
        if (listing.status != .ok) return error.UnexpectedHttpStatus;

        var episode = try fetchRaw(self.client, allocator, parts.episode_url, cookie, parts.listing_url, null);
        defer episode.deinit(allocator);
        try updateSessionCookie(allocator, &cookie, episode.cookie);
        if (episode.status != .ok) return error.UnexpectedHttpStatus;

        const first_url = try parseEpisodeDownloadUrl(allocator, episode.body);
        defer allocator.free(first_url);
        return fetchPublicDownload(self.client, allocator, first_url, cookie, parts.episode_url);
    }
};

fn parseSeriesIndex(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);

    const wanted = try common.normalizeTitle(a, query);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

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

        const series_url = try common.resolveUrl(a, site, href);
        const listing_url = try subtitleListingUrl(a, series_url);
        if (seen.contains(listing_url)) continue;
        try seen.put(a, listing_url, {});

        const item: SearchItem = .{
            .title = title,
            .page_url = listing_url,
        };
        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    try out.appendSlice(a, exact.items);
    try out.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try out.toOwnedSlice(a) });
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
    return .{ .listing_url = payload[0..sep], .episode_url = payload[sep + 1 ..] };
}

fn parseEpisodeDownloadUrl(allocator: Allocator, body: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);
    const anchor = parsed.doc.queryOne("div#altyazi_indir a[href]") orelse return error.MissingField;
    const href = common.getAttributeValueSafe(anchor, "href") orelse return error.MissingField;
    const resolved = try common.resolveUrl(a, site, href);
    return allocator.dupe(u8, resolved);
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
    cookie: ?[]u8,
    location: ?[]u8,

    fn deinit(self: *RawResponse, allocator: Allocator) void {
        allocator.free(self.body);
        if (self.cookie) |value| allocator.free(value);
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
    try validateProviderUrl(url);
    try common.ensureClientTlsReady(client);
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

    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{ .override = user_agent orelse common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra_storage[0..extra_count],
    });
    defer req.deinit();
    errdefer req.connection.?.closing = true;
    try req.sendBodiless();

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = try req.receiveHead(&head_buffer);
    const cookie_value = try extractSessionCookie(allocator, response.head.bytes);
    errdefer if (cookie_value) |value| allocator.free(value);
    const location = if (response.head.location) |value| try allocator.dupe(u8, value) else null;
    errdefer if (location) |value| allocator.free(value);

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = readBoundedBody(allocator, reader, max_raw_response_bytes) catch |err| {
        if (err == error.ReadFailed) {
            if (response.bodyErr()) |body_err| return body_err;
            if (req.connection.?.stream_reader.err) |stream_err| return stream_err;
        }
        return err;
    };
    errdefer allocator.free(body);
    switch (req.reader.state) {
        .body_remaining_content_length => |left| if (left != 0) return error.HttpBodyTruncated,
        .body_remaining_chunk_len => return error.HttpChunkTruncated,
        else => {},
    }

    return .{
        .status = response.head.status,
        .body = body,
        .cookie = cookie_value,
        .location = location,
    };
}

fn extractSessionCookie(allocator: Allocator, headers: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.findIgnoreCase(value, "ASPSESSIONID") != 0) continue;
        const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        return @as(?[]u8, try allocator.dupe(u8, value[0..end]));
    }
    return null;
}

fn updateSessionCookie(allocator: Allocator, current: *?[]u8, candidate: ?[]u8) !void {
    const value = candidate orelse return;
    const replacement = try allocator.dupe(u8, value);
    if (current.*) |old| allocator.free(old);
    current.* = replacement;
}

fn isProviderOrigin(url: []const u8) !bool {
    const uri = try std.Uri.parse(url);
    if (uri.user != null or uri.password != null) return false;
    return common.sameOrigin(site, url);
}

fn validateProviderUrl(url: []const u8) !void {
    if (!(isProviderOrigin(url) catch false)) return error.InvalidDownloadUrl;
}

fn initialSessionCookie(url: []const u8, cookie: ?[]const u8) !?[]const u8 {
    return if (try isProviderOrigin(url)) cookie else null;
}

const DownloadDisposition = enum {
    success,
    redirect,
    rate_limited,
    challenge,
    unexpected_status,
};

fn downloadDisposition(response: RawResponse) DownloadDisposition {
    // A provider rate limit remains terminal even if its body is a challenge
    // page. Opening a browser cannot turn a quota response into success.
    if (response.status == .too_many_requests) return .rate_limited;
    if (cloudflare.isChallengeBody(response.body) or
        response.status == .forbidden or
        response.status == .service_unavailable)
    {
        return .challenge;
    }
    if (common.isRedirectStatus(response.status)) return .redirect;
    return if (response.status == .ok) .success else .unexpected_status;
}

fn fetchPublicDownload(
    client: *std.http.Client,
    allocator: Allocator,
    start_url: []const u8,
    initial_cookie: ?[]const u8,
    initial_referer: []const u8,
) !common.HttpResponse {
    return fetchPublicDownloadWith(
        fetchRaw,
        cloudflare.ensureDomainSession,
        common.fetchBytes,
        client,
        allocator,
        start_url,
        initial_cookie,
        initial_referer,
        6,
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
    // Every URL carrying provider session state is constrained to the exact
    // HTTPS provider origin. This also makes an absolute cross-origin href or
    // redirect fail closed before any ASP or browser cookie can be attached.
    try validateProviderUrl(start_url);
    try validateProviderUrl(initial_referer);

    var current_url: []const u8 = try allocator.dupe(u8, start_url);
    defer allocator.free(current_url);
    var referer: []const u8 = try allocator.dupe(u8, initial_referer);
    defer allocator.free(referer);
    var asp_cookie = if (try initialSessionCookie(start_url, initial_cookie)) |value|
        try allocator.dupe(u8, value)
    else
        null;
    defer if (asp_cookie) |value| allocator.free(value);

    var browser_session: ?cloudflare.Session = null;
    defer if (browser_session) |*session| session.deinit(allocator);
    var refreshed_rejected_session = false;
    var redirects: usize = 0;

    while (true) {
        var browser_cookie: ?[]u8 = null;
        defer if (browser_cookie) |value| allocator.free(value);

        const request_cookie: ?[]const u8 = if (browser_session) |session| blk: {
            browser_cookie = try session.cookieHeaderForUrl(allocator, current_url);
            break :blk browser_cookie;
        } else asp_cookie;
        const request_user_agent = if (browser_session) |session| session.user_agent else common.default_user_agent;

        var response = try fetch(client, allocator, current_url, request_cookie, referer, request_user_agent);
        var response_owned = true;
        errdefer if (response_owned) response.deinit(allocator);

        switch (downloadDisposition(response)) {
            .rate_limited => {
                response.deinit(allocator);
                response_owned = false;
                return error.RateLimited;
            },
            .challenge => {
                response.deinit(allocator);
                response_owned = false;

                if (browser_session) |session| {
                    if (refreshed_rejected_session) return error.CloudflareChallenge;
                    const refreshed = try ensure_session(allocator, .{
                        .domain = "animekalesi.com",
                        .challenge_url = current_url,
                        .force_refresh = true,
                        .rejected_generation = session.generation,
                    });
                    if (browser_session) |*owned| owned.deinit(allocator);
                    browser_session = refreshed;
                    refreshed_rejected_session = true;
                } else {
                    browser_session = try ensure_session(allocator, .{
                        .domain = "animekalesi.com",
                        .challenge_url = current_url,
                    });
                }
                continue;
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
                    try common.validatePublicHttpUrl(next_url);
                    response.deinit(allocator);
                    response_owned = false;
                    return fetch_external(client, allocator, next_url, .{
                        .accept = "application/zip,application/octet-stream,*/*",
                        .cache = false,
                        .max_attempts = 2,
                        .require_public_origin = true,
                    });
                }
                try updateSessionCookie(allocator, &asp_cookie, response.cookie);
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

        const body = response.body;
        if (response.cookie) |value| allocator.free(value);
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
            else => return err,
        };
        received += count;
    }
    var body = writer.toArrayList();
    errdefer body.deinit(allocator);
    return body.toOwnedSlice(allocator);
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

test "animekalesi initial session cookies require the exact provider origin" {
    const cookie = "ASPSESSIONID=fixture";
    try std.testing.expectEqualStrings(cookie, (try initialSessionCookie("https://ANIMEKALESI.com:443/download.zip", cookie)).?);
    for ([_][]const u8{
        "https://animekalesi.com.example/download.zip",      "https://cdn.animekalesi.com/download.zip",
        "http://animekalesi.com/download.zip",               "https://animekalesi.com:444/download.zip",
        "https://animekalesi.com@example.test/download.zip", "https://user@animekalesi.com/download.zip",
    }) |url| {
        try std.testing.expect(!try isProviderOrigin(url));
        try std.testing.expectEqual(@as(?[]const u8, null), try initialSessionCookie(url, cookie));
    }
    try std.testing.expectEqual(@as(?[]const u8, null), try initialSessionCookie("https://cdn.example.test/download.zip", cookie));
}

test "animekalesi final downloads require the exact HTTPS provider origin" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
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
            fetchPublicDownload(&client, std.testing.allocator, url, "ASPSESSIONID=fixture", site ++ "/episode"),
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
        .{ .status = .forbidden, .body = "", .expected = .challenge },
        .{ .status = .service_unavailable, .body = "", .expected = .challenge },
        .{ .status = .too_many_requests, .body = challenge, .expected = .rate_limited },
        .{ .status = .found, .body = "", .expected = .redirect },
        .{ .status = .internal_server_error, .body = "", .expected = .unexpected_status },
    }) |case| {
        try std.testing.expectEqual(case.expected, downloadDisposition(.{
            .status = case.status,
            .body = @constCast(case.body),
            .cookie = null,
            .location = null,
        }));
    }
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
                        .body = try allocator.dupe(u8, "forbidden"),
                        .cookie = null,
                        .location = null,
                    };
                },
                2 => {
                    try std.testing.expectEqualStrings("cf_clearance=first-clearance", cookie.?);
                    try std.testing.expectEqualStrings("fixture-browser-1", user_agent.?);
                    return .{
                        .status = .ok,
                        .body = try allocator.dupe(u8, "<html><script>window._cf_chl_opt = {};</script></html>"),
                        .cookie = null,
                        .location = null,
                    };
                },
                3 => {
                    try std.testing.expectEqualStrings("cf_clearance=second-clearance", cookie.?);
                    try std.testing.expectEqualStrings("fixture-browser-2", user_agent.?);
                    return .{
                        .status = .ok,
                        .body = try allocator.dupe(u8, "PK fixture archive"),
                        .cookie = null,
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
                return makeSession(allocator, "first-clearance", "fixture-browser-1", 41);
            }
            if (session_calls == 2) {
                try std.testing.expect(options.force_refresh);
                try std.testing.expectEqual(@as(?u64, 41), options.rejected_generation);
                return makeSession(allocator, "second-clearance", "fixture-browser-2", 42);
            }
            return error.TooManyMockSessions;
        }

        fn makeSession(allocator: Allocator, clearance_source: []const u8, agent_source: []const u8, generation: u64) !cloudflare.Session {
            const cookies = try allocator.alloc(cloudflare.Cookie, 1);
            errdefer allocator.free(cookies);
            const name = try allocator.dupe(u8, "cf_clearance");
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, clearance_source);
            errdefer allocator.free(value);
            const domain = try allocator.dupe(u8, "animekalesi.com");
            errdefer allocator.free(domain);
            const path = try allocator.dupe(u8, "/download/");
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

            const clearance = try allocator.dupe(u8, clearance_source);
            errdefer allocator.free(clearance);
            const user_agent = try allocator.dupe(u8, agent_source);
            return .{
                .cookies = cookies,
                .cf_clearance = clearance,
                .user_agent = user_agent,
                .csrf_token = null,
                .acquired_at_unix = 0,
                .generation = generation,
            };
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
    try std.testing.expectEqualStrings("PK fixture archive", response.body);
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
                .cookie = null,
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
