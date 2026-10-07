const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;
const site = "http://fansubs.ru";
const search_url = site ++ "/search.php";
const download_url = site ++ "/base.php";
pub const download_token_prefix = "fansubs-post:";

pub const SearchItem = struct {
    title: []const u8,
    media_id: []const u8,
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const normalized_query = try common.normalizeTitle(a, trimmed);
        if (normalized_query.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const payload = try std.fmt.allocPrint(a, "query={s}", .{encoded});
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;

        var response = try common.fetchBytes(self.client, a, search_url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{
                .{ .name = "accept-language", .value = "ru,en;q=0.8" },
            },
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .deadline_ms = deadline_ms,
        });

        if (isRateLimited(response.body)) {
            try sleepBeforeDeadline(deadline_ms, 5200);
            response = try common.fetchBytes(self.client, a, search_url, .{
                .method = .POST,
                .payload = payload,
                .content_type = "application/x-www-form-urlencoded",
                .accept = "text/html,application/xhtml+xml,*/*",
                .extra_headers = &[_]std.http.Header{
                    .{ .name = "accept-language", .value = "ru,en;q=0.8" },
                },
                .cache = false,
                .max_attempts = 2,
                .require_public_origin = true,
                .deadline_ms = deadline_ms,
            });
        }
        try requireSearchNotRateLimited(response.body);

        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateDetailsUrl(item.page_url, item.media_id);

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{
                .{ .name = "accept-language", .value = "ru,en;q=0.8" },
            },
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });

        const subtitles = try parseSubtitleRows(a, response.body);
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const subtitle_id = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        const id_encoded = try common.encodeUriComponent(allocator, subtitle_id);
        defer allocator.free(id_encoded);
        const payload = try std.fmt.allocPrint(allocator, "srt={s}&x=0&y=0", .{id_encoded});
        defer allocator.free(payload);
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;

        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            const response = fetchDownloadOnce(self.client, allocator, payload, deadline_ms) catch |err| {
                if (!shouldRetryDownloadError(err)) return err;
                if (attempt + 1 < 3) {
                    try sleepBeforeDeadline(deadline_ms, 250 * (attempt + 1));
                    continue;
                }
                return err;
            };
            requireDownloadStatus(response.status) catch |err| {
                allocator.free(response.body);
                return err;
            };
            if (common.looksLikeHtml(response.body)) {
                allocator.free(response.body);
                return error.UnexpectedResponseType;
            }
            return response;
        }
        return error.TruncatedResponse;
    }
};

fn shouldRetryDownloadError(err: anyerror) bool {
    return !common.mustNotRetryFetchError(err);
}

fn requireDownloadStatus(status: std.http.Status) !void {
    if (status == .too_many_requests) return error.RateLimited;
    if (status != .ok) return error.UnexpectedHttpStatus;
}

fn sleepBeforeDeadline(deadline_ms: i64, requested_ms: u64) !void {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;
    const remaining_ms: u64 = @intCast(deadline_ms -| now_ms);
    const delay_ms = @min(requested_ms, remaining_ms);
    try common.sleepMillisecondsCancelable(delay_ms);
    if (common.compatMilliTimestamp() >= deadline_ms) return error.Timeout;
}

