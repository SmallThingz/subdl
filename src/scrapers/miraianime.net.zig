const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://miraianime.net";
const api = site ++ "/wp-json/wp/v2";

pub const MediaKind = enum {
    movie,
    tv,
};

pub const SearchItem = struct {
    title: []const u8,
    english_title: ?[]const u8,
    anime_id: i64,
    media_kind: MediaKind,
    episodes: ?i64,
    page_url: []const u8,
    subtitle_page_url: []const u8,
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
        const url = try std.fmt.allocPrint(a, "{s}/search?search={s}&per_page=20", .{ api, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const array = switch (root) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        const wanted = try normalizeTitle(a, trimmed);
        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var inspected: usize = 0;

        for (array.items) |entry| {
            if (inspected >= 10) break;
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const subtype = jsonString(obj, "subtype") orelse continue;
            if (!std.mem.eql(u8, subtype, "anime")) continue;
            const anime_id = jsonIntFromObject(obj, "id") orelse continue;
            const search_title = jsonString(obj, "title") orelse continue;
            const page_url = jsonString(obj, "url") orelse continue;
            if (anime_id <= 0 or search_title.len == 0 or page_url.len == 0) continue;
            inspected += 1;

            const detail_url = try std.fmt.allocPrint(a, "{s}/anime/{d}", .{ api, anime_id });
            const detail_response = common.fetchBytes(self.client, a, detail_url, .{
                .accept = "application/json",
                .cache = false,
                .max_attempts = 2,
            }) catch continue;
            const detail = try std.json.parseFromSliceLeaky(std.json.Value, a, detail_response.body, .{});
            const detail_obj = switch (detail) {
                .object => |value| value,
                else => continue,
            };

            const rendered_title = nestedString(detail_obj, &.{ "title", "rendered" }) orelse search_title;
            const english_title = nestedString(detail_obj, &.{ "acf", "basic_data", "anime_titles", "english_title" });
            const type_code = nestedString(detail_obj, &.{ "acf", "basic_data", "type" }) orelse "";
            const episodes = nestedInt(detail_obj, &.{ "acf", "basic_data", "episodes" });
            const media_kind: MediaKind = if (std.mem.eql(u8, type_code, "3") or (episodes != null and episodes.? == 1))
                .movie
            else
                .tv;

            const slug = pageSlug(page_url) orelse continue;
            const subtitle_page_url = try std.fmt.allocPrint(a, "{s}/subtitle/{s}/", .{ site, slug });
            const title = try a.dupe(u8, rendered_title);
            const item: SearchItem = .{
                .title = title,
                .english_title = if (english_title) |value| try a.dupe(u8, value) else null,
                .anime_id = anime_id,
                .media_kind = media_kind,
                .episodes = episodes,
                .page_url = try a.dupe(u8, page_url),
                .subtitle_page_url = subtitle_page_url,
            };

            const normalized_title = try normalizeTitle(a, title);
            const normalized_english = if (english_title) |value| try normalizeTitle(a, value) else "";
            if (std.mem.eql(u8, normalized_title, wanted) or
                (normalized_english.len > 0 and std.mem.eql(u8, normalized_english, wanted)))
            {
                try exact.append(a, item);
            } else {
                try partial.append(a, item);
            }
        }

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        try items.appendSlice(a, exact.items);
        try items.appendSlice(a, partial.items);
        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.subtitle_page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = item.page_url }},
            .cache = false,
            .max_attempts = 2,
        });
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        var parsed = try common.parseHtmlStable(a, response.body);
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var anchors = parsed.doc.queryAll("a.download-file[href]");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.ascii.indexOfIgnoreCase(href, "font") != null) continue;
            if (!hasArchiveExtension(href)) continue;
            if (seen.contains(href)) continue;
            try seen.put(a, try a.dupe(u8, href), {});

            const download_url = try common.resolveUrl(a, site, href);
            try subtitles.append(a, .{
                .language_code = "ar",
                .filename = try filenameFromUrl(a, download_url, item.title),
                .download_url = download_url,
            });
        }

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }
};

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonIntFromObject(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return jsonInt(value);
}

fn jsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        .float => |number| @intFromFloat(number),
        else => null,
    };
}

fn nestedValue(root: std.json.ObjectMap, path: []const []const u8) ?std.json.Value {
    if (path.len == 0) return null;
    var value = root.get(path[0]) orelse return null;
    for (path[1..]) |key| {
        const obj = switch (value) {
            .object => |map| map,
            else => return null,
        };
        value = obj.get(key) orelse return null;
    }
    return value;
}

fn nestedString(root: std.json.ObjectMap, path: []const []const u8) ?[]const u8 {
    const value = nestedValue(root, path) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn nestedInt(root: std.json.ObjectMap, path: []const []const u8) ?i64 {
    const value = nestedValue(root, path) orelse return null;
    return jsonInt(value);
}

fn pageSlug(page_url: []const u8) ?[]const u8 {
    var end = page_url.len;
    while (end > 0 and page_url[end - 1] == '/') end -= 1;
    if (end == 0) return null;
    const slash = std.mem.lastIndexOfScalar(u8, page_url[0..end], '/') orelse return null;
    if (slash + 1 >= end) return null;
    return page_url[slash + 1 .. end];
}

fn hasArchiveExtension(url: []const u8) bool {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..end];
    return std.ascii.endsWithIgnoreCase(path, ".zip") or
        std.ascii.endsWithIgnoreCase(path, ".rar") or
        std.ascii.endsWithIgnoreCase(path, ".7z");
}

fn filenameFromUrl(allocator: Allocator, url: []const u8, fallback_title: []const u8) ![]u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..end];
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const filename = path[slash + 1 ..];
        if (filename.len > 0) return allocator.dupe(u8, filename);
    }
    return std.fmt.allocPrint(allocator, "{s}.zip", .{fallback_title});
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

test "miraianime parses anime media kind metadata" {
    const allocator = std.testing.allocator;
    const json =
        "{\"title\":{\"rendered\":\"Kimi no Na wa.\"},\"acf\":{\"basic_data\":{\"type\":\"3\",\"episodes\":1,\"anime_titles\":{\"english_title\":\"Your Name.\"}}}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3", nestedString(root, &.{ "acf", "basic_data", "type" }).?);
    try std.testing.expectEqual(@as(?i64, 1), nestedInt(root, &.{ "acf", "basic_data", "episodes" }));
}

test "live miraianime movie and tv subtitle packs" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "miraianime.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Kimi no Na wa");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    try std.testing.expect(movie.items[0].media_kind == .movie);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    try std.testing.expect(movie_subtitles.subtitles.len > 0);
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Death Note");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    try std.testing.expect(tv.items[0].media_kind == .tv);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    try std.testing.expect(tv_subtitles.subtitles.len > 0);
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}
