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
        const encoded = try common.encodeUriComponent(a, trimmed);
        const payload = try std.fmt.allocPrint(a, "query={s}", .{encoded});

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
        });

        if (isRateLimited(response.body)) {
            try common.sleepMillisecondsCancelable(5200);
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
            });
        }
        try requireSearchNotRateLimited(response.body);

        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(item.page_url);

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

        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            const response = fetchDownloadOnce(self.client, allocator, payload) catch |err| {
                if (!shouldRetryDownloadError(err)) return err;
                if (attempt + 1 < 3) {
                    try common.sleepMillisecondsCancelable(250 * (attempt + 1));
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

fn fetchDownloadOnce(client: *std.http.Client, allocator: Allocator, payload: []const u8) !common.HttpResponse {
    try validateProviderUrl(download_url);
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
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    const status = response.head.status;
    const expected_length = response.head.content_length;

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = readBoundedBody(allocator, reader, max_raw_response_bytes) catch |err| {
        if (err == error.ReadFailed) {
            if (response.bodyErr()) |body_err| return body_err;
            return common.normalizeRequestReadError(&req, err);
        }
        return err;
    };
    errdefer allocator.free(body);
    switch (req.reader.state) {
        .body_remaining_content_length => |left| if (left != 0) return error.HttpBodyTruncated,
        .body_remaining_chunk_len => return error.HttpChunkTruncated,
        else => {},
    }
    if (expected_length) |expected| {
        if (body.len != expected) {
            return error.TruncatedResponse;
        }
    }
    return .{ .status = status, .body = body };
}

fn validateProviderUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const wanted = try common.normalizeTitle(a, query);

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var cursor: usize = 0;

    while (findBaseIdLink(body, cursor)) |link| {
        cursor = link.next;
        if (seen.contains(link.id)) continue;
        try seen.put(a, try a.dupe(u8, link.id), {});

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

fn findBaseIdLink(body: []const u8, from: usize) ?LinkMatch {
    const markers = [_][]const u8{ "href=\"base.php?id=", "href=base.php?id=" };
    var best_pos: ?usize = null;
    var best_marker: []const u8 = undefined;
    for (markers) |marker| {
        if (std.mem.indexOfPos(u8, body, from, marker)) |pos| {
            if (best_pos == null or pos < best_pos.?) {
                best_pos = pos;
                best_marker = marker;
            }
        }
    }
    const pos = best_pos orelse return null;
    const id_start = pos + best_marker.len;
    var id_end = id_start;
    while (id_end < body.len and std.ascii.isDigit(body[id_end])) : (id_end += 1) {}
    if (id_end == id_start) return null;

    var gt = id_end;
    while (gt < body.len and body[gt] != '>') : (gt += 1) {}
    if (gt >= body.len) return null;
    const close = std.mem.indexOfPos(u8, body, gt + 1, "</a>") orelse return null;
    return .{
        .id = body[id_start..id_end],
        .text = body[gt + 1 .. close],
        .next = close + "</a>".len,
    };
}

fn parseSubtitleRows(allocator: Allocator, body: []const u8) ![]const SubtitleItem {
    var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var cursor: usize = 0;

    const marker = "name=\"srt\" value=\"";
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        const id_start = pos + marker.len;
        const id_end_rel = std.mem.indexOfScalar(u8, body[id_start..], '"') orelse break;
        const subtitle_id = body[id_start .. id_start + id_end_rel];
        cursor = id_start + id_end_rel + 1;
        if (subtitle_id.len == 0 or seen.contains(subtitle_id)) continue;
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
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ download_token_prefix, subtitle_id });
}

pub fn parseDownloadToken(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const subtitle_id = value[download_token_prefix.len..];
    if (subtitle_id.len == 0) return null;
    for (subtitle_id) |c| if (!std.ascii.isDigit(c)) return null;
    return subtitle_id;
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
    try validateProviderUrl("http://fansubs.ru/base.php?id=368");
    for ([_][]const u8{
        "http://127.0.0.1/base.php?id=368",
        "http://fansubs.ru.example/base.php?id=368",
        "http://user@fansubs.ru/base.php?id=368",
        "https://fansubs.ru/base.php?id=368",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url));
    }
}

test "fansubs download retry policy stops on deterministic transport errors" {
    try std.testing.expect(!shouldRetryDownloadError(error.PublicOriginProxyUnsupported));
    try std.testing.expect(!shouldRetryDownloadError(error.InvalidDownloadUrl));
    try std.testing.expect(!shouldRetryDownloadError(error.ResponseTooLarge));
    try std.testing.expect(!shouldRetryDownloadError(error.Canceled));
    try std.testing.expect(!shouldRetryDownloadError(error.OutOfMemory));
    try std.testing.expect(shouldRetryDownloadError(error.ConnectionResetByPeer));
}

test "fansubs raw download classifies rate limits" {
    try requireDownloadStatus(.ok);
    try std.testing.expectError(error.RateLimited, requireDownloadStatus(.too_many_requests));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireDownloadStatus(.service_unavailable));
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
