const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "http://subs.sab.bz";
const search_url = site ++ "/index.php?";
pub const download_token_prefix = "subs-sab-referer:";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    language_code: []const u8,
    attach_id: []const u8,
    page_url: []const u8,
    download_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const SearchLanguage = struct {
    form_code: []const u8,
    language_code: []const u8,
};

const languages = [_]SearchLanguage{
    .{ .form_code = "1", .language_code = "en" },
    .{ .form_code = "2", .language_code = "bg" },
};

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

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        for (languages) |language| {
            const payload = try std.fmt.allocPrint(
                a,
                "act=search&movie={s}&select-language={s}&upldr=&yr=&release=",
                .{ encoded, language.form_code },
            );
            const response = try common.fetchBytes(self.client, a, search_url, .{
                .method = .POST,
                .payload = payload,
                .content_type = "application/x-www-form-urlencoded",
                .accept = "text/html,application/xhtml+xml,*/*",
                .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
                .cache = false,
                .max_attempts = 3,
                .require_public_origin = true,
            });
            try appendSearchRows(a, response.body, trimmed, language.language_code, &seen, &exact, &partial);
        }

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        try items.appendSlice(a, exact.items);
        try items.appendSlice(a, partial.items);
        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const slugged = try common.asciiSlug(a, item.title);
        const filename = try std.fmt.allocPrint(a, "subs-sab-{s}-{s}", .{ item.attach_id, slugged });
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = filename,
            .download_url = try makeDownloadToken(a, item.attach_id),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const attach_id = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        const url = try std.fmt.allocPrint(allocator, "{s}/index.php?act=download&attach_id={s}", .{ site, attach_id });
        defer allocator.free(url);
        const response = try common.fetchBytes(self.client, allocator, url, .{
            .accept = "application/octet-stream,application/download,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = search_url }},
            .cache = false,
            .max_attempts = 3,
            .require_public_origin = true,
        });
        if (response.status != .ok) {
            allocator.free(response.body);
            return error.UnexpectedHttpStatus;
        }
        if (common.looksLikeHtml(response.body)) {
            allocator.free(response.body);
            return error.UnexpectedResponseType;
        }
        return response;
    }
};

pub fn makeDownloadToken(allocator: Allocator, attach_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ download_token_prefix, attach_id });
}

pub fn parseDownloadToken(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const attach_id = value[download_token_prefix.len..];
    if (attach_id.len == 0) return null;
    for (attach_id) |c| if (!std.ascii.isDigit(c)) return null;
    return attach_id;
}

test "subs sab download tokens reject URL injection" {
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "http://127.0.0.1/private") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "https://user:pass@subs.sab.bz/private") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "https://subs.sab.bz.evil.com/private") == null);
}

fn appendSearchRows(
    allocator: Allocator,
    body: []const u8,
    query: []const u8,
    language_code: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    exact: *std.ArrayListUnmanaged(SearchItem),
    partial: *std.ArrayListUnmanaged(SearchItem),
) !void {
    const wanted = try common.normalizeTitle(allocator, query);
    defer allocator.free(wanted);

    var cursor: usize = 0;
    const row_marker = "<tr class=\"subs-row\">";
    while (std.mem.indexOfPos(u8, body, cursor, row_marker)) |row_start| {
        const tail_start = row_start + row_marker.len;
        const row_end = std.mem.indexOfPos(u8, body, tail_start, "</tr>") orelse body.len;
        const row = body[row_start..row_end];
        cursor = row_end;

        const attach_marker = "attach_id=";
        const attach_pos = std.mem.indexOf(u8, row, attach_marker) orelse continue;
        const attach_tail = row[attach_pos + attach_marker.len ..];
        var attach_end: usize = 0;
        while (attach_end < attach_tail.len and std.ascii.isDigit(attach_tail[attach_end])) : (attach_end += 1) {}
        if (attach_end == 0) continue;
        const attach_id = attach_tail[0..attach_end];

        if (seen.contains(attach_id)) continue;
        try seen.put(allocator, attach_id, {});

        const c2_marker = "class=\"c2field\"";
        const c2_pos = std.mem.indexOf(u8, row, c2_marker) orelse continue;
        const c2_tail = row[c2_pos + c2_marker.len ..];
        const anchor_pos = std.mem.indexOf(u8, c2_tail, "<a ") orelse continue;
        const anchor_tail = c2_tail[anchor_pos..];
        const close = std.mem.indexOf(u8, anchor_tail, "</a>") orelse continue;
        const open_end = std.mem.lastIndexOfScalar(u8, anchor_tail[0..close], '>') orelse continue;
        const text_tail = anchor_tail[open_end + 1 ..];
        const raw_title = std.mem.trim(u8, text_tail[0 .. close - open_end - 1], " \t\r\n");
        if (raw_title.len == 0) continue;

        const year = parseYearAfterAnchor(anchor_tail[close + "</a>".len ..]);
        const canonical = canonicalTitle(raw_title);
        const normalized = try common.normalizeTitle(allocator, canonical);
        defer allocator.free(normalized);
        if (normalized.len == 0) continue;
        if (std.mem.indexOf(u8, normalized, wanted) == null and std.mem.indexOf(u8, wanted, normalized) == null) continue;

        const media_kind: MediaKind = if (isTvTitle(raw_title)) .tv else .movie;
        const download_url = try std.fmt.allocPrint(allocator, "{s}/index.php?act=download&attach_id={s}", .{ site, attach_id });
        const item: SearchItem = .{
            .title = try allocator.dupe(u8, canonical),
            .year = year,
            .media_kind = media_kind,
            .language_code = try allocator.dupe(u8, language_code),
            .attach_id = try allocator.dupe(u8, attach_id),
            .page_url = download_url,
            .download_url = try allocator.dupe(u8, download_url),
        };

        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(allocator, item)
        else
            try partial.append(allocator, item);
    }
}

