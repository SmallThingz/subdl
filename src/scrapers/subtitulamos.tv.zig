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
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}?q={s}", .{ search_url, encoded });
        const search_response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json,text/html;q=0.8,*/*;q=0.5",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        const hit = try chooseShow(a, search_response.body, trimmed) orelse
            return .{ .arena = arena, .items = &.{} };
        const show_url = try std.fmt.allocPrint(a, "{s}/shows/{d}", .{ site, hit.id });
        const show_page = try common.fetchBytes(self.client, a, show_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
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
                const season_url = resolveProviderUrl(a, season_choice.href, .season, .{
                    .show_id = hit.id,
                    .season = season_choice.number,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => continue,
                };
                const season_page = try common.fetchBytes(self.client, a, season_url, .{
                    .accept = "text/html,application/xhtml+xml,*/*",
                    .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = show_url }},
                    .cache = false,
                    .max_attempts = 2,
                    .require_public_origin = true,
                    .require_https = true,
                    .require_same_origin = true,
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

        try validateProviderUrl(item.page_url, .episode, .{
            .show_id = item.show_id,
            .season = item.season,
            .episode = item.episode,
        });

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
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
    if (wanted.len == 0) return null;

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
        if (partial == null and common.normalizedTitlesRelated(normalized, wanted)) {
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
        const page_url = resolveProviderUrl(allocator, choice.href, .episode, .{
            .show_id = show.id,
            .season = season,
            .episode = choice.number,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        if (seen.contains(page_url)) {
            allocator.free(page_url);
            continue;
        }
        const title = try allocator.dupe(u8, show.name);
        try seen.ensureUnusedCapacity(allocator, 1);
        try out.ensureUnusedCapacity(allocator, 1);
        seen.putAssumeCapacityNoClobber(page_url, {});
        out.appendAssumeCapacity(.{
            .title = title,
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
        var href_cursor: usize = 0;
        var selected_href: ?[]const u8 = null;
        var selected_url: ?[]const u8 = null;
        while (findDownloadHref(block, &href_cursor)) |href| {
            const download_url = resolveProviderUrl(allocator, href, .download, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            selected_href = href;
            selected_url = download_url;
            break;
        }
        const href = selected_href orelse continue;
        const download_url = selected_url.?;
        if (seen.contains(download_url)) {
            allocator.free(download_url);
            continue;
        }
        const id = subtitleIdFromHref(href) orelse "subtitle";
        const slugged = try common.asciiSlug(allocator, item.title);
        const language_code = try allocator.dupe(u8, language);
        const filename = try std.fmt.allocPrint(
            allocator,
            "subtitulamos-{s}-s{d}e{d}-{s}-{s}.srt",
            .{ slugged, item.season, item.episode, language, id },
        );
        try seen.ensureUnusedCapacity(allocator, 1);
        try out.ensureUnusedCapacity(allocator, 1);
        seen.putAssumeCapacityNoClobber(download_url, {});
        out.appendAssumeCapacity(.{
            .language_code = language_code,
            .filename = filename,
            .download_url = download_url,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn findDownloadHref(block: []const u8, cursor: *usize) ?[]const u8 {
    const marker = "/subtitles/";
    while (std.mem.indexOfPos(u8, block, cursor.*, marker)) |pos| {
        const quote_start = std.mem.lastIndexOfScalar(u8, block[0..pos], '"') orelse {
            cursor.* = pos + marker.len;
            continue;
        };
        const tail = block[quote_start + 1 ..];
        const quote_end = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
        const href = tail[0..quote_end];
        cursor.* = quote_start + 1 + quote_end + 1;
        if (std.mem.endsWith(u8, href, "/download")) return href;
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
    if (std.ascii.eqlIgnoreCase(label, "Portuguese")) return "pt";
    if (std.ascii.eqlIgnoreCase(label, "Brazilian")) return "pt-br";
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

const ProviderRoute = enum { show, season, episode, download };

const RouteExpectation = struct {
    show_id: ?i64 = null,
    season: ?i64 = null,
    episode: ?i64 = null,
};

fn resolveProviderUrl(
    allocator: Allocator,
    href: []const u8,
    route: ProviderRoute,
    expected: RouteExpectation,
) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderUrl(resolved, route, expected);
    return resolved;
}

fn validateProviderUrl(url: []const u8, route: ProviderRoute, expected: RouteExpectation) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len < 2 or path[0] != '/') return error.UnsafeHttpTarget;

    var segments = std.mem.splitScalar(u8, path[1..], '/');
    const valid = switch (route) {
        .show => blk: {
            if (!std.mem.eql(u8, segments.next() orelse break :blk false, "shows")) break :blk false;
            const show_id = positiveRouteInt(segments.next() orelse break :blk false) orelse break :blk false;
            if (segments.next() != null) break :blk false;
            break :blk expected.show_id == null or show_id == expected.show_id.?;
        },
        .season => blk: {
            // A season choice links to that season's first episode; /shows/{id}
            // itself redirects to the newest episode instead of listing seasons.
            if (!std.mem.eql(u8, segments.next() orelse break :blk false, "episodes")) break :blk false;
            _ = positiveRouteInt(segments.next() orelse break :blk false) orelse break :blk false;
            const slug = segments.next() orelse break :blk false;
            if (segments.next() != null) break :blk false;
            break :blk episodeSlugMatches(slug, expected.season, null);
        },
        .episode => blk: {
            if (!std.mem.eql(u8, segments.next() orelse break :blk false, "episodes")) break :blk false;
            _ = positiveRouteInt(segments.next() orelse break :blk false) orelse break :blk false;
            const slug = segments.next() orelse break :blk false;
            if (segments.next() != null) break :blk false;
            break :blk episodeSlugMatches(slug, expected.season, expected.episode);
        },
        .download => blk: {
            if (!std.mem.eql(u8, segments.next() orelse break :blk false, "subtitles")) break :blk false;
            _ = positiveRouteInt(segments.next() orelse break :blk false) orelse break :blk false;
            if (!std.mem.eql(u8, segments.next() orelse break :blk false, "download")) break :blk false;
            break :blk segments.next() == null;
        },
    };
    if (!valid) return error.UnsafeHttpTarget;
}

fn positiveRouteInt(value: []const u8) ?i64 {
    if (value.len == 0 or value[0] == '0') return null;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    const parsed = std.fmt.parseInt(i64, value, 10) catch return null;
    return if (parsed > 0) parsed else null;
}

fn episodeSlugMatches(slug: []const u8, expected_season: ?i64, expected_episode: ?i64) bool {
    const season = expected_season orelse return false;
    if (season <= 0 or (expected_episode != null and expected_episode.? <= 0) or
        slug.len == 0 or slug.len > 512 or
        !std.ascii.isAlphanumeric(slug[0]) or
        !std.ascii.isAlphanumeric(slug[slug.len - 1])) return false;
    for (slug) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }

    for (slug, 0..) |byte, marker| {
        if (byte != 'x' and byte != 'X') continue;
        var season_start = marker;
        while (season_start > 0 and std.ascii.isDigit(slug[season_start - 1])) season_start -= 1;
        if (season_start == marker or (season_start > 0 and slug[season_start - 1] != '-')) continue;

        var episode_end = marker + 1;
        while (episode_end < slug.len and std.ascii.isDigit(slug[episode_end])) episode_end += 1;
        if (episode_end == marker + 1 or (episode_end < slug.len and slug[episode_end] != '-')) continue;

        const parsed_season = std.fmt.parseInt(i64, slug[season_start..marker], 10) catch continue;
        const parsed_episode = std.fmt.parseInt(i64, slug[marker + 1 .. episode_end], 10) catch continue;
        if (parsed_season == season and parsed_episode > 0 and
            (expected_episode == null or parsed_episode == expected_episode.?)) return true;
    }
    return false;
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
    var href_cursor: usize = 0;
    try std.testing.expectEqualStrings("/subtitles/11767/download", findDownloadHref(
        "<div class=\"version-container\"><a rel=\"nofollow\" href=\"/subtitles/11767/download\"><div class=\"download-button\"></div></a></div>",
        &href_cursor,
    ).?);
}

test "subtitulamos emits canonical Portuguese language variants" {
    try std.testing.expectEqualStrings("pt", languageCode("Portuguese").?);
    try std.testing.expectEqualStrings("pt-br", languageCode("Brazilian").?);
}

test "subtitulamos invalid leading href does not suppress a valid href in one version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const item: SearchItem = .{
        .title = "Chernobyl",
        .show_id = 527,
        .season = 1,
        .episode = 1,
        .page_url = site ++ "/episodes/4681/chernobyl-1x01-1-23-45",
    };
    const body =
        "<span class=\"language-name\">English</span>" ++
        "<div class=\"version-container\">" ++
        "<a href=\"https://evil.test/subtitles/1/download\">bad</a>" ++
        "<a href=\"/subtitles/11767/download\">good</a></div>";
    const subtitles = try parseEpisodeSubtitles(arena.allocator(), body, item);

    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings(site ++ "/subtitles/11767/download", subtitles[0].download_url);
}

test "subtitulamos malformed episode choice does not suppress a valid sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    try appendEpisodesFromPage(
        allocator,
        "<div id=\"episode-choices\">" ++
            "<a href=\"https://evil.test/episodes/4681/chernobyl-1x01-1-23-45\">Episode 1</a>" ++
            "<a href=\"/episodes/4682/chernobyl-1x02-1-23-45\">Episode 2</a></div>",
        .{ .id = 527, .name = "Chernobyl" },
        1,
        &out,
        &seen,
    );

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(i64, 2), out.items[0].episode);
    try std.testing.expectEqualStrings(site ++ "/episodes/4682/chernobyl-1x02-1-23-45", out.items[0].page_url);
}

test "subtitulamos accepts episode-backed season choices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const choices = try parseChoices(
        allocator,
        "<div id=\"season-choices\"><a href=\"/episodes/4681/chernobyl-1x01-first\">1</a></div>",
        "season-choices",
    );

    try std.testing.expectEqual(@as(usize, 1), choices.len);
    try std.testing.expectEqual(@as(i64, 1), choices[0].number);
    const url = try resolveProviderUrl(allocator, choices[0].href, .season, .{
        .show_id = 527,
        .season = choices[0].number,
    });
    try std.testing.expectEqualStrings(site ++ "/episodes/4681/chernobyl-1x01-first", url);
}

