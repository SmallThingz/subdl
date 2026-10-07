const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://grupahatak.pl";
const catalog_url = site ++ "/napisy/";
// Catalog and episode documents are small HTML pages. Bound their wire and
// decoded representations independently from the larger archive allowance.
const max_html_response_bytes: usize = 4 * 1024 * 1024;
// Keep archive downloads at the shared transport ceiling, which also matches
// the application's bounded total-unpacked archive allowance.
const max_archive_response_bytes: usize = (common.FetchOptions{}).max_response_bytes;
// Keep provider-controlled catalog and episode lists bounded for callers.
const max_search_items: usize = 24;
const max_subtitle_items: usize = 120;
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
        return self.searchUsing(common.fetchBytes, query);
    }

    fn searchUsing(self: *Scraper, comptime fetch: anytype, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const normalized_query = try common.normalizeTitle(a, trimmed);
        if (normalized_query.len == 0) return .{ .arena = arena, .items = &.{} };

        const response = try fetch(self.client, a, catalog_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_response_bytes = max_html_response_bytes,
            .max_encoded_response_bytes = max_html_response_bytes,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });
        return parseCatalog(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemUsing(common.fetchBytes, item);
    }

    fn fetchSubtitlesBySearchItemUsing(self: *Scraper, comptime fetch: anytype, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(item.page_url, .page);

        const response = try fetch(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = catalog_url }},
            .cache = false,
            .max_response_bytes = max_html_response_bytes,
            .max_encoded_response_bytes = max_html_response_bytes,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });

        const subtitles = try parseEpisodes(a, response.body, item.title, item.page_url);
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        return self.fetchDownloadByTokenUsing(common.fetchBytes, allocator, token);
    }

    fn fetchDownloadByTokenUsing(self: *Scraper, comptime fetch: anytype, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateProviderUrl(parts.page_url, .page);
        try validateProviderUrl(parts.download_url, .download);
        const response = try fetch(self.client, allocator, parts.download_url, .{
            .accept = "application/zip,application/octet-stream,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = parts.page_url }},
            .cache = false,
            .max_response_bytes = max_archive_response_bytes,
            .max_encoded_response_bytes = max_archive_response_bytes,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
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

const ProviderRoute = enum { page, download };

fn validateProviderUrl(url: []const u8, route: ProviderRoute) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (std.mem.indexOfScalar(u8, path, '\\') != null or
        std.ascii.findIgnoreCase(path, "%2f") != null or
        std.ascii.findIgnoreCase(path, "%5c") != null or
        std.ascii.findIgnoreCase(path, "%2e") != null)
    {
        return error.InvalidDownloadUrl;
    }

    const valid = switch (route) {
        .page => isPagePath(path),
        .download => isDownloadPath(path),
    };
    if (!valid) return error.InvalidDownloadUrl;
}

fn isPagePath(path: []const u8) bool {
    const prefix = "/napisy/";
    if (!std.mem.startsWith(u8, path, prefix) or path.len <= prefix.len + 2 or
        path[path.len - 1] != '/')
    {
        return false;
    }
    const body = path[prefix.len .. path.len - 1];
    const slash = std.mem.indexOfScalar(u8, body, '/') orelse return false;
    if (slash == 0 or slash + 1 >= body.len or std.mem.indexOfScalar(u8, body[slash + 1 ..], '/') != null) {
        return false;
    }
    if (!isPositiveDecimalPathSegment(body[0..slash])) return false;
    const slug = body[slash + 1 ..];
    return !std.mem.eql(u8, slug, ".") and !std.mem.eql(u8, slug, "..");
}

fn isDownloadPath(path: []const u8) bool {
    const prefix = "/napisy/pobierz/";
    if (!std.mem.startsWith(u8, path, prefix) or path.len <= prefix.len + 1 or
        path[path.len - 1] != '/')
    {
        return false;
    }
    const id = path[prefix.len .. path.len - 1];
    return isPositiveDecimalPathSegment(id);
}

fn isPositiveDecimalPathSegment(value: []const u8) bool {
    if (value.len == 0 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn parseCatalog(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var cursor: usize = 0;
    const marker = "href=\"/napisy/";

    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        const href_start = pos + "href=\"".len;
        const next_pos = std.mem.indexOfPos(u8, body, pos + marker.len, marker);
        const candidate_end = next_pos orelse body.len;
        const href_end_rel = std.mem.indexOfScalar(u8, body[href_start..candidate_end], '"') orelse {
            cursor = candidate_end;
            continue;
        };
        const href = body[href_start .. href_start + href_end_rel];
        cursor = href_start + href_end_rel + 1;
        if (!isSeriesHref(href)) continue;

        const gt = std.mem.indexOfPos(u8, body, cursor, ">") orelse continue;
        if (gt >= candidate_end or gt - cursor > 80) continue;
        // The closing quote above must still belong to this anchor's opening
        // tag. Do not borrow `>` and title text from an ordinary sibling.
        if (std.mem.indexOfScalar(u8, body[cursor..gt], '<') != null) continue;
        const close = std.mem.indexOfPos(u8, body, gt + 1, "</a>") orelse continue;
        if (close >= candidate_end or close - gt > 200) continue;
        const title = std.mem.trim(u8, body[gt + 1 .. close], " \t\r\n");
        if (title.len == 0 or std.mem.indexOfScalar(u8, title, '<') != null) continue;

        const normalized = try common.normalizeTitle(a, title);
        if (normalized.len == 0) continue;
        if (std.mem.indexOf(u8, normalized, wanted) == null and
            std.mem.indexOf(u8, wanted, normalized) == null) continue;

        const page_url = try common.resolveUrl(a, site, href);
        validateProviderUrl(page_url, .page) catch continue;
        const route_id = pageRouteId(page_url) orelse continue;
        const is_exact = std.mem.eql(u8, normalized, wanted);
        if (is_exact) {
            if (catalogItemIndex(exact.items, route_id) != null or
                exact.items.len >= max_search_items) continue;
            if (catalogItemIndex(partial.items, route_id)) |index| {
                _ = partial.orderedRemove(index);
            }
        } else {
            if (catalogItemIndex(exact.items, route_id) != null or
                catalogItemIndex(partial.items, route_id) != null or
                partial.items.len >= max_search_items) continue;
        }

        const item: SearchItem = .{
            .title = try a.dupe(u8, title),
            .page_url = page_url,
        };
        if (is_exact)
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    const exact_count = @min(exact.items.len, max_search_items);
    try items.appendSlice(a, exact.items[0..exact_count]);
    if (items.items.len < max_search_items) {
        const remaining = max_search_items - items.items.len;
        try items.appendSlice(a, partial.items[0..@min(remaining, partial.items.len)]);
    }
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn pageRouteId(url: []const u8) ?[]const u8 {
    validateProviderUrl(url, .page) catch return null;
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const rest = path["/napisy/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[0..slash];
}

fn catalogItemIndex(items: []const SearchItem, route_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        const item_id = pageRouteId(item.page_url) orelse continue;
        if (std.mem.eql(u8, item_id, route_id)) return index;
    }
    return null;
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
    errdefer {
        for (out.items) |item| {
            allocator.free(item.filename);
            allocator.free(item.download_url);
        }
        out.deinit(allocator);
    }
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit(allocator);
    }
    var cursor: usize = 0;
    const marker = "<td class=\"num_released\">";

    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        if (out.items.len >= max_subtitle_items) break;
        const number_start = pos + marker.len;
        var row_limit = body.len;
        if (std.mem.indexOfPos(u8, body, number_start, "<tr")) |next_row|
            row_limit = @min(row_limit, next_row);
        if (std.mem.indexOfPos(u8, body, number_start, marker)) |next_episode|
            row_limit = @min(row_limit, next_episode);

        const number_end = std.mem.indexOfPos(u8, body, number_start, "</td>") orelse {
            cursor = row_limit;
            continue;
        };
        if (number_end >= row_limit) {
            cursor = row_limit;
            continue;
        }
        const episode_text = std.mem.trim(u8, body[number_start..number_end], " \t\r\n");
        const row_end = std.mem.indexOfPos(u8, body, number_end, "</tr>") orelse {
            cursor = row_limit;
            continue;
        };
        if (row_end >= row_limit) {
            cursor = row_limit;
            continue;
        }
        const row_tail = body[number_end + "</td>".len .. row_end];
        cursor = row_end + "</tr>".len;

        const parsed = parseSeasonEpisode(episode_text) orelse continue;
        const href_marker = "href=\"/napisy/pobierz/";
        var href_cursor: usize = 0;
        var selected_url: ?[]const u8 = null;
        while (std.mem.indexOfPos(u8, row_tail, href_cursor, href_marker)) |href_pos| {
            const href_start = href_pos + "href=\"".len;
            const next_pos = std.mem.indexOfPos(u8, row_tail, href_pos + href_marker.len, href_marker);
            const candidate_end = next_pos orelse row_tail.len;
            const href_end_rel = std.mem.indexOfScalar(u8, row_tail[href_start..candidate_end], '"') orelse {
                href_cursor = candidate_end;
                continue;
            };
            href_cursor = href_start + href_end_rel + 1;
            const href = row_tail[href_start .. href_start + href_end_rel];
            const candidate_url = try common.resolveUrl(allocator, site, href);
            validateProviderUrl(candidate_url, .download) catch {
                allocator.free(candidate_url);
                continue;
            };
            if (seen.contains(candidate_url)) {
                allocator.free(candidate_url);
                continue;
            }
            selected_url = candidate_url;
            break;
        }
        const actual_url = selected_url orelse continue;
        defer allocator.free(actual_url);
        try seen.ensureUnusedCapacity(allocator, 1);
        const seen_url = try allocator.dupe(u8, actual_url);
        seen.putAssumeCapacityNoClobber(seen_url, {});

        const slugged = try common.asciiSlug(allocator, title);
        defer allocator.free(slugged);
        const filename = try std.fmt.allocPrint(
            allocator,
            "grupahatak-{s}-s{d}e{d}.zip",
            .{ slugged, parsed.season, parsed.episode },
        );
        errdefer allocator.free(filename);
        const download_url = try makeDownloadToken(allocator, page_url, actual_url);
        errdefer allocator.free(download_url);
        try out.append(allocator, .{
            .language_code = "pl",
            .filename = filename,
            .download_url = download_url,
            .season = parsed.season,
            .episode = parsed.episode,
        });
    }

    const owned = try out.toOwnedSlice(allocator);
    stableSortEpisodes(owned);
    return owned;
}

fn stableSortEpisodes(items: []SubtitleItem) void {
    // Multiple releases may target the same episode. A bounded insertion sort
    // keeps their provider order while sorting episodes chronologically.
    var index: usize = 1;
    while (index < items.len) : (index += 1) {
        const item = items[index];
        var insertion = index;
        while (insertion > 0 and episodeComesBefore(item, items[insertion - 1])) : (insertion -= 1) {
            items[insertion] = items[insertion - 1];
        }
        items[insertion] = item;
    }
}

fn episodeComesBefore(lhs: SubtitleItem, rhs: SubtitleItem) bool {
    if (lhs.season != rhs.season) return lhs.season < rhs.season;
    return lhs.episode < rhs.episode;
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
    try validateProviderUrl(page_url, .page);
    try validateProviderUrl(download_url, .download);
    return std.fmt.allocPrint(
        allocator,
        "{s}v1:{d}:{s}{d}:{s}",
        .{ download_token_prefix, page_url.len, page_url, download_url.len, download_url },
    );
}

const DownloadToken = struct {
    page_url: []const u8,
    download_url: []const u8,
};

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    if (!std.mem.startsWith(u8, payload, "v1:")) return null;
    var cursor: usize = "v1:".len;
    const page_url = takeTokenField(payload, &cursor) orelse return null;
    const download_url = takeTokenField(payload, &cursor) orelse return null;
    if (cursor != payload.len) return null;
    validateProviderUrl(page_url, .page) catch return null;
    validateProviderUrl(download_url, .download) catch return null;
    return .{ .page_url = page_url, .download_url = download_url };
}

fn takeTokenField(payload: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= payload.len) return null;
    const length_end_rel = std.mem.indexOfScalar(u8, payload[cursor.*..], ':') orelse return null;
    const length_end = cursor.* + length_end_rel;
    if (length_end == cursor.*) return null;
    const length_text = payload[cursor.*..length_end];
    if (length_text.len > 1 and length_text[0] == '0') return null;
    for (length_text) |c| if (!std.ascii.isDigit(c)) return null;
    const field_len = std.fmt.parseInt(usize, length_text, 10) catch return null;
    const field_start = length_end + 1;
    const field_end = std.math.add(usize, field_start, field_len) catch return null;
    if (field_end > payload.len) return null;
    cursor.* = field_end;
    return payload[field_start..field_end];
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

test "grupahatak punctuation-only normalized query yields no search results" {
    var response = try parseCatalog(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<li><a href=\"/napisy/512/Teen_Wolf/\">Teen Wolf</a></li>",
        "... !!! ---",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "grupahatak applies bounded response options by content type" {
    const Fixture = struct {
        client: std.http.Client,
        catalog_calls: usize = 0,
        episode_calls: usize = 0,
        archive_calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            try std.testing.expectEqual(@as(usize, 2), options.max_attempts);
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);

            if (std.mem.eql(u8, url, catalog_url)) {
                self.catalog_calls += 1;
                try std.testing.expectEqual(max_html_response_bytes, options.max_response_bytes);
                try std.testing.expectEqual(max_html_response_bytes, options.max_encoded_response_bytes);
                return .{
                    .status = .ok,
                    .body = try allocator.dupe(u8, "<a href=\"/napisy/1/Show/\">Show</a>"),
                };
            }
            if (std.mem.eql(u8, url, "https://grupahatak.pl/napisy/1/Show/")) {
                self.episode_calls += 1;
                try std.testing.expectEqual(max_html_response_bytes, options.max_response_bytes);
                try std.testing.expectEqual(max_html_response_bytes, options.max_encoded_response_bytes);
                return .{
                    .status = .ok,
                    .body = try allocator.dupe(
                        u8,
                        "<tr><td class=\"num_released\">01x01</td>" ++
                            "<td><a href=\"/napisy/pobierz/2/\">Episode</a></td></tr>",
                    ),
                };
            }
            if (std.mem.eql(u8, url, "https://grupahatak.pl/napisy/pobierz/2/")) {
                self.archive_calls += 1;
                try std.testing.expectEqual(max_archive_response_bytes, options.max_response_bytes);
                try std.testing.expectEqual(max_archive_response_bytes, options.max_encoded_response_bytes);
                return .{ .status = .ok, .body = try allocator.dupe(u8, "PK\x03\x04") };
            }
            return error.UnexpectedFixtureUrl;
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);

    var search = try scraper.searchUsing(Fixture.fetch, "Show");
    defer search.deinit();
    try std.testing.expectEqual(@as(usize, 1), search.items.len);

    var subtitles = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, search.items[0]);
    defer subtitles.deinit();
    try std.testing.expectEqual(@as(usize, 1), subtitles.subtitles.len);

    const archive = try scraper.fetchDownloadByTokenUsing(
        Fixture.fetch,
        std.testing.allocator,
        subtitles.subtitles[0].download_url,
    );
    defer std.testing.allocator.free(archive.body);
    try std.testing.expectEqualStrings("PK\x03\x04", archive.body);
    try std.testing.expectEqual(@as(usize, 1), fixture.catalog_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.episode_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.archive_calls);
}

test "grupahatak catalog caps partials and promotes later exact route duplicates" {
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    for (1..max_search_items + 4) |index| {
        try body.writer.print(
            "<a href=\"/napisy/{d}/target-variant-{d}/\">Target Variant {d}</a>",
            .{ index, index, index },
        );
    }
    try body.writer.writeAll(
        "<a href=\"/napisy/1/target/\">Target</a>" ++
            "<a href=\"/napisy/999/target/\">Target</a>",
    );

    var response = try parseCatalog(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        body.written(),
        "Target",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, max_search_items), response.items.len);
    try std.testing.expectEqualStrings("1", pageRouteId(response.items[0].page_url).?);
    try std.testing.expectEqualStrings("999", pageRouteId(response.items[1].page_url).?);
    try std.testing.expectEqualStrings("2", pageRouteId(response.items[2].page_url).?);
    try std.testing.expectEqualStrings("23", pageRouteId(response.items[max_search_items - 1].page_url).?);
}

test "grupahatak episode rows obey the global output cap" {
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    for (1..max_subtitle_items + 6) |episode| {
        try body.writer.print(
            "<tr><td class=\"num_released\">1x{d}</td><td><a href=\"/napisy/pobierz/{d}/\">Episode</a></td></tr>",
            .{ episode, episode },
        );
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseEpisodes(
        arena.allocator(),
        body.written(),
        "Show",
        "https://grupahatak.pl/napisy/1/Show/",
    );
    try std.testing.expectEqual(@as(usize, max_subtitle_items), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].episode);
    try std.testing.expectEqual(@as(i64, max_subtitle_items), rows[max_subtitle_items - 1].episode);
}

test "grupahatak does not borrow a download from the following episode row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseEpisodes(arena.allocator(), "<tr><td class=\"num_released\">01x01</td><td>Pending</td></tr>" ++
        "<tr><td class=\"num_released\">01x02</td><td><a href=\"/napisy/pobierz/2/\">Episode 2</a></td></tr>", "Show", "https://grupahatak.pl/napisy/1/Show/");
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 2), rows[0].episode);
    try std.testing.expect(std.mem.endsWith(u8, rows[0].download_url, "/napisy/pobierz/2/"));
}

