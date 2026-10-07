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
        const wanted = try common.normalizeTitle(self.allocator, trimmed);
        defer self.allocator.free(wanted);
        if (wanted.len == 0) return .{ .arena = std.heap.ArenaAllocator.init(self.allocator), .items = &.{} };
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;

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
                .deadline_ms = deadline_ms,
            });
            const parsed = parseSearchJson(common.takeArena(&arena), response.body, trimmed) catch |err| {
                if (!shouldRetryPayloadError(err, payload_attempt)) return err;
                try sleepBeforeDeadline(deadline_ms, payload_retry_delay_ms);
                continue;
            };
            return parsed;
        }
        unreachable;
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        try validateListingEndpoint(item.page_url);
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;
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
                    .deadline_ms = deadline_ms,
                });
                const value = parseSubtitlesJson(common.takeArena(&arena), response.body, item) catch |err| {
                    if (!shouldRetryPayloadError(err, payload_attempt)) return err;
                    try sleepBeforeDeadline(deadline_ms, payload_retry_delay_ms);
                    continue;
                };
                break :parsed_response value;
            }
            unreachable;
        };
        errdefer parsed.deinit();
        try resolveSubtitleRedirectsUsing(resolveDownloadRedirect, self.client, &parsed, deadline_ms);
        return parsed;
    }
};

