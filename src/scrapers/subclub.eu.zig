const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.subclub.eu";
const search_endpoint = site ++ "/jutud.php";
const archive_endpoint = site ++ "/subtitles_archivecontent.php";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    season: ?i64,
    episode: ?i64,
    archive_id: []const u8,
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
        const url = try std.fmt.allocPrint(a, "{s}?otsing={s}", .{ search_endpoint, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        if (!isCanonicalPositiveId(item.archive_id)) return error.UnsafeHttpTarget;
        const encoded_id = try common.encodeUriComponent(a, item.archive_id);
        const url = try std.fmt.allocPrint(a, "{s}?id={s}", .{ archive_endpoint, encoded_id });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        var anchors = parsed.doc.queryAll("a[href*='down.php'][href*='filename=']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const filename = try common.innerTextTrimmedOwned(a, anchor);
            if (filename.len == 0 or !common.isSubtitleFilename(filename)) continue;

            const download_url = resolveSubclubHref(a, href, item.archive_id) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            if (seen.contains(download_url)) continue;
            try seen.put(a, download_url, {});

            try out.append(a, .{
                .language_code = "et",
                .filename = filename,
                .download_url = download_url,
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try out.toOwnedSlice(a),
        });
    }
};

const ParsedTitle = struct {
    title: []const u8,
    year: ?i64,
    season: ?i64,
    episode: ?i64,
};

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    var parsed = try common.parseHtmlStable(a, body);
    const wanted = try common.normalizeTitle(a, query);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var rows = parsed.doc.queryAll("table#tale_list tbody tr");
    while (rows.next()) |row| {
        var anchors = row.queryAll("a.sc_link[href*='down.php?id=']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const archive_id = try parseArchiveId(a, href) orelse continue;

            const raw_title = try common.innerTextTrimmedOwned(a, anchor);
            const meta = parseTitle(raw_title);
            if (meta.title.len == 0) continue;

            const normalized = try common.normalizeTitle(a, meta.title);
            if (!normalizedTitlesRelated(normalized, wanted)) continue;

            // Do not let an unrelated row with a reused archive id suppress a
            // later relevant result.
            if (seen.contains(archive_id)) continue;
            try seen.put(a, archive_id, {});

            const title = try a.dupe(u8, meta.title);
            const page_url = try std.fmt.allocPrint(a, "{s}/down.php?id={s}", .{ site, archive_id });
            const item: SearchItem = .{
                .title = title,
                .year = meta.year,
                .media_kind = if (meta.season != null or meta.episode != null) .tv else .movie,
                .season = meta.season,
                .episode = meta.episode,
                .archive_id = archive_id,
                .page_url = page_url,
            };

            if (std.mem.eql(u8, normalized, wanted))
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

fn normalizedTitlesRelated(lhs: []const u8, rhs: []const u8) bool {
    return containsNormalizedPhrase(lhs, rhs) or containsNormalizedPhrase(rhs, lhs);
}

fn containsNormalizedPhrase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len == 0 or needle.len == 0 or needle.len > haystack.len) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        const end = index + needle.len;
        const starts_at_boundary = index == 0 or haystack[index - 1] == ' ';
        const ends_at_boundary = end == haystack.len or haystack[end] == ' ';
        if (starts_at_boundary and ends_at_boundary) return true;
        start = index + 1;
    }
    return false;
}

fn parseArchiveId(allocator: Allocator, href: []const u8) !?[]u8 {
    const resolved = common.resolveUrl(allocator, site ++ "/", href) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(resolved);

    common.validatePublicHttpUrl(resolved) catch return null;
    if (!(common.sameOrigin(site, resolved) catch false)) return null;
    const archive_id = archiveIdFromPageUrl(resolved) orelse return null;
    return try allocator.dupe(u8, archive_id);
}

