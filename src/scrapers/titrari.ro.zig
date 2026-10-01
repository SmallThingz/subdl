const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.titrari.ro";
const search_page = "cautamainaltaparte";
pub const download_token_prefix = "titrari-referer:";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    language_code: []const u8,
    subtitle_id: []const u8,
    page_url: []const u8,
    download_url: []const u8,
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
        const url = try std.fmt.allocPrint(
            a,
            "{s}/index.php?page={s}&z7={s}&z2=&z5=&z3=-1&z4=-1&z8=-1&z9=All&z11=0&z6=0",
            .{ site, search_page, encoded },
        );
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 3,
        });
        var parsed = try parseSearchHtml(arena, response.body, trimmed);
        try self.preferZipMovieDuplicate(a, &parsed);
        return parsed;
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const filename = try std.fmt.allocPrint(a, "titrari-{s}-{s}", .{ item.subtitle_id, try common.asciiSlug(a, item.title) });
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = filename,
            .download_url = try makeDownloadToken(a, item.subtitle_id, item.page_url),
        };
        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        };
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parsed = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        const url = try std.fmt.allocPrint(allocator, "{s}/get.php?id={s}", .{ site, parsed.subtitle_id });
        defer allocator.free(url);
        const response = try common.fetchBytes(self.client, allocator, url, .{
            .accept = "application/octet-stream,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = parsed.page_url }},
            .cache = false,
            .max_attempts = 3,
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

    fn preferZipMovieDuplicate(self: *Scraper, allocator: Allocator, response: *SearchResponse) !void {
        if (response.items.len < 2) return;
        const first = response.items[0];
        if (first.media_kind != .movie) return;
        if (try self.probeArchiveKind(allocator, first) != .rar) return;

        const max_probe = @min(response.items.len, @as(usize, 6));
        var idx: usize = 1;
        while (idx < max_probe) : (idx += 1) {
            const candidate = response.items[idx];
            if (candidate.media_kind != .movie) continue;
            if (!std.ascii.eqlIgnoreCase(candidate.title, first.title)) continue;
            if (candidate.year != first.year) continue;
            if (try self.probeArchiveKind(allocator, candidate) != .zip) continue;

            const reordered = try allocator.alloc(SearchItem, response.items.len);
            @memcpy(reordered, response.items);
            std.mem.swap(SearchItem, &reordered[0], &reordered[idx]);
            response.items = reordered;
            return;
        }
    }

    fn probeArchiveKind(self: *Scraper, allocator: Allocator, item: SearchItem) !ArchiveHint {
        try common.ensureClientTlsReady(self.client);
        const normalized = try common.normalizeUrlForFetch(allocator, item.download_url);
        defer allocator.free(normalized);
        const uri = try std.Uri.parse(normalized);
        const headers = [_]std.http.Header{.{ .name = "referer", .value = item.page_url }};
        var req = try self.client.request(.HEAD, uri, .{
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
        const response = try req.receiveHead(&head_buffer);
        if (response.head.status != .ok) return .unknown;
        return archiveHintFromHeaders(response.head.bytes);
    }
};

const ArchiveHint = enum {
    unknown,
    zip,
    rar,
    seven_z,
};

fn archiveHintFromHeaders(headers: []const u8) ArchiveHint {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-disposition")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.indexOfIgnoreCase(value, ".zip") != null) return .zip;
        if (std.ascii.indexOfIgnoreCase(value, ".rar") != null) return .rar;
        if (std.ascii.indexOfIgnoreCase(value, ".7z") != null) return .seven_z;
    }
    return .unknown;
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
    const subtitle_id = payload[0..sep];
    for (subtitle_id) |c| if (!std.ascii.isDigit(c)) return null;
    return .{ .subtitle_id = subtitle_id, .page_url = payload[sep + 1 ..] };
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
    const title_marker = "<h1><a";
    while (std.mem.indexOfPos(u8, body, cursor, title_marker)) |title_start| {
        const next = std.mem.indexOfPos(u8, body, title_start + title_marker.len, title_marker) orelse body.len;
        const block = body[title_start..next];
        cursor = next;

        const open_end = std.mem.indexOfPos(u8, block, title_marker.len, ">") orelse continue;
        const title_tail = block[open_end + 1 ..];
        const close = std.mem.indexOf(u8, title_tail, "</a>") orelse continue;
        const raw_title = std.mem.trim(u8, title_tail[0..close], " \t\r\n");
        if (raw_title.len == 0) continue;

        const id_marker = "get.php?id=";
        const id_pos = std.mem.indexOf(u8, block, id_marker) orelse continue;
        const id_tail = block[id_pos + id_marker.len ..];
        var id_end: usize = 0;
        while (id_end < id_tail.len and std.ascii.isDigit(id_tail[id_end])) : (id_end += 1) {}
        if (id_end == 0) continue;
        const subtitle_id = id_tail[0..id_end];
        if (seen.contains(subtitle_id)) continue;
        try seen.put(a, try a.dupe(u8, subtitle_id), {});

        const language_code: []const u8 = if (std.mem.indexOf(u8, block, "flags/1.gif") != null or std.mem.indexOf(u8, block, "[ Romana ]") != null)
            "ro"
        else if (std.mem.indexOf(u8, block, "flags/2.gif") != null or std.mem.indexOf(u8, block, "[ Engleza ]") != null)
            "en"
        else
            continue;

        const split = common.splitTrailingYear(raw_title);
        const clean_title = stripSeasonSuffix(split.title);
        const normalized = try common.normalizeTitle(a, clean_title);
        if (normalized.len == 0) continue;
        if (std.mem.indexOf(u8, normalized, wanted) == null and std.mem.indexOf(u8, wanted, normalized) == null) continue;

        const media_kind: MediaKind = if (hasSeasonSuffix(split.title)) .tv else .movie;
        const page_url = try std.fmt.allocPrint(a, "{s}/index.php?page={s}&z10={s}", .{ site, search_page, subtitle_id });
        const download_url = try std.fmt.allocPrint(a, "{s}/get.php?id={s}", .{ site, subtitle_id });
        const item: SearchItem = .{
            .title = try a.dupe(u8, clean_title),
            .year = split.year,
            .media_kind = media_kind,
            .language_code = try a.dupe(u8, language_code),
            .subtitle_id = try a.dupe(u8, subtitle_id),
            .page_url = page_url,
            .download_url = download_url,
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

fn hasSeasonSuffix(title: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(title, " - Sezonul ") != null or
        std.ascii.indexOfIgnoreCase(title, " - Sezoanele ") != null;
}

fn stripSeasonSuffix(title: []const u8) []const u8 {
    if (std.ascii.indexOfIgnoreCase(title, " - Sezonul ")) |idx| return std.mem.trimEnd(u8, title[0..idx], " \t");
    if (std.ascii.indexOfIgnoreCase(title, " - Sezoanele ")) |idx| return std.mem.trimEnd(u8, title[0..idx], " \t");
    return std.mem.trim(u8, title, " \t\r\n");
}

test "titrari parses movie and season pack results" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<h1><a href=x>The Matrix Resurrections (2021)</a></h1>[ Romana ]<img src=flags/1.gif><a href=get.php?id=142169>Descarca</a>" ++
        "<h1><a href=x>Reacher - Sezonul 4 (2022)</a></h1>[ Romana ]<img src=flags/1.gif><a href=get.php?id=142095>Descarca</a>";
    var response = try parseSearchHtml(
        arena,
        fixture,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Reacher", response.items[0].title);
    try std.testing.expectEqual(MediaKind.tv, response.items[0].media_kind);
    try std.testing.expectEqual(@as(?i64, 2022), response.items[0].year);
    try std.testing.expectEqualStrings("https://www.titrari.ro/get.php?id=142095", response.items[0].download_url);
    const token = try makeDownloadToken(std.testing.allocator, "142095", response.items[0].page_url);
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("142095", parseDownloadToken(token).?.subtitle_id);
}

test "live titrari movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "titrari.ro")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix Resurrections");
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
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}