test "subtitulamos accepts only exact bound provider routes before fetch" {
    try validateProviderUrl(site ++ "/shows/527", .show, .{ .show_id = 527 });
    try validateProviderUrl(site ++ "/episodes/4681/chernobyl-1x01-1-23-45", .season, .{
        .show_id = 527,
        .season = 1,
    });
    try validateProviderUrl(site ++ "/episodes/4682/chernobyl-1x02-1-23-45", .episode, .{
        .show_id = 527,
        .season = 1,
        .episode = 2,
    });
    try validateProviderUrl(site ++ "/subtitles/11767/download", .download, .{});

    const invalid = [_]struct { url: []const u8, route: ProviderRoute, expected: RouteExpectation }{
        .{ .url = "http://127.0.0.1/subtitles/1/download", .route = .download, .expected = .{} },
        .{ .url = "https://user@www.subtitulamos.tv/subtitles/1/download", .route = .download, .expected = .{} },
        .{ .url = "https://www.subtitulamos.tv.attacker.example/subtitles/1/download", .route = .download, .expected = .{} },
        .{ .url = site ++ "/admin", .route = .episode, .expected = .{ .season = 1, .episode = 2 } },
        .{ .url = site ++ "/episodes/4682/chernobyl-1x02-1-23-45?next=/admin", .route = .episode, .expected = .{ .season = 1, .episode = 2 } },
        .{ .url = site ++ "/episodes/4682/chernobyl-1x02-1-23-45#fragment", .route = .episode, .expected = .{ .season = 1, .episode = 2 } },
        .{ .url = site ++ "/episodes/4682/chernobyl-1x02-1-23-45/extra", .route = .episode, .expected = .{ .season = 1, .episode = 2 } },
        .{ .url = site ++ "/episodes/04682/chernobyl-1x02-1-23-45", .route = .episode, .expected = .{ .season = 1, .episode = 2 } },
        .{ .url = site ++ "/episodes/4682/chernobyl-2x02-1-23-45", .route = .episode, .expected = .{ .season = 1, .episode = 2 } },
        .{ .url = site ++ "/episodes/4682/chernobyl-1x03-1-23-45", .route = .episode, .expected = .{ .season = 1, .episode = 2 } },
        .{ .url = site ++ "/episodes/4682/chernobyl-1x02%2f..%2fadmin", .route = .episode, .expected = .{ .season = 1, .episode = 2 } },
        .{ .url = site ++ "/episodes/4681/chernobyl-2x01-1-23-45", .route = .season, .expected = .{ .show_id = 527, .season = 1 } },
        .{ .url = site ++ "/episodes/4681/chernobyl-1x00-1-23-45", .route = .season, .expected = .{ .show_id = 527, .season = 1 } },
        .{ .url = site ++ "/episodes/4681/chernobyl-1x01-1-23-45/extra", .route = .season, .expected = .{ .show_id = 527, .season = 1 } },
        .{ .url = site ++ "/shows/527/season/1", .route = .season, .expected = .{ .show_id = 527, .season = 1 } },
        .{ .url = site ++ "/subtitles/01/download", .route = .download, .expected = .{} },
        .{ .url = site ++ "/subtitles/1%2f..%2fadmin/download", .route = .download, .expected = .{} },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(case.url, case.route, case.expected));
    }
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
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, download.body, "-->") != null);
}
