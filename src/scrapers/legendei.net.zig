const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://legendei.net";
const api_search = site ++ "/wp-json/wp/v2/search";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    post_id: i64,
    media_kind: MediaKind,
    season: ?i64,
    episode: ?i64,
    language_code: []const u8,
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
        const wanted = try common.normalizeTitle(a, stripReleaseNoise(trimmed));
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}?search={s}&per_page=20", .{ api_search, encoded });
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
            const post_id = jsonInt(obj, "id") orelse continue;
            const title = common.jsonString(obj, "title") orelse continue;
            const page_url = common.jsonString(obj, "url") orelse continue;
            if (post_id <= 0 or title.len == 0 or page_url.len == 0) continue;
            validateProviderUrl(page_url) catch continue;
            if (seen_ids.contains(post_id)) continue;

            const se = common.parseSeasonEpisode(title);
            const media_kind: MediaKind = if (se.episode != null) .tv else .movie;
            const canonical = stripReleaseNoise(title);
            const normalized = try common.normalizeTitle(a, canonical);
            if (normalized.len == 0) continue;
            if (std.mem.indexOf(u8, normalized, wanted) == null and
                std.mem.indexOf(u8, wanted, normalized) == null) continue;

            const item: SearchItem = .{
                .title = try a.dupe(u8, title),
                .post_id = post_id,
                .media_kind = media_kind,
                .season = se.season,
                .episode = se.episode,
                .language_code = try a.dupe(u8, languageCodeFromTitle(title)),
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        if (item.post_id <= 0) return error.InvalidDownloadUrl;
        try validateProviderUrl(item.page_url);

        const response = try fetch(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        const download_url = if (try parseExplicitDownloadHref(a, response.body, item.page_url, item.post_id)) |url|
            url
        else blk: {
            const identity_url = try std.fmt.allocPrint(a, "{s}/wp-json/wp/v2/posts/{d}", .{ site, item.post_id });
            const identity_response = try fetch(self.client, a, identity_url, .{
                .accept = "application/json",
                .cache = false,
                .max_attempts = 2,
                .require_public_origin = true,
                .require_https = true,
                .require_same_origin = true,
            });
            const identity_root = try std.json.parseFromSliceLeaky(std.json.Value, a, identity_response.body, .{});
            const identity_obj = switch (identity_root) {
                .object => |value| value,
                else => return error.InvalidFieldType,
            };
            try validatePostIdentity(identity_obj, item);
            break :blk try std.fmt.allocPrint(
                a,
                "{s}/wp-content/themes/simple-grid/zip-attachments.php?post_id={d}",
                .{ site, item.post_id },
            );
        };

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = try std.fmt.allocPrint(a, "legendei-{d}-{s}.zip", .{ item.post_id, item.language_code }),
            .download_url = download_url,
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn parseExplicitDownloadHref(
    allocator: Allocator,
    body: []const u8,
    page_url: []const u8,
    expected_post_id: i64,
) !?[]const u8 {
    var anchor_cursor: usize = 0;
    while (anchorHrefBeforeText(body, "BAIXAR LEGENDA", &anchor_cursor)) |href| {
        const resolved = resolveExplicitDownloadUrl(allocator, page_url, href, expected_post_id) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            continue;
        };
        return resolved;
    }

    const pattern = "?dl_id=";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, pattern)) |pos| {
        cursor = pos + pattern.len;
        const quote_start = std.mem.lastIndexOfScalar(u8, body[0..pos], '"') orelse continue;
        const tail = body[quote_start + 1 ..];
        const quote_end = std.mem.indexOfScalar(u8, tail, '"') orelse continue;
        const resolved = resolveExplicitDownloadUrl(allocator, page_url, tail[0..quote_end], expected_post_id) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            continue;
        };
        return resolved;
    }

    return null;
}

fn resolveExplicitDownloadUrl(
    allocator: Allocator,
    page_url: []const u8,
    href: []const u8,
    expected_post_id: i64,
) ![]const u8 {
    if (expected_post_id <= 0) return error.InvalidDownloadUrl;
    const resolved = try resolvePublicDownloadUrl(allocator, page_url, href);
    errdefer allocator.free(resolved);

    const uri = std.Uri.parse(resolved) catch return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/") or uri.query == null) return error.InvalidDownloadUrl;

    const query_start = std.mem.indexOfScalar(u8, resolved, '?') orelse return error.InvalidDownloadUrl;
    const query = resolved[query_start + 1 ..];
    const prefix = "dl_id=";
    if (!std.mem.startsWith(u8, query, prefix)) return error.InvalidDownloadUrl;
    const id = query[prefix.len..];
    if (!isCanonicalPositivePostId(id)) return error.InvalidDownloadUrl;
    const parsed_id = std.fmt.parseInt(i64, id, 10) catch return error.InvalidDownloadUrl;
    if (parsed_id != expected_post_id) return error.InvalidDownloadUrl;
    return resolved;
}

