const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "http://www.subsynchro.com";
const search_endpoint = site ++ "/include/ajax/subMarin.php";
const payload_max_attempts: usize = 2;
const payload_retry_delay_ms: u64 = 350;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    page_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = std.heap.ArenaAllocator.init(self.allocator), .items = &.{} };

        var payload_attempt: usize = 0;
        while (payload_attempt < payload_max_attempts) : (payload_attempt += 1) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const url = try buildSearchUrl(a, trimmed, null);
            const response = try common.fetchBytes(self.client, a, url, .{
                .accept = "application/json,*/*",
                .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site }},
                .cache = false,
                .max_attempts = 2,
                .require_public_origin = true,
            });
            const parsed = parseSearchJson(common.takeArena(&arena), response.body, trimmed) catch |err| {
                if (!shouldRetryPayloadError(err, payload_attempt)) return err;
                try common.sleepMillisecondsCancelable(payload_retry_delay_ms);
                continue;
            };
            return parsed;
        }
        unreachable;
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        try validateProviderEndpoint(item.page_url);
        var parsed = parsed_response: {
            var payload_attempt: usize = 0;
            while (payload_attempt < payload_max_attempts) : (payload_attempt += 1) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const a = arena.allocator();

                const response = try common.fetchBytes(self.client, a, item.page_url, .{
                    .accept = "application/json,*/*",
                    .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site }},
                    .cache = false,
                    .max_attempts = 2,
                    .require_public_origin = true,
                });
                const value = parseSubtitlesJson(common.takeArena(&arena), response.body, item) catch |err| {
                    if (!shouldRetryPayloadError(err, payload_attempt)) return err;
                    try common.sleepMillisecondsCancelable(payload_retry_delay_ms);
                    continue;
                };
                break :parsed_response value;
            }
            unreachable;
        };
        errdefer parsed.deinit();
        try resolveSubtitleRedirectsUsing(resolveDownloadRedirect, self.client, &parsed);
        return parsed;
    }
};

fn resolveSubtitleRedirectsUsing(
    comptime resolve: anytype,
    client: *std.http.Client,
    parsed: *SubtitlesResponse,
) !void {
    const parsed_allocator = parsed.arena.allocator();
    var resolved: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    for (parsed.subtitles) |subtitle| {
        const direct_url = resolve(client, parsed_allocator, subtitle.download_url) catch |err| {
            if (common.mustPropagateOptionalFailure(err)) return err;
            continue;
        };
        try resolved.append(parsed_allocator, .{
            .language_code = subtitle.language_code,
            .filename = subtitle.filename,
            .download_url = direct_url,
        });
    }
    parsed.subtitles = try resolved.toOwnedSlice(parsed_allocator);
}

fn shouldRetryPayloadError(err: anyerror, attempt: usize) bool {
    if (attempt + 1 >= payload_max_attempts) return false;
    return !common.mustPropagateOptionalFailure(err);
}

fn buildSearchUrl(allocator: Allocator, title: []const u8, year: ?i64) ![]u8 {
    const encoded = try common.encodeUriComponent(allocator, title);
    if (year) |value| {
        return try std.fmt.allocPrint(allocator, "{s}?title={s}&year={d}", .{ search_endpoint, encoded, value });
    }
    return try std.fmt.allocPrint(allocator, "{s}?title={s}&year=", .{ search_endpoint, encoded });
}