test "grupahatak unterminated episode row does not consume a valid sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseEpisodes(
        arena.allocator(),
        "<tr><td class=\"num_released\">01x01</td><td>Pending" ++
            "<tr><td class=\"num_released\">01x02</td><td><a href=\"/napisy/pobierz/2/\">Episode 2</a></td></tr>",
        "Show",
        "https://grupahatak.pl/napisy/1/Show/",
    );
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 2), rows[0].episode);
    try std.testing.expect(std.mem.endsWith(u8, rows[0].download_url, "/napisy/pobierz/2/"));
}

test "grupahatak skips malformed download routes without hiding valid siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseEpisodes(
        arena.allocator(),
        "<tr><td class=\"num_released\">01x01</td><td><a href=\"/napisy/pobierz/not-an-id/\">bad</a></td></tr>" ++
            "<tr><td class=\"num_released\">01x02</td><td><a href=\"/napisy/pobierz/2/\">good</a></td></tr>",
        "Show",
        "https://grupahatak.pl/napisy/1/Show/",
    );
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 2), rows[0].episode);
}

test "grupahatak scans later canonical downloads in the same episode row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseEpisodes(
        arena.allocator(),
        "<tr><td class=\"num_released\">01x01</td><td>" ++
            "<a href=\"/napisy/pobierz/not-an-id/\">bad</a>" ++
            "<a href=\"/napisy/pobierz/2/\">good</a>" ++
            "</td></tr>",
        "Show",
        "https://grupahatak.pl/napisy/1/Show/",
    );
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].episode);
    try std.testing.expect(std.mem.endsWith(u8, rows[0].download_url, "/napisy/pobierz/2/"));
}

