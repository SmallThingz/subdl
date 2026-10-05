const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://www.subtitulamos.tv";
const search_url = site ++ "/search/query";
const max_seasons: usize = 32;
const max_episodes: usize = 512;

pub const SearchItem = struct {
    title: []const u8,
    show_id: i64,
    season: i64,
    episode: i64,
    page_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const ShowHit = struct {
    id: i64,
    name: []const u8,
};

const Choice = struct {
    number: i64,
    href: []const u8,
};

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
        if (trimmed.len < 2) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}?q={s}", .{ search_url, encoded });
        const search_response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json,text/html;q=0.8,*/*;q=0.5",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
        });

        const hit = try chooseShow(a, search_response.body, trimmed) orelse
            return .{ .arena = arena, .items = &.{} };
        const show_url = try std.fmt.allocPrint(a, "{s}/shows/{d}", .{ site, hit.id });
        const show_page = try common.fetchBytes(self.client, a, show_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
        });

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        const seasons = try parseChoices(a, show_page.body, "season-choices");

        if (seasons.len == 0) {
            try appendEpisodesFromPage(
                a,
                show_page.body,
                hit,
                1,
                &items,
                &seen,
            );
        } else {
            for (seasons[0..@min(seasons.len, max_seasons)]) |season_choice| {
                const season_url = try common.resolveUrl(a, site, season_choice.href);
                const season_page = try common.fetchBytes(self.client, a, season_url, .{
                    .accept = "text/html,application/xhtml+xml,*/*",
                    .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = show_url }},
                    .cache = false,
                    .max_attempts = 2,
                });
                try appendEpisodesFromPage(
                    a,
                    season_page.body,
                    hit,
                    season_choice.number,
                    &items,
                    &seen,
                );
                if (items.items.len >= max_episodes) break;
            }
        }

        const owned = try items.toOwnedSlice(a);
        std.mem.sort(SearchItem, owned, {}, common.seasonEpisodeLessThan(SearchItem));
        return .{ .arena = arena, .items = owned };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
        });

        const subtitles = try parseEpisodeSubtitles(a, response.body, item);
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn chooseShow(allocator: Allocator, body: []const u8, query: []const u8) !?ShowHit {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    const array = switch (root) {
        .array => |value| value,
        else => return error.InvalidFieldType,
    };
    const wanted = try common.normalizeTitle(allocator, query);

    var partial: ?ShowHit = null;
    for (array.items) |entry| {
        const obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const id = jsonInt(obj.get("show_id") orelse continue) orelse continue;
        const name = jsonString(obj.get("show_name") orelse continue) orelse continue;
        if (id <= 0 or name.len == 0) continue;

        const normalized = try common.normalizeTitle(allocator, name);
        const hit: ShowHit = .{
            .id = id,
            .name = try allocator.dupe(u8, name),
        };
        if (std.mem.eql(u8, normalized, wanted)) return hit;
        if (partial == null and
            (std.mem.indexOf(u8, normalized, wanted) != null or std.mem.indexOf(u8, wanted, normalized) != null))
        {
            partial = hit;
        }
    }
    return partial;
}

fn parseChoices(allocator: Allocator, body: []const u8, container_id: []const u8) ![]const Choice {
    var parsed = try common.parseHtmlStable(allocator, body);
    var out: std.ArrayListUnmanaged(Choice) = .empty;
    if (std.mem.eql(u8, container_id, "season-choices")) {
        var anchors = parsed.doc.queryAll("#season-choices a[href]");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const text = try common.innerTextTrimmedOwned(allocator, anchor);
            const number = firstPositiveInt(text) orelse continue;
            try out.append(allocator, .{
                .number = number,
                .href = try allocator.dupe(u8, href),
            });
        }
    } else if (std.mem.eql(u8, container_id, "episode-choices")) {
        var anchors = parsed.doc.queryAll("#episode-choices a[href]");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const text = try common.innerTextTrimmedOwned(allocator, anchor);
            const number = firstPositiveInt(text) orelse continue;
            try out.append(allocator, .{
                .number = number,
                .href = try allocator.dupe(u8, href),
            });
        }
    } else {
        return error.InvalidFieldType;
    }
    return out.toOwnedSlice(allocator);
}

fn appendEpisodesFromPage(
    allocator: Allocator,
    body: []const u8,
    show: ShowHit,
    season: i64,
    out: *std.ArrayListUnmanaged(SearchItem),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const episodes = try parseChoices(allocator, body, "episode-choices");
    for (episodes) |choice| {
        if (out.items.len >= max_episodes) break;
        const page_url = try common.resolveUrl(allocator, site, choice.href);
        if (seen.contains(page_url)) continue;
        try seen.put(allocator, page_url, {});
        try out.append(allocator, .{
            .title = try allocator.dupe(u8, show.name),
            .show_id = show.id,
            .season = season,
            .episode = choice.number,
            .page_url = page_url,
        });
    }
}

