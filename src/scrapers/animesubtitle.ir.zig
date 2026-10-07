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
        return self.searchUsing(common.fetchBytes, query);
    }

    fn searchUsing(self: *Scraper, comptime fetch: anytype, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(
            a,
            "{s}/search?search={s}&type=post&subtype=post&per_page=20",
            .{ api, encoded },
        );
        const response = try fetch(self.client, a, url, .{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const array = switch (root) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen_ids = std.AutoHashMapUnmanaged(i64, void).empty;

        for (array.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const post_id = common.jsonInt(obj.get("id") orelse continue) orelse continue;
            const raw_title = common.jsonString(obj, "title") orelse continue;
            const page_url = common.jsonString(obj, "url") orelse continue;
            if (post_id <= 0 or page_url.len == 0) continue;
            validateProviderPageUrl(page_url) catch continue;
            if (seen_ids.contains(post_id)) continue;

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
            try seen_ids.put(a, post_id, {});
        }

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        try items.appendSlice(a, exact.items);
        try items.appendSlice(a, partial.items);
        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemUsing(common.fetchBytes, item);
    }

    fn fetchSubtitlesBySearchItemUsing(self: *Scraper, comptime fetch: anytype, item: SearchItem) !SubtitlesResponse {
        if (item.post_id <= 0) return error.InvalidDownloadUrl;
        try validateProviderPageUrl(item.page_url);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const url = try std.fmt.allocPrint(a, "{s}/posts/{d}", .{ api, item.post_id });
        const response = try fetch(self.client, a, url, .{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const obj = switch (root) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        try validatePostIdentity(obj, item);
        const content = nestedString(obj, &.{ "content", "rendered" }) orelse return error.MissingField;

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var cursor: usize = 0;
        while (nextDoubleQuotedHref(content, &cursor)) |link| {
            const href = link.href;
            if (std.mem.indexOf(u8, href, "/download/") == null) continue;

            const download_url = (try resolveOptionalPublicDownloadUrl(a, href)) orelse continue;
            if (seen.contains(download_url)) continue;
            try seen.put(a, download_url, {});
            const filename = try filenameNearHref(a, content, link.marker_pos, item.title);
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

const HrefMatch = struct {
    href: []const u8,
    marker_pos: usize,
};

fn nextDoubleQuotedHref(content: []const u8, cursor: *usize) ?HrefMatch {
    const marker = "href=\"";
    while (std.mem.indexOfPos(u8, content, cursor.*, marker)) |pos| {
        const start = pos + marker.len;
        const end_rel = std.mem.indexOfScalar(u8, content[start..], '"') orelse {
            cursor.* = start;
            continue;
        };
        const end = start + end_rel;
        if (std.mem.indexOfPos(u8, content, start, marker)) |nested| {
            if (nested < end) {
                cursor.* = nested;
                continue;
            }
        }
        cursor.* = end + 1;
        return .{ .href = content[start..end], .marker_pos = pos };
    }
    return null;
}

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

fn resolvePublicDownloadUrl(allocator: Allocator, href: []const u8) ![]const u8 {
    const unescaped = try htmlUnescapeUrl(allocator, href);
    defer allocator.free(unescaped);
    const resolved = try common.resolveUrl(allocator, site, unescaped);
    errdefer allocator.free(resolved);
    try common.validatePublicHttpUrl(resolved);
    if (!(try common.sameOrigin(site, resolved))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(resolved) catch return error.InvalidDownloadUrl;
    if (uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "/download/";
    if (!std.mem.startsWith(u8, path, prefix) or !isSafeEncodedPath(path[prefix.len..])) return error.InvalidDownloadUrl;
    return resolved;
}

fn resolveOptionalPublicDownloadUrl(allocator: Allocator, href: []const u8) !?[]const u8 {
    return resolvePublicDownloadUrl(allocator, href) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        return null;
    };
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

fn validatePostIdentity(obj: std.json.ObjectMap, item: SearchItem) !void {
    const detail_id = common.jsonInt(obj.get("id") orelse return error.InvalidDownloadUrl) orelse
        return error.InvalidDownloadUrl;
    if (detail_id != item.post_id) return error.InvalidDownloadUrl;
    const detail_link = common.jsonString(obj, "link") orelse return error.InvalidDownloadUrl;
    if (!canonicalProviderPagesEqual(detail_link, item.page_url)) return error.InvalidDownloadUrl;
}

fn canonicalProviderPagesEqual(a: []const u8, b: []const u8) bool {
    const a_path = canonicalProviderPagePath(a) orelse return false;
    const b_path = canonicalProviderPagePath(b) orelse return false;
    return std.mem.eql(u8, a_path, b_path);
}

fn canonicalProviderPagePath(url: []const u8) ?[]const u8 {
    validateProviderPageUrl(url) catch return null;
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    return if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
}

fn validateProviderPageUrl(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len < 2 or path[0] != '/' or std.mem.indexOf(u8, path, "//") != null) return error.InvalidDownloadUrl;
    const tail = if (path[path.len - 1] == '/') path[1 .. path.len - 1] else path[1..];
    if (!isSafeEncodedPath(tail)) return error.InvalidDownloadUrl;
    const first_end = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
    const first = tail[0..first_end];
    if (encodedAsciiEqualsIgnoreCase(first, "wp-admin") or
        encodedAsciiEqualsIgnoreCase(first, "wp-json") or
        encodedAsciiEqualsIgnoreCase(first, "wp-content") or
        encodedAsciiEqualsIgnoreCase(first, "wp-includes") or
        std.mem.count(u8, tail, "/") > 1) return error.InvalidDownloadUrl;
}

fn encodedAsciiEqualsIgnoreCase(encoded: []const u8, expected: []const u8) bool {
    var encoded_index: usize = 0;
    var expected_index: usize = 0;
    while (encoded_index < encoded.len and expected_index < expected.len) : (expected_index += 1) {
        const byte = if (encoded[encoded_index] == '%') blk: {
            if (encoded.len - encoded_index < 3) return false;
            const high = std.fmt.charToDigit(encoded[encoded_index + 1], 16) catch return false;
            const low = std.fmt.charToDigit(encoded[encoded_index + 2], 16) catch return false;
            encoded_index += 3;
            break :blk @as(u8, @intCast(high * 16 + low));
        } else blk: {
            const value = encoded[encoded_index];
            encoded_index += 1;
            break :blk value;
        };
        if (std.ascii.toLower(byte) != std.ascii.toLower(expected[expected_index])) return false;
    }
    return encoded_index == encoded.len and expected_index == expected.len;
}

fn isSafeEncodedPath(value: []const u8) bool {
    if (value.len == 0 or value.len > 2048) return false;
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |segment| {
        if (!isSafeEncodedSegment(segment)) return false;
    }
    return true;
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

test "animesubtitle ir extracts latin titles and media kind hints" {
    try std.testing.expectEqualStrings(
        "Given: Umi e",
        extractLatinTitle("زیرنویس فارسی فیلم انیمه ای Given: Umi e"),
    );
    try std.testing.expect(std.mem.indexOf(u8, "زیرنویس فارسی فیلم انیمه ای Given: Umi e", "فیلم") != null);
}

test "animesubtitle rejects normalized-empty searches before I/O" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.TestUnexpectedResult;
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetch, "---");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "animesubtitle binds REST post identity to the search permalink" {
    const item: SearchItem = .{
        .title = "Given",
        .post_id = 42,
        .media_kind = .movie,
        .page_url = site ++ "/given-umi-e",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const valid = try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        "{\"id\":42,\"link\":\"https://animesubtitle.ir/given-umi-e/\"}",
        .{},
    );
    try validatePostIdentity(valid.object, item);

    for ([_][]const u8{
        "{\"id\":41,\"link\":\"https://animesubtitle.ir/given-umi-e/\"}",
        "{\"id\":42,\"link\":\"https://animesubtitle.ir/other/\"}",
        "{\"id\":42,\"link\":\"https://animesubtitle.ir/given%2Dumi-e/\"}",
        "{\"id\":42,\"link\":\"https://animesubtitle.ir/given-umi-e/?next=/admin\"}",
        "{\"id\":42}",
        "{\"link\":\"https://animesubtitle.ir/given-umi-e/\"}",
        "{\"id\":42.5,\"link\":\"https://animesubtitle.ir/given-umi-e/\"}",
    }) |body| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        try std.testing.expectError(error.InvalidDownloadUrl, validatePostIdentity(parsed.object, item));
    }
}

test "animesubtitle detail fetch enforces HTTPS same-origin policy and identity" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(api ++ "/posts/42", url);
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);
            try std.testing.expect(options.require_same_origin);
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "{\"id\":42,\"link\":\"https://animesubtitle.ir/given-umi-e/\",\"content\":{\"rendered\":\"<a href=\\\"/download/given.zip\\\"><strong>given.zip</strong></a>\"}}"),
            };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
        .title = "Given",
        .post_id = 42,
        .media_kind = .movie,
        .page_url = site ++ "/given-umi-e/",
    });
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    try std.testing.expectEqualStrings(site ++ "/download/given.zip", response.subtitles[0].download_url);
}

