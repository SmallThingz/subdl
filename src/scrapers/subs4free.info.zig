const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.subs4free.info";
const download_endpoint = site ++ "/getSub.php";

pub const download_token_prefix = "subs4free-session:";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    language_code: []const u8,
    release: []const u8,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    language_code: []const u8,
    filename: []const u8,
    download_url: []const u8,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SearchItem,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    subtitles: []const SubtitleItem,

    pub fn deinit(self: *SubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn deinit(_: *Scraper) void {}

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
        });
        return parseSearchHtml(arena, response.body, trimmed);
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
        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        };
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const page_url = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        var page = try fetchDetailPage(self.client, allocator, page_url);
        defer page.deinit(allocator);
        if (page.status != .ok) return error.UnexpectedHttpStatus;
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

fn fetchDetailPage(client: *std.http.Client, allocator: Allocator, url: []const u8) !DetailPage {
    try common.ensureClientTlsReady(client);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);
    const headers = [_]std.http.Header{
        .{ .name = "referer", .value = site },
        .{ .name = "accept", .value = "text/html,application/xhtml+xml,*/*" },
    };
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &headers,
    });
    defer req.deinit();
    try req.sendBodiless();

    var head_buffer: [16 * 1024]u8 = undefined;
    var response = try req.receiveHead(&head_buffer);
    const cookie = try extractPhpSessionCookie(allocator, response.head.bytes);

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    _ = try reader.streamRemaining(&writer.writer);
    return .{
        .status = response.head.status,
        .body = try allocator.dupe(u8, writer.writer.buffered()),
        .cookie = cookie,
    };
}

fn extractPhpSessionCookie(allocator: Allocator, headers: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const marker = "PHPSESSID=";
        const start = std.mem.indexOf(u8, value, marker) orelse continue;
        const tail = value[start..];
        const end = std.mem.indexOfScalar(u8, tail, ';') orelse tail.len;
        return try allocator.dupe(u8, tail[0..end]);
    }
    return null;
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

    const wanted = try normalizeTitle(a, query);
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
        const normalized = try normalizeTitle(a, split.title);
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
    return .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) };
}

const TitleYear = struct {
    title: []const u8,
    year: i64,
};

fn splitTitleYear(input: []const u8) ?TitleYear {
    var i: usize = 0;
    while (i + 4 <= input.len) : (i += 1) {
        const digits = input[i .. i + 4];
        if (!allDigits(digits)) continue;
        const before_ok = i == 0 or !std.ascii.isDigit(input[i - 1]);
        const after_ok = i + 4 == input.len or !std.ascii.isDigit(input[i + 4]);
        if (!before_ok or !after_ok) continue;
        const year = std.fmt.parseInt(i64, digits, 10) catch continue;
        if (year < 1900 or year > 2100) continue;
        const title = std.mem.trim(u8, input[0..i], " \t\r\n()-");
        if (title.len == 0) continue;
        return .{ .title = title, .year = year };
    }
    return null;
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

fn normalizeTitle(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            pending_space = out.items.len > 0;
        }
    }
    return out.toOwnedSlice(allocator);
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