fn isCanonicalPositivePostId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn resolvePublicDownloadUrl(allocator: Allocator, page_url: []const u8, href: []const u8) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, page_url, href);
    errdefer allocator.free(resolved);
    try common.validatePublicHttpUrl(resolved);
    if (!(try common.sameOrigin(site, resolved))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(resolved) catch return error.InvalidDownloadUrl;
    if (uri.fragment != null) return error.InvalidDownloadUrl;
    return resolved;
}

fn validateProviderUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len < 2 or path[0] != '/' or std.mem.indexOf(u8, path, "//") != null) return error.InvalidDownloadUrl;
    const without_trailing = if (path[path.len - 1] == '/') path[1 .. path.len - 1] else path[1..];
    var segments = std.mem.splitScalar(u8, without_trailing, '/');
    var segment_count: usize = 0;
    while (segments.next()) |segment| {
        if (!isSafeEncodedSegment(segment)) return error.InvalidDownloadUrl;
        if (segment_count == 0 and isReservedProviderSegment(segment)) return error.InvalidDownloadUrl;
        segment_count += 1;
    }
    if (segment_count == 0 or segment_count > 2) return error.InvalidDownloadUrl;
}

fn validatePostIdentity(obj: std.json.ObjectMap, item: SearchItem) !void {
    const detail_id = jsonInt(obj, "id") orelse return error.InvalidDownloadUrl;
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
    validateProviderUrl(url) catch return null;
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    return if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
}

fn isReservedProviderSegment(segment: []const u8) bool {
    return encodedAsciiEqualsIgnoreCase(segment, "wp-admin") or
        encodedAsciiEqualsIgnoreCase(segment, "wp-json") or
        encodedAsciiEqualsIgnoreCase(segment, "wp-content") or
        encodedAsciiEqualsIgnoreCase(segment, "wp-includes") or
        encodedAsciiEqualsIgnoreCase(segment, "wp-login.php") or
        encodedAsciiEqualsIgnoreCase(segment, "xmlrpc.php");
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

fn isSafeEncodedSegment(value: []const u8) bool {
    if (value.len == 0 or value.len > 512) return false;
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

fn anchorHrefBeforeText(body: []const u8, needle: []const u8, cursor: *usize) ?[]const u8 {
    while (std.mem.indexOfPos(u8, body, cursor.*, needle)) |text_pos| {
        cursor.* = text_pos + needle.len;
        const prefix = body[0..text_pos];
        const anchor_pos = std.mem.lastIndexOf(u8, prefix, "<a ") orelse continue;
        const tag_end = std.mem.indexOfPos(u8, body, anchor_pos, ">") orelse continue;
        if (tag_end > text_pos) continue;
        if (std.ascii.findIgnoreCase(body[tag_end + 1 ..], "</a")) |close_rel| {
            if (tag_end + 1 + close_rel < text_pos) continue;
        }
        const tag = body[anchor_pos .. tag_end + 1];
        if (attributeValue(tag, "href")) |href| return href;
    }
    return null;
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, tag, cursor, name)) |marker| {
        cursor = marker + name.len;
        if (isInsideAttributeQuote(tag[0..marker])) continue;
        if (marker > 0 and tag[marker - 1] != '<' and !std.ascii.isWhitespace(tag[marker - 1])) continue;
        var eq = cursor;
        while (eq < tag.len and std.ascii.isWhitespace(tag[eq])) : (eq += 1) {}
        if (eq >= tag.len or tag[eq] != '=') continue;
        eq += 1;
        while (eq < tag.len and std.ascii.isWhitespace(tag[eq])) : (eq += 1) {}
        if (eq >= tag.len) return null;
        const quote = tag[eq];
        if (quote != '"' and quote != '\'') continue;
        const start = eq + 1;
        const end_rel = std.mem.indexOfScalar(u8, tag[start..], quote) orelse return null;
        return tag[start .. start + end_rel];
    }
    return null;
}

