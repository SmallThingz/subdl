const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.subs4free.info";
const download_endpoint = site ++ "/getSub.php";
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;

pub const download_token_prefix = "subs4free-session:";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    language_code: []const u8,
    release: []const u8,
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
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/search_report.php?search={s}&searchType=1", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = try subtitleFilename(a, item.release),
            .download_url = try makeDownloadToken(a, item.page_url),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const page_url = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;
        var page = try fetchDetailPage(self.client, allocator, page_url, deadline_ms);
        defer page.deinit(allocator);
        try requireDetailStatus(page.status);
        const cookie = page.cookie orelse return error.SessionExpired;

        const id = try parseDownloadId(allocator, page.body) orelse return error.MissingField;
        defer allocator.free(id);
        const encoded_id = try common.encodeUriComponent(allocator, id);
        defer allocator.free(encoded_id);
        const payload = try std.fmt.allocPrint(allocator, "id={s}&x=10&y=10", .{encoded_id});
        defer allocator.free(payload);
        const headers = [_]std.http.Header{
            .{ .name = "referer", .value = page_url },
            .{ .name = "cookie", .value = cookie },
        };
        const response = try common.fetchBytes(self.client, allocator, download_endpoint, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "application/zip,application/octet-stream,*/*",
            .extra_headers = &headers,
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
            .deadline_ms = deadline_ms,
        });
        if (response.status == .too_many_requests) {
            allocator.free(response.body);
            return error.RateLimited;
        }
        if (response.status != .ok) {
            allocator.free(response.body);
            return error.UnexpectedHttpStatus;
        }
        validateZipDownloadBody(response.body) catch |err| {
            allocator.free(response.body);
            return err;
        };
        return response;
    }
};

fn subtitleFilename(allocator: Allocator, release: []const u8) ![]u8 {
    const bounded = release[0..@min(release.len, 160)];
    const slug = try common.asciiSlug(allocator, bounded);
    defer allocator.free(slug);
    if (slug.len == 0) return allocator.dupe(u8, "subs4free-subtitle.zip");
    return std.fmt.allocPrint(allocator, "{s}.zip", .{slug});
}

const DetailPage = struct {
    status: std.http.Status,
    body: []u8,
    cookie: ?[]u8,

    fn deinit(self: *DetailPage, allocator: Allocator) void {
        allocator.free(self.body);
        if (self.cookie) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn requireDetailStatus(status: std.http.Status) !void {
    if (status == .too_many_requests) return error.RateLimited;
    if (status != .ok) return error.UnexpectedHttpStatus;
}

fn fetchDetailPage(client: *std.http.Client, allocator: Allocator, url: []const u8, deadline_ms: i64) !DetailPage {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;

    const FetchTask = struct {
        fn run(result: *?DetailPage, task_client: *std.http.Client, task_allocator: Allocator, task_url: []const u8) !void {
            result.* = try fetchDetailPageUnbounded(task_client, task_allocator, task_url);
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
    var owned_page: ?DetailPage = null;
    defer {
        selection.cancelDiscard();
        if (owned_page) |*page| page.deinit(allocator);
    }

    const remaining_ms: i64 = deadline_ms -| now_ms;
    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(client.io, .{
        .raw = std.Io.Duration.fromMilliseconds(remaining_ms),
        .clock = .awake,
    }) };
    try selection.concurrent(.fetch, FetchTask.run, .{ &owned_page, client, allocator, url });
    try selection.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, client.io });

    switch (try selection.await()) {
        .fetch => |result| {
            try result;
            const page = owned_page orelse return error.MissingHttpResponse;
            owned_page = null;
            return page;
        },
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}

fn fetchDetailPageUnbounded(client: *std.http.Client, allocator: Allocator, url: []const u8) !DetailPage {
    try validateProviderDetailUrl(url);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);
    const headers = [_]std.http.Header{
        .{ .name = "referer", .value = site },
        .{ .name = "accept", .value = "text/html,application/xhtml+xml,*/*" },
    };
    try common.validateHttpHeaders(&headers);
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
        try validateRawDetailResponseHead(response.head);
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    try validateRawDetailResponseHead(response.head);
    const cookie = try common.extractPhpSessionCookie(allocator, response.head.bytes);
    errdefer if (cookie) |value| allocator.free(value);

    const body = try common.readStrictResponseBody(&req, &response, allocator, max_raw_response_bytes);
    errdefer allocator.free(body);
    return .{
        .status = response.head.status,
        .body = body,
        .cookie = cookie,
    };
}

fn validateRawDetailResponseHead(head: std.http.Client.Response.Head) !void {
    try common.validateResponseFraming(head);
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

fn validateProviderDetailUrl(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.fragment != null) return error.UnsafeHttpTarget;
    if (std.mem.indexOfScalar(u8, url, '?') != null) return error.UnsafeHttpTarget;
    var path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (path.len > 1 and path[path.len - 1] == '/') return error.UnsafeHttpTarget;

    const greek_prefix = "/greek-subtitles/";
    const english_prefix = "/english-subtitles/";
    const remainder = if (std.mem.startsWith(u8, path, greek_prefix))
        path[greek_prefix.len..]
    else if (std.mem.startsWith(u8, path, english_prefix))
        path[english_prefix.len..]
    else
        return error.UnsafeHttpTarget;

    var segments = std.mem.splitScalar(u8, remainder, '/');
    const detail_id = segments.next() orelse return error.UnsafeHttpTarget;
    const slug = segments.next() orelse return error.UnsafeHttpTarget;
    if (segments.next() != null or !isDetailId(detail_id) or !isDetailSlug(slug))
        return error.UnsafeHttpTarget;
}

fn isDetailId(value: []const u8) bool {
    if (value.len != 11 or value[0] != 's') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn isDetailSlug(value: []const u8) bool {
    if (value.len == 0 or value[0] == '-' or value[value.len - 1] == '-') return false;
    for (value) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'z') and c != '-') return false;
    }
    return true;
}