test "animesubtitle rejects unsafe provider download URLs" {
    const allocator = std.testing.allocator;
    const valid = try resolvePublicDownloadUrl(allocator, "/download/subtitle.zip?x=1&amp;y=2");
    defer allocator.free(valid);
    try std.testing.expectEqualStrings("https://animesubtitle.ir/download/subtitle.zip?x=1&y=2", valid);

    for ([_][]const u8{
        "http://127.0.0.1/download/subtitle.zip",
        "https://user@example.com/download/subtitle.zip",
        "https://cdn.example.com/download/subtitle.zip",
        "https://animesubtitle.ir/admin/subtitle.zip",
        "https://animesubtitle.ir/download/../admin.zip",
        "https://animesubtitle.ir/download/a%2fb.zip",
        "https://animesubtitle.ir/download/a%252fb.zip",
        "https://animesubtitle.ir/download/subtitle.zip#fragment",
    }) |url| {
        const unexpected = resolvePublicDownloadUrl(allocator, url) catch continue;
        allocator.free(unexpected);
        return error.TestUnexpectedResult;
    }
}

test "animesubtitle canonical page routes and href recovery" {
    try validateProviderPageUrl("https://animesubtitle.ir/given-umi-e/");
    for ([_][]const u8{
        "https://animesubtitle.ir/wp-admin/users.php",
        "https://animesubtitle.ir/%77p-admin/users.php",
        "https://animesubtitle.ir/given/?next=/admin",
        "https://animesubtitle.ir/given/#fragment",
        "https://animesubtitle.ir/../admin",
        "https://animesubtitle.ir/a%2fb/",
        "https://animesubtitle.ir/a%252fb/",
        "https://attacker.example/given/",
    }) |url| {
        _ = validateProviderPageUrl(url) catch continue;
        return error.TestUnexpectedResult;
    }

    const invalid_item: SearchItem = .{
        .title = "Given",
        .post_id = 42,
        .media_kind = .movie,
        .page_url = "https://animesubtitle.ir/wp-json/wp/v2/posts/42",
    };
    try std.testing.expectError(error.InvalidDownloadUrl, validateProviderPageUrl(invalid_item.page_url));

    const html = "<a href=\"unterminated <a href=\"/download/valid.zip\"><strong>valid.zip</strong>";
    var cursor: usize = 0;
    const match = nextDoubleQuotedHref(html, &cursor).?;
    try std.testing.expectEqualStrings("/download/valid.zip", match.href);
}

test "animesubtitle optional fields preserve allocation failures" {
    var failing_url = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, resolveOptionalPublicDownloadUrl(failing_url.allocator(), "/download/subtitle.zip"));
    try std.testing.expect(failing_url.has_induced_failure);

    var failing_filename = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, filenameNearHref(failing_filename.allocator(), "href=\"/download/subtitle.zip\"><strong>subtitle.zip</strong>", 0, "Anime"));
    try std.testing.expect(failing_filename.has_induced_failure);

    const fallback = try filenameNearHref(std.testing.allocator, "href=\"/download/subtitle.zip\">", 0, "Anime");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("Anime.zip", fallback);
    try std.testing.expect((try resolveOptionalPublicDownloadUrl(std.testing.allocator, "http://127.0.0.1/download/subtitle.zip")) == null);
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
        .require_public_origin = true,
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
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}
