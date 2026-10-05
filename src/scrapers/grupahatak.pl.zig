const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://grupahatak.pl";
const catalog_url = site ++ "/napisy/";
pub const download_token_prefix = "grupahatak-referer:";

pub const SearchItem = common.SearchLink;

pub const SubtitleItem = common.EpisodeSubtitleFile;

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
            .cache = false,
            .max_attempts = 2,
        });
        return parseCatalog(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = catalog_url }},
            .cache = false,
            .max_attempts = 2,
        });

        const subtitles = try parseEpisodes(a, response.body, item.title, item.page_url);
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        const response = try common.fetchBytes(self.client, allocator, parts.download_url, .{
            .accept = "application/zip,application/octet-stream,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = parts.page_url }},
            .cache = false,
            .max_attempts = 2,
        });
        if (response.status != .ok) {
            allocator.free(response.body);
            return error.UnexpectedHttpStatus;
        }
        if (response.body.len < 4 or !std.mem.eql(u8, response.body[0..2], "PK")) {
            allocator.free(response.body);
            return error.UnexpectedResponseType;
        }
        return response;
    }
};

fn parseCatalog(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const wanted = try common.normalizeTitle(a, query);

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var cursor: usize = 0;
    const marker = "href=\"/napisy/";

    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        const href_start = pos + "href=\"".len;
        const href_end_rel = std.mem.indexOfScalar(u8, body[href_start..], '"') orelse break;
        const href = body[href_start .. href_start + href_end_rel];
        cursor = href_start + href_end_rel + 1;
        if (!isSeriesHref(href) or seen.contains(href)) continue;

        const gt = std.mem.indexOfPos(u8, body, cursor, ">") orelse continue;
        if (gt - cursor > 80) continue;
        const close = std.mem.indexOfPos(u8, body, gt + 1, "</a>") orelse continue;
        if (close - gt > 200) continue;
        const title = std.mem.trim(u8, body[gt + 1 .. close], " \t\r\n");
        if (title.len == 0 or std.mem.indexOfScalar(u8, title, '<') != null) continue;

        const normalized = try common.normalizeTitle(a, title);
        if (normalized.len == 0) continue;
        if (std.mem.indexOf(u8, normalized, wanted) == null and
            std.mem.indexOf(u8, wanted, normalized) == null) continue;

        try seen.put(a, try a.dupe(u8, href), {});
        const item: SearchItem = .{
            .title = try a.dupe(u8, title),
            .page_url = try common.resolveUrl(a, site, href),
        };
        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn isSeriesHref(href: []const u8) bool {
    if (!std.mem.startsWith(u8, href, "/napisy/")) return false;
    const rest = href["/napisy/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    if (slash == 0) return false;
    for (rest[0..slash]) |c| if (!std.ascii.isDigit(c)) return false;
    return slash + 1 < rest.len;
}

fn parseEpisodes(allocator: Allocator, body: []const u8, title: []const u8, page_url: []const u8) ![]const SubtitleItem {
    var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var cursor: usize = 0;
    const marker = "<td class=\"num_released\">";

    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        const number_start = pos + marker.len;
        const number_end = std.mem.indexOfPos(u8, body, number_start, "</td>") orelse break;
        const episode_text = std.mem.trim(u8, body[number_start..number_end], " \t\r\n");
        cursor = number_end + "</td>".len;

        const parsed = parseSeasonEpisode(episode_text) orelse continue;
        const href_marker = "href=\"/napisy/pobierz/";
        const href_pos = std.mem.indexOfPos(u8, body, cursor, href_marker) orelse continue;
        if (href_pos - cursor > 1200) continue;
        const href_start = href_pos + "href=\"".len;
        const href_end_rel = std.mem.indexOfScalar(u8, body[href_start..], '"') orelse continue;
        const href = body[href_start .. href_start + href_end_rel];
        cursor = href_start + href_end_rel + 1;
        if (seen.contains(href)) continue;
        try seen.put(allocator, try allocator.dupe(u8, href), {});

        const actual_url = try common.resolveUrl(allocator, site, href);
        const slugged = try common.asciiSlug(allocator, title);
        try out.append(allocator, .{
            .language_code = "pl",
            .filename = try std.fmt.allocPrint(
                allocator,
                "grupahatak-{s}-s{d}e{d}.zip",
                .{ slugged, parsed.season, parsed.episode },
            ),
            .download_url = try makeDownloadToken(allocator, page_url, actual_url),
            .season = parsed.season,
            .episode = parsed.episode,
        });
    }

    const owned = try out.toOwnedSlice(allocator);
    std.mem.sort(SubtitleItem, owned, {}, common.seasonEpisodeLessThan(SubtitleItem));
    return owned;
}

const SeasonEpisode = struct {
    season: i64,
    episode: i64,
};

fn parseSeasonEpisode(value: []const u8) ?SeasonEpisode {
    const x = std.mem.indexOfScalar(u8, value, 'x') orelse
        std.mem.indexOfScalar(u8, value, 'X') orelse return null;
    if (x == 0 or x + 1 >= value.len) return null;
    const season_text = std.mem.trimStart(u8, value[0..x], "0");
    const episode_text = std.mem.trimStart(u8, value[x + 1 ..], "0");
    const season = std.fmt.parseInt(i64, if (season_text.len > 0) season_text else "0", 10) catch return null;
    const episode = std.fmt.parseInt(i64, if (episode_text.len > 0) episode_text else "0", 10) catch return null;
    if (season <= 0 or episode <= 0) return null;
    return .{ .season = season, .episode = episode };
}

pub fn makeDownloadToken(allocator: Allocator, page_url: []const u8, download_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}|{s}", .{ download_token_prefix, page_url, download_url });
}

const DownloadToken = struct {
    page_url: []const u8,
    download_url: []const u8,
};

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    const sep = std.mem.indexOfScalar(u8, payload, '|') orelse return null;
    if (sep == 0 or sep + 1 >= payload.len) return null;
    return .{ .page_url = payload[0..sep], .download_url = payload[sep + 1 ..] };
}

test "grupahatak parses catalog and episode rows" {
    var catalog = try parseCatalog(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<li><a href=\"/napisy/512/Teen_Wolf/\">Teen Wolf</a></li>",
        "Teen Wolf",
    );
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseEpisodes(
        arena.allocator(),
        "<tr><td class=\"num_released\">01x01</td><td class=\"title_released\"><a href=\"/napisy/pobierz/21062/\" name=\"01x01\">Wolf Moon</a></td></tr>",
        "Teen Wolf",
        "https://grupahatak.pl/napisy/512/Teen_Wolf/",
    );
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].season);
    try std.testing.expectEqual(@as(i64, 1), rows[0].episode);
}

test "live grupahatak teen wolf listing and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "grupahatak.pl")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Teen Wolf");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    try std.testing.expectEqual(@as(i64, 1), subtitles.subtitles[0].season);
    try std.testing.expectEqual(@as(i64, 1), subtitles.subtitles[0].episode);

    const download = try scraper.fetchDownloadByToken(std.testing.allocator, subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