fn validateZipDownloadBody(body: []const u8) !void {
    if (body.len < 4) return error.UnexpectedResponseType;
    const signature = body[0..4];
    if (!std.mem.eql(u8, signature, "PK\x03\x04") and
        !std.mem.eql(u8, signature, "PK\x05\x06") and
        !std.mem.eql(u8, signature, "PK\x07\x08"))
    {
        return error.UnexpectedResponseType;
    }
}

pub fn makeDownloadToken(allocator: Allocator, page_url: []const u8) ![]u8 {
    try validateProviderDetailUrl(page_url);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ download_token_prefix, page_url });
}

pub fn parseDownloadToken(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const page_url = value[download_token_prefix.len..];
    validateProviderDetailUrl(page_url) catch return null;
    return page_url;
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };
    var parsed = try common.parseHtmlStable(a, body);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var anchors = parsed.doc.queryAll(".movie-details a.movie-heading[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (!std.mem.startsWith(u8, href, "/greek-subtitles/") and
            !std.mem.startsWith(u8, href, "/english-subtitles/")) continue;
        const release = try common.innerTextTrimmedOwned(a, anchor);
        if (release.len == 0) continue;
        const split = splitTitleYear(release) orelse continue;
        const normalized = try common.normalizeTitle(a, split.title);
        const exact_match = std.mem.eql(u8, normalized, wanted);
        const partial_match = normalizedTitlesRelated(normalized, wanted);
        if (!exact_match and !partial_match) continue;

        const page_url = try common.resolveUrl(a, site, href);
        validateProviderDetailUrl(page_url) catch continue;
        if (seen.contains(page_url)) continue;
        try seen.put(a, page_url, {});
        const item: SearchItem = .{
            .title = try a.dupe(u8, split.title),
            .year = split.year,
            .language_code = if (std.mem.startsWith(u8, href, "/greek-subtitles/")) "el" else "en",
            .release = try a.dupe(u8, release),
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

const TitleYear = common.RequiredTitleYear;

fn splitTitleYear(input: []const u8) ?TitleYear {
    var result: ?TitleYear = null;
    var i: usize = 0;
    while (i + 4 <= input.len) : (i += 1) {
        const digits = input[i .. i + 4];
        if (!allDigits(digits)) continue;
        const before_ok = i == 0 or !std.ascii.isAlphanumeric(input[i - 1]);
        const after_ok = i + 4 == input.len or !std.ascii.isAlphanumeric(input[i + 4]);
        if (!before_ok or !after_ok) continue;
        if (isSpacedResolutionDimension(input, i)) continue;
        const year = std.fmt.parseInt(i64, digits, 10) catch continue;
        if (year < 1900 or year > 2100) continue;
        const title = std.mem.trim(u8, input[0..i], " \t\r\n()-");
        if (title.len == 0) continue;
        // The release year follows the complete title, which may itself contain a year.
        result = .{ .title = title, .year = year };
    }
    return result;
}

fn isSpacedResolutionDimension(input: []const u8, start: usize) bool {
    const after = std.mem.trimStart(u8, input[start + 4 ..], " \t\r\n");
    // A separate x between dimensions differs from a codec label such as x264.
    if (after.len >= 2 and (after[0] == 'x' or after[0] == 'X') and std.ascii.isWhitespace(after[1])) {
        const height = std.mem.trimStart(u8, after[1..], " \t\r\n");
        if (height.len > 0 and std.ascii.isDigit(height[0])) return true;
    }
    const before = std.mem.trimEnd(u8, input[0..start], " \t\r\n");
    if (before.len > 0 and (before[before.len - 1] == 'x' or before[before.len - 1] == 'X')) {
        const width = std.mem.trimEnd(u8, before[0 .. before.len - 1], " \t\r\n");
        if (width.len > 0 and std.ascii.isDigit(width[width.len - 1])) return true;
    }
    return false;
}

fn allDigits(input: []const u8) bool {
    for (input) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn parseDownloadId(allocator: Allocator, body: []const u8) !?[]u8 {
    var parsed = try common.parseHtmlStable(allocator, body);
    defer parsed.deinit();
    var forms = parsed.doc.queryAll("form[action]");
    while (forms.next()) |form| {
        const action = common.getAttributeValueSafe(form, "action") orelse continue;
        if (!(try formTargetsDownloadEndpoint(allocator, action))) continue;

        var nodes = form.queryAll("input[name=\"id\"][value]");
        while (nodes.next()) |node| {
            const value = common.getAttributeValueSafe(node, "value") orelse continue;
            if (!isCanonicalPositiveDownloadId(value)) continue;
            return try allocator.dupe(u8, value);
        }
    }
    return null;
}

fn formTargetsDownloadEndpoint(allocator: Allocator, action: []const u8) !bool {
    const resolved = common.resolveUrl(allocator, site ++ "/", action) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer allocator.free(resolved);

    common.validatePublicHttpUrl(resolved) catch return false;
    if (!(common.sameOrigin(site, resolved) catch false)) return false;
    const uri = std.Uri.parse(resolved) catch return false;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return false;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    return std.mem.eql(u8, path, "/getSub.php");
}

fn isCanonicalPositiveDownloadId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "subs4free preserves numeric titles and ignores resolution numbers" {
    const fixture =
        "<div class='movie-details'><a class='movie-heading' href='/greek-subtitles/s0000000001/a'>Blade Runner 2049 2017 1920x1080 BluRay</a></div>" ++
        "<div class='movie-details'><a class='movie-heading' href='/english-subtitles/s0000000002/b'>Blade Runner 2049 (2017) 1080p</a></div>" ++
        "<div class='movie-details'><a class='movie-heading' href='/greek-subtitles/s0000000003/c'>Blade Runner 2049 2017 1920 x 1080 BluRay</a></div>";
    var response = try parseSearchHtml(std.heap.ArenaAllocator.init(std.testing.allocator), fixture, "Blade Runner 2049");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 3), response.items.len);
    for (response.items) |item| {
        try std.testing.expectEqualStrings("Blade Runner 2049", item.title);
        try std.testing.expectEqual(@as(?i64, 2017), item.year);
    }
    const cases = .{
        .{ "Class of 1984 1982 1080p", "Class of 1984", 1982 },
        .{ "1917 2019 1080p", "1917", 2019 },
        .{ "2001: A Space Odyssey 1968 BluRay", "2001: A Space Odyssey", 1968 },
        .{ "The Matrix 1999 1920x1080", "The Matrix", 1999 },
        .{ "The Matrix 1999 1920 x 1080", "The Matrix", 1999 },
        .{ "The Matrix 1999 1080 X 1920", "The Matrix", 1999 },
        .{ "The Matrix 1999 x264", "The Matrix", 1999 },
    };
    inline for (cases) |case| {
        const split = splitTitleYear(case[0]) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(case[1], split.title);
        try std.testing.expectEqual(@as(i64, case[2]), split.year);
    }
    try std.testing.expect(splitTitleYear("No Year 1920x1080") == null);
    try std.testing.expect(splitTitleYear("No Year 1920 x 1080") == null);
    try std.testing.expect(splitTitleYear("No Year 1080 X 1920") == null);
}

