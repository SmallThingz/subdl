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

/// Values from one browser session whose user enabled the site's download
/// protection. Do not synthesize fingerprints or rotate identities on refusal.
pub const DownloadSession = struct {
    cookie: []const u8,
    user_agent: []const u8,
    fingerprint: []const u8,
};

pub fn parseDownloadUrl(url: []const u8) ?i64 {
    const prefix = api ++ "/translations/series/";
    const suffix = "/download";
    if (!std.mem.startsWith(u8, url, prefix) or !std.mem.endsWith(u8, url, suffix)) return null;
    if (url.len <= prefix.len + suffix.len) return null;
    const digits = url[prefix.len .. url.len - suffix.len];
    if (digits[0] == '0') return null;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    const id = std.fmt.parseInt(i64, digits, 10) catch return null;
    return if (id > 0) id else null;
}

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    /// Configure all three SCRAPERS_PRIJEVODI_{COOKIE,USER_AGENT,FINGERPRINT}
    /// values from the same consenting browser. Missing consent is actionable;
    /// it is never an empty successful download or an upstream outage.
    pub fn fetchDownloadByUrl(self: *Scraper, allocator: Allocator, url: []const u8) !common.HttpResponse {
        _ = parseDownloadUrl(url) orelse return error.InvalidDownloadUrl;
        const cookie = try common.getenvOwned(allocator, "SCRAPERS_PRIJEVODI_COOKIE");
        defer if (cookie) |value| allocator.free(value);
        const user_agent = try common.getenvOwned(allocator, "SCRAPERS_PRIJEVODI_USER_AGENT");
        defer if (user_agent) |value| allocator.free(value);
        const fingerprint = try common.getenvOwned(allocator, "SCRAPERS_PRIJEVODI_FINGERPRINT");
        defer if (fingerprint) |value| allocator.free(value);
        if (cookie == null and user_agent == null and fingerprint == null) return error.DownloadConsentRequired;
        return self.fetchDownloadByUrlWithSession(allocator, url, .{
            .cookie = cookie orelse return error.InvalidDownloadSession,
            .user_agent = user_agent orelse return error.InvalidDownloadSession,
            .fingerprint = fingerprint orelse return error.InvalidDownloadSession,
        });
    }

    pub fn fetchDownloadByUrlWithSession(self: *Scraper, allocator: Allocator, url: []const u8, session: DownloadSession) !common.HttpResponse {
        return self.fetchDownloadUsing(common.fetchBytes, allocator, url, session);
    }

    fn fetchDownloadUsing(self: *Scraper, comptime fetch: anytype, allocator: Allocator, url: []const u8, session: DownloadSession) !common.HttpResponse {
        const translation_id = parseDownloadUrl(url) orelse return error.InvalidDownloadUrl;
        try validateDownloadSession(session);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const headers: []const std.http.Header = &.{
            .{ .name = "Cookie", .value = session.cookie },
            .{ .name = "User-Agent", .value = session.user_agent },
            .{ .name = "X-PO-Fingerprint", .value = session.fingerprint },
            .{ .name = "Origin", .value = site },
            .{ .name = "Referer", .value = site ++ "/" },
        };
        const payload = try std.fmt.allocPrint(a, "{{\"section\":\"series\",\"translationIds\":[{d}]}}", .{translation_id});
        const deadline = common.compatMilliTimestamp() + 120_000;
        const ticket_response = try fetch(self.client, a, api ++ "/downloads/ticket", .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/json",
            .accept = "application/json",
            .extra_headers = headers,
            .allow_non_ok = true,
            .cache = false,
            .max_attempts = 1,
            .retry_on_429 = false,
            .max_response_bytes = 64 * 1024,
            .max_encoded_response_bytes = 64 * 1024,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
            .private_headers_path_prefix = "/api/v1",
            .deadline_ms = deadline,
        });
        try checkDownloadStatus(ticket_response);
        const ticket = try parseDownloadTicket(a, ticket_response.body);
        const encoded = try common.encodeUriComponent(a, ticket);
        const ticket_url = try std.fmt.allocPrint(a, "{s}?ticket={s}", .{ url, encoded });
        const response = try fetch(self.client, allocator, ticket_url, .{
            .accept = "application/zip,application/octet-stream,*/*",
            .extra_headers = headers,
            .allow_non_ok = true,
            .cache = false,
            .max_attempts = 1,
            .retry_on_429 = false,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
            .private_headers_path_prefix = "/api/v1",
            .deadline_ms = deadline,
        });
        errdefer allocator.free(response.body);
        if (response.status == .forbidden) {
            const root = std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            if (root) |value| if (value == .object) {
                if (value.object.get("error")) |err_value| if (err_value == .object) {
                    if (common.jsonString(err_value.object, "code")) |code| {
                        if (std.mem.eql(u8, code, "Tracking/TicketInvalid")) return error.DownloadTicketInvalid;
                    }
                };
            };
        }
        try checkDownloadStatus(response);
        if (response.body.len < 4 or !std.mem.eql(u8, response.body[0..4], "PK\x03\x04")) return error.InvalidArchive;
        return response;
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len < 2) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

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
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
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

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var other: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen_ids = std.AutoHashMapUnmanaged(i64, void).empty;

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
            if (series_id <= 0 or !isSafeSlug(slug) or seen_ids.contains(series_id)) continue;

            const normalized = try common.normalizeTitle(a, title);
            if (normalized.len == 0) continue;
            if (!normalizedTitlesRelated(normalized, wanted)) continue;

            const item: SearchItem = .{
                .title = try a.dupe(u8, title),
                .series_id = series_id,
                .slug = try a.dupe(u8, slug),
                .page_url = try seriesPageUrl(a, slug),
            };
            const match_kind = common.jsonString(obj, "matchKind");
            if ((match_kind != null and std.mem.eql(u8, match_kind.?, "exact")) or std.mem.eql(u8, normalized, wanted))
                try exact.append(a, item)
            else
                try other.append(a, item);
            try seen_ids.put(a, series_id, {});
        }

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        try out.appendSlice(a, exact.items);
        try out.appendSlice(a, other.items);
        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try out.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        if (item.series_id <= 0 or !isSafeSlug(item.slug)) return error.InvalidDownloadUrl;
        const expected_page_url = try seriesPageUrl(a, item.slug);
        if (!std.mem.eql(u8, item.page_url, expected_page_url)) return error.UnsafeHttpTarget;

        const url = try std.fmt.allocPrint(
            a,
            "{s}/translations/series?seriesId={d}&page=1&perPage=1000&publishedRowsOnly=true&hasFile=true",
            .{ api, item.series_id },
        );
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
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
        var seen_ids = std.AutoHashMapUnmanaged(i64, void).empty;
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
            if (translation_id <= 0 or season < 0 or episode <= 0 or filename.len == 0 or seen_ids.contains(translation_id)) continue;
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
            try seen_ids.put(a, translation_id, {});
        }

        const owned = try subtitles.toOwnedSlice(a);
        std.mem.sort(SubtitleItem, owned, {}, subtitleLessThan);

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = owned,
        });
    }
};