fn archiveIdFromPageUrl(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    if (uri.user != null or uri.password != null or uri.fragment != null) return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/down.php")) return null;
    const query = if (uri.query) |component| switch (component) {
        .raw, .percent_encoded => |value| value,
    } else return null;
    const prefix = "id=";
    if (!std.mem.startsWith(u8, query, prefix)) return null;
    const archive_id = query[prefix.len..];
    if (!isCanonicalPositiveId(archive_id)) return null;
    return archive_id;
}

fn isCanonicalPositiveId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn parseTitle(input: []const u8) ParsedTitle {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    var season: ?i64 = null;
    var episode: ?i64 = null;
    var metadata_end = trimmed.len;

    // Episode metadata is an optional trailing suffix. Do not let brackets in
    // the actual title change its media kind or truncate it.
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ']') {
        if (std.mem.lastIndexOfScalar(u8, trimmed, '[')) |lb| {
            const token = std.mem.trim(u8, trimmed[lb + 1 .. trimmed.len - 1], " \t");
            const separator = std.mem.indexOfAny(u8, token, "xX");
            if (separator) |x| {
                const parsed_season: ?i64 = std.fmt.parseInt(i64, std.mem.trim(u8, token[0..x], " \t"), 10) catch null;
                const parsed_episode: ?i64 = std.fmt.parseInt(i64, std.mem.trim(u8, token[x + 1 ..], " \t"), 10) catch null;
                if (parsed_season != null and parsed_episode != null) {
                    season = parsed_season;
                    episode = parsed_episode;
                    metadata_end = std.mem.trimEnd(u8, trimmed[0..lb], " \t").len;
                }
            }
        }
    }

    const title_and_year = std.mem.trim(u8, trimmed[0..metadata_end], " \t");
    var title = title_and_year;
    var year: ?i64 = null;
    if (title_and_year.len > 0 and title_and_year[title_and_year.len - 1] == ')') {
        if (std.mem.lastIndexOfScalar(u8, title_and_year, '(')) |open| {
            const year_text = std.mem.trim(u8, title_and_year[open + 1 .. title_and_year.len - 1], " \t");
            if (year_text.len == 4) {
                const parsed_year: ?i64 = std.fmt.parseInt(i64, year_text, 10) catch null;
                if (parsed_year != null and parsed_year.? >= 1800 and parsed_year.? <= 2100) {
                    const before_year = std.mem.trim(u8, title_and_year[0..open], " \t");
                    if (before_year.len > 0) {
                        title = before_year;
                        year = parsed_year;
                    }
                }
            }
        }
    }

    return .{
        .title = title,
        .year = year,
        .season = season,
        .episode = episode,
    };
}

fn resolveSubclubHref(allocator: Allocator, href: []const u8, expected_archive_id: ?[]const u8) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site ++ "/", href);
    errdefer allocator.free(resolved);
    try validateDownloadEndpoint(resolved, expected_archive_id);
    return resolved;
}

fn validateDownloadEndpoint(url: []const u8, expected_archive_id: ?[]const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/down.php")) return error.UnsafeHttpTarget;

    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return error.UnsafeHttpTarget;
    const query = url[query_start + 1 ..];
    var found_id = false;
    var found_filename = false;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.UnsafeHttpTarget;
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        if (std.mem.eql(u8, key, "id")) {
            if (found_id or !isCanonicalPositiveId(value)) return error.UnsafeHttpTarget;
            if (expected_archive_id) |expected| {
                if (!std.mem.eql(u8, value, expected)) return error.UnsafeHttpTarget;
            }
            found_id = true;
        } else if (std.mem.eql(u8, key, "filename")) {
            if (found_filename or !isStandardBase64(value)) return error.UnsafeHttpTarget;
            found_filename = true;
        } else {
            return error.UnsafeHttpTarget;
        }
    }
    if (!found_id or !found_filename) return error.UnsafeHttpTarget;
}

fn isStandardBase64(value: []const u8) bool {
    if (value.len == 0 or value.len % 4 != 0) return false;
    var padding_count: usize = 0;
    var saw_padding = false;
    for (value) |c| {
        if (c == '=') {
            saw_padding = true;
            padding_count += 1;
            if (padding_count > 2) return false;
        } else {
            if (saw_padding) return false;
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '/') return false;
        }
    }
    return true;
}