test "subs4free parses exact movie rows before partial matches" {
    const fixture =
        "<div class=\"movie-details\"><a class=\"movie-heading\" href=\"/greek-subtitles/s0000000001/a\">The Matrix Revolutions 2003 1080p</a></div>" ++
        "<div class=\"movie-details\"><a class=\"movie-heading\" href=\"/greek-subtitles/s0000000002/b\">The Matrix 1999 1080p BrRip x264 YIFY</a></div>" ++
        "<div class=\"movie-details\"><a class=\"movie-heading\" href=\"/english-subtitles/s0000000003/c\">The Matrix 1999 BluRay</a></div>";
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(arena, fixture, "The Matrix");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 3), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 1999), response.items[0].year);
    try std.testing.expectEqualStrings("el", response.items[0].language_code);
    try std.testing.expectEqualStrings("The Matrix", response.items[1].title);
    try std.testing.expectEqualStrings("en", response.items[1].language_code);
    try std.testing.expectEqualStrings("The Matrix Revolutions", response.items[2].title);
}

test "subs4free selects a canonical positive download id" {
    const body =
        "<form action=\"/profile\"><input type=\"hidden\" name=\"id\" value=\"999\"></form>" ++
        "<form action=\"/getSub.php\"><input type=\"hidden\" name=\"id\" value=\"0\"></form>" ++
        "<form action=\"https://example.com/getSub.php\"><input type=\"hidden\" name=\"id\" value=\"998\"></form>" ++
        "<form action=\"/getSub.php?next=/admin\"><input type=\"hidden\" name=\"id\" value=\"997\"></form>" ++
        "<form action=\"getSub.php\"><input type=\"hidden\" name=\"id\" value=\"abc123\"></form>" ++
        "<form action=\"/getSub.php\"><input type=\"hidden\" name=\"id\" value=\"01\"></form>" ++
        "<form action=\"/getSub.php\"><input type=\"hidden\" name=\"id\" value=\"123\"></form>";
    const id = (try parseDownloadId(std.testing.allocator, body)).?;
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("123", id);
    try std.testing.expect((try parseDownloadId(
        std.testing.allocator,
        "<form action=\"/unrelated\"><input name=\"id\" value=\"1\"></form>" ++
            "<form action=\"/getSub.php\"><input name=\"id\" value=\"0\"><input name=\"id\" value=\"0001\"></form>",
    )) == null);
}