fn resolveSubtitleRedirectsUsing(
    comptime resolve: anytype,
    client: *std.http.Client,
    parsed: *SubtitlesResponse,
    deadline_ms: i64,
) !void {
    const parsed_allocator = parsed.arena.allocator();
    var resolved: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    for (parsed.subtitles) |subtitle| {
        const direct_url = resolve(client, parsed_allocator, subtitle.download_url, deadline_ms) catch |err| {
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

fn sleepBeforeDeadline(deadline_ms: i64, requested_ms: u64) !void {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;
    const remaining_ms: u64 = @intCast(deadline_ms -| now_ms);
    const delay_ms = @min(requested_ms, remaining_ms);
    try common.sleepMillisecondsCancelable(delay_ms);
    if (common.compatMilliTimestamp() >= deadline_ms) return error.Timeout;
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
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };
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
        const partial_match = common.normalizedTitlesRelated(local_normalized, wanted) or
            (original_normalized.len > 0 and common.normalizedTitlesRelated(original_normalized, wanted));
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
        errdefer a.free(download_url);
        try validateInitialDownloadEndpoint(download_url);
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
        _ = try providerUri(normalized);
        return normalized;
    }
    errdefer allocator.free(absolute);
    _ = try providerUri(absolute);
    return absolute;
}

fn resolveDownloadRedirect(client: *std.http.Client, allocator: Allocator, url: []const u8, deadline_ms: i64) ![]const u8 {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;

    const FetchTask = struct {
        fn run(result: *?[]const u8, task_client: *std.http.Client, task_allocator: Allocator, task_url: []const u8) !void {
            result.* = try resolveDownloadRedirectUnbounded(task_client, task_allocator, task_url);
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
    var owned_url: ?[]const u8 = null;
    defer {
        selection.cancelDiscard();
        if (owned_url) |value| allocator.free(value);
    }

    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(client.io, .{
        .raw = std.Io.Duration.fromMilliseconds(deadline_ms -| now_ms),
        .clock = .awake,
    }) };
    try selection.concurrent(.fetch, FetchTask.run, .{ &owned_url, client, allocator, url });
    try selection.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, client.io });

    switch (try selection.await()) {
        .fetch => |result| {
            try result;
            const value = owned_url orelse return error.MissingHttpResponse;
            owned_url = null;
            return value;
        },
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}

fn resolveDownloadRedirectUnbounded(client: *std.http.Client, allocator: Allocator, url: []const u8) ![]const u8 {
    try validateInitialDownloadEndpoint(url);
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
        .handle_continue = false,
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
    req.sendBodiless() catch |err| return common.normalizeRequestWriteError(&req, err);

    var head_buffer: [16 * 1024]u8 = undefined;
    var response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    var interim_count: usize = 0;
    while (response.head.status.class() == .informational) {
        if (response.head.status == .switching_protocols) return error.UnsupportedProtocolUpgrade;
        try validateRawRedirectResponseHead(response.head);
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    try validateRawRedirectResponseHead(response.head);
    try requireRedirectResponseStatus(response.head.status);
    if (response.head.status == .ok) return try allocator.dupe(u8, url);

    const location = try extractHeader(allocator, response.head.bytes, "location") orelse return error.MissingField;
    defer allocator.free(location);
    return try resolveRedirectLocation(allocator, location);
}

fn validateRawRedirectResponseHead(head: std.http.Client.Response.Head) !void {
    try common.validateResponseFraming(head);
}

fn resolveRedirectLocation(allocator: Allocator, location: []const u8) ![]const u8 {
    const normalized_location = try common.normalizeUrlForFetch(allocator, location);
    defer allocator.free(normalized_location);

    var owned_location_for_resolve: ?[]u8 = null;
    defer if (owned_location_for_resolve) |value| allocator.free(value);

    const location_for_resolve: []const u8 = if (std.mem.startsWith(u8, normalized_location, "http://") or
        std.mem.startsWith(u8, normalized_location, "https://") or
        std.mem.startsWith(u8, normalized_location, "/"))
        normalized_location
    else prefixed: {
        const value = try std.fmt.allocPrint(allocator, "/{s}", .{normalized_location});
        owned_location_for_resolve = value;
        break :prefixed value;
    };
    const resolved = try common.resolveUrl(allocator, site, location_for_resolve);
    defer allocator.free(resolved);
    const normalized = try normalizeProviderUrl(allocator, resolved);
    errdefer allocator.free(normalized);
    try validateFinalArchiveEndpoint(normalized);
    return normalized;
}

fn requireRedirectResponseStatus(status: std.http.Status) !void {
    if (status == .too_many_requests) return error.RateLimited;
    if (status == .unauthorized or status == .forbidden) return error.ProviderAccessBlocked;
    if (status != .ok and !common.isRedirectStatus(status)) return error.UnexpectedHttpStatus;
}

fn providerUri(url: []const u8) !std.Uri {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    return uri;
}

fn uriPath(uri: std.Uri) []const u8 {
    return switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
}

fn uriQuery(uri: std.Uri) ?[]const u8 {
    const component = uri.query orelse return null;
    return switch (component) {
        .raw, .percent_encoded => |value| value,
    };
}

fn validateListingEndpoint(url: []const u8) !void {
    const uri = try providerUri(url);
    if (uri.fragment != null or !std.mem.eql(u8, uriPath(uri), "/include/ajax/subMarin.php"))
        return error.InvalidDownloadUrl;
    const query = uriQuery(uri) orelse return error.InvalidDownloadUrl;
    const title_prefix = "title=";
    const year_marker = "&year=";
    if (!std.mem.startsWith(u8, query, title_prefix)) return error.InvalidDownloadUrl;
    const marker_index = std.mem.indexOf(u8, query[title_prefix.len..], year_marker) orelse
        return error.InvalidDownloadUrl;
    const title_end = title_prefix.len + marker_index;
    const title = query[title_prefix.len..title_end];
    const year = query[title_end + year_marker.len ..];
    if (!isCanonicalEncodedQueryValue(title) or std.mem.indexOfScalar(u8, year, '&') != null)
        return error.InvalidDownloadUrl;
    if (year.len != 0 and !isCanonicalSignedDecimal(year)) return error.InvalidDownloadUrl;
}

fn validateInitialDownloadEndpoint(url: []const u8) !void {
    const uri = try providerUri(url);
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = uriPath(uri);
    const prefix = "/telecharger-le-fichier-";
    const suffix = ".html";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix))
        return error.InvalidDownloadUrl;
    const id_text = path[prefix.len .. path.len - suffix.len];
    if (!isCanonicalPositiveDecimal(id_text)) return error.InvalidDownloadUrl;
}

fn validateFinalArchiveEndpoint(url: []const u8) !void {
    const uri = try providerUri(url);
    if (uri.query != null or uri.fragment != null or !isSafeArchivePath(uriPath(uri)))
        return error.InvalidDownloadUrl;
}

fn isCanonicalPositiveDecimal(value: []const u8) bool {
    if (value.len == 0 or value.len > 20 or value[0] == '0') return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    _ = std.fmt.parseInt(u64, value, 10) catch return false;
    return true;
}

