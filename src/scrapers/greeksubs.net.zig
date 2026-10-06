const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://greeksubs.net";
const search_url = site ++ "/en/search";

pub const download_token_prefix = "greeksubs-session:";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    id: []const u8,
    language_code: ?[]const u8,
    filename: []const u8,
    download_url: []const u8,
};

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchUsing(common.fetchBytes, query);
    }

    fn searchUsing(self: *Scraper, comptime fetch: anytype, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const payload = try std.fmt.allocPrint(a, "searchval={s}&searchtype=all", .{encoded});
        const response = try fetch(self.client, a, search_url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
        });
        if (response.status == .too_many_requests) return error.RateLimited;
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemUsing(common.fetchBytes, item);
    }

    fn fetchSubtitlesBySearchItemUsing(self: *Scraper, comptime fetch: anytype, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(item.page_url);

        const response = try fetch(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
        });
        if (response.status == .too_many_requests) return error.RateLimited;
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        try collectSubtitleRows(a, response.body, item.page_url, &subtitles, &seen);

        if (subtitles.items.len == 0 and item.media_kind == .tv) {
            var parsed = try common.parseHtmlStable(a, response.body);
            var links = parsed.doc.queryAll("a[href*='/en/view/']");
            var followed: usize = 0;
            var seen_pages = std.StringHashMapUnmanaged(void).empty;
            while (links.next()) |link| {
                if (followed >= 8 or subtitles.items.len >= 24) break;
                const href = common.getAttributeValueSafe(link, "href") orelse continue;
                const text = try common.innerTextTrimmedOwned(a, link);
                if (std.ascii.findIgnoreCase(text, "Season") == null) continue;
                const page_url = try common.resolveUrl(a, site, href);
                validateProviderUrl(page_url) catch continue;
                if (seen_pages.contains(page_url)) continue;
                try seen_pages.put(a, page_url, {});
                followed += 1;

                const child = fetch(self.client, a, page_url, .{
                    .accept = "text/html,application/xhtml+xml,*/*",
                    .cache = false,
                    .max_attempts = 2,
                    .retry_on_429 = false,
                    .allow_non_ok = true,
                    .require_public_origin = true,
                }) catch |err| {
                    if (common.mustPropagateOptionalFailure(err)) return err;
                    continue;
                };
                if (child.status == .too_many_requests) return error.RateLimited;
                if (child.status != .ok) continue;
                try collectSubtitleRows(a, child.body, page_url, &subtitles, &seen);
            }
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateProviderUrl(parts.page_url);
        var page = try fetchRaw(self.client, allocator, parts.page_url, &.{});
        defer page.deinit(allocator);
        if (page.status == .too_many_requests) return error.RateLimited;
        if (page.status != .ok) return error.UnexpectedHttpStatus;
        const cookie = page.cookie orelse return error.SessionExpired;

        const sec_code = parseSecCode(page.body) orelse return error.MissingField;
        if (std.mem.indexOf(u8, page.body, parts.subtitle_id) == null) return error.MissingField;

        const url = try std.fmt.allocPrint(allocator, "{s}/dll/{s}/0/{s}", .{ site, parts.subtitle_id, sec_code });
        defer allocator.free(url);
        const headers = [_]std.http.Header{
            .{ .name = "cookie", .value = cookie },
            .{ .name = "referer", .value = parts.page_url },
            .{ .name = "accept", .value = "application/octet-stream,text/plain,*/*" },
        };
        const download = try fetchRaw(self.client, allocator, url, &headers);
        defer if (download.cookie) |value| allocator.free(value);
        if (download.status != .ok) {
            allocator.free(download.body);
            if (download.status == .too_many_requests) return error.RateLimited;
            return error.UnexpectedHttpStatus;
        }
        return .{ .status = download.status, .body = download.body };
    }
};

fn collectSubtitleRows(
    allocator: Allocator,
    body: []const u8,
    page_url: []const u8,
    subtitles: *std.ArrayListUnmanaged(SubtitleItem),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    var parsed = try common.parseHtmlStable(allocator, body);
    var rows = parsed.doc.queryAll("table tbody tr");
    while (rows.next()) |row| {
        const button = row.queryOne("button[onclick]") orelse continue;
        const onclick = common.getAttributeValueSafe(button, "onclick") orelse continue;
        const id = parseDownloadId(onclick) orelse continue;
        if (seen.contains(id)) continue;
        try seen.put(allocator, try allocator.dupe(u8, id), {});

        const language_code = if (row.queryOne("img[alt]")) |img|
            try common.dupOptional(allocator, common.getAttributeValueSafe(img, "alt"))
        else
            null;
        const filename_base = try tableCellText(allocator, row, 6) orelse continue;
        if (filename_base.len == 0) continue;
        const filename = if (hasKnownDownloadExtension(filename_base))
            filename_base
        else
            try std.fmt.allocPrint(allocator, "{s}.srt", .{filename_base});

        try subtitles.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .language_code = language_code,
            .filename = filename,
            .download_url = try makeDownloadToken(allocator, id, page_url),
        });
    }
}