test "subs4free output names and title relevance are filesystem safe" {
    const filename = try subtitleFilename(std.testing.allocator, "../The Matrix\\Release: 1080p");
    defer std.testing.allocator.free(filename);
    try std.testing.expectEqualStrings("the-matrix-release-1080p.zip", filename);
    const fallback = try subtitleFilename(std.testing.allocator, "../...");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("subs4free-subtitle.zip", fallback);
    try std.testing.expect(normalizedTitlesRelated("jack reacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("preacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("reacher", ""));
}

test "subs4free accepts only complete ZIP signatures" {
    for ([_][]const u8{
        "PK\x03\x04payload",
        "PK\x05\x06",
        "PK\x07\x08payload",
    }) |body| try validateZipDownloadBody(body);

    for ([_][]const u8{
        "",
        "PK",
        "PKxx",
        "PK<html>",
        "Rar!",
    }) |body| try std.testing.expectError(error.UnexpectedResponseType, validateZipDownloadBody(body));
}

test "subs4free raw detail page classifies rate limits" {
    try requireDetailStatus(.ok);
    try std.testing.expectError(error.RateLimited, requireDetailStatus(.too_many_requests));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireDetailStatus(.service_unavailable));
}

test "subs4free detail fetch rejects an expired deadline before I/O" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(
        error.Timeout,
        fetchDetailPage(
            &client,
            std.testing.allocator,
            site ++ "/greek-subtitles/s0000000001/title",
            common.compatMilliTimestamp(),
        ),
    );
}

