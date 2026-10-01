const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const payload = try std.fmt.allocPrint(a, "searchval={s}&searchtype=all", .{encoded});
        const response = try common.fetchBytes(self.client, a, search_url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
        });
        return parseSearchHtml(arena, response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
        });
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
                if (std.ascii.indexOfIgnoreCase(text, "Season") == null) continue;
                const page_url = try common.resolveUrl(a, site, href);
                if (seen_pages.contains(page_url)) continue;
                try seen_pages.put(a, page_url, {});
                followed += 1;

                const child = common.fetchBytes(self.client, a, page_url, .{
                    .accept = "text/html,application/xhtml+xml,*/*",
                    .cache = false,
                    .max_attempts = 2,
                }) catch continue;
                try collectSubtitleRows(a, child.body, page_url, &subtitles, &seen);
            }
        }

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        var page = try fetchRaw(self.client, allocator, parts.page_url, &.{});
        defer page.deinit(allocator);
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
    try common.ensureClientTlsReady(client);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra_headers,
    });
    defer req.deinit();
    try req.sendBodiless();

    var head_buffer: [16 * 1024]u8 = undefined;
    var response = try req.receiveHead(&head_buffer);
    const status = response.head.status;
    const cookie = try common.extractPhpSessionCookie(allocator, response.head.bytes);

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    _ = try reader.streamRemaining(&writer.writer);

    return .{
        .status = status,
        .body = try allocator.dupe(u8, writer.writer.buffered()),
        .cookie = cookie,
    };
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

        const item: SearchItem = .{
            .title = title,
            .year = parseYear(try common.innerTextTrimmedOwned(a, anchor)),
            .media_kind = media_kind,
            .page_url = try common.resolveUrl(a, site, href),
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
    return .{ .arena = owned_arena, .items = try out.toOwnedSlice(a) };
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