fn validateDownloadSession(session: DownloadSession) !void {
    if (session.cookie.len == 0 or session.cookie.len > 32 * 1024 or
        session.user_agent.len == 0 or session.user_agent.len > 4096 or
        session.fingerprint.len != 64) return error.InvalidDownloadSession;
    for (session.fingerprint) |byte| if (!std.ascii.isHex(byte)) return error.InvalidDownloadSession;
    try common.validateHttpHeaders(&.{
        .{ .name = "Cookie", .value = session.cookie },
        .{ .name = "User-Agent", .value = session.user_agent },
    });
    var cookies = std.mem.splitScalar(u8, session.cookie, ';');
    while (cookies.next()) |raw| {
        const cookie = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, cookie, "po_visitor=") and cookie.len > "po_visitor=".len) return;
    }
    return error.InvalidDownloadSession;
}

fn checkDownloadStatus(response: common.HttpResponse) !void {
    if (response.status == .too_many_requests) return error.TooManyRequests;
    if (@import("opensubtitles_com_cf.zig").isChallengeBody(response.body)) return error.CloudflareChallenge;
    if (common.isAustralianWebsiteBlockPage(response.body)) return error.AustralianWebsiteBlocked;
    if (response.status == .unauthorized or response.status == .forbidden) return error.AccessDenied;
    if (response.status != .ok) return error.HttpStatusNotOk;
}

