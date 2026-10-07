const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://subtitles.ajatt.top";
const raw_site = "https://raw.githubusercontent.com";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    english_name: ?[]const u8,
    japanese_name: ?[]const u8,
    media_kind: MediaKind,
    page_url: []const u8,
};

pub const SubtitleItem = common.DownloadSubtitleFile;

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

        if (std.mem.trim(u8, query, " \t\r\n").len == 0) return .{ .arena = arena, .items = &.{} };

        const response = try common.fetchBytes(self.client, a, site ++ "/", .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });
        return parseIndex(common.takeArena(&arena), response.body, query);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        try validateProviderEndpoint(item.page_url, item.media_kind);

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var anchors = parsed.doc.queryAll("a[href^='https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            validateRawEndpoint(href) catch continue;
            const filename = if (common.getAttributeValueSafe(anchor, "download")) |download|
                try a.dupe(u8, download)
            else
                try common.innerTextTrimmedOwned(a, anchor);
            if (!isSafeOutputFilename(filename)) continue;
            if (seen.contains(href)) continue;
            try seen.put(a, href, {});
            try subtitles.append(a, .{
                .filename = filename,
                .download_url = try a.dupe(u8, href),
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }
};

fn parseIndex(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const normalized_query = try normalizeForSearch(a, query);
    if (normalized_query.len == 0) return .{ .arena = owned_arena, .items = &.{} };

    var parsed = try common.parseHtmlStable(a, body);
    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    var rows = parsed.doc.queryAll("tr[data-entry-type]");
    while (rows.next()) |row| {
        const media_kind = parseMediaKind(common.getAttributeValueSafe(row, "data-entry-type") orelse "") orelse continue;
        const catalog_link = try firstValidCatalogLink(a, row, media_kind) orelse continue;
        const title = catalog_link.title;

        const english_name = if (row.queryOne("td.english_name")) |node| blk: {
            const text = try common.innerTextTrimmedOwned(a, node);
            break :blk if (text.len > 0) text else null;
        } else null;
        const japanese_name = if (row.queryOne("td.japanese_name")) |node| blk: {
            const text = try common.innerTextTrimmedOwned(a, node);
            break :blk if (text.len > 0) text else null;
        } else null;

        if (!try rowMatchesQuery(a, normalized_query, title, english_name, japanese_name)) continue;
        try items.append(a, .{
            .title = title,
            .english_name = english_name,
            .japanese_name = japanese_name,
            .media_kind = media_kind,
            .page_url = catalog_link.page_url,
        });
    }

    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

const CatalogLink = struct {
    title: []const u8,
    page_url: []const u8,
};

fn firstValidCatalogLink(allocator: Allocator, row: anytype, media_kind: MediaKind) !?CatalogLink {
    const cell = row.queryOne("td.entry_name") orelse return null;
    var anchors = cell.queryAll("a[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const page_url = resolveProviderUrl(allocator, href, media_kind) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const title = try common.innerTextTrimmedOwned(allocator, anchor);
        if (title.len == 0) continue;
        return .{ .title = title, .page_url = page_url };
    }
    return null;
}

fn parseMediaKind(value: []const u8) ?MediaKind {
    if (std.mem.eql(u8, value, "anime_movie")) return .movie;
    if (std.mem.eql(u8, value, "anime_tv")) return .tv;
    return null;
}

fn rowMatchesQuery(
    allocator: Allocator,
    normalized_query: []const u8,
    title: []const u8,
    english_name: ?[]const u8,
    japanese_name: ?[]const u8,
) !bool {
    if (try normalizedContains(allocator, title, normalized_query)) return true;
    if (english_name) |value| if (try normalizedContains(allocator, value, normalized_query)) return true;
    if (japanese_name) |value| if (try normalizedContains(allocator, value, normalized_query)) return true;
    return false;
}

fn normalizedContains(allocator: Allocator, value: []const u8, normalized_query: []const u8) !bool {
    const normalized = try normalizeForSearch(allocator, value);
    return common.normalizedTitlesRelated(normalized, normalized_query);
}

fn normalizeForSearch(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, std.ascii.toLower(c));
            continue;
        }
        if (c >= 0x80) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, c);
            continue;
        }
        pending_space = out.items.len > 0;
    }
    return out.toOwnedSlice(allocator);
}

fn resolveProviderUrl(allocator: Allocator, href: []const u8, media_kind: MediaKind) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderEndpoint(resolved, media_kind);
    return resolved;
}

fn validateProviderEndpoint(url: []const u8, media_kind: MediaKind) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = switch (media_kind) {
        .movie => "/anime_movie/",
        .tv => "/anime_tv/",
    };
    if (!std.mem.startsWith(u8, path, prefix)) return error.UnsafeHttpTarget;
    const filename = path[prefix.len..];
    if (!isSafeEncodedSegment(filename) or !std.ascii.endsWithIgnoreCase(filename, ".html"))
        return error.UnsafeHttpTarget;
}

