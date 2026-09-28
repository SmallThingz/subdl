const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "http://fansubs.ru";
const search_url = site ++ "/search.php";
const download_url = site ++ "/base.php";
pub const download_token_prefix = "fansubs-post:";

pub const SearchItem = struct {
    title: []const u8,
    media_id: []const u8,
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
        });

        if (isRateLimited(response.body)) {
            common.sleepMilliseconds(5200);
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
            });
        }

        return parseSearchHtml(arena, response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{
                .{ .name = "accept-language", .value = "ru,en;q=0.8" },
            },
            .cache = false,
            .max_attempts = 2,
        });

        const subtitles = try parseSubtitleRows(a, response.body);
        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        };
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
                if (attempt + 1 < 3) {
                    common.sleepMilliseconds(250 * (attempt + 1));
                    continue;
                }
                return err;
            };
            if (response.status != .ok) {
                allocator.free(response.body);
                return error.UnexpectedHttpStatus;
            }
            if (looksLikeHtml(response.body)) {
                allocator.free(response.body);
                return error.UnexpectedResponseType;
            }
            return response;
        }
        return error.TruncatedResponse;
    }
};

fn fetchDownloadOnce(client: *std.http.Client, allocator: Allocator, payload: []const u8) !common.HttpResponse {
    try common.ensureClientTlsReady(client);
    const normalized = try common.normalizeUrlForFetch(allocator, download_url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

    var req = try client.request(.POST, uri, .{
        .headers = .{
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .extra_headers = &[_]std.http.Header{
            .{ .name = "accept", .value = "application/octet-stream,application/zip,application/x-rar-compressed,text/plain,*/*" },
            .{ .name = "accept-language", .value = "ru,en;q=0.8" },
        },
    });
    defer req.deinit();

    const mutable_payload = try allocator.dupe(u8, payload);
    defer allocator.free(mutable_payload);
    try req.sendBodyComplete(mutable_payload);

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = try req.receiveHead(&head_buffer);
    const status = response.head.status;
    const expected_length = response.head.content_length;

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    _ = try reader.streamRemaining(&writer.writer);

    const body = try allocator.dupe(u8, writer.writer.buffered());
    errdefer allocator.free(body);
    if (expected_length) |expected| {
        if (body.len != expected) {
            allocator.free(body);
            return error.TruncatedResponse;
        }
    }
    return .{ .status = status, .body = body };
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const wanted = try normalizeTitle(a, query);

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
        const normalized = try normalizeTitle(a, title);
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
    return .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) };
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
        const ext = if (std.ascii.indexOfIgnoreCase(format, "ASS") != null or std.ascii.indexOfIgnoreCase(format, "SSA") != null)
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

fn looksLikeHtml(body: []const u8) bool {
    const head = std.mem.trimStart(u8, body[0..@min(body.len, 1024)], " \t\r\n");
    return std.ascii.startsWithIgnoreCase(head, "<!doctype html") or
        std.ascii.startsWithIgnoreCase(head, "<html") or
        std.mem.indexOf(u8, head, "<body") != null;
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

    common.sleepMilliseconds(5200);
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