fn parseDownloadTicket(allocator: Allocator, body: []const u8) ![]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidDownloadTicketResponse,
    };
    if (root != .object) return error.InvalidDownloadTicketResponse;
    const download = root.object.get("download") orelse return error.InvalidDownloadTicketResponse;
    if (download != .object) return error.InvalidDownloadTicketResponse;
    const outcome = common.jsonString(download.object, "outcome") orelse return error.InvalidDownloadTicketResponse;
    if (std.mem.eql(u8, outcome, "ticket")) {
        const ticket = common.jsonString(download.object, "ticket") orelse return error.InvalidDownloadTicketResponse;
        if (ticket.len == 0 or ticket.len > 8192) return error.InvalidDownloadTicketResponse;
        for (ticket) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidDownloadTicketResponse;
        return ticket;
    }
    if (!std.mem.eql(u8, outcome, "refused")) return error.InvalidDownloadTicketResponse;
    const refusal = download.object.get("refusal") orelse return error.InvalidDownloadTicketResponse;
    if (refusal != .object) return error.InvalidDownloadTicketResponse;
    const reason = common.jsonString(refusal.object, "reason") orelse return error.InvalidDownloadTicketResponse;
    if (std.mem.eql(u8, reason, "consent_required")) return error.DownloadConsentRequired;
    if (std.mem.eql(u8, reason, "captcha_required")) return error.CaptchaRequired;
    if (std.mem.eql(u8, reason, "blocked")) return error.DownloadBlocked;
    if (std.mem.eql(u8, reason, "temporarily_blocked")) return error.DownloadTemporarilyBlocked;
    if (std.mem.eql(u8, reason, "cooldown")) return error.DownloadCooldown;
    if (std.mem.eql(u8, reason, "daily_cap")) return error.DownloadDailyCap;
    return error.DownloadTicketRefused;
}

fn normalizedTitlesRelated(lhs: []const u8, rhs: []const u8) bool {
    return containsNormalizedPhrase(lhs, rhs) or containsNormalizedPhrase(rhs, lhs);
}

fn containsNormalizedPhrase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len == 0 or needle.len == 0 or needle.len > haystack.len) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        const end = index + needle.len;
        const starts_at_boundary = index == 0 or haystack[index - 1] == ' ';
        const ends_at_boundary = end == haystack.len or haystack[end] == ' ';
        if (starts_at_boundary and ends_at_boundary) return true;
        start = index + 1;
    }
    return false;
}

fn isSafeSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or value[0] == '-' or value[value.len - 1] == '-') return false;
    var previous_dash = false;
    for (value) |byte| {
        if (byte == '-') {
            if (previous_dash) return false;
            previous_dash = true;
        } else {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
            previous_dash = false;
        }
    }
    return true;
}

fn seriesPageUrl(allocator: Allocator, slug: []const u8) ![]u8 {
    if (!isSafeSlug(slug)) return error.InvalidDownloadUrl;
    const encoded = try common.encodeUriComponent(allocator, slug);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{s}/series/view/{s}", .{ site, encoded });
}

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

