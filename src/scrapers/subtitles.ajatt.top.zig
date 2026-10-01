const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://subtitles.ajatt.top";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    english_name: ?[]const u8,
    japanese_name: ?[]const u8,
    media_kind: MediaKind,
    page_url: []const u8,
};

pub const SubtitleItem = common.DownloadSubtitleFile;

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

        const response = try common.fetchBytes(self.client, a, site ++ "/", .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .max_attempts = 2,
        });
        return parseIndex(arena, response.body, query);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .max_attempts = 2,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var anchors = parsed.doc.queryAll("a[href^='https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const filename = if (common.getAttributeValueSafe(anchor, "download")) |download|
                try a.dupe(u8, download)
            else
                try common.innerTextTrimmedOwned(a, anchor);
            if (!common.isSubtitleFilename(filename)) continue;
            if (seen.contains(href)) continue;
            try seen.put(a, href, {});
            try subtitles.append(a, .{
                .filename = filename,
                .download_url = try a.dupe(u8, href),
            });
        }

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }
};

fn parseIndex(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const normalized_query = try normalizeForSearch(a, query);
    if (normalized_query.len == 0) return .{ .arena = owned_arena, .items = &.{} };

    var parsed = try common.parseHtmlStable(a, body);
    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    var rows = parsed.doc.queryAll("tr[data-entry-type]");
    while (rows.next()) |row| {
        const media_kind = parseMediaKind(common.getAttributeValueSafe(row, "data-entry-type") orelse "") orelse continue;
        const anchor = row.queryOne("td.entry_name a[href]") orelse continue;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const title = try common.innerTextTrimmedOwned(a, anchor);
        if (title.len == 0) continue;

        const english_name = if (row.queryOne("td.english_name")) |node| blk: {
            const text = try common.innerTextTrimmedOwned(a, node);
            break :blk if (text.len > 0) text else null;
        } else null;
        const japanese_name = if (row.queryOne("td.japanese_name")) |node| blk: {
            const text = try common.innerTextTrimmedOwned(a, node);
            break :blk if (text.len > 0) text else null;
        } else null;

        if (!try rowMatchesQuery(a, normalized_query, title, english_name, japanese_name)) continue;

        try items.append(a, .{
            .title = title,
            .english_name = english_name,
            .japanese_name = japanese_name,
            .media_kind = media_kind,
            .page_url = try common.resolveUrl(a, site, href),
        });
    }

    return .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) };
}

fn parseMediaKind(value: []const u8) ?MediaKind {
    if (std.mem.eql(u8, value, "anime_movie")) return .movie;
    if (std.mem.eql(u8, value, "anime_tv")) return .tv;
    return null;
}

fn rowMatchesQuery(
    allocator: Allocator,
    normalized_query: []const u8,
    title: []const u8,
    english_name: ?[]const u8,
    japanese_name: ?[]const u8,
) !bool {
    if (try normalizedContains(allocator, title, normalized_query)) return true;
    if (english_name) |value| if (try normalizedContains(allocator, value, normalized_query)) return true;
    if (japanese_name) |value| if (try normalizedContains(allocator, value, normalized_query)) return true;
    return false;
}

fn normalizedContains(allocator: Allocator, value: []const u8, normalized_query: []const u8) !bool {
    const normalized = try normalizeForSearch(allocator, value);
    return std.mem.indexOf(u8, normalized, normalized_query) != null;
}

fn normalizeForSearch(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, std.ascii.toLower(c));
            continue;
        }
        if (c >= 0x80) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, c);
            continue;
        }
        pending_space = out.items.len > 0;
    }
    return out.toOwnedSlice(allocator);
}

test "ajatt parses movie and tv catalog rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseIndex(
        arena,
        \\<table>
        \\<tr data-entry-type="anime_tv"><td class="entry_name"><a href="anime_tv/death-note.html">DEATH NOTE</a></td><td class="english_name">Death Note</td><td class="japanese_name">DEATH NOTE</td></tr>
        \\<tr data-entry-type="anime_movie"><td class="entry_name"><a href="anime_movie/sen-to-chihiro-no-kamikakushi.html">Sen to Chihiro no Kamikakushi</a></td><td class="english_name">Spirited Away</td><td class="japanese_name">千と千尋の神隠し</td></tr>
        \\</table>
    ,
        "Death Note",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqual(MediaKind.tv, response.items[0].media_kind);
    try std.testing.expectEqualStrings("https://subtitles.ajatt.top/anime_tv/death-note.html", response.items[0].page_url);
}

test "live ajatt movie search" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitles.ajatt.top")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Spirited Away");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    try std.testing.expect(search.items[0].media_kind == .movie);
}

test "live ajatt tv search and subtitle listing" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitles.ajatt.top")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Death Note");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, subtitles.subtitles[0].download_url, "https://raw.githubusercontent.com/"));
}
