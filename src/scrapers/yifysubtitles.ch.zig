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

        const encoded_query = try common.encodeUriComponent(a, query);
        const url = try std.fmt.allocPrint(a, "{s}/ajax/search/?mov={s}", .{ site, encoded_query });

        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .max_attempts = 2,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const arr = switch (root) {
            .array => |v| v,
            else => return error.InvalidFieldType,
        };

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const movie = obj.get("movie") orelse continue;
            const imdb = obj.get("imdb") orelse continue;
            if (movie != .string or imdb != .string) continue;

            const link = try std.fmt.allocPrint(a, "{s}/movie-imdb/{s}", .{ site, imdb.string });
            try items.append(a, .{
                .movie = movie.string,
                .imdb_id = imdb.string,
                .movie_page_url = link,
            });
        }

        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesByMovieLink(self: *Scraper, movie_page_url: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, movie_page_url, .{ .accept = "text/html", .max_attempts = 2 });
        var parsed = try common.parseHtmlStable(a, response.body);
        defer parsed.deinit();

        const title_node = parsed.doc.queryOne("title");
        const title = if (title_node) |n|
            try n.innerTextWithOptions(a, .{ .normalize_whitespace = true })
        else
            "";

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var rows = parsed.doc.queryAll("table tbody tr");
        var had_rows = false;
        while (rows.next()) |row| {
            had_rows = true;
            const lang = if (row.queryOne("span.sub-lang")) |lang_node|
                try lang_node.innerTextWithOptions(a, .{ .normalize_whitespace = true })
            else
                "";

            const details_href = if (row.queryOne("a[href*='/subtitles/']")) |details_anchor|
                details_anchor.getAttributeValue("href") orelse continue
            else
                continue;

            const details_url = try common.resolveUrl(a, site, details_href);
            const zip_url = try subtitleToZipUrl(a, details_url);

            const release_text = if (row.queryOne("a > span.text-muted")) |release_node|
                try release_node.innerTextWithOptions(a, .{ .normalize_whitespace = true })
            else
                "";

            const rating = if (row.queryOne("span.label")) |rating_node|
                try rating_node.innerTextWithOptions(a, .{ .normalize_whitespace = true })
            else
                null;

            const uploader = if (row.queryOne("a[href*='/user/']")) |uploader_node|
                try uploader_node.innerTextWithOptions(a, .{ .normalize_whitespace = true })
            else
                null;

            try subtitles.append(a, .{
                .language = common.trimAscii(lang),
                .rating = rating,
                .uploader = uploader,
                .release_text = common.trimAscii(release_text),
                .details_url = details_url,
                .zip_url = zip_url,
            });
        }

        if (!had_rows) {
            var fallback_rows = parsed.doc.queryAll("table tr");
            while (fallback_rows.next()) |row| {
                const details_href = if (row.queryOne("a[href*='/subtitles/']")) |details_anchor|
                    details_anchor.getAttributeValue("href") orelse continue
                else
                    continue;
                const details_url = try common.resolveUrl(a, site, details_href);
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

        return .{
            .arena = arena,
            .title = title,
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }

    fn subtitleToZipUrl(allocator: Allocator, details_url: []const u8) ![]const u8 {
        const marker = "/subtitles/";
        const idx = std.mem.indexOf(u8, details_url, marker) orelse return error.InvalidDownloadUrl;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, details_url[0..idx]);
        try buf.appendSlice(allocator, "/subtitle/");
        try buf.appendSlice(allocator, details_url[idx + marker.len ..]);
        try buf.appendSlice(allocator, ".zip");
        return try buf.toOwnedSlice(allocator);
    }
};

test "yify zip url" {
    const allocator = std.testing.allocator;
    const url = try Scraper.subtitleToZipUrl(allocator, "https://yifysubtitles.ch/subtitles/the-matrix-english-yify-100");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://yifysubtitles.ch/subtitle/the-matrix-english-yify-100.zip", url);
}

test "live yify search and subtitle extraction" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "YIFY")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesByMovieLink(search.items[0].movie_page_url);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
}