fn isInsideAttributeQuote(prefix: []const u8) bool {
    var quote: ?u8 = null;
    for (prefix) |byte| {
        if (quote) |active| {
            if (byte == active) quote = null;
        } else if (byte == '"' or byte == '\'') {
            quote = byte;
        }
    }
    return quote != null;
}

fn languageCodeFromTitle(title: []const u8) []const u8 {
    if (std.ascii.findIgnoreCase(title, "English Subtitle") != null) return "en";
    if (std.ascii.findIgnoreCase(title, "Español") != null or
        std.ascii.findIgnoreCase(title, "Spanish Subtitle") != null) return "es";
    return "pt";
}

fn stripReleaseNoise(value: []const u8) []const u8 {
    const parsed = common.parseEpisodeQuery(value);
    if (parsed.episode != null) return parsed.title;

    const markers = [_][]const u8{
        " BluRay", " WEB DL", " WEB-DL", " 1080p", " 2160p", " 720p", " BRRip",
        " HDR ",   " WEBDL",  " WEBRip",
    };
    var end = value.len;
    for (markers) |marker| {
        if (std.ascii.findIgnoreCase(value[0..end], marker)) |pos|
            end = @min(end, pos);
    }
    return std.mem.trim(u8, value[0..end], " \t-._");
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}

test "legendei parses media hints and download anchor" {
    const allocator = std.testing.allocator;
    const se = common.parseSeasonEpisode("Chernobyl S01E01 1080p");
    try std.testing.expectEqual(@as(?i64, 1), se.season);
    try std.testing.expectEqual(@as(?i64, 1), se.episode);
    try std.testing.expectEqualStrings("pt", languageCodeFromTitle("Chernobyl S01E01"));
    try std.testing.expectEqualStrings("en", languageCodeFromTitle("Chernobyl S01E01 [English Subtitle]"));

    const url = (try parseExplicitDownloadHref(
        allocator,
        "<a href=\"https://legendei.net/?dl_id=26215\"><i></i> BAIXAR LEGENDA</a>",
        site ++ "/post/",
        26215,
    )) orelse return error.MissingField;
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://legendei.net/?dl_id=26215", url);
}

test "legendei rejects normalized-empty searches before HTTPS same-origin I/O" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(api_search ++ "?search=Matrix&per_page=20", url);
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);
            try std.testing.expect(options.require_same_origin);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "[]") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var empty = try scraper.searchUsing(Fixture.fetch, "---");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);

    var normal = try scraper.searchUsing(Fixture.fetch, "Matrix");
    defer normal.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), normal.items.len);
}

test "legendei binds the synthesized fallback to a fresh REST identity" {
    const Case = struct { body: []const u8, accepted: bool };
    const Fixture = struct {
        client: std.http.Client,
        identity_body: []const u8,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);
            try std.testing.expect(options.require_same_origin);
            return switch (self.calls) {
                1 => blk: {
                    try std.testing.expectEqualStrings(site ++ "/post/example", url);
                    break :blk .{ .status = .ok, .body = try allocator.dupe(u8, "<html>No explicit download</html>") };
                },
                2 => blk: {
                    try std.testing.expectEqualStrings(site ++ "/wp-json/wp/v2/posts/42", url);
                    break :blk .{ .status = .ok, .body = try allocator.dupe(u8, self.identity_body) };
                },
                else => error.TestUnexpectedResult,
            };
        }
    };

    for ([_]Case{
        .{ .body = "{\"id\":42,\"link\":\"https://legendei.net/post/example/\"}", .accepted = true },
        .{ .body = "{\"id\":41,\"link\":\"https://legendei.net/post/example/\"}", .accepted = false },
        .{ .body = "{\"id\":42,\"link\":\"https://legendei.net/post/other/\"}", .accepted = false },
        .{ .body = "{\"id\":42,\"link\":\"https://legendei.net/post/example/?next=/admin\"}", .accepted = false },
        .{ .body = "{\"id\":42}", .accepted = false },
    }) |case| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .identity_body = case.body,
        };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        const item: SearchItem = .{
            .title = "Example",
            .post_id = 42,
            .media_kind = .movie,
            .season = null,
            .episode = null,
            .language_code = "pt",
            .page_url = site ++ "/post/example",
        };
        if (case.accepted) {
            var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, item);
            defer response.deinit();
            try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
            try std.testing.expectEqualStrings(
                site ++ "/wp-content/themes/simple-grid/zip-attachments.php?post_id=42",
                response.subtitles[0].download_url,
            );
        } else {
            try std.testing.expectError(
                error.InvalidDownloadUrl,
                scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, item),
            );
        }
        try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    }
}