test "grupahatak scans past duplicate downloads in the same episode row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseEpisodes(
        arena.allocator(),
        "<tr><td class=\"num_released\">01x01</td><td>" ++
            "<a href=\"/napisy/pobierz/2/\">first</a></td></tr>" ++
            "<tr><td class=\"num_released\">01x02</td><td>" ++
            "<a href=\"/napisy/pobierz/2/\">duplicate</a>" ++
            "<a href=\"/napisy/pobierz/3/\">unique</a></td></tr>",
        "Show",
        "https://grupahatak.pl/napisy/1/Show/",
    );
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings(
        "https://grupahatak.pl/napisy/pobierz/3/",
        parseDownloadToken(rows[1].download_url).?.download_url,
    );
}

test "grupahatak keeps provider order for alternate files of one episode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseEpisodes(
        arena.allocator(),
        "<tr><td class=\"num_released\">01x02</td><td><a href=\"/napisy/pobierz/20/\">first alt</a></td></tr>" ++
            "<tr><td class=\"num_released\">01x01</td><td><a href=\"/napisy/pobierz/10/\">earlier episode</a></td></tr>" ++
            "<tr><td class=\"num_released\">01x02</td><td><a href=\"/napisy/pobierz/21/\">second alt</a></td></tr>",
        "Show",
        "https://grupahatak.pl/napisy/1/Show/",
    );
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].episode);
    try std.testing.expectEqual(@as(i64, 2), rows[1].episode);
    try std.testing.expectEqual(@as(i64, 2), rows[2].episode);
    try std.testing.expectEqualStrings(
        "https://grupahatak.pl/napisy/pobierz/20/",
        parseDownloadToken(rows[1].download_url).?.download_url,
    );
    try std.testing.expectEqualStrings(
        "https://grupahatak.pl/napisy/pobierz/21/",
        parseDownloadToken(rows[2].download_url).?.download_url,
    );
}

