const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://www.sous-titres.eu";

pub const MediaKind = common.MediaKind;

pub const SearchItem = common.MediaSearchLink;

pub const SubtitleItem = struct {
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
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/search.html?q={s}", .{ site, encoded });
        const headers = [_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }};
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
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

        try validateProviderEndpoint(item.page_url, item.media_kind, .detail);
        const headers = [_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }};
        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var anchors = parsed.doc.queryAll("a.subList");
        const section = switch (item.media_kind) {
            .movie => site ++ "/films/",
            .tv => site ++ "/series/",
        };
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const filename_node = anchor.queryOne("span.filenameSerie") orelse
                anchor.queryOne("span.filenameFilm") orelse continue;
            const filename = try common.innerTextTrimmedOwned(a, filename_node);
            if (filename.len == 0) continue;
            const language_code = if (anchor.queryOne("span.lang img[alt]")) |img|
                try common.dupOptional(a, common.getAttributeValueSafe(img, "alt"))
            else
                null;

            const download_url = resolveProviderUrl(a, section, href, item.media_kind, .download) catch |err| {
                if (err == error.OutOfMemory or err == error.Canceled) return err;
                continue;
            };
            if (seen.contains(download_url)) continue;
            try seen.put(a, download_url, {});
            try subtitles.append(a, .{
                .language_code = language_code,
                .filename = filename,
                .download_url = download_url,
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }
};

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };
    var parsed = try common.parseHtmlStable(a, body);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var other: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var rows = parsed.doc.queryAll("li");
    while (rows.next()) |row| {
        const classes = common.getAttributeValueSafe(row, "class") orelse continue;
        const media_kind: MediaKind = if (hasClassToken(classes, "film"))
            .movie
        else if (hasClassToken(classes, "serie"))
            .tv
        else
            continue;

        const search_link = try firstValidSearchLink(a, row, media_kind) orelse continue;
        const title = search_link.title;

        const normalized = try common.normalizeTitle(a, title);
        if (!normalizedTitlesRelated(normalized, wanted)) continue;
        const page_url = search_link.page_url;
        if (seen.contains(page_url)) continue;
        try seen.put(a, page_url, {});

        const item: SearchItem = .{
            .title = title,
            .media_kind = media_kind,
            .page_url = page_url,
        };
        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(a, item)
        else
            try other.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, other.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

const SearchRowLink = struct {
    title: []const u8,
    page_url: []const u8,
};

fn firstValidSearchLink(allocator: Allocator, row: anytype, media_kind: MediaKind) !?SearchRowLink {
    var anchors = row.queryAll("h3 a[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const page_url = resolveProviderUrl(allocator, site, href, media_kind, .detail) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            continue;
        };
        const title = if (row.queryOne("img[alt]")) |img|
            try allocator.dupe(u8, common.getAttributeValueSafe(img, "alt") orelse "")
        else
            try common.innerTextTrimmedOwned(allocator, anchor);
        if (title.len == 0) continue;
        return .{ .title = title, .page_url = page_url };
    }
    return null;
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

const ProviderRoute = enum { detail, download };

fn resolveProviderUrl(allocator: Allocator, base: []const u8, href: []const u8, media_kind: MediaKind, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, base, href);
    errdefer allocator.free(resolved);
    try validateProviderEndpoint(resolved, media_kind, route);
    return resolved;
}

fn validateProviderEndpoint(url: []const u8, media_kind: MediaKind, route: ProviderRoute) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.query != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = switch (media_kind) {
        .movie => "/films/",
        .tv => "/series/",
    };
    if (!std.mem.startsWith(u8, path, prefix)) return error.UnsafeHttpTarget;
    const tail = path[prefix.len..];
    switch (route) {
        .detail => {
            if (std.mem.indexOfScalar(u8, tail, '/') != null or
                !std.ascii.endsWithIgnoreCase(tail, ".html") or
                !isSafeEncodedSegment(tail)) return error.UnsafeHttpTarget;
        },
        .download => {
            const download_prefix = "download/";
            if (!std.mem.startsWith(u8, tail, download_prefix)) return error.UnsafeHttpTarget;
            var segments = std.mem.splitScalar(u8, tail[download_prefix.len..], '/');
            var count: usize = 0;
            while (segments.next()) |segment| {
                if (!isSafeEncodedSegment(segment)) return error.UnsafeHttpTarget;
                count += 1;
            }
            if (count == 0) return error.UnsafeHttpTarget;
        },
    }
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
            if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~')) return false;
            index += 1;
        }
        if (byte < 0x20 or byte == 0x7f or byte == '%' or byte == '/' or byte == '\\' or byte == '?' or byte == '#') return false;
        decoded_len += 1;
        if (byte != '.') decoded_all_dots = false;
    }
    return !(decoded_all_dots and (decoded_len == 1 or decoded_len == 2));
}