test "legendei download scanner skips an unsafe leading anchor" {
    const url = (try parseExplicitDownloadHref(
        std.testing.allocator,
        "<a href=\"http://127.0.0.1/private.zip\">BAIXAR LEGENDA</a>" ++
            "<a href=\"/?dl_id=42\">BAIXAR LEGENDA</a>",
        site ++ "/post/example",
        42,
    )) orelse return error.MissingField;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(site ++ "/?dl_id=42", url);
    try std.testing.expectEqualStrings("/right.zip", attributeValue("<a data-href=\"/wrong.zip\" href = \"/right.zip\">", "href").?);
    try std.testing.expectEqualStrings("/right.zip", attributeValue("<a title=\" href='/wrong.zip'\" href=\"/right.zip\">", "href").?);
}

test "legendei download text must belong to its anchor" {
    const url = (try parseExplicitDownloadHref(
        std.testing.allocator,
        "<a href=\"/wrong.zip\">Other</a> BAIXAR LEGENDA" ++
            "<a href=\"/?dl_id=42\">BAIXAR LEGENDA</a>",
        site ++ "/post/example",
        42,
    )) orelse return error.MissingField;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(site ++ "/?dl_id=42", url);
}

test "legendei explicit downloads require the root route and matching post id" {
    const body =
        "<a href=\"https://evil.example/?dl_id=42\">BAIXAR LEGENDA</a>" ++
        "<a href=\"/?dl_id=41\">BAIXAR LEGENDA</a>" ++
        "<a href=\"/?dl_id=042\">BAIXAR LEGENDA</a>" ++
        "<a href=\"/?download=42\">BAIXAR LEGENDA</a>" ++
        "<a href=\"/post/example?dl_id=42\">BAIXAR LEGENDA</a>" ++
        "<a href=\"/?dl_id=42&next=/admin\">BAIXAR LEGENDA</a>" ++
        "<a href=\"/?dl_id=42\">BAIXAR LEGENDA</a>";
    const url = (try parseExplicitDownloadHref(
        std.testing.allocator,
        body,
        site ++ "/post/example",
        42,
    )) orelse return error.MissingField;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(site ++ "/?dl_id=42", url);

    try std.testing.expect((try parseExplicitDownloadHref(
        std.testing.allocator,
        "<a href=\"/?download=42\">BAIXAR LEGENDA</a>",
        site ++ "/post/example",
        42,
    )) == null);
}

test "legendei rejects unsafe provider and download targets" {
    try validateProviderUrl("https://legendei.net/post/example");
    for ([_][]const u8{
        "https://legendei.net.example/post/example",
        "https://user@legendei.net/post/example",
        "https://legendei.net/wp-admin/users.php",
        "https://legendei.net/%77p-admin/users.php",
        "https://legendei.net/post/example?next=/admin",
        "https://legendei.net/post/example#fragment",
        "https://legendei.net/post/../admin",
        "https://legendei.net/post/a%2fb",
        "https://legendei.net/post/a%252fb",
        "https://legendei.net/a/b/c",
    }) |url| try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url));
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        resolvePublicDownloadUrl(std.testing.allocator, site ++ "/post/example", "http://127.0.0.1/archive.zip"),
    );
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        resolvePublicDownloadUrl(std.testing.allocator, site ++ "/post/example", "https://attacker.example/archive.zip"),
    );
    try std.testing.expectError(
        error.InvalidDownloadUrl,
        resolvePublicDownloadUrl(std.testing.allocator, site ++ "/post/example", "/archive.zip#fragment"),
    );
}

test "live legendei movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "legendei.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix Resurrections");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subs = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subs.deinit();
    const movie_dl = try common.fetchBytes(&client, std.testing.allocator, movie_subs.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(movie_dl.body);
    try std.testing.expect(movie_dl.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_dl.body[0..2], "PK"));

    var tv = try scraper.search("Chernobyl S01E01");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    var tv_subs = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subs.deinit();
    const tv_dl = try common.fetchBytes(&client, std.testing.allocator, tv_subs.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(tv_dl.body);
    try std.testing.expect(tv_dl.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_dl.body[0..2], "PK"));
}

test "release noise truncation uses the season marker not title letters" {
    try std.testing.expectEqualStrings("The Last of Us", stripReleaseNoise("The Last of Us S01E01"));
    try std.testing.expectEqualStrings("House", stripReleaseNoise("House S01E01"));
    try std.testing.expectEqualStrings("Specials", stripReleaseNoise("Specials S00E01"));
}
