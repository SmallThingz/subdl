const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const site = "https://jimaku.cc";
const catalog_url = site ++ "/";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    english_name: ?[]const u8,
    japanese_name: ?[]const u8,
    media_kind: MediaKind,
    entry_id: i64,
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

        const response = try common.fetchBytes(self.client, a, catalog_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .max_attempts = 2,
            .require_public_origin = true,
        });
        return parseCatalog(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const page_entry_id = try validateEntryUrl(item.page_url);
        if (page_entry_id != item.entry_id) return error.InvalidDownloadUrl;

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = catalog_url }},
            .max_attempts = 2,
            .require_public_origin = true,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var anchors = parsed.doc.queryAll("a.file-name[href^='/entry/']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.mem.indexOf(u8, href, "/download/") == null) continue;

            const filename = try common.innerTextTrimmedOwned(a, anchor);
            if (!isSupportedFile(filename)) continue;
            if (seen.contains(href)) continue;
            try seen.put(a, try a.dupe(u8, href), {});

            const download_url = common.resolveUrl(a, site, href) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            validateDownloadUrl(download_url, item.entry_id) catch continue;

            try subtitles.append(a, .{
                .language_code = "ja",
                .filename = filename,
                .download_url = download_url,
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.english_name orelse item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }
};

fn providerPath(url: []const u8) ![]const u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len > 4096) return error.InvalidDownloadUrl;
    return path;
}

fn validateEntryUrl(url: []const u8) !i64 {
    const path = try providerPath(url);
    const prefix = "/entry/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidDownloadUrl;
    const id_text = path[prefix.len..];
    if (!isCanonicalPositiveInteger(id_text)) return error.InvalidDownloadUrl;
    return std.fmt.parseInt(i64, id_text, 10) catch return error.InvalidDownloadUrl;
}

fn validateDownloadUrl(url: []const u8, expected_entry_id: i64) !void {
    if (expected_entry_id <= 0) return error.InvalidDownloadUrl;
    const path = try providerPath(url);
    const prefix = "/entry/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidDownloadUrl;

    const after_prefix = path[prefix.len..];
    const marker = "/download/";
    const marker_index = std.mem.indexOf(u8, after_prefix, marker) orelse return error.InvalidDownloadUrl;
    const id_text = after_prefix[0..marker_index];
    if (!isCanonicalPositiveInteger(id_text)) return error.InvalidDownloadUrl;
    const entry_id = std.fmt.parseInt(i64, id_text, 10) catch return error.InvalidDownloadUrl;
    if (entry_id != expected_entry_id) return error.InvalidDownloadUrl;
    if (!isSafeEncodedFilename(after_prefix[marker_index + marker.len ..])) return error.InvalidDownloadUrl;
}