test "grupahatak malformed catalog anchor does not consume a valid sibling" {
    var response = try parseCatalog(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<a href=\"/napisy/broken " ++
            "<a href=\"/napisy/1/Teen_Wolf/\">Teen Wolf</a>",
        "Teen Wolf",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Teen Wolf", response.items[0].title);
    try std.testing.expectEqualStrings("https://grupahatak.pl/napisy/1/Teen_Wolf/", response.items[0].page_url);
}

test "grupahatak malformed catalog anchor does not borrow an ordinary sibling title" {
    var response = try parseCatalog(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<a href=\"/napisy/1/wrong/\" <a href=\"/other\">Teen Wolf</a>" ++
            "<a href=\"/napisy/2/Teen_Wolf/\">Teen Wolf</a>",
        "Teen Wolf",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("2", pageRouteId(response.items[0].page_url).?);
    try std.testing.expectEqualStrings("Teen Wolf", response.items[0].title);
}

test "grupahatak rejects non-provider token targets" {
    try validateProviderUrl("https://grupahatak.pl/napisy/512/Teen_Wolf/", .page);
    try validateProviderUrl("https://grupahatak.pl/napisy/pobierz/1/", .download);
    for ([_][]const u8{
        "http://127.0.0.1/napisy/pobierz/1/",
        "https://grupahatak.pl.example/napisy/pobierz/1/",
        "https://user@grupahatak.pl/napisy/pobierz/1/",
        "https://grupahatak.pl/napisy/pobierz/1/?next=/private",
        "https://grupahatak.pl/napisy/pobierz/1/%2fprivate/",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url, .download));
    }
}

test "grupahatak token constructor and parser enforce evidenced routes" {
    const page_url = "https://grupahatak.pl/napisy/512/Teen_Wolf/";
    const download_url = "https://grupahatak.pl/napisy/pobierz/21062/";
    const token = try makeDownloadToken(std.testing.allocator, page_url, download_url);
    defer std.testing.allocator.free(token);
    const parsed = parseDownloadToken(token).?;
    try std.testing.expectEqualStrings(page_url, parsed.page_url);
    try std.testing.expectEqualStrings(download_url, parsed.download_url);
    try std.testing.expectError(
        error.InvalidDownloadUrl,
        makeDownloadToken(std.testing.allocator, page_url, "https://grupahatak.pl/private"),
    );
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "v1:01:x") == null);
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
