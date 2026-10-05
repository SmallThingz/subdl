const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
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
        });
        return parseSeriesIndex(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = series_index_url }},
            .cache = false,
            .max_attempts = 2,
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

        var cookie: ?[]u8 = null;
        defer if (cookie) |value| allocator.free(value);

        var index = try fetchRaw(self.client, allocator, series_index_url, null, null);
        defer index.deinit(allocator);
        try updateSessionCookie(allocator, &cookie, index.cookie);
        if (index.status != .ok) return error.UnexpectedHttpStatus;

        var listing = try fetchRaw(self.client, allocator, parts.listing_url, cookie, series_index_url);
        defer listing.deinit(allocator);
        try updateSessionCookie(allocator, &cookie, listing.cookie);
        if (listing.status != .ok) return error.UnexpectedHttpStatus;

        var episode = try fetchRaw(self.client, allocator, parts.episode_url, cookie, parts.listing_url);
        defer episode.deinit(allocator);
        try updateSessionCookie(allocator, &cookie, episode.cookie);
        if (episode.status != .ok) return error.UnexpectedHttpStatus;

        const first_url = try parseEpisodeDownloadUrl(allocator, episode.body);
        defer allocator.free(first_url);
        return fetchRedirectChain(self.client, allocator, first_url, cookie, parts.episode_url, 6);
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
) !RawResponse {
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
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra_storage[0..extra_count],
    });
    defer req.deinit();
    try req.sendBodiless();

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = try req.receiveHead(&head_buffer);
    const cookie_value = try extractSessionCookie(allocator, response.head.bytes);
    errdefer if (cookie_value) |value| allocator.free(value);
    const location = try extractHeader(allocator, response.head.bytes, "location");
    errdefer if (location) |value| allocator.free(value);

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    _ = try reader.streamRemaining(&writer.writer);

    return .{
        .status = response.head.status,
        .body = try allocator.dupe(u8, writer.writer.buffered()),
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

fn extractHeader(allocator: Allocator, headers: []const u8, wanted: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, wanted)) continue;
        return @as(?[]u8, try allocator.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " \t")));
    }
    return null;
}

fn updateSessionCookie(allocator: Allocator, current: *?[]u8, candidate: ?[]u8) !void {
    const value = candidate orelse return;
    const replacement = try allocator.dupe(u8, value);
    if (current.*) |old| allocator.free(old);
    current.* = replacement;
}

fn fetchRedirectChain(
    client: *std.http.Client,
    allocator: Allocator,
    start_url: []const u8,
    initial_cookie: ?[]const u8,
    initial_referer: []const u8,
    max_redirects: usize,
) !common.HttpResponse {
    var current_url: []const u8 = try allocator.dupe(u8, start_url);
    defer allocator.free(current_url);
    var referer: []const u8 = try allocator.dupe(u8, initial_referer);
    defer allocator.free(referer);
    var cookie = if (initial_cookie) |value| try allocator.dupe(u8, value) else null;
    defer if (cookie) |value| allocator.free(value);

    var redirects: usize = 0;
    while (true) {
        var response = try fetchRaw(client, allocator, current_url, cookie, referer);
        defer response.deinit(allocator);
        try updateSessionCookie(allocator, &cookie, response.cookie);

        if (!common.isRedirectStatus(response.status)) {
            if (response.status != .ok) {
                return error.UnexpectedHttpStatus;
            }
            const body = response.body;
            response.body = &.{};
            return .{ .status = .ok, .body = body };
        }

        if (redirects >= max_redirects) {
            return error.TooManyRedirects;
        }
        const location = response.location orelse {
            return error.MissingField;
        };
        const next_url = try common.resolveUrl(allocator, current_url, location);
        errdefer allocator.free(next_url);
        if (!try common.sameOrigin(current_url, next_url)) {
            if (cookie) |value| allocator.free(value);
            cookie = null;
        }

        allocator.free(referer);
        referer = current_url;
        current_url = next_url;
        redirects += 1;
    }
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