test "prijevodi binds series pages to one canonical slug segment" {
    const valid = try seriesPageUrl(std.testing.allocator, "chernobyl-2019");
    defer std.testing.allocator.free(valid);
    try std.testing.expectEqualStrings(site ++ "/series/view/chernobyl-2019", valid);
    for ([_][]const u8{ "", ".", "..", "a/b", "a%2fb", "a?next=admin", "-leading", "trailing-" }) |slug| {
        try std.testing.expectError(error.InvalidDownloadUrl, seriesPageUrl(std.testing.allocator, slug));
    }
}

test "prijevodi title relevance requires complete normalized words" {
    try std.testing.expect(normalizedTitlesRelated("the matrix", "matrix"));
    try std.testing.expect(!normalizedTitlesRelated("preacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("the matrix", ""));
}

const DownloadFixture = struct {
    const session: DownloadSession = .{ .cookie = "po_visitor=fixture; cf_clearance=fixture", .user_agent = "fixture-browser", .fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    const url = api ++ "/translations/series/135872/download";
    var calls: usize = 0;
    var ticket_body: []const u8 = "";
    var download_body: []const u8 = "";
    var download_status: std.http.Status = .ok;
    var failure: ?anyerror = null;
    var deadline: ?i64 = null;

    fn reset() void {
        calls = 0;
        ticket_body = "{\"download\":{\"outcome\":\"ticket\",\"ticket\":\"opaque+/=ticket\"}}";
        download_body = "PK\x03\x04fixture";
        download_status = .ok;
        failure = null;
        deadline = null;
    }

    fn fetch(_: *std.http.Client, allocator: Allocator, target: []const u8, options: common.FetchOptions) !common.HttpResponse {
        calls += 1;
        if (failure) |err| return err;
        try std.testing.expect(calls <= 2);
        try std.testing.expect(options.require_public_origin and options.require_https and options.require_same_origin);
        try std.testing.expect(!options.cache and !options.retry_on_429 and options.allow_non_ok);
        try std.testing.expectEqual(@as(usize, 1), options.max_attempts);
        try std.testing.expectEqualStrings("/api/v1", options.private_headers_path_prefix.?);
        try std.testing.expectEqualStrings(session.cookie, options.extra_headers[0].value);
        try std.testing.expectEqualStrings(session.user_agent, options.extra_headers[1].value);
        try std.testing.expectEqualStrings(session.fingerprint, options.extra_headers[2].value);
        if (calls == 1) {
            try std.testing.expectEqualStrings(api ++ "/downloads/ticket", target);
            try std.testing.expectEqual(std.http.Method.POST, options.method);
            try std.testing.expectEqualStrings("{\"section\":\"series\",\"translationIds\":[135872]}", options.payload.?);
            try std.testing.expectEqualStrings("application/json", options.content_type.?);
            try std.testing.expect(options.deadline_ms != null);
            deadline = options.deadline_ms;
            return .{ .status = .ok, .body = try allocator.dupe(u8, ticket_body) };
        }
        try std.testing.expectEqualStrings(url ++ "?ticket=opaque%2B%2F%3Dticket", target);
        try std.testing.expectEqual(std.http.Method.GET, options.method);
        try std.testing.expect(options.payload == null);
        try std.testing.expectEqual(deadline, options.deadline_ms);
        return .{ .status = download_status, .body = try allocator.dupe(u8, download_body) };
    }
};

test "prijevodi acquires fresh ticket immediately before download with same session" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    DownloadFixture.reset();
    const result = try scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, DownloadFixture.url, DownloadFixture.session);
    defer std.testing.allocator.free(result.body);
    try std.testing.expectEqual(@as(usize, 2), DownloadFixture.calls);
    try std.testing.expectEqualStrings(DownloadFixture.download_body, result.body);
}

test "prijevodi rejects unsafe download URLs and incomplete sessions before requests" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    DownloadFixture.reset();
    try std.testing.expectEqual(@as(?i64, 135872), parseDownloadUrl(DownloadFixture.url));
    for ([_][]const u8{
        "https://evil.invalid/api/v1/translations/series/135872/download",
        "http://www.prijevodi-online.org/api/v1/translations/series/135872/download",
        api ++ "/translations/series/0/download",
        api ++ "/translations/series/01/download",
        api ++ "/translations/series/-1/download",
        api ++ "/translations/series/9223372036854775808/download",
        api ++ "/translations/series/1/../2/download",
        api ++ "/translations/series/%31/download",
        DownloadFixture.url ++ "?ticket=untrusted",
        DownloadFixture.url ++ "#fragment",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, url, DownloadFixture.session));
    }
    var session = DownloadFixture.session;
    session.cookie = "other_visitor=fixture";
    try std.testing.expectError(error.InvalidDownloadSession, scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, DownloadFixture.url, session));
    session = DownloadFixture.session;
    session.fingerprint = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
    try std.testing.expectError(error.InvalidDownloadSession, scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, DownloadFixture.url, session));
    session = DownloadFixture.session;
    session.user_agent = "agent\r\nInjected: true";
    try std.testing.expectError(error.InvalidHttpHeader, scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, DownloadFixture.url, session));
    try std.testing.expectEqual(@as(usize, 0), DownloadFixture.calls);
}