fn validateRawEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(raw_site, url))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/subtitles/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.UnsafeHttpTarget;
    var segments = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const media_dir = segments.next() orelse return error.UnsafeHttpTarget;
    if (!(std.mem.eql(u8, media_dir, "anime_movie") or std.mem.eql(u8, media_dir, "anime_tv")))
        return error.UnsafeHttpTarget;
    var segment_count: usize = 0;
    var last: []const u8 = "";
    while (segments.next()) |segment| {
        if (!isSafeEncodedSegment(segment)) return error.UnsafeHttpTarget;
        segment_count += 1;
        last = segment;
    }
    if (segment_count < 2 or !common.isSubtitleFilename(last)) return error.UnsafeHttpTarget;
}

fn isSafeEncodedSegment(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024) return false;
    var decoded_len: usize = 0;
    var decoded_all_dots = true;
    var index: usize = 0;
    while (index < value.len) {
        var byte = value[index];
        if (byte == '%') {
            if (value.len - index < 3) return false;
            const high = std.fmt.charToDigit(value[index + 1], 16) catch return false;
            const low = std.fmt.charToDigit(value[index + 2], 16) catch return false;
            byte = @intCast(high * 16 + low);
            index += 3;
        } else {
            if (byte == '/' or byte == '\\' or byte == '?' or byte == '#') return false;
            index += 1;
        }
        if (byte < 0x20 or byte == 0x7f or byte == '%' or byte == '/' or byte == '\\' or byte == '?' or byte == '#') return false;
        decoded_len += 1;
        if (byte != '.') decoded_all_dots = false;
    }
    return !(decoded_all_dots and (decoded_len == 1 or decoded_len == 2));
}

fn isSafeOutputFilename(value: []const u8) bool {
    if (value.len == 0 or value.len > 512 or !common.isSubtitleFilename(value) or
        std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\') return false;
    }
    return true;
}

test "ajatt rejects unsafe provider and raw download endpoints" {
    try validateProviderEndpoint(site ++ "/anime_tv/death-note.html", .tv);
    try validateRawEndpoint(raw_site ++ "/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/subtitles/anime_tv/DEATH%20NOTE/episode.srt");
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/private", .tv));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@subtitles.ajatt.top/anime_tv/test.html", .tv));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://subtitles.ajatt.top.evil.com/anime_tv/test.html", .tv));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/anime_movie/test.html", .tv));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/anime_tv/a%2fb.html", .tv));
    try std.testing.expectError(error.UnsafeHttpTarget, validateRawEndpoint("https://raw.githubusercontent.com.evil.com/repo/file.srt"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateRawEndpoint(raw_site ++ "/other/repo/refs/heads/main/subtitles/anime_tv/show/file.srt"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateRawEndpoint(raw_site ++ "/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/subtitles/anime_tv/show/a%2fb.srt"));
    try std.testing.expect(!isSafeOutputFilename("../episode.srt"));
}

test "ajatt parses movie and tv catalog rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseIndex(
        arena,
        \\<table>
        \\<tr data-entry-type="anime_tv"><td class="entry_name"><a href="anime_tv/death-note.html">DEATH NOTE</a></td><td class="english_name">Death Note</td><td class="japanese_name">DEATH NOTE</td></tr>
        \\<tr data-entry-type="anime_movie"><td class="entry_name"><a href="anime_movie/sen-to-chihiro-no-kamikakushi.html">Sen to Chihiro no Kamikakushi</a></td><td class="english_name">Spirited Away</td><td class="japanese_name">千と千尋の神隠し</td></tr>
        \\</table>
    ,
        "Death Note",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqual(MediaKind.tv, response.items[0].media_kind);
    try std.testing.expectEqualStrings("https://subtitles.ajatt.top/anime_tv/death-note.html", response.items[0].page_url);
}

test "ajatt catalog rows scan past a malformed first entry link" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseIndex(
        arena,
        \\<table><tr data-entry-type="anime_tv"><td class="entry_name">
        \\<a href="anime_movie/death-note.html">wrong route</a>
        \\<a href="anime_tv/death-note.html">Death Note</a>
        \\</td></tr></table>
    ,
        "Death Note",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Death Note", response.items[0].title);
    try std.testing.expectEqualStrings(site ++ "/anime_tv/death-note.html", response.items[0].page_url);
}

test "ajatt search relevance respects normalized token boundaries" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseIndex(
        arena,
        \\<table>
        \\<tr data-entry-type="anime_tv"><td class="entry_name"><a href="anime_tv/preacher.html">Preacher</a></td></tr>
        \\<tr data-entry-type="anime_tv"><td class="entry_name"><a href="anime_tv/jack-reacher.html">Jack Reacher</a></td></tr>
        \\<tr data-entry-type="anime_movie"><td class="entry_name"><a href="anime_movie/unrelated.html">Unrelated</a></td><td class="english_name">Reacher: The Movie</td></tr>
        \\</table>
    ,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings("Jack Reacher", response.items[0].title);
    try std.testing.expectEqualStrings("Unrelated", response.items[1].title);
}

test "ajatt empty search does not download the catalog" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.search(" \t\r\n");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "live ajatt movie search" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitles.ajatt.top")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Spirited Away");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    try std.testing.expect(search.items[0].media_kind == .movie);
}

test "live ajatt tv search and subtitle listing" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitles.ajatt.top")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Death Note");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, subtitles.subtitles[0].download_url, "https://raw.githubusercontent.com/"));
}