fn isCanonicalPositiveInteger(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isSafeEncodedFilename(value: []const u8) bool {
    if (value.len == 0 or value.len > 3072) return false;
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

fn parseCatalog(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    const wanted = try normalizeTitle(a, query);
    var parsed = try common.parseHtmlStable(a, body);

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.AutoHashMapUnmanaged(i64, void).empty;

    var rows = parsed.doc.queryAll("div.entry[data-extra]");
    while (rows.next()) |row| {
        var anchors = row.queryAll("a.file-name[href^='/entry/']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const page_url = common.resolveUrl(a, site, href) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            const entry_id = validateEntryUrl(page_url) catch continue;
            if (seen.contains(entry_id)) continue;

            const metadata_raw = common.getAttributeValueSafe(row, "data-extra") orelse continue;
            const metadata = try decodeHtmlEntities(a, metadata_raw);
            const json = (try parseCatalogMetadata(a, metadata)) orelse continue;
            const obj = switch (json) {
                .object => |value| value,
                else => continue,
            };

            const name = jsonString(obj, "name") orelse try common.innerTextTrimmedOwned(a, anchor);
            const english_name = jsonString(obj, "english_name");
            const japanese_name = jsonString(obj, "japanese_name");
            const flags = common.jsonIntField(obj, "flags") orelse 0;
            const media_kind: MediaKind = if ((flags & 8) != 0) .movie else .tv;

            const norm_name = try normalizeTitle(a, name);
            const norm_english = if (english_name) |value| try normalizeTitle(a, value) else "";
            const norm_japanese = if (japanese_name) |value| try normalizeTitle(a, value) else "";

            const matches = containsNormalized(norm_name, wanted) or
                containsNormalized(norm_english, wanted) or
                containsNormalized(norm_japanese, wanted);
            if (!matches) continue;

            try seen.put(a, entry_id, {});
            const item: SearchItem = .{
                .title = try a.dupe(u8, name),
                .english_name = if (english_name) |value| try a.dupe(u8, value) else null,
                .japanese_name = if (japanese_name) |value| try a.dupe(u8, value) else null,
                .media_kind = media_kind,
                .entry_id = entry_id,
                .page_url = page_url,
            };

            const is_exact = std.mem.eql(u8, norm_name, wanted) or
                (english_name != null and std.mem.eql(u8, norm_english, wanted)) or
                (japanese_name != null and std.mem.eql(u8, norm_japanese, wanted));
            if (is_exact)
                try exact.append(a, item)
            else
                try partial.append(a, item);
            break;
        }
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn parseCatalogMetadata(allocator: Allocator, metadata: []const u8) Allocator.Error!?std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, metadata, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

fn containsNormalized(candidate: []const u8, wanted: []const u8) bool {
    if (candidate.len == 0 or wanted.len == 0) return false;
    return std.mem.indexOf(u8, candidate, wanted) != null or
        std.mem.indexOf(u8, wanted, candidate) != null;
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
        } else if (c >= 0x80) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, c);
        } else {
            pending_space = out.items.len > 0;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn decodeHtmlEntities(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "&#34;")) {
            try out.append(allocator, '"');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&#39;")) {
            try out.append(allocator, '\'');
            i += 5;
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

fn isSupportedFile(filename: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(filename, ".srt") or
        std.ascii.endsWithIgnoreCase(filename, ".ass") or
        std.ascii.endsWithIgnoreCase(filename, ".ssa") or
        std.ascii.endsWithIgnoreCase(filename, ".vtt") or
        std.ascii.endsWithIgnoreCase(filename, ".sub") or
        std.ascii.endsWithIgnoreCase(filename, ".zip") or
        std.ascii.endsWithIgnoreCase(filename, ".7z");
}

test "jimaku rejects non-provider entry targets" {
    try std.testing.expectEqual(@as(i64, 440), try validateEntryUrl("https://jimaku.cc/entry/440"));
    for ([_][]const u8{
        "http://127.0.0.1/entry/440",
        "https://jimaku.cc.example/entry/440",
        "https://user@jimaku.cc/entry/440",
        "https://jimaku.cc/entry/440/extra",
        "https://jimaku.cc/entry/0440",
        "https://jimaku.cc/entry/440?next=/admin",
        "https://jimaku.cc/entry/%34%34%30",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateEntryUrl(url));
    }
}

test "jimaku accepts only bound single-segment download routes" {
    try validateDownloadUrl(
        "https://jimaku.cc/entry/440/download/%5BGroup%5D%20Movie%20(1080p).ass",
        440,
    );
    for ([_][]const u8{
        "https://jimaku.cc/entry/441/download/movie.ass",
        "https://jimaku.cc/entry/440/download/../admin",
        "https://jimaku.cc/entry/440/download/%2e%2e",
        "https://jimaku.cc/entry/440/download/a%2fb.ass",
        "https://jimaku.cc/entry/440/download/a%252fb.ass",
        "https://jimaku.cc/entry/440/download/a.ass/extra",
        "https://jimaku.cc/entry/440/download/a.ass?next=/admin",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateDownloadUrl(url, 440));
    }
}

test "jimaku parses movie and tv catalog entries" {
    const movie_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var movie = try parseCatalog(
        movie_arena,
        "<div class=\"entry\" data-extra=\"{&#34;name&#34;:&#34;Kimi no Na wa.&#34;,&#34;flags&#34;:13,&#34;english_name&#34;:&#34;Your Name.&#34;,&#34;japanese_name&#34;:&#34;君の名は。&#34;}\"><a href=\"/entry/440\" class=\"table-data file-name\">Kimi no Na wa.</a></div>",
        "Your Name",
    );
    defer movie.deinit();
    try std.testing.expectEqual(@as(usize, 1), movie.items.len);
    try std.testing.expectEqual(MediaKind.movie, movie.items[0].media_kind);
    try std.testing.expectEqual(@as(i64, 440), movie.items[0].entry_id);

    const tv_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var tv = try parseCatalog(
        tv_arena,
        "<div class=\"entry\" data-extra=\"{&#34;name&#34;:&#34;86: Eighty Six&#34;,&#34;flags&#34;:5,&#34;english_name&#34;:&#34;86 EIGHTY-SIX&#34;,&#34;japanese_name&#34;:&#34;86－エイティシックス－&#34;}\"><a href=\"/entry/940\" class=\"table-data file-name\">86: Eighty Six</a></div>",
        "86 Eighty Six",
    );
    defer tv.deinit();
    try std.testing.expectEqual(@as(usize, 1), tv.items.len);
    try std.testing.expectEqual(MediaKind.tv, tv.items[0].media_kind);
}

test "jimaku scans past malformed same-row entry candidates" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseCatalog(
        arena,
        "<div class=\"entry\" data-extra=\"{&#34;name&#34;:&#34;Your Name&#34;,&#34;flags&#34;:13}\"><a href=\"/entry/0\" class=\"file-name\">decoy</a><a href=\"/entry/440\" class=\"file-name\">Your Name</a></div>",
        "Your Name",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqual(@as(i64, 440), response.items[0].entry_id);
    try std.testing.expectEqualStrings("https://jimaku.cc/entry/440", response.items[0].page_url);
}

test "jimaku catalog metadata skips malformed JSON and preserves allocation errors" {
    try std.testing.expect((try parseCatalogMetadata(std.testing.allocator, "not-json")) == null);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        parseCatalogMetadata(failing.allocator(), "{\"name\":\"test\"}"),
    );
}

test "live jimaku movie and tv direct downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "jimaku.cc")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Kimi no Na wa");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subs = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subs.deinit();
    try std.testing.expect(movie_subs.subtitles.len > 0);

    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subs.subtitles[0].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 32);

    var tv = try scraper.search("86 Eighty Six");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    var tv_subs = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subs.deinit();
    try std.testing.expect(tv_subs.subtitles.len >= 10);

    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subs.subtitles[0].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 32);
}