fn parseYearAfterAnchor(value: []const u8) ?i64 {
    const open = std.mem.indexOfScalar(u8, value, '(') orelse return null;
    if (open + 5 > value.len) return null;
    const digits = value[open + 1 .. open + 5];
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    if (open + 5 >= value.len or value[open + 5] != ')') return null;
    return std.fmt.parseInt(i64, digits, 10) catch null;
}

fn canonicalTitle(raw: []const u8) []const u8 {
    const patterns = [_][]const u8{
        " - Season ",
        " - season ",
    };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, raw, pattern)) |idx| return std.mem.trimEnd(u8, raw[0..idx], " \t");
    }

    var i: usize = 0;
    while (i + 6 <= raw.len) : (i += 1) {
        if (raw[i] != ' ' or raw[i + 1] != '-') continue;
        var p = i + 2;
        while (p < raw.len and raw[p] == ' ') : (p += 1) {}
        if (p + 4 >= raw.len) continue;
        if (std.ascii.isDigit(raw[p]) and std.ascii.isDigit(raw[p + 1]) and raw[p + 2] == 'x' and
            std.ascii.isDigit(raw[p + 3]) and std.ascii.isDigit(raw[p + 4]))
        {
            return std.mem.trimEnd(u8, raw[0..i], " \t");
        }
    }
    return std.mem.trim(u8, raw, " \t\r\n");
}

fn isTvTitle(raw: []const u8) bool {
    if (std.ascii.findIgnoreCase(raw, " - Season ") != null) return true;
    var i: usize = 0;
    while (i + 5 <= raw.len) : (i += 1) {
        if (std.ascii.isDigit(raw[i]) and std.ascii.isDigit(raw[i + 1]) and raw[i + 2] == 'x' and
            std.ascii.isDigit(raw[i + 3]) and std.ascii.isDigit(raw[i + 4]))
        {
            return true;
        }
    }
    return false;
}

test "subs sab parses movie and tv rows" {
    const allocator = std.testing.allocator;
    const fixture =
        "<tr class=\"subs-row\"><td class=\"c2field\"><a href=\"http://subs.sab.bz/index.php?act=download&attach_id=52867\">The Matrix</a> (1999)</td><td>English</td></tr>" ++
        "<tr class=\"subs-row\"><td class=\"c2field\"><a href=\"http://subs.sab.bz/index.php?act=download&attach_id=101693\">Reacher - Season 1</a> (2022)</td><td>English</td></tr>";
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    defer {
        for (exact.items) |item| {
            allocator.free(item.title);
            allocator.free(item.language_code);
            allocator.free(item.attach_id);
            allocator.free(item.page_url);
            allocator.free(item.download_url);
        }
        exact.deinit(allocator);
    }
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    defer {
        for (partial.items) |item| {
            allocator.free(item.title);
            allocator.free(item.language_code);
            allocator.free(item.attach_id);
            allocator.free(item.page_url);
            allocator.free(item.download_url);
        }
        partial.deinit(allocator);
    }

    try appendSearchRows(allocator, fixture, "Reacher", "en", &seen, &exact, &partial);
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqualStrings("Reacher", exact.items[0].title);
    try std.testing.expectEqual(MediaKind.tv, exact.items[0].media_kind);
    try std.testing.expectEqual(@as(?i64, 2022), exact.items[0].year);
}

test "live subs sab movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subs.sab.bz")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    const movie_download = try scraper.fetchDownloadByToken(std.testing.allocator, movie_subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, movie_download.body, "Rar!") or std.mem.startsWith(u8, movie_download.body, "PK"));

    var tv = try scraper.search("Reacher");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    try std.testing.expect(tv.items[0].media_kind == .tv);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    const tv_download = try scraper.fetchDownloadByToken(std.testing.allocator, tv_subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK") or std.mem.startsWith(u8, tv_download.body, "Rar!"));
}