fn parseSearchJson(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const obj = switch (root) {
        .object => |value| value,
        else => return error.InvalidFieldType,
    };
    const status = if (obj.get("status")) |value| jsonInt(value) else null;
    if (status == null or status.? != 200) return .{ .arena = owned_arena, .items = &.{} };
    const data_value = obj.get("data") orelse return error.MissingField;
    const data = switch (data_value) {
        .array => |value| value,
        else => return error.InvalidFieldType,
    };

    const wanted = try common.normalizeTitle(a, query);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    for (data.items) |entry| {
        const entry_obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const local_title = common.jsonString(entry_obj, "titre") orelse continue;
        const original_title = common.jsonString(entry_obj, "titre_original");
        const display_title = if (original_title) |value|
            if (std.mem.trim(u8, value, " \t\r\n").len > 0) value else local_title
        else
            local_title;
        const year = if (entry_obj.get("date")) |value| jsonInt(value) else null;

        const local_normalized = try common.normalizeTitle(a, local_title);
        const original_normalized = if (original_title) |value| try common.normalizeTitle(a, value) else "";
        const exact_match = std.mem.eql(u8, local_normalized, wanted) or
            (original_normalized.len > 0 and std.mem.eql(u8, original_normalized, wanted));
        const partial_match = std.mem.indexOf(u8, local_normalized, wanted) != null or
            std.mem.indexOf(u8, wanted, local_normalized) != null or
            (original_normalized.len > 0 and
                (std.mem.indexOf(u8, original_normalized, wanted) != null or
                    std.mem.indexOf(u8, wanted, original_normalized) != null));
        if (!exact_match and !partial_match) continue;

        const page_url = try buildSearchUrl(a, local_title, year);
        if (seen.contains(page_url)) continue;
        try seen.put(a, page_url, {});

        const item: SearchItem = .{
            .title = try a.dupe(u8, display_title),
            .year = year,
            .page_url = page_url,
        };
        if (exact_match)
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn parseSubtitlesJson(arena: std.heap.ArenaAllocator, body: []const u8, item: SearchItem) !SubtitlesResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const obj = switch (root) {
        .object => |value| value,
        else => return error.InvalidFieldType,
    };
    const status = if (obj.get("status")) |value| jsonInt(value) else null;
    if (status == null or status.? != 200) {
        return common.finishResponse(SubtitlesResponse, &owned_arena, .{ .arena = owned_arena, .title = try a.dupe(u8, item.title), .subtitles = &.{} });
    }
    const data_value = obj.get("data") orelse return error.MissingField;
    const data = switch (data_value) {
        .array => |value| value,
        else => return error.InvalidFieldType,
    };

    const wanted = try common.normalizeTitle(a, item.title);
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    for (data.items) |entry| {
        const entry_obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const local_title = common.jsonString(entry_obj, "titre") orelse continue;
        const original_title = common.jsonString(entry_obj, "titre_original");
        const local_normalized = try common.normalizeTitle(a, local_title);
        const original_normalized = if (original_title) |value| try common.normalizeTitle(a, value) else "";
        if (!std.mem.eql(u8, local_normalized, wanted) and
            !(original_normalized.len > 0 and std.mem.eql(u8, original_normalized, wanted))) continue;

        const year = if (entry_obj.get("date")) |value| jsonInt(value) else null;
        if (item.year) |wanted_year| {
            if (year == null or year.? != wanted_year) continue;
        }

        const filename = common.jsonString(entry_obj, "filename") orelse continue;
        const raw_download_url = common.jsonString(entry_obj, "telechargement") orelse continue;
        const download_url = try normalizeProviderUrl(a, raw_download_url);
        if (seen.contains(download_url)) continue;
        try seen.put(a, download_url, {});

        try subtitles.append(a, .{
            .language_code = "fr",
            .filename = try a.dupe(u8, filename),
            .download_url = download_url,
        });
    }

    return common.finishResponse(SubtitlesResponse, &owned_arena, .{
        .arena = owned_arena,
        .title = try a.dupe(u8, item.title),
        .subtitles = try subtitles.toOwnedSlice(a),
    });
}

fn normalizeProviderUrl(allocator: Allocator, raw_url: []const u8) ![]const u8 {
    const absolute = try common.resolveUrl(allocator, site, raw_url);
    if (std.mem.startsWith(u8, absolute, "https://www.subsynchro.com/")) {
        const normalized = try std.fmt.allocPrint(allocator, "http://{s}", .{absolute["https://".len..]});
        allocator.free(absolute);
        errdefer allocator.free(normalized);
        try validateProviderEndpoint(normalized);
        return normalized;
    }
    errdefer allocator.free(absolute);
    try validateProviderEndpoint(absolute);
    return absolute;
}

fn resolveDownloadRedirect(client: *std.http.Client, allocator: Allocator, url: []const u8) ![]const u8 {
    try validateProviderEndpoint(url);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

    const headers = [_]std.http.Header{
        .{ .name = "referer", .value = site },
        .{ .name = "accept", .value = "application/zip,application/octet-stream,*/*" },
    };
    try common.validateHttpHeaders(&headers);
    var public_client: std.http.Client = undefined;
    try common.initPublicOriginClient(client, &public_client);
    defer public_client.deinit();
    const pinned_connection = try common.connectPinnedPublicHttpUrl(&public_client, allocator, normalized);
    pinned_connection.closing = true;

    var req = public_client.request(.HEAD, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .connection = pinned_connection,
        .headers = .{
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &headers,
    }) catch |err| {
        public_client.connection_pool.release(pinned_connection, public_client.io);
        return err;
    };
    defer req.deinit();
    errdefer req.connection.?.closing = true;
    try req.sendBodiless();

    var head_buffer: [16 * 1024]u8 = undefined;
    const response = try req.receiveHead(&head_buffer);
    try requireRedirectResponseStatus(response.head.status);
    if (response.head.status == .ok) return try allocator.dupe(u8, url);

    const location = try extractHeader(allocator, response.head.bytes, "location") orelse return error.MissingField;
    defer allocator.free(location);
    const location_for_resolve = if (std.mem.startsWith(u8, location, "http://") or
        std.mem.startsWith(u8, location, "https://") or
        std.mem.startsWith(u8, location, "/"))
        location
    else
        try std.fmt.allocPrint(allocator, "/{s}", .{location});
    const resolved = try common.resolveUrl(allocator, site, location_for_resolve);
    defer allocator.free(resolved);
    return try normalizeProviderUrl(allocator, resolved);
}

fn requireRedirectResponseStatus(status: std.http.Status) !void {
    if (status == .too_many_requests) return error.RateLimited;
    if (status == .unauthorized or status == .forbidden) return error.ProviderAccessBlocked;
    if (status != .ok and !common.isRedirectStatus(status)) return error.UnexpectedHttpStatus;
}

fn validateProviderEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

fn extractHeader(allocator: Allocator, headers: []const u8, wanted: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, wanted)) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return try allocator.dupe(u8, value);
    }
    return null;
}