fn parseEpisodeSubtitles(allocator: Allocator, body: []const u8, item: SearchItem) ![]const SubtitleItem {
    var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var cursor: usize = 0;
    var current_language: ?[]const u8 = null;
    while (cursor < body.len) {
        const lang_pos = std.mem.indexOfPos(u8, body, cursor, "language-name");
        const version_pos = std.mem.indexOfPos(u8, body, cursor, "version-container");

        if (lang_pos == null and version_pos == null) break;
        if (lang_pos != null and (version_pos == null or lang_pos.? < version_pos.?)) {
            const class_pos = lang_pos.?;
            const gt = std.mem.indexOfPos(u8, body, class_pos, ">") orelse break;
            const close = std.mem.indexOfPos(u8, body, gt + 1, "</") orelse break;
            const label = std.mem.trim(u8, body[gt + 1 .. close], " \t\r\n");
            current_language = languageCode(label);
            cursor = close + 2;
            continue;
        }

        const pos = version_pos.?;
        const next_lang = std.mem.indexOfPos(u8, body, pos + 1, "language-name") orelse body.len;
        const next_version = std.mem.indexOfPos(u8, body, pos + 1, "version-container") orelse body.len;
        const end = @min(next_lang, next_version);
        const block = body[pos..end];
        cursor = end;

        const language = current_language orelse continue;
        const href = findDownloadHref(block) orelse continue;
        if (seen.contains(href)) continue;
        try seen.put(allocator, try allocator.dupe(u8, href), {});

        const download_url = try common.resolveUrl(allocator, site, href);
        const id = subtitleIdFromHref(href) orelse "subtitle";
        const slugged = try common.asciiSlug(allocator, item.title);
        try out.append(allocator, .{
            .language_code = try allocator.dupe(u8, language),
            .filename = try std.fmt.allocPrint(
                allocator,
                "subtitulamos-{s}-s{d}e{d}-{s}-{s}.srt",
                .{ slugged, item.season, item.episode, language, id },
            ),
            .download_url = download_url,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn findDownloadHref(block: []const u8) ?[]const u8 {
    const marker = "/subtitles/";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, block, cursor, marker)) |pos| {
        const quote_start = std.mem.lastIndexOfScalar(u8, block[0..pos], '"') orelse {
            cursor = pos + marker.len;
            continue;
        };
        const tail = block[quote_start + 1 ..];
        const quote_end = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
        const href = tail[0..quote_end];
        if (std.mem.endsWith(u8, href, "/download")) return href;
        cursor = pos + marker.len;
    }
    return null;
}

fn subtitleIdFromHref(href: []const u8) ?[]const u8 {
    const marker = "/subtitles/";
    const pos = std.mem.indexOf(u8, href, marker) orelse return null;
    const tail = href[pos + marker.len ..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return null;
    if (slash == 0) return null;
    return tail[0..slash];
}

fn languageCode(label_raw: []const u8) ?[]const u8 {
    const label = std.mem.trim(u8, label_raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(label, "English") or
        std.ascii.eqlIgnoreCase(label, "English (US)") or
        std.ascii.eqlIgnoreCase(label, "English (UK)")) return "en";
    if (std.ascii.startsWithIgnoreCase(label, "Espa")) return "es";
    if (std.ascii.eqlIgnoreCase(label, "Portuguese") or std.ascii.eqlIgnoreCase(label, "Brazilian")) return "pt";
    if (std.ascii.eqlIgnoreCase(label, "Català") or std.ascii.eqlIgnoreCase(label, "Catala")) return "ca";
    if (std.ascii.eqlIgnoreCase(label, "Galego")) return "gl";
    return null;
}

fn firstPositiveInt(value: []const u8) ?i64 {
    var i: usize = 0;
    while (i < value.len) {
        if (!std.ascii.isDigit(value[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
        const number = std.fmt.parseInt(i64, value[start..i], 10) catch continue;
        if (number > 0) return number;
    }
    return null;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        .string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        .float => |number| common.jsonInt(.{ .float = number }),
        else => null,
    };
}

test "subtitulamos parses search hit and direct subtitle href" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const hit = (try chooseShow(
        allocator,
        "[{\"show_id\":527,\"show_name\":\"Chernobyl\"}]",
        "Chernobyl",
    )).?;
    try std.testing.expectEqual(@as(i64, 527), hit.id);
    try std.testing.expectEqualStrings("Chernobyl", hit.name);
    try std.testing.expectEqualStrings("/subtitles/11767/download", findDownloadHref(
        "<div class=\"version-container\"><a rel=\"nofollow\" href=\"/subtitles/11767/download\"><div class=\"download-button\"></div></a></div>",
    ).?);
}

test "live subtitulamos tv search and direct download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitulamos.tv")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Chernobyl");
    defer search.deinit();
    try std.testing.expect(search.items.len >= 5);
    try std.testing.expectEqual(@as(i64, 1), search.items[0].season);
    try std.testing.expectEqual(@as(i64, 1), search.items[0].episode);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len >= 2);

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,text/srt,*/*",
        .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = search.items[0].page_url }},
        .cache = false,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, download.body, "-->") != null);
}