const RawResponse = common.RawResponse;

fn fetchRaw(client: *std.http.Client, allocator: Allocator, url: []const u8, extra_headers: []const std.http.Header) !RawResponse {
    try validateProviderUrl(url);
    try common.validateHttpHeaders(extra_headers);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

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
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra_headers,
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
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    const status = response.head.status;
    const cookie = try common.extractPhpSessionCookie(allocator, response.head.bytes);
    errdefer if (cookie) |value| allocator.free(value);

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

    return .{
        .status = status,
        .body = body,
        .cookie = cookie,
    };
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
    var parsed = try common.parseHtmlStable(a, body);

    const normalized_query = try common.normalizeTitle(a, query);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var anchors = parsed.doc.queryAll("a[href*='/en/view/']");
    while (anchors.next()) |anchor| {
        const h3 = anchor.queryOne("h3") orelse continue;
        const title = try common.innerTextTrimmedOwned(a, h3);
        if (title.len == 0) continue;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const media_kind = try cardMediaKind(a, anchor) orelse continue;
        const normalized_title = try common.normalizeTitle(a, title);
        if (normalized_title.len == 0) continue;
        if (std.mem.indexOf(u8, normalized_title, normalized_query) == null and
            std.mem.indexOf(u8, normalized_query, normalized_title) == null) continue;

        const page_url = try common.resolveUrl(a, site, href);
        validateProviderUrl(page_url) catch continue;
        const item: SearchItem = .{
            .title = title,
            .year = parseYear(try common.innerTextTrimmedOwned(a, anchor)),
            .media_kind = media_kind,
            .page_url = page_url,
        };
        if (std.mem.eql(u8, normalized_title, normalized_query)) {
            try exact.append(a, item);
        } else {
            try partial.append(a, item);
        }
    }

    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    try out.appendSlice(a, exact.items);
    try out.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try out.toOwnedSlice(a) });
}

fn cardMediaKind(allocator: Allocator, anchor: anytype) !?MediaKind {
    var spans = anchor.queryAll("span");
    while (spans.next()) |span| {
        const text = try common.innerTextTrimmedOwned(allocator, span);
        if (std.ascii.eqlIgnoreCase(text, "Movie")) return .movie;
        if (std.ascii.eqlIgnoreCase(text, "Series")) return .tv;
    }
    return null;
}

fn tableCellText(allocator: Allocator, row: anytype, wanted: usize) !?[]const u8 {
    var cells = row.queryAll("td");
    var idx: usize = 0;
    while (cells.next()) |cell| : (idx += 1) {
        if (idx == wanted) return try common.innerTextTrimmedOwned(allocator, cell);
    }
    return null;
}

fn parseDownloadId(onclick: []const u8) ?[]const u8 {
    const marker = "downloadMe('";
    const start = std.mem.indexOf(u8, onclick, marker) orelse return null;
    const tail = onclick[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, tail, '\'') orelse return null;
    return tail[0..end];
}

fn hasKnownDownloadExtension(value: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(value, ".srt") or
        std.ascii.endsWithIgnoreCase(value, ".ass") or
        std.ascii.endsWithIgnoreCase(value, ".ssa") or
        std.ascii.endsWithIgnoreCase(value, ".vtt") or
        std.ascii.endsWithIgnoreCase(value, ".sub") or
        std.ascii.endsWithIgnoreCase(value, ".zip") or
        std.ascii.endsWithIgnoreCase(value, ".rar") or
        std.ascii.endsWithIgnoreCase(value, ".7z");
}

fn parseSecCode(body: []const u8) ?[]const u8 {
    const marker = "id=\"secCode\"";
    const id_pos = std.mem.indexOf(u8, body, marker) orelse return null;
    const tag_start = std.mem.lastIndexOfScalar(u8, body[0..id_pos], '<') orelse return null;
    const tag_end_rel = std.mem.indexOfScalar(u8, body[id_pos..], '>') orelse return null;
    const tag = body[tag_start .. id_pos + tag_end_rel + 1];
    const value_marker = "value=\"";
    const value_pos = std.mem.indexOf(u8, tag, value_marker) orelse return null;
    const tail = tag[value_pos + value_marker.len ..];
    const end = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    return tail[0..end];
}

