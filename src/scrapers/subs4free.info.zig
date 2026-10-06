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

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/search_report.php?search={s}&searchType=1", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
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
            .filename = try std.fmt.allocPrint(a, "{s}.zip", .{item.release}),
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
        var page = try fetchDetailPage(self.client, allocator, page_url);
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
        });
        if (response.status != .ok or response.body.len < 4 or !std.mem.eql(u8, response.body[0..2], "PK")) {
            allocator.free(response.body);
            return error.UnexpectedResponseType;
        }
        return response;
    }
};

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

fn fetchDetailPage(client: *std.http.Client, allocator: Allocator, url: []const u8) !DetailPage {
    try validateProviderEndpoint(url);
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
    var response = try req.receiveHead(&head_buffer);
    const cookie = try common.extractPhpSessionCookie(allocator, response.head.bytes);
    errdefer if (cookie) |value| allocator.free(value);

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
        .cookie = cookie,
    };
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

fn validateProviderEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

pub fn makeDownloadToken(allocator: Allocator, page_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ download_token_prefix, page_url });
}

pub fn parseDownloadToken(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const page_url = value[download_token_prefix.len..];
    if (!std.mem.startsWith(u8, page_url, site ++ "/")) return null;
    return page_url;
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);

    const wanted = try common.normalizeTitle(a, query);
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
        const partial_match = std.mem.indexOf(u8, normalized, wanted) != null or
            std.mem.indexOf(u8, wanted, normalized) != null;
        if (!exact_match and !partial_match) continue;

        const page_url = try common.resolveUrl(a, site, href);
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
    const node = parsed.doc.queryOne("input[name=\"id\"][value]") orelse return null;
    const value = common.getAttributeValueSafe(node, "value") orelse return null;
    if (value.len == 0) return null;
    return try allocator.dupe(u8, value);
}

test "subs4free preserves numeric titles and ignores resolution numbers" {
    const fixture =
        "<div class='movie-details'><a class='movie-heading' href='/greek-subtitles/a'>Blade Runner 2049 2017 1920x1080 BluRay</a></div>" ++
        "<div class='movie-details'><a class='movie-heading' href='/english-subtitles/b'>Blade Runner 2049 (2017) 1080p</a></div>" ++
        "<div class='movie-details'><a class='movie-heading' href='/greek-subtitles/c'>Blade Runner 2049 2017 1920 x 1080 BluRay</a></div>";
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
        "<div class=\"movie-details\"><a class=\"movie-heading\" href=\"/greek-subtitles/a\">The Matrix Revolutions 2003 1080p</a></div>" ++
        "<div class=\"movie-details\"><a class=\"movie-heading\" href=\"/greek-subtitles/b\">The Matrix 1999 1080p BrRip x264 YIFY</a></div>" ++
        "<div class=\"movie-details\"><a class=\"movie-heading\" href=\"/english-subtitles/c\">The Matrix 1999 BluRay</a></div>";
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

test "subs4free parses download id" {
    const id = (try parseDownloadId(std.testing.allocator, "<form><input type=\"hidden\" name=\"id\" value=\"abc123\"></form>")).?;
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("abc123", id);
}

test "subs4free raw detail page classifies rate limits" {
    try requireDetailStatus(.ok);
    try std.testing.expectError(error.RateLimited, requireDetailStatus(.too_many_requests));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireDetailStatus(.service_unavailable));
}

test "subs4free rejects unsafe detail targets before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("http://127.0.0.1/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://user:pass@www.subs4free.info/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://www.google.com/private"));
}
