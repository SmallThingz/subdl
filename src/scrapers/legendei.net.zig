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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}?search={s}&per_page=20", .{ api_search, encoded });
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
        const wanted = try common.normalizeTitle(a, stripReleaseNoise(trimmed));
        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

        for (array.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const post_id = jsonInt(obj, "id") orelse continue;
            const title = common.jsonString(obj, "title") orelse continue;
            const page_url = common.jsonString(obj, "url") orelse continue;
            if (post_id <= 0 or title.len == 0 or page_url.len == 0) continue;

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

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
        });
        const download_url = try parseDownloadHref(a, response.body, item.page_url, item.post_id);

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = try std.fmt.allocPrint(a, "legendei-{d}-{s}.zip", .{ item.post_id, item.language_code }),
            .download_url = download_url,
        };
        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        };
    }
};

fn parseDownloadHref(allocator: Allocator, body: []const u8, page_url: []const u8, post_id: i64) ![]const u8 {
    if (anchorHrefBeforeText(body, "BAIXAR LEGENDA")) |href|
        return common.resolveUrl(allocator, page_url, href);

    const patterns = [_][]const u8{ "?dl_id=", "?download=" };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, body, pattern)) |pos| {
            const quote_start = std.mem.lastIndexOfScalar(u8, body[0..pos], '"') orelse continue;
            const tail = body[quote_start + 1 ..];
            const quote_end = std.mem.indexOfScalar(u8, tail, '"') orelse continue;
            return common.resolveUrl(allocator, page_url, tail[0..quote_end]);
        }
    }

    return std.fmt.allocPrint(
        allocator,
        "{s}/wp-content/themes/simple-grid/zip-attachments.php?post_id={d}",
        .{ site, post_id },
    );
}

fn anchorHrefBeforeText(body: []const u8, needle: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, needle)) |text_pos| {
        cursor = text_pos + needle.len;
        const prefix = body[0..text_pos];
        const anchor_pos = std.mem.lastIndexOf(u8, prefix, "<a ") orelse continue;
        const tag_end = std.mem.indexOfPos(u8, body, anchor_pos, ">") orelse continue;
        if (tag_end > text_pos) continue;
        const tag = body[anchor_pos .. tag_end + 1];
        if (attributeValue(tag, "href")) |href| return href;
    }
    return null;
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, tag, name) orelse return null;
    const eq = std.mem.indexOfPos(u8, tag, marker + name.len, "=") orelse return null;
    if (eq + 1 >= tag.len) return null;
    const quote = tag[eq + 1];
    if (quote != '"' and quote != '\'') return null;
    const start = eq + 2;
    const end_rel = std.mem.indexOfScalar(u8, tag[start..], quote) orelse return null;
    return tag[start .. start + end_rel];
}

fn languageCodeFromTitle(title: []const u8) []const u8 {
    if (std.ascii.findIgnoreCase(title, "English Subtitle") != null) return "en";
    if (std.ascii.findIgnoreCase(title, "Español") != null or
        std.ascii.findIgnoreCase(title, "Spanish Subtitle") != null) return "es";
    return "pt";
}

fn stripReleaseNoise(value: []const u8) []const u8 {
    const se = common.parseSeasonEpisode(value);
    if (se.episode != null) {
        var i: usize = 0;
        while (i + 4 < value.len) : (i += 1) {
            if ((value[i] == 's' or value[i] == 'S') and i > 0)
                return std.mem.trimEnd(u8, value[0..i], " \t-._");
        }
    }

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

    const url = try parseDownloadHref(
        allocator,
        "<a href=\"https://legendei.net/?dl_id=26215\"><i></i> BAIXAR LEGENDA</a>",
        site ++ "/post/",
        1,
    );
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://legendei.net/?dl_id=26215", url);
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
    });
    defer std.testing.allocator.free(tv_dl.body);
    try std.testing.expect(tv_dl.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_dl.body[0..2], "PK"));
}