pub fn makeDownloadToken(allocator: Allocator, subtitle_id: []const u8, page_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}|{s}", .{ download_token_prefix, subtitle_id, page_url });
}

const DownloadToken = common.SubtitleDownloadToken;

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    const sep = std.mem.indexOfScalar(u8, payload, '|') orelse return null;
    if (sep == 0 or sep + 1 >= payload.len) return null;
    return .{ .subtitle_id = payload[0..sep], .page_url = payload[sep + 1 ..] };
}

fn parseYear(value: []const u8) ?i64 {
    var i: usize = 0;
    while (i + 4 <= value.len) : (i += 1) {
        const slice = value[i .. i + 4];
        var all_digits = true;
        for (slice) |c| if (!std.ascii.isDigit(c)) {
            all_digits = false;
            break;
        };
        if (!all_digits) continue;
        const year = std.fmt.parseInt(i64, slice, 10) catch continue;
        if (year >= 1900 and year <= 2100) return year;
    }
    return null;
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

test "greeksubs token and download id parsing" {
    try std.testing.expectEqualStrings("abc-123", parseDownloadId("downloadMe('abc-123')").?);
    const allocator = std.testing.allocator;
    const token = try makeDownloadToken(allocator, "abc", "https://greeksubs.net/en/view/x");
    defer allocator.free(token);
    const parsed = parseDownloadToken(token).?;
    try std.testing.expectEqualStrings("abc", parsed.subtitle_id);
    try std.testing.expectEqualStrings("https://greeksubs.net/en/view/x", parsed.page_url);
    try std.testing.expect(!hasKnownDownloadExtension("Interstellar.2014.1080p.BluRay.x264-YIFY"));
    try std.testing.expect(hasKnownDownloadExtension("Interstellar.2014.srt"));
    try std.testing.expect(hasKnownDownloadExtension("Game of Thrones Season 1.zip"));
}

test "greeksubs rejects non-provider session targets" {
    try validateProviderUrl("https://greeksubs.net/en/view/interstellar");
    for ([_][]const u8{
        "http://127.0.0.1/en/view/interstellar",
        "https://greeksubs.net.example/en/view/interstellar",
        "https://user@greeksubs.net/en/view/interstellar",
        "http://greeksubs.net/en/view/interstellar",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url));
    }
}

test "greeksubs stops season fallback on rate limits and cancellation" {
    const Scenario = enum { limited, canceled, out_of_memory };
    const Case = struct { scenario: Scenario, expected_error: anyerror };
    const Fixture = struct {
        client: std.http.Client,
        scenario: Scenario,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(!options.retry_on_429);
            if (std.mem.eql(u8, url, "https://greeksubs.net/en/view/show")) {
                return .{
                    .status = .ok,
                    .body = try allocator.dupe(u8, "<a href='/en/view/show-season-1'>Season 1</a>" ++
                        "<a href='/en/view/show-season-2'>Season 2</a>"),
                };
            }
            try std.testing.expectEqual(@as(usize, 2), self.calls);
            return switch (self.scenario) {
                .limited => .{ .status = .too_many_requests, .body = try allocator.dupe(u8, "limited") },
                .canceled => error.Canceled,
                .out_of_memory => error.OutOfMemory,
            };
        }
    };

    for ([_]Case{
        .{ .scenario = .limited, .expected_error = error.RateLimited },
        .{ .scenario = .canceled, .expected_error = error.Canceled },
        .{ .scenario = .out_of_memory, .expected_error = error.OutOfMemory },
    }) |case| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .scenario = case.scenario,
        };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        try std.testing.expectError(case.expected_error, scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
            .title = "Show",
            .year = null,
            .media_kind = .tv,
            .page_url = "https://greeksubs.net/en/view/show",
        }));
        try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    }
}

test "greeksubs continues after one ordinary season failure" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            if (std.mem.endsWith(u8, url, "/show")) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "<a href='/en/view/show-season-1'>Season 1</a><a href='/en/view/show-season-2'>Season 2</a>"),
            };
            if (std.mem.endsWith(u8, url, "season-1")) return error.ConnectionResetByPeer;
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<html><body>No rows</body></html>") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
        .title = "Show",
        .year = null,
        .media_kind = .tv,
        .page_url = "https://greeksubs.net/en/view/show",
    });
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.subtitles.len);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}

test "live greeksubs movie search, listing and session download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "greeksubs.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Interstellar");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);

    const response = try scraper.fetchDownloadByToken(std.testing.allocator, subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(response.body);
    try std.testing.expect(response.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "-->") != null);
}