fn isCanonicalSignedDecimal(value: []const u8) bool {
    if (value.len == 0 or value.len > 20) return false;
    const digits = if (value[0] == '-') value[1..] else value;
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0') or
        (value[0] == '-' and std.mem.eql(u8, digits, "0")))
    {
        return false;
    }
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return false;
    _ = std.fmt.parseInt(i64, value, 10) catch return false;
    return true;
}

fn isCanonicalEncodedQueryValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 4096) return false;
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            index += 1;
            continue;
        }
        if (byte != '%' or value.len - index < 3) return false;
        const high = value[index + 1];
        const low = value[index + 2];
        if (!isUpperHexDigit(high) or !isUpperHexDigit(low)) return false;
        const decoded = (std.fmt.charToDigit(high, 16) catch return false) * 16 +
            (std.fmt.charToDigit(low, 16) catch return false);
        const decoded_byte: u8 = @intCast(decoded);
        if (std.ascii.isAlphanumeric(decoded_byte) or decoded_byte == '-' or
            decoded_byte == '_' or decoded_byte == '.' or decoded_byte == '~')
        {
            return false;
        }
        index += 3;
    }
    return true;
}

fn isUpperHexDigit(byte: u8) bool {
    return std.ascii.isDigit(byte) or (byte >= 'A' and byte <= 'F');
}

fn isSafeArchivePath(path: []const u8) bool {
    if (path.len < "/a.zip".len or path.len > 4096 or path[0] != '/' or
        !std.ascii.endsWithIgnoreCase(path, ".zip"))
    {
        return false;
    }

    var index: usize = 1;
    var segment_len: usize = 0;
    var segment_all_dots = true;
    while (index < path.len) {
        if (path[index] == '/') {
            if (segment_len == 0 or (segment_all_dots and segment_len <= 2)) return false;
            segment_len = 0;
            segment_all_dots = true;
            index += 1;
            continue;
        }

        const byte = if (path[index] == '%') blk: {
            if (path.len - index < 3) return false;
            const high = std.fmt.charToDigit(path[index + 1], 16) catch return false;
            const low = std.fmt.charToDigit(path[index + 2], 16) catch return false;
            index += 3;
            break :blk @as(u8, @intCast(high * 16 + low));
        } else blk: {
            const raw = path[index];
            index += 1;
            break :blk raw;
        };
        if (byte < 0x20 or byte == 0x7f or byte == '%' or byte == '/' or byte == '\\' or
            byte == '?' or byte == '#')
        {
            return false;
        }
        segment_len += 1;
        if (byte != '.') segment_all_dots = false;
    }
    return segment_len != 0 and !(segment_all_dots and segment_len <= 2);
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

test "subsynchro accepts only the canonical listing route" {
    try validateListingEndpoint(
        site ++ "/include/ajax/subMarin.php?title=The%20Matrix&year=1999",
    );
    try validateListingEndpoint(
        site ++ "/include/ajax/subMarin.php?title=Inception&year=",
    );

    for ([_][]const u8{
        site ++ "/admin?title=Inception&year=2010",
        site ++ "/include/ajax/subMarin.php",
        site ++ "/include/ajax/subMarin.php?year=2010&title=Inception",
        site ++ "/include/ajax/subMarin.php?title=&year=2010",
        site ++ "/include/ajax/subMarin.php?title=%49nception&year=2010",
        site ++ "/include/ajax/subMarin.php?title=Inception&year=-0",
        site ++ "/include/ajax/subMarin.php?title=Inception&year=2010&admin=1",
        site ++ "/include/ajax/subMarin.php?title=Inception&year=2010#result",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateListingEndpoint(url));
    }
}

test "subsynchro separates initial download and final archive routes" {
    try validateInitialDownloadEndpoint(site ++ "/telecharger-le-fichier-42.html");
    try validateFinalArchiveEndpoint(site ++ "/archive.zip");
    try validateFinalArchiveEndpoint(site ++ "/uploads/subtitles/movie.ZIP");

    for ([_][]const u8{
        site ++ "/admin",
        site ++ "/telecharger-le-fichier-0.html",
        site ++ "/telecharger-le-fichier-01.html",
        site ++ "/telecharger-le-fichier-42.html?download=1",
        site ++ "/telecharger-le-fichier-42.html/extra",
    }) |url| {
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            validateInitialDownloadEndpoint(url),
        );
    }

    for ([_][]const u8{
        site ++ "/admin",
        site ++ "/archive.rar",
        site ++ "/archive.zip?token=secret",
        site ++ "/archive.zip#fragment",
        site ++ "/uploads/../archive.zip",
        site ++ "/uploads/%2e%2e/archive.zip",
        site ++ "/uploads%2Farchive.zip",
        site ++ "/uploads%252Farchive.zip",
        site ++ "/uploads%5Carchive.zip",
    }) |url| {
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            validateFinalArchiveEndpoint(url),
        );
    }
}