fn hasClassToken(classes: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, classes, " \t\r\n");
    while (it.next()) |value| if (std.mem.eql(u8, value, token)) return true;
    return false;
}

test "sous-titres parses exact movie and series rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<ul>" ++
        "<li class=\"serie exact\"><img alt=\"Chernobyl\"/><h3><a href=\"https://attacker.example/archive.zip\">bad</a></h3></li>" ++
        "<li class=\"film exact\"><img alt=\"The Matrix\"/><h3><a href=\"films/the_matrix.html\">The Matrix (1999)</a></h3></li>" ++
        "<li class=\"serie exact\"><img alt=\"Chernobyl\"/><h3><a href=\"series/chernobyl.html\">Chernobyl</a></h3></li>" ++
        "</ul>";
    var response = try parseSearchHtml(
        arena,
        fixture,
        "Chernobyl",
    );
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Chernobyl", response.items[0].title);
    try std.testing.expect(response.items[0].media_kind == .tv);
    try std.testing.expectEqualStrings("https://www.sous-titres.eu/series/chernobyl.html", response.items[0].page_url);
}

test "sous-titres rows scan past a malformed first detail link" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        "<ul><li class='film exact'><img alt='The Matrix'/><h3>" ++
            "<a href='https://attacker.example/films/the_matrix.html'>bad</a>" ++
            "<a href='films/the_matrix.html'>The Matrix</a>" ++
            "</h3></li></ul>",
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqualStrings(site ++ "/films/the_matrix.html", response.items[0].page_url);
}

test "sous-titres title relevance rejects empty and partial-word matches" {
    try std.testing.expect(normalizedTitlesRelated("the matrix", "matrix"));
    try std.testing.expect(!normalizedTitlesRelated("preacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("the matrix", ""));
}

test "sous-titres rejects unsafe provider links before fetch" {
    const valid = try resolveProviderUrl(std.testing.allocator, site ++ "/films/", "download/token/the_matrix.zip", .movie, .download);
    defer std.testing.allocator.free(valid);
    try std.testing.expectEqualStrings(site ++ "/films/download/token/the_matrix.zip", valid);
    for ([_][]const u8{
        "http://127.0.0.1/private.zip",
        "https://user:pass@www.sous-titres.eu/private.zip",
        "https://www.google.com/private.zip",
        "https://www.sous-titres.eu/admin",
        "https://www.sous-titres.eu/films/file.zip",
        "https://www.sous-titres.eu/films/file.zip?next=/admin",
        "https://www.sous-titres.eu/films/file.zip#fragment",
        "https://www.sous-titres.eu/films/../admin.zip",
        "https://www.sous-titres.eu/films/a%2fb.zip",
        "https://www.sous-titres.eu/films/download/a%252fb.zip",
    }) |url| try std.testing.expectError(
        error.UnsafeHttpTarget,
        resolveProviderUrl(std.testing.allocator, site ++ "/films/", url, .movie, .download),
    );
}

test "live sous-titres movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "sous-titres.eu")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    try std.testing.expect(movie.items[0].media_kind == .movie);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    try std.testing.expect(movie_subtitles.subtitles.len > 0);

    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Chernobyl");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    try std.testing.expect(tv.items[0].media_kind == .tv);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    try std.testing.expect(tv_subtitles.subtitles.len > 0);
    try std.testing.expect(std.ascii.findIgnoreCase(tv_subtitles.subtitles[0].filename, "Chernobyl") != null);
}
