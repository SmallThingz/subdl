const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

const site = "https://yifysubtitles.ch";

pub const SearchItem = struct {
    movie: []const u8,
    imdb_id: []const u8,
    movie_page_url: []const u8,
};

pub const SubtitleItem = struct {
    language: []const u8,
    rating: ?[]const u8,
    uploader: ?[]const u8,
    release_text: []const u8,
    details_url: []const u8,
    zip_url: []const u8,
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

        const trimmed_query = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed_query.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, trimmed_query);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded_query = try common.encodeUriComponent(a, trimmed_query);
        const url = try std.fmt.allocPrint(a, "{s}/ajax/search/?mov={s}", .{ site, encoded_query });

        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });

        return parseSearchJson(common.takeArena(&arena), response.body, trimmed_query);
    }

    pub fn fetchSubtitlesByMovieLink(self: *Scraper, movie_page_url: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(movie_page_url, .movie);

        const response = try common.fetchBytes(self.client, a, movie_page_url, .{
            .accept = "text/html",
            .max_attempts = 2,
            .cache = false,
            .require_public_origin = true,
            .require_https = true,
        });
        if (response.body.len == 0) return error.UnexpectedHttpStatus;
        var parsed = try common.parseHtmlStable(a, response.body);

        const title_node = parsed.doc.queryOne("title");
        const title = if (title_node) |n|
            try common.innerTextTrimmedOwned(a, n)
        else
            "";

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var rows = parsed.doc.queryAll("table tbody tr");
        while (rows.next()) |row| {
            const lang = if (row.queryOne("span.sub-lang")) |lang_node|
                try common.innerTextTrimmedOwned(a, lang_node)
            else
                "";

            const details_url = try firstValidDetailsUrl(a, row) orelse continue;
            const zip_url = try subtitleToZipUrl(a, details_url);

            const release_text = if (row.queryOne("a > span.text-muted")) |release_node|
                try common.innerTextTrimmedOwned(a, release_node)
            else
                "";

            const rating = if (row.queryOne("span.label")) |rating_node|
                try common.innerTextTrimmedOwned(a, rating_node)
            else
                null;

            const uploader = if (row.queryOne("a[href*='/user/']")) |uploader_node|
                try common.innerTextTrimmedOwned(a, uploader_node)
            else
                null;

            try subtitles.append(a, .{
                .language = lang,
                .rating = rating,
                .uploader = uploader,
                .release_text = release_text,
                .details_url = details_url,
                .zip_url = zip_url,
            });
        }

        if (subtitles.items.len == 0) {
            var fallback_rows = parsed.doc.queryAll("table tr");
            while (fallback_rows.next()) |row| {
                const details_url = try firstValidDetailsUrl(a, row) orelse continue;
                const zip_url = try subtitleToZipUrl(a, details_url);
                try subtitles.append(a, .{
                    .language = "",
                    .rating = null,
                    .uploader = null,
                    .release_text = "",
                    .details_url = details_url,
                    .zip_url = zip_url,
                });
            }
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = title,
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }

    fn subtitleToZipUrl(allocator: Allocator, details_url: []const u8) ![]const u8 {
        try validateProviderUrl(details_url, .details);
        const uri = std.Uri.parse(details_url) catch return error.InvalidDownloadUrl;
        const path = switch (uri.path) {
            .raw, .percent_encoded => |value| value,
        };
        const slug = detailsSlug(path) orelse return error.InvalidDownloadUrl;
        const url = try std.fmt.allocPrint(allocator, site ++ "/subtitle/{s}.zip", .{slug});
        errdefer allocator.free(url);
        try validateProviderUrl(url, .download);
        return url;
    }
};

fn firstValidDetailsUrl(allocator: Allocator, row: anytype) !?[]const u8 {
    var anchors = row.queryAll("a[href*='/subtitles/']");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const details_url = resolveProviderUrl(allocator, href, .details) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        return details_url;
    }
    return null;
}