test "subsynchro classifies redirect response failures" {
    try requireRedirectResponseStatus(.ok);
    try requireRedirectResponseStatus(.moved_permanently);
    try std.testing.expectError(error.RateLimited, requireRedirectResponseStatus(.too_many_requests));
    try std.testing.expectError(error.ProviderAccessBlocked, requireRedirectResponseStatus(.unauthorized));
    try std.testing.expectError(error.ProviderAccessBlocked, requireRedirectResponseStatus(.forbidden));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireRedirectResponseStatus(.internal_server_error));
}

test "subsynchro HEAD probe rejects an expired deadline before I/O" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(
        error.Timeout,
        resolveDownloadRedirect(&client, std.testing.allocator, site ++ "/archive.zip", common.compatMilliTimestamp()),
    );
}

test "subsynchro payload retry sleep rejects an expired shared deadline" {
    try std.testing.expectError(
        error.Timeout,
        sleepBeforeDeadline(common.compatMilliTimestamp(), payload_retry_delay_ms),
    );
}

test "subsynchro frees a prefixed relative redirect location" {
    const resolved = try resolveRedirectLocation(std.testing.allocator, "archive.zip");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(site ++ "/archive.zip", resolved);
}

test "subsynchro accepts mixed-case absolute redirect schemes" {
    const resolved = try resolveRedirectLocation(std.testing.allocator, "HtTp://www.subsynchro.com/archive.zip");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(site ++ "/archive.zip", resolved);
}

test "subsynchro only retries non-terminal malformed payload failures" {
    try std.testing.expect(shouldRetryPayloadError(error.UnexpectedEndOfInput, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.Canceled, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.OutOfMemory, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.RateLimited, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.ProviderAccessBlocked, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.UnsafeHttpTarget, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.InvalidDownloadUrl, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.Timeout, 0));
    try std.testing.expect(!shouldRetryPayloadError(error.UnexpectedEndOfInput, payload_max_attempts - 1));
}

test "subsynchro skips one ordinary redirect failure" {
    const Resolve = struct {
        fn redirect(_: *std.http.Client, allocator: Allocator, url: []const u8, _: i64) anyerror![]const u8 {
            if (std.mem.indexOf(u8, url, "fichier-1") != null) return error.ConnectionResetByPeer;
            return allocator.dupe(u8, "http://www.subsynchro.com/archive.zip");
        }
    };
    var response = try parseSubtitlesJson(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "{\"status\":200,\"data\":[{\"filename\":\"one.srt\",\"titre\":\"Movie\",\"telechargement\":\"http://www.subsynchro.com/telecharger-le-fichier-1.html\"},{\"filename\":\"two.srt\",\"titre\":\"Movie\",\"telechargement\":\"http://www.subsynchro.com/telecharger-le-fichier-2.html\"}]}",
        .{ .title = "Movie", .year = null, .page_url = "unused" },
    );
    defer response.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try resolveSubtitleRedirectsUsing(Resolve.redirect, &client, &response, common.compatMilliTimestamp() +| common.default_fetch_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    try std.testing.expectEqualStrings("two.srt", response.subtitles[0].filename);
}

test "subsynchro raw redirect transport rejects ambiguous response framing" {
    for ([_][]const u8{
        "HTTP/1.1 302 Found\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\nLocation: /archive.zip\r\n\r\n",
        "HTTP/1.1 302 Found\r\nContent-Length: 1\r\nContent-Length: 1\r\nLocation: /archive.zip\r\n\r\n",
    }) |raw_head| {
        const head = try std.http.Client.Response.Head.parse(raw_head);
        try std.testing.expectError(error.AmbiguousHttpFraming, validateRawRedirectResponseHead(head));
    }
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