fn jsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        .float => |number| common.jsonInt(.{ .float = number }),
        .string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}

test "subsynchro parses and deduplicates movie search results" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchJson(
        arena,
        \\{"status":200,"data":[{"filename":"a.srt","titre":"Inception","titre_original":"Inception","date":"2010","telechargement":"https://www.subsynchro.com/a"},{"filename":"b.srt","titre":"Inception","titre_original":"Inception","date":"2010","telechargement":"https://www.subsynchro.com/b"}]}
    ,
        "Inception",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Inception", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 2010), response.items[0].year);
    try std.testing.expectEqualStrings(
        "http://www.subsynchro.com/include/ajax/subMarin.php?title=Inception&year=2010",
        response.items[0].page_url,
    );
}

test "subsynchro parses subtitle rows and normalizes provider download scheme" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSubtitlesJson(
        arena,
        \\{"status":200,"data":[{"filename":"Inception.2010.srt","titre":"Inception","titre_original":"Inception","date":"2010","telechargement":"https://www.subsynchro.com/telecharger-le-fichier-1.html"}]}
    ,
        .{
            .title = "Inception",
            .year = 2010,
            .page_url = "unused",
        },
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    try std.testing.expectEqualStrings("fr", response.subtitles[0].language_code);
    try std.testing.expectEqualStrings("Inception.2010.srt", response.subtitles[0].filename);
    try std.testing.expectEqualStrings(
        "http://www.subsynchro.com/telecharger-le-fichier-1.html",
        response.subtitles[0].download_url,
    );
}

test "subsynchro rejects unsafe provider redirect targets before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, normalizeProviderUrl(std.testing.allocator, "http://127.0.0.1/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, normalizeProviderUrl(std.testing.allocator, "https://user:pass@www.subsynchro.com/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, normalizeProviderUrl(std.testing.allocator, "https://www.google.com/private"));
}

test "subsynchro classifies redirect response failures" {
    try requireRedirectResponseStatus(.ok);
    try requireRedirectResponseStatus(.moved_permanently);
    try std.testing.expectError(error.RateLimited, requireRedirectResponseStatus(.too_many_requests));
    try std.testing.expectError(error.ProviderAccessBlocked, requireRedirectResponseStatus(.unauthorized));
    try std.testing.expectError(error.ProviderAccessBlocked, requireRedirectResponseStatus(.forbidden));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireRedirectResponseStatus(.internal_server_error));
}

test "subsynchro only retries non-terminal malformed payload failures" {
    try std.testing.expect(shouldRetryPayloadError(error.UnexpectedEndOfInput, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.Canceled, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.OutOfMemory, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.RateLimited, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.ProviderAccessBlocked, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.UnsafeHttpTarget, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.InvalidDownloadUrl, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.UnexpectedEndOfInput, payload_max_attempts - 1));
}

test "subsynchro skips one ordinary redirect failure" {
    const Resolve = struct {
        fn redirect(_: *std.http.Client, allocator: Allocator, url: []const u8) anyerror![]const u8 {
            if (std.mem.indexOf(u8, url, "file-1") != null) return error.ConnectionResetByPeer;
            return allocator.dupe(u8, "http://www.subsynchro.com/archive.zip");
        }
    };
    var response = try parseSubtitlesJson(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "{\"status\":200,\"data\":[{\"filename\":\"one.srt\",\"titre\":\"Movie\",\"telechargement\":\"http://www.subsynchro.com/file-1\"},{\"filename\":\"two.srt\",\"titre\":\"Movie\",\"telechargement\":\"http://www.subsynchro.com/file-2\"}]}",
        .{ .title = "Movie", .year = null, .page_url = "unused" },
    );
    defer response.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try resolveSubtitleRedirectsUsing(Resolve.redirect, &client, &response);
    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    try std.testing.expectEqualStrings("two.srt", response.subtitles[0].filename);
}

test "live subsynchro movie search, listing and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subsynchro.com")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Inception");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .max_attempts = 2,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