test "subs4free accepts only provider detail routes" {
    inline for (.{
        "https://www.subs4free.info/greek-subtitles/sc8643a5496/the-matrix-revolutions-2003",
        "https://www.subs4free.info/english-subtitles/s0cc253fd68/the-matrix-resurrections-2021",
        "https://www.subs4free.info/english-subtitles/s0cc253fd68/the-matrix-resurrections-2021/",
    }) |url| {
        try validateProviderDetailUrl(url);
        const token = try makeDownloadToken(std.testing.allocator, url);
        defer std.testing.allocator.free(token);
        try std.testing.expectEqualStrings(url, parseDownloadToken(token).?);
    }

    inline for (.{
        "http://127.0.0.1/greek-subtitles/s0000000001/title",
        "https://user:pass@www.subs4free.info/greek-subtitles/s0000000001/title",
        "https://www.google.com/greek-subtitles/s0000000001/title",
        "https://www.subs4free.info/admin",
        "https://www.subs4free.info/greek-subtitles/s0000000001",
        "https://www.subs4free.info/greek-subtitles/s0000000001/title/extra",
        "https://www.subs4free.info/greek-subtitles/not-an-id/title",
        "https://www.subs4free.info/greek-subtitles/s000000000g/title",
        "https://www.subs4free.info/greek-subtitles/s0000000001/not_a_slug",
        "https://www.subs4free.info/greek-subtitles/s0000000001/title//",
        "https://www.subs4free.info/greek-subtitles/../admin/title",
        "https://www.subs4free.info/greek-subtitles/s0000000001/%2e%2e",
        "https://www.subs4free.info/greek-subtitles/s0000000001/title?from=search",
        "https://www.subs4free.info/greek-subtitles/s0000000001/title#fragment",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderDetailUrl(url));
        try std.testing.expect(parseDownloadToken(download_token_prefix ++ url) == null);
    }
}

test "subs4free raw detail transport rejects ambiguous response framing" {
    for ([_][]const u8{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
    }) |raw_head| {
        const head = try std.http.Client.Response.Head.parse(raw_head);
        try std.testing.expectError(error.AmbiguousHttpFraming, validateRawDetailResponseHead(head));
    }
}

test "live subs4free search session and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subs4free.info")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    const item = blk: {
        for (search.items) |candidate| {
            if (candidate.year == 1999 and std.ascii.eqlIgnoreCase(candidate.title, "The Matrix"))
                break :blk candidate;
        }
        return error.TestUnexpectedResult;
    };
    std.debug.print("[live][subs4free.info][search]\n", .{});
    try common.livePrintField(std.testing.allocator, "title", item.title);
    try common.livePrintField(std.testing.allocator, "release", item.release);
    try common.livePrintField(std.testing.allocator, "page_url", item.page_url);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(item);
    defer subtitles.deinit();
    if (subtitles.subtitles.len != 1) return error.TestUnexpectedResult;
    const subtitle = subtitles.subtitles[0];
    try common.livePrintField(std.testing.allocator, "filename", subtitle.filename);

    const download = try scraper.fetchDownloadByToken(std.testing.allocator, subtitle.download_url);
    defer std.testing.allocator.free(download.body);
    if (download.status != .ok or download.body.len < 4) return error.TestUnexpectedResult;
    std.debug.print("[live][subs4free.info][download] bytes={d}\n", .{download.body.len});
}
