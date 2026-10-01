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
        });
        return parseCatalog(arena, response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = catalog_url }},
            .max_attempts = 2,
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

            try subtitles.append(a, .{
                .language_code = "ja",
                .filename = filename,
                .download_url = try common.resolveUrl(a, site, href),
            });
        }

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.english_name orelse item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }
};

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
        const anchor = row.queryOne("a.file-name[href^='/entry/']") orelse continue;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const entry_id = parseEntryId(href) orelse continue;
        if (seen.contains(entry_id)) continue;

        const metadata_raw = common.getAttributeValueSafe(row, "data-extra") orelse continue;
        const metadata = try decodeHtmlEntities(a, metadata_raw);
        const json = std.json.parseFromSliceLeaky(std.json.Value, a, metadata, .{}) catch continue;
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
            .page_url = try common.resolveUrl(a, site, href),
        };

        const is_exact = std.mem.eql(u8, norm_name, wanted) or
            (english_name != null and std.mem.eql(u8, norm_english, wanted)) or
            (japanese_name != null and std.mem.eql(u8, norm_japanese, wanted));
        if (is_exact)
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) };
}

fn parseEntryId(href: []const u8) ?i64 {
    const marker = "/entry/";
    const pos = std.mem.indexOf(u8, href, marker) orelse return null;
    const tail = href[pos + marker.len ..];
    var end: usize = 0;
    while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(i64, tail[0..end], 10) catch null;
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
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 32);
}