fn fetchDownloadOnce(client: *std.http.Client, allocator: Allocator, payload: []const u8, deadline_ms: i64) !common.HttpResponse {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;

    const FetchTask = struct {
        fn run(result: *?common.HttpResponse, task_client: *std.http.Client, task_allocator: Allocator, task_payload: []const u8) !void {
            result.* = try fetchDownloadOnceUnbounded(task_client, task_allocator, task_payload);
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
    var owned_response: ?common.HttpResponse = null;
    defer {
        selection.cancelDiscard();
        if (owned_response) |response| allocator.free(response.body);
    }

    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(client.io, .{
        .raw = std.Io.Duration.fromMilliseconds(deadline_ms -| now_ms),
        .clock = .awake,
    }) };
    try selection.concurrent(.fetch, FetchTask.run, .{ &owned_response, client, allocator, payload });
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

fn fetchDownloadOnceUnbounded(client: *std.http.Client, allocator: Allocator, payload: []const u8) !common.HttpResponse {
    try validateDownloadPostUrl(download_url);
    const normalized = try common.normalizeUrlForFetch(allocator, download_url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

    var public_client: std.http.Client = undefined;
    try common.initPublicOriginClient(client, &public_client);
    defer public_client.deinit();
    const pinned_connection = try common.connectPinnedPublicHttpUrl(&public_client, allocator, normalized);
    pinned_connection.closing = true;

    var req = public_client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .handle_continue = false,
        .keep_alive = false,
        .connection = pinned_connection,
        .headers = .{
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .extra_headers = &[_]std.http.Header{
            .{ .name = "accept", .value = "application/octet-stream,application/zip,application/x-rar-compressed,text/plain,*/*" },
            .{ .name = "accept-language", .value = "ru,en;q=0.8" },
        },
    }) catch |err| {
        public_client.connection_pool.release(pinned_connection, public_client.io);
        return err;
    };
    defer req.deinit();
    errdefer req.connection.?.closing = true;

    const mutable_payload = try allocator.dupe(u8, payload);
    defer allocator.free(mutable_payload);
    req.sendBodyComplete(mutable_payload) catch |err| return common.normalizeRequestWriteError(&req, err);

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    var interim_count: usize = 0;
    while (response.head.status.class() == .informational) {
        if (response.head.status == .switching_protocols) return error.UnsupportedProtocolUpgrade;
        try validateRawDownloadResponseHead(response.head);
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    try validateRawDownloadResponseHead(response.head);
    const status = response.head.status;
    const body = try common.readStrictResponseBody(&req, &response, allocator, max_raw_response_bytes);
    errdefer allocator.free(body);
    return .{ .status = status, .body = body };
}

fn validateRawDownloadResponseHead(head: std.http.Client.Response.Head) !void {
    try common.validateResponseFraming(head);
}

fn providerUri(url: []const u8) !std.Uri {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
    return uri;
}

fn validateDetailsUrl(url: []const u8, expected_id: []const u8) !void {
    if (!isDecimalId(expected_id)) return error.InvalidDownloadUrl;
    const uri = try providerUri(url);
    if (uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/base.php")) return error.InvalidDownloadUrl;
    const query_component = uri.query orelse return error.InvalidDownloadUrl;
    const query = switch (query_component) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "id=";
    if (!std.mem.startsWith(u8, query, prefix) or
        !std.mem.eql(u8, query[prefix.len..], expected_id))
    {
        return error.InvalidDownloadUrl;
    }
}

fn validateDownloadPostUrl(url: []const u8) !void {
    const uri = try providerUri(url);
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/base.php")) return error.InvalidDownloadUrl;
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var cursor: usize = 0;

    while (findBaseIdLink(body, cursor)) |link| {
        cursor = link.next;
        if (!isDecimalId(link.id)) continue;
        if (seen.contains(link.id)) continue;

        const raw_title = std.mem.trim(u8, link.text, " \t\r\n");
        const visible = if (std.mem.indexOf(u8, raw_title, "<small")) |small|
            std.mem.trimEnd(u8, raw_title[0..small], " \t")
        else
            raw_title;
        const title = if (visible.len > 0 and std.unicode.utf8ValidateSlice(visible))
            try a.dupe(u8, visible)
        else
            try a.dupe(u8, query);
        const normalized = try common.normalizeTitle(a, title);
        if (normalized.len == 0 or
            (std.mem.indexOf(u8, normalized, wanted) == null and
                std.mem.indexOf(u8, wanted, normalized) == null))
        {
            continue;
        }
        const page_url = try std.fmt.allocPrint(a, "{s}/base.php?id={s}", .{ site, link.id });
        const item: SearchItem = .{
            .title = title,
            .media_id = try a.dupe(u8, link.id),
            .page_url = page_url,
        };
        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(a, item)
        else
            try partial.append(a, item);
        try seen.put(a, try a.dupe(u8, link.id), {});
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

const LinkMatch = struct {
    id: []const u8,
    text: []const u8,
    next: usize,
};

const BaseIdMarker = struct {
    pos: usize,
    marker: []const u8,
    closing_quote: ?u8,
};

fn findBaseIdLink(body: []const u8, from: usize) ?LinkMatch {
    var cursor = from;
    while (findBaseIdMarker(body, cursor)) |candidate| {
        const pos = candidate.pos;
        const marker = candidate.marker;
        cursor = pos + 1;
        const next_candidate = findBaseIdMarker(body, cursor);
        const candidate_end = if (next_candidate) |next| next.pos else body.len;

        const id_start = pos + marker.len;
        var id_end = id_start;
        while (id_end < body.len and std.ascii.isDigit(body[id_end])) : (id_end += 1) {}
        if (id_end == id_start) continue;
        if (id_end >= candidate_end) continue;
        if (candidate.closing_quote) |quote| {
            if (body[id_end] != quote) continue;
        } else if (!(std.ascii.isWhitespace(body[id_end]) or body[id_end] == '>')) {
            continue;
        }

        var gt = id_end;
        while (gt < candidate_end and body[gt] != '>') : (gt += 1) {}
        if (gt >= candidate_end) continue;

        const close_rel = std.mem.indexOf(u8, body[gt + 1 .. candidate_end], "</a>") orelse continue;
        const close = gt + 1 + close_rel;
        return .{
            .id = body[id_start..id_end],
            .text = body[gt + 1 .. close],
            .next = close + "</a>".len,
        };
    }
    return null;
}

fn findBaseIdMarker(body: []const u8, from: usize) ?BaseIdMarker {
    const markers = [_]struct { text: []const u8, closing_quote: ?u8 }{
        .{ .text = "href=\"base.php?id=", .closing_quote = '"' },
        .{ .text = "href=base.php?id=", .closing_quote = null },
    };
    var best_pos: ?usize = null;
    var best_marker: []const u8 = undefined;
    var best_closing_quote: ?u8 = null;
    for (markers) |marker| {
        if (std.mem.indexOfPos(u8, body, from, marker.text)) |pos| {
            if (best_pos == null or pos < best_pos.?) {
                best_pos = pos;
                best_marker = marker.text;
                best_closing_quote = marker.closing_quote;
            }
        }
    }
    const pos = best_pos orelse return null;
    return .{ .pos = pos, .marker = best_marker, .closing_quote = best_closing_quote };
}

fn parseSubtitleRows(allocator: Allocator, body: []const u8) ![]const SubtitleItem {
    var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var cursor: usize = 0;

    const marker = "name=\"srt\" value=\"";
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        const id_start = pos + marker.len;
        const next_marker = std.mem.indexOfPos(u8, body, id_start, marker);
        const candidate_end = next_marker orelse body.len;
        const id_end_rel = std.mem.indexOfScalar(u8, body[id_start..candidate_end], '"') orelse {
            cursor = candidate_end;
            continue;
        };
        const id_end = id_start + id_end_rel;
        const subtitle_id = body[id_start..id_end];
        cursor = id_end + 1;
        if (!isDecimalId(subtitle_id) or seen.contains(subtitle_id)) continue;
        try seen.put(allocator, try allocator.dupe(u8, subtitle_id), {});

        const form_end = std.mem.indexOfPos(u8, body, cursor, "</form>") orelse body.len;
        const form = body[pos..form_end];
        const format = parseRowFormat(form);
        const ext = if (std.ascii.findIgnoreCase(format, "ASS") != null or std.ascii.findIgnoreCase(format, "SSA") != null)
            "ass"
        else
            "srt";

        try out.append(allocator, .{
            .language_code = "ru",
            .filename = try std.fmt.allocPrint(allocator, "fansubs-{s}.{s}", .{ subtitle_id, ext }),
            .download_url = try makeDownloadToken(allocator, subtitle_id),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseRowFormat(form: []const u8) []const u8 {
    const marker = "<font";
    const pos = std.mem.indexOf(u8, form, marker) orelse return "SRT";
    const gt = std.mem.indexOfPos(u8, form, pos, ">") orelse return "SRT";
    const close = std.mem.indexOfPos(u8, form, gt + 1, "</font>") orelse return "SRT";
    return form[gt + 1 .. close];
}

pub fn makeDownloadToken(allocator: Allocator, subtitle_id: []const u8) ![]u8 {
    if (!isDecimalId(subtitle_id)) return error.InvalidDownloadUrl;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ download_token_prefix, subtitle_id });
}

pub fn parseDownloadToken(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const subtitle_id = value[download_token_prefix.len..];
    if (!isDecimalId(subtitle_id)) return null;
    return subtitle_id;
}

fn isDecimalId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isRateLimited(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "repeat the search in 5 seconds") != null) return true;
    // CP1251 bytes for "Повторите запрос через 5 секунд".
    return std.mem.indexOf(u8, body, "\xCF\xEE\xE2\xF2\xEE\xF0\xE8\xF2\xE5 \xE7\xE0\xEF\xF0\xEE\xF1 \xF7\xE5\xF0\xE5\xE7 5 \xF1\xE5\xEA\xF3\xED\xE4") != null;
}

fn requireSearchNotRateLimited(body: []const u8) !void {
    if (isRateLimited(body)) return error.RateLimited;
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

test "fansubs rejects non-provider page targets" {
    try validateDetailsUrl("http://fansubs.ru/base.php?id=368", "368");
    try validateDownloadPostUrl("http://fansubs.ru/base.php");
    for ([_][]const u8{
        "http://127.0.0.1/base.php?id=368",
        "http://fansubs.ru.example/base.php?id=368",
        "http://user@fansubs.ru/base.php?id=368",
        "https://fansubs.ru/base.php?id=368",
        "http://fansubs.ru/admin.php?id=368",
        "http://fansubs.ru/base.php?id=369",
        "http://fansubs.ru/base.php?id=368&next=/admin",
        "http://fansubs.ru/base.php?id=%33%36%38",
        "http://fansubs.ru/base.php?id=368#fragment",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateDetailsUrl(url, "368"));
    }
    try std.testing.expectError(error.InvalidDownloadUrl, validateDownloadPostUrl("http://fansubs.ru/base.php?id=368"));
}

test "fansubs download retry policy stops on deterministic transport errors" {
    try std.testing.expect(!shouldRetryDownloadError(error.PublicOriginProxyUnsupported));
    try std.testing.expect(!shouldRetryDownloadError(error.InvalidDownloadUrl));
    try std.testing.expect(!shouldRetryDownloadError(error.ResponseTooLarge));
    try std.testing.expect(!shouldRetryDownloadError(error.Canceled));
    try std.testing.expect(!shouldRetryDownloadError(error.OutOfMemory));
    try std.testing.expect(!shouldRetryDownloadError(error.Timeout));
    try std.testing.expect(shouldRetryDownloadError(error.ConnectionResetByPeer));
}

test "fansubs raw download classifies rate limits" {
    try requireDownloadStatus(.ok);
    try std.testing.expectError(error.RateLimited, requireDownloadStatus(.too_many_requests));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireDownloadStatus(.service_unavailable));
}

test "fansubs raw download rejects an expired deadline before I/O" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(
        error.Timeout,
        fetchDownloadOnce(&client, std.testing.allocator, "srt=1&x=0&y=0", common.compatMilliTimestamp()),
    );
}

test "fansubs retry sleep rejects an expired shared deadline" {
    try std.testing.expectError(
        error.Timeout,
        sleepBeforeDeadline(common.compatMilliTimestamp(), 5200),
    );
}

test "fansubs rejects a rate-limit body after retry" {
    try std.testing.expectError(
        error.RateLimited,
        requireSearchNotRateLimited("Please repeat the search in 5 seconds"),
    );
    try std.testing.expectError(
        error.RateLimited,
        requireSearchNotRateLimited("\xCF\xEE\xE2\xF2\xEE\xF0\xE8\xF2\xE5 \xE7\xE0\xEF\xF0\xEE\xF1 \xF7\xE5\xF0\xE5\xE7 5 \xF1\xE5\xEA\xF3\xED\xE4"),
    );
    try requireSearchNotRateLimited("<html><body>search results</body></html>");
}

test "fansubs parses search and subtitle rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var search = try parseSearchHtml(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<a href=\"base.php?id=368\">Spirited Away <small>(movie)</small></a>",
        "Spirited Away",
    );
    defer search.deinit();
    try std.testing.expectEqual(@as(usize, 1), search.items.len);
    try std.testing.expectEqualStrings("Spirited Away", search.items[0].title);

    const rows = try parseSubtitleRows(
        a,
        "<form method=\"post\" action=\"base.php\"><input type=\"hidden\" name=\"srt\" value=\"759\"><tr><td><b>Movie</b></td><td><a><font>SRT|SMI</font></a></td></tr></form>",
    );
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("fansubs-post:759", rows[0].download_url);
}

test "fansubs punctuation-only normalized query yields no search results" {
    var response = try parseSearchHtml(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<a href=\"base.php?id=368\">Spirited Away</a>",
        "... !!! ---",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "fansubs recovers after an unterminated search result" {
    var search = try parseSearchHtml(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<a href=\"base.php?id=12 <a href=\"base.php?id=368\">Spirited Away</a>",
        "Spirited Away",
    );
    defer search.deinit();
    try std.testing.expectEqual(@as(usize, 1), search.items.len);
    try std.testing.expectEqualStrings("368", search.items[0].media_id);
}

test "fansubs unrelated duplicate does not suppress a later matching result" {
    var search = try parseSearchHtml(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<a href=\"base.php?id=368\">Completely Unrelated</a>" ++
            "<a href=\"base.php?id=368\">Spirited Away</a>",
        "Spirited Away",
    );
    defer search.deinit();

    try std.testing.expectEqual(@as(usize, 1), search.items.len);
    try std.testing.expectEqualStrings("Spirited Away", search.items[0].title);
    try std.testing.expectEqualStrings("368", search.items[0].media_id);
}

test "fansubs ignores non-canonical search result IDs" {
    var search = try parseSearchHtml(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<a href=\"base.php?id=368evil\">Wrong</a>" ++
            "<a href=base.php?id=0>Zero</a>" ++
            "<a href=\"base.php?id=369\">Spirited Away</a>",
        "Spirited Away",
    );
    defer search.deinit();
    try std.testing.expectEqual(@as(usize, 1), search.items.len);
    try std.testing.expectEqualStrings("369", search.items[0].media_id);
}

test "fansubs skips malformed subtitle IDs and constructs only decimal tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseSubtitleRows(
        arena.allocator(),
        "<form><input name=\"srt\" value=\"unterminated " ++
            "<form><input name=\"srt\" value=\"759/../../admin\"><font>SRT</font></form>" ++
            "<form><input name=\"srt\" value=\"759?next\"><font>SRT</font></form>" ++
            "<form><input name=\"srt\" value=\"759\"><font>SRT</font></form>",
    );
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("fansubs-post:759", rows[0].download_url);

    for ([_][]const u8{ "", "abc", "1/2", "1?next", "1#fragment", "1\n2" }) |invalid| {
        try std.testing.expectError(error.InvalidDownloadUrl, makeDownloadToken(std.testing.allocator, invalid));
    }
    const token = try makeDownloadToken(std.testing.allocator, "123");
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("fansubs-post:123", token);
}

test "fansubs raw download transport rejects ambiguous response framing" {
    const te_and_cl = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
    );
    try std.testing.expectError(
        error.AmbiguousHttpFraming,
        validateRawDownloadResponseHead(te_and_cl),
    );

    const duplicate_length = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
    );
    try std.testing.expectError(
        error.AmbiguousHttpFraming,
        validateRawDownloadResponseHead(duplicate_length),
    );
}

test "live fansubs movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "fansubs.ru")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Spirited Away");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subs = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subs.deinit();
    try std.testing.expect(movie_subs.subtitles.len > 0);
    const movie_dl = try scraper.fetchDownloadByToken(std.testing.allocator, movie_subs.subtitles[0].download_url);
    defer std.testing.allocator.free(movie_dl.body);
    try std.testing.expect(movie_dl.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, movie_dl.body, "Rar!") or std.mem.startsWith(u8, movie_dl.body, "PK"));

    try common.sleepMillisecondsCancelable(5200);
    var tv = try scraper.search("Death Note");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    var tv_subs = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subs.deinit();
    try std.testing.expect(tv_subs.subtitles.len > 0);
    const tv_dl = try scraper.fetchDownloadByToken(std.testing.allocator, tv_subs.subtitles[tv_subs.subtitles.len - 1].download_url);
    defer std.testing.allocator.free(tv_dl.body);
    try std.testing.expect(tv_dl.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, tv_dl.body, "Rar!") or std.mem.startsWith(u8, tv_dl.body, "PK"));
}