test "subclub parses movie and episode rows and archive files" {
    const search_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var search = try parseSearchHtml(
        search_arena,
        \\<table id="tale_list"><tbody>
        \\<tr><td></td><td><a class="sc_link" href="../down.php?id=10100">Inception (2010)</a></td></tr>
        \\<tr><td></td><td><a class="sc_link" href="../down.php?id=18128">Chernobyl (2019) [01x01]</a></td></tr>
        \\</tbody></table>
    ,
        "Inception",
    );
    defer search.deinit();

    try std.testing.expectEqual(@as(usize, 1), search.items.len);
    try std.testing.expectEqualStrings("Inception", search.items[0].title);
    try std.testing.expect(search.items[0].media_kind == .movie);
    try std.testing.expectEqual(@as(?i64, 2010), search.items[0].year);

    const archive_id = (try parseArchiveId(std.testing.allocator, "../down.php?id=10100")).?;
    defer std.testing.allocator.free(archive_id);
    try std.testing.expectEqualStrings("10100", archive_id);
    const resolved = try resolveSubclubHref(std.testing.allocator, "../down.php?id=10100&filename=YWJjLnNydA==", "10100");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(
        "https://www.subclub.eu/down.php?id=10100&filename=YWJjLnNydA==",
        resolved,
    );
}

test "subclub accepts only exact download routes and query fields" {
    inline for (.{
        "../down.php?id=10100&filename=YWJjLnNydA==",
        "/down.php?filename=YWJjLnNydA==&id=10100",
    }) |href| {
        const resolved = try resolveSubclubHref(std.testing.allocator, href, null);
        defer std.testing.allocator.free(resolved);
    }

    try std.testing.expectError(error.UnsafeHttpTarget, resolveSubclubHref(std.testing.allocator, "http://127.0.0.1/private", null));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveSubclubHref(std.testing.allocator, "https://user:pass@www.subclub.eu/private", null));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveSubclubHref(std.testing.allocator, "https://www.subclub.eu.evil.com/private", null));
    inline for (.{
        "/admin?next=down.php&filename=x",
        "/down.php?id=abc&filename=x",
        "/down.php?id=0&filename=YWJjLnNydA==",
        "/down.php?id=010100&filename=YWJjLnNydA==",
        "/down.php?id=10100",
        "/down.php?filename=x",
        "/down.php?id=10100&filename=",
        "/down.php?id=10100&filename=x&extra=1",
        "/down.php?id=10100&id=10101&filename=x",
        "/down.php?id=10100&filename=x#fragment",
        "/down.php?id=10100&filename=not-base64",
        "/down.php?id=10100&filename=YW=JjA==",
    }) |href| try std.testing.expectError(error.UnsafeHttpTarget, resolveSubclubHref(std.testing.allocator, href, null));

    try std.testing.expectError(
        error.UnsafeHttpTarget,
        resolveSubclubHref(std.testing.allocator, "/down.php?id=10101&filename=YWJjLnNydA==", "10100"),
    );
}

test "subclub archive ids require the canonical page route" {
    inline for (.{
        "../down.php?id=10100",
        "/down.php?id=10100",
        "https://www.subclub.eu/down.php?id=10100",
    }) |href| {
        const archive_id = (try parseArchiveId(std.testing.allocator, href)).?;
        defer std.testing.allocator.free(archive_id);
        try std.testing.expectEqualStrings("10100", archive_id);
    }

    inline for (.{
        "/admin?next=down.php?id=10100",
        "/path/down.php?id=10100",
        "/down.php?next=1&id=10100",
        "/down.php?id=10100&extra=1",
        "/down.php?id=10100#fragment",
        "https://example.com/down.php?id=10100",
    }) |href| try std.testing.expect((try parseArchiveId(std.testing.allocator, href)) == null);
}