test "prijevodi ticket refusals are terminal and never fetch an archive" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    const cases = .{
        .{ "consent_required", error.DownloadConsentRequired },
        .{ "captcha_required", error.CaptchaRequired },
        .{ "blocked", error.DownloadBlocked },
        .{ "temporarily_blocked", error.DownloadTemporarilyBlocked },
        .{ "cooldown", error.DownloadCooldown },
        .{ "daily_cap", error.DownloadDailyCap },
        .{ "new_refusal", error.DownloadTicketRefused },
    };
    inline for (cases) |case| {
        DownloadFixture.reset();
        DownloadFixture.ticket_body = "{\"download\":{\"outcome\":\"refused\",\"refusal\":{\"reason\":\"" ++ case[0] ++ "\"}}}";
        try std.testing.expectError(case[1], scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, DownloadFixture.url, DownloadFixture.session));
        try std.testing.expectEqual(@as(usize, 1), DownloadFixture.calls);
    }
}

test "prijevodi malformed tickets and failed downloads cannot pass as archives" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    for ([_][]const u8{ "not json", "{}", "{\"download\":{\"outcome\":\"ticket\",\"ticket\":\"\"}}", "{\"download\":{\"outcome\":\"ticket\",\"ticket\":4}}" }) |body| {
        DownloadFixture.reset();
        DownloadFixture.ticket_body = body;
        try std.testing.expectError(error.InvalidDownloadTicketResponse, scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, DownloadFixture.url, DownloadFixture.session));
        try std.testing.expectEqual(@as(usize, 1), DownloadFixture.calls);
    }
    DownloadFixture.reset();
    DownloadFixture.download_body = "{\"error\":{\"code\":\"Tracking/TicketInvalid\",\"message\":\"expired\"}}";
    DownloadFixture.download_status = .forbidden;
    try std.testing.expectError(error.DownloadTicketInvalid, scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, DownloadFixture.url, DownloadFixture.session));
    try std.testing.expectEqual(@as(usize, 2), DownloadFixture.calls);
    DownloadFixture.reset();
    DownloadFixture.download_body = "<html>Not a ZIP</html>";
    try std.testing.expectError(error.InvalidArchive, scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, DownloadFixture.url, DownloadFixture.session));
    for ([_]anyerror{ error.Canceled, error.OutOfMemory }) |err| {
        DownloadFixture.reset();
        DownloadFixture.failure = err;
        try std.testing.expectError(err, scraper.fetchDownloadUsing(DownloadFixture.fetch, std.testing.allocator, DownloadFixture.url, DownloadFixture.session));
        try std.testing.expectEqual(@as(usize, 1), DownloadFixture.calls);
    }
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

    const download = try scraper.fetchDownloadByUrl(std.testing.allocator, subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