fn parseSearchJson(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const arr = switch (root) {
        .array => |value| value,
        else => return error.InvalidFieldType,
    };

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    for (arr.items) |value| {
        const obj = switch (value) {
            .object => |item| item,
            else => continue,
        };
        const movie = common.jsonString(obj, "movie") orelse continue;
        const imdb = common.jsonString(obj, "imdb") orelse continue;
        if (!isCanonicalImdbTitleId(imdb)) continue;

        const normalized = try common.normalizeTitle(a, movie);
        const exact_match = std.mem.eql(u8, normalized, wanted);
        if (!exact_match and !common.normalizedTitlesRelated(normalized, wanted)) continue;

        const item: SearchItem = .{
            .movie = movie,
            .imdb_id = imdb,
            .movie_page_url = try std.fmt.allocPrint(a, "{s}/movie-imdb/{s}", .{ site, imdb }),
        };
        if (exact_match) try exact.append(a, item) else try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

const ProviderRoute = enum { movie, details, download };

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderUrl(resolved, route);
    return resolved;
}

fn validateProviderUrl(url: []const u8, route: ProviderRoute) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.UnsafeHttpTarget;
    }
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const valid = switch (route) {
        .movie => movieImdbId(path) != null,
        .details => detailsSlug(path) != null,
        .download => downloadSlug(path) != null,
    };
    if (!valid) return error.UnsafeHttpTarget;
}

fn movieImdbId(path: []const u8) ?[]const u8 {
    const prefix = "/movie-imdb/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const id = path[prefix.len..];
    if (!isCanonicalImdbTitleId(id)) return null;
    return id;
}

fn detailsSlug(path: []const u8) ?[]const u8 {
    const prefix = "/subtitles/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const raw_slug = path[prefix.len..];
    const slug = if (std.mem.endsWith(u8, raw_slug, "/")) raw_slug[0 .. raw_slug.len - 1] else raw_slug;
    if (!isSafeEncodedSegment(slug)) return null;
    return slug;
}

fn downloadSlug(path: []const u8) ?[]const u8 {
    const prefix = "/subtitle/";
    const suffix = ".zip";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const slug = path[prefix.len .. path.len - suffix.len];
    if (!isSafeEncodedSegment(slug)) return null;
    return slug;
}

fn isSafeEncodedSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 512 or
        std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    var decoded_len: usize = 0;
    var decoded_all_dots = true;
    var index: usize = 0;
    while (index < segment.len) {
        const c = segment[index];
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@", c) != null) {
            decoded_len += 1;
            if (c != '.') decoded_all_dots = false;
            index += 1;
            continue;
        }
        if (c != '%' or segment.len - index < 3 or
            !std.ascii.isHex(segment[index + 1]) or !std.ascii.isHex(segment[index + 2])) return false;
        const decoded = std.fmt.parseInt(u8, segment[index + 1 .. index + 3], 16) catch return false;
        if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
            decoded == '?' or decoded == '#' or decoded == '%') return false;
        decoded_len += 1;
        if (decoded != '.') decoded_all_dots = false;
        index += 3;
    }
    return !(decoded_all_dots and decoded_len <= 2);
}

