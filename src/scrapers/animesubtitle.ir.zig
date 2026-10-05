const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://animesubtitle.ir";
const api = site ++ "/wp-json/wp/v2";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    post_id: i64,
    media_kind: MediaKind,
    page_url: []const u8,
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
            "{s}/search?search={s}&type=post&subtype=post&per_page=20",
            .{ api, encoded },
        );
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

        const wanted = try common.normalizeTitle(a, trimmed);
        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

        for (array.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const post_id = common.jsonInt(obj.get("id") orelse continue) orelse continue;
            const raw_title = common.jsonString(obj, "title") orelse continue;
            const page_url = common.jsonString(obj, "url") orelse continue;
            if (post_id <= 0 or page_url.len == 0) continue;

            const title = extractLatinTitle(raw_title);
            if (title.len == 0) continue;
            const normalized = try common.normalizeTitle(a, title);
            if (std.mem.indexOf(u8, normalized, wanted) == null and
                std.mem.indexOf(u8, wanted, normalized) == null) continue;

            const item: SearchItem = .{
                .title = try a.dupe(u8, title),
                .post_id = post_id,
                .media_kind = if (std.mem.indexOf(u8, raw_title, "فیلم") != null) .movie else .tv,
                .page_url = try a.dupe(u8, page_url),
            };
            if (std.mem.eql(u8, normalized, wanted))
                try exact.append(a, item)
            else
                try partial.append(a, item);
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

        const url = try std.fmt.allocPrint(a, "{s}/posts/{d}", .{ api, item.post_id });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
        });
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const obj = switch (root) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const content = nestedString(obj, &.{ "content", "rendered" }) orelse return error.MissingField;

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var cursor: usize = 0;
        const marker = "href=\"";
        while (std.mem.indexOfPos(u8, content, cursor, marker)) |pos| {
            const start = pos + marker.len;
            const end_rel = std.mem.indexOfScalar(u8, content[start..], '"') orelse break;
            const href = content[start .. start + end_rel];
            cursor = start + end_rel + 1;
            if (std.mem.indexOf(u8, href, "/download/") == null) continue;
            if (seen.contains(href)) continue;
            try seen.put(a, try a.dupe(u8, href), {});

            const download_url = try htmlUnescapeUrl(a, href);
            const filename = filenameNearHref(a, content, pos, item.title) catch
                try std.fmt.allocPrint(a, "{s}.zip", .{item.title});
            try subtitles.append(a, .{
                .language_code = "fa",
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

fn filenameNearHref(allocator: Allocator, content: []const u8, href_pos: usize, fallback: []const u8) ![]u8 {
    const window_end = @min(content.len, href_pos + 700);
    const window = content[href_pos..window_end];
    const open = std.mem.indexOf(u8, window, "<strong>") orelse
        return std.fmt.allocPrint(allocator, "{s}.zip", .{fallback});
    const tail = window[open + "<strong>".len ..];
    const close = std.mem.indexOf(u8, tail, "</strong>") orelse
        return std.fmt.allocPrint(allocator, "{s}.zip", .{fallback});
    const filename = std.mem.trim(u8, tail[0..close], " \t\r\n");
    if (filename.len == 0) return std.fmt.allocPrint(allocator, "{s}.zip", .{fallback});
    return allocator.dupe(u8, filename);
}

fn extractLatinTitle(value: []const u8) []const u8 {
    var start: ?usize = null;
    for (value, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c)) {
            start = i;
            break;
        }
    }
    const from = start orelse return "";
    return std.mem.trim(u8, value[from..], " \t\r\n-:|");
}

fn htmlUnescapeUrl(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "&#038;")) {
            try out.append(allocator, '&');
            i += 6;
        } else if (std.mem.startsWith(u8, input[i..], "&amp;")) {
            try out.append(allocator, '&');
            i += 5;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn nestedString(root: std.json.ObjectMap, path: []const []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    var value = root.get(path[0]) orelse return null;
    for (path[1..]) |key| {
        const obj = switch (value) {
            .object => |map| map,
            else => return null,
        };
        value = obj.get(key) orelse return null;
    }
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

test "animesubtitle ir extracts latin titles and media kind hints" {
    try std.testing.expectEqualStrings(
        "Given: Umi e",
        extractLatinTitle("زیرنویس فارسی فیلم انیمه ای Given: Umi e"),
    );
    try std.testing.expect(std.mem.indexOf(u8, "زیرنویس فارسی فیلم انیمه ای Given: Umi e", "فیلم") != null);
}

test "live animesubtitle ir movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "animesubtitle.ir")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Given Umi e");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    try std.testing.expect(movie.items[0].media_kind == .movie);
    var movie_subs = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subs.deinit();
    try std.testing.expect(movie_subs.subtitles.len > 0);
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subs.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Wind Breaker");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    try std.testing.expect(tv.items[0].media_kind == .tv);
    var tv_subs = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subs.deinit();
    try std.testing.expect(tv_subs.subtitles.len > 0);
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subs.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}