test "subclub parses only trailing year and episode metadata" {
    const nested = parseTitle("Birdman or (The Unexpected Virtue of Ignorance) (2014)");
    try std.testing.expectEqualStrings("Birdman or (The Unexpected Virtue of Ignorance)", nested.title);
    try std.testing.expectEqual(@as(?i64, 2014), nested.year);
    try std.testing.expectEqual(@as(?i64, null), nested.season);

    const episode = parseTitle("Show (US) (2020) [02X03]");
    try std.testing.expectEqualStrings("Show (US)", episode.title);
    try std.testing.expectEqual(@as(?i64, 2020), episode.year);
    try std.testing.expectEqual(@as(?i64, 2), episode.season);
    try std.testing.expectEqual(@as(?i64, 3), episode.episode);

    const no_year = parseTitle("Title (Director's Cut)");
    try std.testing.expectEqualStrings("Title (Director's Cut)", no_year.title);
    try std.testing.expectEqual(@as(?i64, null), no_year.year);
}

test "subclub unrelated duplicate does not suppress a later relevant row" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<table id="tale_list"><tbody>
        \\  <tr><td><a class="sc_link" href="../down.php?id=10100">Preacher (2016)</a></td></tr>
        \\  <tr><td><a class="sc_link" href="../down.php?id=10100">Jack Reacher (2012)</a></td></tr>
        \\</tbody></table>
    ,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Jack Reacher", response.items[0].title);
    try std.testing.expectEqualStrings("10100", response.items[0].archive_id);
}

test "subclub invalid exact archive ids do not precede a later valid row" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<table id="tale_list"><tbody>
        \\  <tr><td><a class="sc_link" href="../down.php?id=0">Inception (2010)</a></td></tr>
        \\  <tr><td><a class="sc_link" href="../down.php?id=010100">Inception (2010)</a></td></tr>
        \\  <tr><td><a class="sc_link" href="../down.php?id=10100">Inception (2010)</a></td></tr>
        \\</tbody></table>
    ,
        "Inception",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("10100", response.items[0].archive_id);
}

test "subclub scans past a malformed first anchor in one row" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<table id="tale_list"><tbody>
        \\  <tr><td>
        \\    <a class="sc_link" href="/admin?next=down.php?id=99999">Wrong route</a>
        \\    <a class="sc_link" href="../down.php?id=10100">Inception (2010)</a>
        \\  </td></tr>
        \\</tbody></table>
    ,
        "Inception",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("10100", response.items[0].archive_id);
}

test "live subclub movie and tv direct downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subclub.eu")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Inception");
    defer movie.deinit();
    const movie_idx = findMovie(movie.items, "Inception", 2010) orelse return error.TestUnexpectedResult;
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[movie_idx]);
    defer movie_subtitles.deinit();
    if (movie_subtitles.subtitles.len == 0) return error.TestUnexpectedResult;
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, movie_download.body, "-->") != null);

    var tv = try scraper.search("Chernobyl");
    defer tv.deinit();
    const tv_idx = findEpisode(tv.items, "Chernobyl", 1, 1) orelse return error.TestUnexpectedResult;
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[tv_idx]);
    defer tv_subtitles.deinit();
    if (tv_subtitles.subtitles.len == 0) return error.TestUnexpectedResult;
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, tv_download.body, "-->") != null);
}

fn findMovie(items: []const SearchItem, title: []const u8, year: i64) ?usize {
    for (items, 0..) |item, idx| {
        if (item.media_kind == .movie and item.year == year and std.ascii.eqlIgnoreCase(item.title, title))
            return idx;
    }
    return null;
}

fn findEpisode(items: []const SearchItem, title: []const u8, season: i64, episode: i64) ?usize {
    for (items, 0..) |item, idx| {
        if (item.media_kind == .tv and item.season == season and item.episode == episode and std.ascii.eqlIgnoreCase(item.title, title))
            return idx;
    }
    return null;
}