fn isCanonicalImdbTitleId(value: []const u8) bool {
    if (value.len < 9 or value.len > 12 or !std.mem.startsWith(u8, value, "tt")) return false;
    var any_nonzero = false;
    for (value[2..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
        any_nonzero = any_nonzero or c != '0';
    }
    return any_nonzero;
}

test "yify zip url" {
    const allocator = std.testing.allocator;
    const url = try Scraper.subtitleToZipUrl(allocator, "https://yifysubtitles.ch/subtitles/the-matrix-english-yify-100");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://yifysubtitles.ch/subtitle/the-matrix-english-yify-100.zip", url);
}

test "yify zip URL rejects noncanonical detail routes" {
    try std.testing.expectError(error.UnsafeHttpTarget, Scraper.subtitleToZipUrl(std.testing.allocator, "https://yifysubtitles.ch/subtitles/title/?download=1#file"));
    try std.testing.expectError(error.UnsafeHttpTarget, Scraper.subtitleToZipUrl(std.testing.allocator, "https://yifysubtitles.ch/subtitles/?download=1"));
    try std.testing.expectError(error.UnsafeHttpTarget, Scraper.subtitleToZipUrl(std.testing.allocator, "https://yifysubtitles.ch/subtitles/a%252fb"));
    try std.testing.expectError(error.UnsafeHttpTarget, Scraper.subtitleToZipUrl(std.testing.allocator, "https://yifysubtitles.ch/admin/subtitles/title"));
}

test "yify rejects unsafe provider urls before fetch" {
    try validateProviderUrl(site ++ "/subtitles/caf%C3%A9", .details);
    for ([_][]const u8{
        "http://127.0.0.1/subtitles/x",
        "https://user@yifysubtitles.ch/subtitles/x",
        "https://yifysubtitles.ch.attacker.example/subtitles/x",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(url, .details));
    }
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(site ++ "/movie-imdb/tt0133093/extra", .movie));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(site ++ "/subtitle/title.zip?next=/", .download));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(site ++ "/subtitles/%2e%2E", .details));
}

test "yify accepts only canonical imdb title identifiers" {
    try std.testing.expect(isCanonicalImdbTitleId("tt0133093"));
    try std.testing.expect(isCanonicalImdbTitleId("tt1234567890"));
    for ([_][]const u8{ "TT0133093", "tt123", "tt0000000", "tt0000000000", "tt0133093/extra", "tt0133093?x=1", "nm0133093" }) |value| {
        try std.testing.expect(!isCanonicalImdbTitleId(value));
    }
}

test "yify subtitle rows scan past malformed first details anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed = try common.parseHtmlStable(
        arena.allocator(),
        "<table><tr><td><a href='https://attacker.example/subtitles/shadow'>bad</a>" ++
            "<a href='/subtitles/the-matrix-english-yify-100'>good</a></td></tr></table>",
    );
    defer parsed.deinit();
    const row = parsed.doc.queryOne("tr") orelse return error.TestUnexpectedResult;
    const url = try firstValidDetailsUrl(arena.allocator(), row) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        site ++ "/subtitles/the-matrix-english-yify-100",
        url,
    );
}

test "yify empty search does not acquire the provider" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.search(" \t\r\n");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "yify search relevance uses the returned movie field" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchJson(
        arena,
        \\[{"movie":"Preacher","imdb":"tt1234567"},{"movie":"Jack Reacher","imdb":"tt0790724"},{"movie":"The Matrix","imdb":"tt0133093"}]
    ,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Jack Reacher", response.items[0].movie);
    try std.testing.expectEqualStrings("tt0790724", response.items[0].imdb_id);
}

test "live yify search and subtitle extraction" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "YIFY")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    const item = search.items[0];
    std.debug.print("[live][yifysubtitles.ch][search][0]\n", .{});
    try common.livePrintField(std.testing.allocator, "movie", item.movie);
    try common.livePrintField(std.testing.allocator, "imdb_id", item.imdb_id);
    try common.livePrintField(std.testing.allocator, "movie_page_url", item.movie_page_url);

    var subtitles = try scraper.fetchSubtitlesByMovieLink(item.movie_page_url);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    try common.livePrintField(std.testing.allocator, "subtitles_title", subtitles.title);
    const sub = subtitles.subtitles[0];
    std.debug.print("[live][yifysubtitles.ch][subtitle][0]\n", .{});
    try common.livePrintField(std.testing.allocator, "language", sub.language);
    try common.livePrintOptionalField(std.testing.allocator, "rating", sub.rating);
    try common.livePrintOptionalField(std.testing.allocator, "uploader", sub.uploader);
    try common.livePrintField(std.testing.allocator, "release_text", sub.release_text);
    try common.livePrintField(std.testing.allocator, "details_url", sub.details_url);
    try common.livePrintField(std.testing.allocator, "zip_url", sub.zip_url);
}
