const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://kitsunekko.net";
const english_catalog = site ++ "/dirlist.php?dir=subtitles%2F";
const japanese_catalog = site ++ "/dirlist.php?dir=subtitles%2Fjapanese%2F";
const max_search_items = 24;
const max_subtitle_items = 100;

pub const SearchItem = struct {
    title: []const u8,
    language_code: []const u8,
    season: ?u16,
    episode: ?u16,
    page_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const ParsedQuery = common.EpisodeQuery;
const parseQuery = common.parseEpisodeQuery;

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

        const parsed_query = parseQuery(query);
        if (parsed_query.title.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, parsed_query.title);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        try self.appendCatalogMatches(a, english_catalog, "en", parsed_query, wanted, &exact, &partial, &seen);
        try self.appendCatalogMatches(a, japanese_catalog, "ja", parsed_query, wanted, &exact, &partial, &seen);

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        const exact_count = @min(exact.items.len, max_search_items);
        try items.appendSlice(a, exact.items[0..exact_count]);
        if (items.items.len < max_search_items) {
            const remaining = max_search_items - items.items.len;
            try items.appendSlice(a, partial.items[0..@min(remaining, partial.items.len)]);
        }

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    fn appendCatalogMatches(
        self: *Scraper,
        allocator: Allocator,
        catalog_url: []const u8,
        language_code: []const u8,
        parsed_query: ParsedQuery,
        wanted: []const u8,
        exact: *std.ArrayListUnmanaged(SearchItem),
        partial: *std.ArrayListUnmanaged(SearchItem),
        seen: *std.StringHashMapUnmanaged(void),
    ) !void {
        const response = try common.fetchBytes(self.client, allocator, catalog_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = true,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });

        try appendCatalogMatchesFromBody(allocator, response.body, language_code, parsed_query, wanted, exact, partial, seen);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        try validateProviderUrl(item.page_url, .listing);

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });

        const subtitles = try parseSubtitleFiles(a, response.body, item);

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn appendCatalogMatchesFromBody(
    allocator: Allocator,
    body: []const u8,
    language_code: []const u8,
    parsed_query: ParsedQuery,
    wanted: []const u8,
    exact: *std.ArrayListUnmanaged(SearchItem),
    partial: *std.ArrayListUnmanaged(SearchItem),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    var parsed = try common.parseHtmlStable(allocator, body);
    var anchors = parsed.doc.queryAll("a[href*='dirlist.php?dir=']");
    while (anchors.next()) |anchor| {
        if (exact.items.len >= max_search_items and partial.items.len >= max_search_items) break;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (std.mem.indexOf(u8, href, "&sort=") != null or std.mem.indexOf(u8, href, "&amp;sort=") != null) continue;

        const raw_title = try common.innerTextTrimmedOwned(allocator, anchor);
        if (raw_title.len == 0) continue;
        const normalized = try common.normalizeTitle(allocator, raw_title);
        if (normalized.len == 0) continue;

        const is_exact = std.mem.eql(u8, normalized, wanted);
        const is_partial = std.mem.indexOf(u8, normalized, wanted) != null or std.mem.indexOf(u8, wanted, normalized) != null;
        if (!is_exact and !is_partial) continue;
        if ((is_exact and exact.items.len >= max_search_items) or
            (!is_exact and partial.items.len >= max_search_items)) continue;

        const page_url = resolveProviderUrl(allocator, href, .listing) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        if (seen.contains(page_url)) continue;
        try seen.put(allocator, page_url, {});

        const item: SearchItem = .{
            .title = try allocator.dupe(u8, raw_title),
            .language_code = language_code,
            .season = parsed_query.season,
            .episode = parsed_query.episode,
            .page_url = page_url,
        };
        if (is_exact)
            try exact.append(allocator, item)
        else
            try partial.append(allocator, item);
    }
}

fn parseSubtitleFiles(allocator: Allocator, body: []const u8, item: SearchItem) ![]const SubtitleItem {
    var parsed = try common.parseHtmlStable(allocator, body);
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var anchors = parsed.doc.queryAll("a[href]");
    while (anchors.next()) |anchor| {
        if (subtitles.items.len >= max_subtitle_items) break;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const filename = try common.innerTextTrimmedOwned(allocator, anchor);
        if (!isSupportedFilename(filename)) continue;
        if (item.episode) |episode| {
            if (!filenameMatchesEpisode(filename, item.season orelse 1, episode)) continue;
        }
        const download_url = resolveDownloadHref(allocator, href) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        if (seen.contains(download_url)) continue;
        try seen.put(allocator, download_url, {});
        try subtitles.append(allocator, .{
            .language_code = try allocator.dupe(u8, item.language_code),
            .filename = filename,
            .download_url = download_url,
        });
    }
    return subtitles.toOwnedSlice(allocator);
}

fn isSupportedFilename(filename: []const u8) bool {
    if (filename.len == 0 or filename.len > 512 or
        std.mem.eql(u8, filename, ".") or std.mem.eql(u8, filename, "..")) return false;
    for (filename) |c| {
        if (c < 0x20 or c == 0x7f or c == '/' or c == '\\') return false;
    }
    // Keep the user path on plain subtitle files or ZIP. Kitsunekko also hosts
    // RAR and 7z packs, but those are intentionally not advertised because
    // extraction support is less reliable and equivalent direct/ZIP files exist.
    return std.ascii.endsWithIgnoreCase(filename, ".srt") or
        std.ascii.endsWithIgnoreCase(filename, ".ass") or
        std.ascii.endsWithIgnoreCase(filename, ".ssa") or
        std.ascii.endsWithIgnoreCase(filename, ".vtt") or
        std.ascii.endsWithIgnoreCase(filename, ".zip");
}

const ProviderRoute = enum { listing, download };

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderUrl(resolved, route);
    return resolved;
}

fn resolveDownloadHref(allocator: Allocator, href: []const u8) ![]const u8 {
    const encoded_href = try encodeDownloadHref(allocator, href);
    defer allocator.free(encoded_href);
    return resolveProviderUrl(allocator, encoded_href, .download);
}

fn encodeDownloadHref(allocator: Allocator, href: []const u8) ![]u8 {
    if (href.len == 0 or href.len > 4096 or std.mem.indexOfAny(u8, href, "?#") != null or
        std.mem.startsWith(u8, href, "//")) return error.UnsafeHttpTarget;
    const relative = if (href[0] == '/') href[1..] else href;
    if (!std.mem.startsWith(u8, relative, "subtitles/")) return error.UnsafeHttpTarget;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (href[0] == '/') try out.append(allocator, '/');
    var index: usize = 0;
    while (index < relative.len) {
        const byte = relative[index];
        if (byte < 0x20 or byte == 0x7f or byte == '\\') return error.UnsafeHttpTarget;
        if (byte == '/' or std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '_' or byte == '.' or byte == '~')
        {
            try out.append(allocator, byte);
            index += 1;
            continue;
        }
        if (byte == '%') {
            if (relative.len - index < 3 or
                !std.ascii.isHex(relative[index + 1]) or !std.ascii.isHex(relative[index + 2]))
            {
                return error.UnsafeHttpTarget;
            }
            const decoded = std.fmt.parseInt(u8, relative[index + 1 .. index + 3], 16) catch return error.UnsafeHttpTarget;
            if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
                decoded == '?' or decoded == '#' or decoded == '%') return error.UnsafeHttpTarget;
            try out.appendSlice(allocator, &.{
                '%',
                "0123456789ABCDEF"[decoded >> 4],
                "0123456789ABCDEF"[decoded & 0xf],
            });
            index += 3;
            continue;
        }
        try out.appendSlice(allocator, &.{
            '%',
            "0123456789ABCDEF"[byte >> 4],
            "0123456789ABCDEF"[byte & 0xf],
        });
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn validateProviderUrl(url: []const u8, route: ProviderRoute) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const query = if (uri.query) |component| switch (component) {
        .raw, .percent_encoded => |value| value,
    } else null;

    switch (route) {
        .listing => {
            if (!std.mem.eql(u8, path, "/dirlist.php") or query == null or
                !isSafeDirectoryQuery(query.?)) return error.UnsafeHttpTarget;
        },
        .download => {
            if (query != null or !isSafeDownloadPath(path)) return error.UnsafeHttpTarget;
        },
    }
}

fn isSafeDirectoryQuery(query: []const u8) bool {
    const prefix = "dir=";
    if (!std.mem.startsWith(u8, query, prefix)) return false;
    const value = query[prefix.len..];
    if (value.len == 0 or value.len > 2048 or std.mem.indexOfAny(u8, value, "&#=") != null) return false;

    var segment_count: usize = 0;
    var segment_len: usize = 0;
    var segment_all_dots = true;
    var first_segment_matches = true;
    var index: usize = 0;
    while (index < value.len) {
        const decoded = if (value[index] == '%') blk: {
            if (value.len - index < 3 or
                !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return false;
            const byte = std.fmt.parseInt(u8, value[index + 1 .. index + 3], 16) catch return false;
            index += 3;
            break :blk byte;
        } else blk: {
            const byte = value[index];
            index += 1;
            break :blk byte;
        };
        if (decoded == '/') {
            if (segment_len == 0 or (segment_all_dots and segment_len <= 2)) return false;
            if (segment_count == 0 and
                (!first_segment_matches or segment_len != "subtitles".len)) return false;
            segment_count += 1;
            segment_len = 0;
            segment_all_dots = true;
            continue;
        }
        if (decoded < 0x20 or decoded == 0x7f or decoded == '\\' or decoded == '%') return false;
        if (segment_count == 0) {
            const expected = "subtitles";
            if (segment_len >= expected.len or decoded != expected[segment_len]) first_segment_matches = false;
        }
        segment_len += 1;
        if (decoded != '.') segment_all_dots = false;
    }
    return segment_len == 0 and segment_count >= 1 and first_segment_matches;
}

fn isSafeDownloadPath(path: []const u8) bool {
    const prefix = "/subtitles/";
    if (path.len <= prefix.len or path.len > 4096 or !std.mem.startsWith(u8, path, prefix) or
        path[path.len - 1] == '/') return false;
    var segments = std.mem.splitScalar(u8, path[prefix.len..], '/');
    var last: []const u8 = "";
    while (segments.next()) |segment| {
        if (!isSafeEncodedPathSegment(segment)) return false;
        last = segment;
    }
    return isSupportedFilename(last);
}

fn isSafeEncodedPathSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 512 or
        std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    var decoded_len: usize = 0;
    var decoded_all_dots = true;
    var index: usize = 0;
    while (index < segment.len) {
        const c = segment[index];
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~!$'()*+,;=:@", c) != null) {
            decoded_len += 1;
            if (c != '.') decoded_all_dots = false;
            index += 1;
            continue;
        }
        if (c != '%' or segment.len - index < 3 or
            !std.ascii.isHex(segment[index + 1]) or !std.ascii.isHex(segment[index + 2])) return false;
        const decoded = std.fmt.parseInt(u8, segment[index + 1 .. index + 3], 16) catch return false;
        if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
            decoded == '?' or decoded == '#' or decoded == '%') return false;
        decoded_len += 1;
        if (decoded != '.') decoded_all_dots = false;
        index += 3;
    }
    return !(decoded_all_dots and decoded_len <= 2);
}

fn filenameMatchesEpisode(filename: []const u8, season: u16, episode: u16) bool {
    if (explicitEpisodeMarkerMatches(filename, season, episode)) |matches| return matches;
    if (season != 1) return false;
    if (releaseEpisodeMarkerMatches(filename, episode)) |matches| return matches;
    return bareEpisodeNumberMatches(filename, episode);
}

const ParsedEpisodeNumber = struct {
    value: u16,
    end: usize,
};

fn parseEpisodeNumber(value: []const u8, start: usize) ?ParsedEpisodeNumber {
    if (start >= value.len or !std.ascii.isDigit(value[start])) return null;
    var end = start + 1;
    while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
    const number = std.fmt.parseInt(u16, value[start..end], 10) catch return null;
    return .{ .value = number, .end = end };
}

fn episodeTokenEnd(value: []const u8, number_end: usize) ?usize {
    var end = number_end;
    if (end < value.len and std.ascii.toLower(value[end]) == 'v') {
        end += 1;
        const revision_start = end;
        while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
        if (end == revision_start) return null;
    }
    if (end < value.len and std.ascii.isAlphanumeric(value[end])) return null;
    return end;
}

fn explicitEpisodeMarkerMatches(value: []const u8, season: u16, episode: u16) ?bool {
    var found = false;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (i > 0 and std.ascii.isAlphanumeric(value[i - 1])) continue;

        const lower = std.ascii.toLower(value[i]);
        if (lower == 's') {
            const parsed_season = parseEpisodeNumber(value, i + 1) orelse continue;
            if (parsed_season.end >= value.len or std.ascii.toLower(value[parsed_season.end]) != 'e') continue;
            const parsed_episode = parseEpisodeNumber(value, parsed_season.end + 1) orelse continue;
            _ = episodeTokenEnd(value, parsed_episode.end) orelse continue;
            found = true;
            if (parsed_season.value == season and parsed_episode.value == episode) return true;
            continue;
        }

        if (std.ascii.isDigit(value[i])) {
            const parsed_season = parseEpisodeNumber(value, i) orelse continue;
            if (parsed_season.value > 99 or parsed_season.end >= value.len or std.ascii.toLower(value[parsed_season.end]) != 'x') continue;
            const parsed_episode = parseEpisodeNumber(value, parsed_season.end + 1) orelse continue;
            if (parsed_episode.value > 999) continue;
            _ = episodeTokenEnd(value, parsed_episode.end) orelse continue;
            found = true;
            if (parsed_season.value == season and parsed_episode.value == episode) return true;
            continue;
        }

        if (lower == 'e') {
            var cursor = i + 1;
            const word = "episode";
            if (i + word.len <= value.len and std.ascii.eqlIgnoreCase(value[i .. i + word.len], word)) cursor = i + word.len;
            while (cursor < value.len and (std.ascii.isWhitespace(value[cursor]) or value[cursor] == '.' or value[cursor] == '_' or value[cursor] == '-')) : (cursor += 1) {}
            const parsed_episode = parseEpisodeNumber(value, cursor) orelse continue;
            _ = episodeTokenEnd(value, parsed_episode.end) orelse continue;
            found = true;
            if (parsed_episode.value == episode and episodeOnlySeasonMatches(value, season)) return true;
        }
    }
    return if (found) false else null;
}

fn episodeOnlySeasonMatches(value: []const u8, season: u16) bool {
    var found = false;
    for (value, 0..) |c, i| {
        if (i > 0 and std.ascii.isAlphanumeric(value[i - 1])) continue;
        if (std.ascii.isDigit(c)) {
            const parsed = parseEpisodeNumber(value, i) orelse continue;
            if (parsed.value > 99 or parsed.end >= value.len or std.ascii.toLower(value[parsed.end]) != 'x') continue;
            const episode = parseEpisodeNumber(value, parsed.end + 1) orelse continue;
            if (episode.value > 999) continue;
            _ = episodeTokenEnd(value, episode.end) orelse continue;
            found = true;
            if (parsed.value != season) return false;
            continue;
        }
        if (std.ascii.toLower(c) != 's') continue;

        var number_start = i + 1;
        const word = "season";
        if (i + word.len <= value.len and std.ascii.eqlIgnoreCase(value[i .. i + word.len], word)) {
            number_start = i + word.len;
            while (number_start < value.len and (std.ascii.isWhitespace(value[number_start]) or
                value[number_start] == '.' or value[number_start] == '_' or value[number_start] == '-')) : (number_start += 1)
            {}
        }
        const parsed = parseEpisodeNumber(value, number_start) orelse continue;
        if (parsed.end < value.len and std.ascii.isAlphanumeric(value[parsed.end])) {
            // A compact S02E03 is also explicit season context for a later E-only token.
            if (std.ascii.toLower(value[parsed.end]) != 'e') continue;
            const episode = parseEpisodeNumber(value, parsed.end + 1) orelse continue;
            _ = episodeTokenEnd(value, episode.end) orelse continue;
        }
        found = true;
        if (parsed.value != season) return false;
    }
    return found or season == 1;
}

fn releaseEpisodeMarkerMatches(value: []const u8, episode: u16) ?bool {
    var bracket_depth: usize = 0;
    var found = false;
    for (value, 0..) |c, i| {
        if (c == '[') {
            bracket_depth += 1;
            continue;
        }
        if (c == ']') {
            if (bracket_depth > 0) bracket_depth -= 1;
            continue;
        }
        // Release-group tags commonly contain numeric suffixes such as
        // `[Group-2]`. They are metadata, not episode markers.
        if (c != '-' or bracket_depth != 0) continue;
        var start = i + 1;
        while (start < value.len and std.ascii.isWhitespace(value[start])) : (start += 1) {}
        const parsed = parseEpisodeNumber(value, start) orelse continue;
        if (parsed.end - start > 3 or isDecimalNumber(value, start, parsed.end)) continue;
        _ = episodeTokenEnd(value, parsed.end) orelse continue;
        found = true;
        if (parsed.value == episode) return true;
    }
    return if (found) false else null;
}

fn isDecimalNumber(value: []const u8, start: usize, end: usize) bool {
    return (start >= 2 and value[start - 1] == '.' and std.ascii.isDigit(value[start - 2])) or
        (end + 1 < value.len and value[end] == '.' and std.ascii.isDigit(value[end + 1]));
}

fn bareEpisodeNumberMatches(value: []const u8, episode: u16) bool {
    var i: usize = 0;
    while (i < value.len) {
        if (!std.ascii.isDigit(value[i]) or (i > 0 and std.ascii.isAlphanumeric(value[i - 1]))) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
        const digits_end = i;
        const number = std.fmt.parseInt(u16, value[start..i], 10) catch continue;
        if (isDecimalNumber(value, start, digits_end)) continue;
        var end = i;
        if (end < value.len and std.ascii.toLower(value[end]) == 'v') {
            end += 1;
            const revision_start = end;
            while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
            if (end == revision_start) continue;
        }
        if (end < value.len and std.ascii.isAlphanumeric(value[end])) continue;
        if (digits_end - start == 4 and number >= 1900 and number <= 2099) continue;
        return number == episode;
    }
    return false;
}

fn findResult(items: []const SearchItem, title: []const u8, language_code: []const u8) ?usize {
    for (items, 0..) |item, idx| {
        if (std.ascii.eqlIgnoreCase(item.title, title) and std.mem.eql(u8, item.language_code, language_code))
            return idx;
    }
    return null;
}

fn firstDirectSubtitle(items: []const SubtitleItem) ?usize {
    for (items, 0..) |item, idx| {
        if (!std.ascii.endsWithIgnoreCase(item.filename, ".zip")) return idx;
    }
    return if (items.len > 0) 0 else null;
}

test "kitsunekko parses episode query and filters unsafe archive formats" {
    const parsed = parseQuery("Death Note S01E01");
    try std.testing.expectEqualStrings("Death Note", parsed.title);
    try std.testing.expectEqual(@as(?u16, 1), parsed.season);
    try std.testing.expectEqual(@as(?u16, 1), parsed.episode);

    try std.testing.expect(filenameMatchesEpisode("Death Note Episode 1 - Animelon.ass", 1, 1));
    try std.testing.expect(filenameMatchesEpisode("Death.Note.S01E01.en.srt", 1, 1));
    try std.testing.expect(!filenameMatchesEpisode("Death.Note.S01E02.en.srt", 1, 1));

    try std.testing.expect(isSupportedFilename("episode.srt"));
    try std.testing.expect(isSupportedFilename("series.zip"));
    try std.testing.expect(!isSupportedFilename("series.rar"));
    try std.testing.expect(!isSupportedFilename("series.7z"));
}

test "kitsunekko does not fetch catalogs for punctuation-only queries" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.search("---...");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "kitsunekko rejects off-origin listing and download links" {
    try validateProviderUrl("https://kitsunekko.net/dirlist.php?dir=subtitles%2F", .listing);
    try validateProviderUrl(site ++ "/subtitles/caf%C3%A9/file.srt", .download);
    for ([_][]const u8{
        "http://127.0.0.1/private.srt",
        "https://user@kitsunekko.net/private.srt",
        "https://kitsunekko.net.evil.example/private.srt",
        "https://example.com/private.srt",
    }) |url| try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, url, .download));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(site ++ "/dirlist.php?dir=..%2F", .listing));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(site ++ "/dirlist.php?dir=subtitles%252Fsecret%2F", .listing));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(site ++ "/dirlist.php?dir=subtitles%2FShow%2F&sort=name", .listing));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(site ++ "/admin/export.srt", .listing));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(site ++ "/subtitles/Show/a%252fb.srt", .download));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(site ++ "/subtitles/%2e%2E/file.srt", .download));
    try std.testing.expect(!isSupportedFilename("../episode.srt"));
}

test "kitsunekko skips invalid catalog rows before a valid row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        "<a href='https://example.com/dirlist.php?dir=subtitles%2FTarget%2F'>Target</a>" ++
        "<a href='file:///dirlist.php?dir=subtitles%2FTarget%2F'>Target</a>" ++
        "<a href='/dirlist.php?dir=subtitles%2FTarget%2F'>Target</a>";
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    try appendCatalogMatchesFromBody(a, body, "en", parseQuery("Target"), "target", &exact, &partial, &seen);
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqual(@as(usize, 0), partial.items.len);
    try std.testing.expectEqualStrings("https://kitsunekko.net/dirlist.php?dir=subtitles%2FTarget%2F", exact.items[0].page_url);
}

test "kitsunekko partial cap does not hide a later exact catalog match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body: std.Io.Writer.Allocating = .init(a);
    defer body.deinit();
    for (0..max_search_items * 4) |index| {
        try body.writer.print(
            "<a href='/dirlist.php?dir=subtitles%2FTarget-{d}%2F'>Target extended {d}</a>",
            .{ index, index },
        );
    }
    try body.writer.writeAll("<a href='/dirlist.php?dir=subtitles%2FTarget%2F'>Target</a>");

    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    try appendCatalogMatchesFromBody(a, body.written(), "en", parseQuery("Target"), "target", &exact, &partial, &seen);

    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqual(@as(usize, max_search_items), partial.items.len);
    try std.testing.expectEqualStrings("Target", exact.items[0].title);
}

test "kitsunekko skips invalid file rows before a valid row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        "<a href='https://example.com/bad.srt'>Show.S01E02.bad.srt</a>" ++
        "<a href='file:///bad.srt'>Show.S01E02.bad-too.srt</a>" ++
        "<a href='subtitles/Show/good.srt'>Show.S01E02.good.srt</a>";
    const subtitles = try parseSubtitleFiles(arena.allocator(), body, .{
        .title = "Show",
        .language_code = "en",
        .season = 1,
        .episode = 2,
        .page_url = site ++ "/dirlist.php?dir=subtitles%2FShow%2F",
    });
    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings("Show.S01E02.good.srt", subtitles[0].filename);
    try std.testing.expectEqualStrings("https://kitsunekko.net/subtitles/Show/good.srt", subtitles[0].download_url);
}

test "kitsunekko encodes raw file href characters from directory listings" {
    const url = try resolveDownloadHref(std.testing.allocator, "subtitles/Death Note/[Group] Episode 01.ass");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        site ++ "/subtitles/Death%20Note/%5BGroup%5D%20Episode%2001.ass",
        url,
    );
}

test "live kitsunekko english and japanese movie plus tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "kitsunekko.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Spirited Away");
    defer movie.deinit();

    const en_idx = findResult(movie.items, "Spirited Away", "en") orelse return error.TestUnexpectedResult;
    var en_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[en_idx]);
    defer en_subtitles.deinit();
    const en_sub_idx = firstDirectSubtitle(en_subtitles.subtitles) orelse return error.TestUnexpectedResult;
    const en_download = try common.fetchBytes(&client, std.testing.allocator, en_subtitles.subtitles[en_sub_idx].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(en_download.body);
    try std.testing.expect(en_download.body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, en_download.body, "-->") != null);

    const ja_idx = findResult(movie.items, "Spirited Away (Sen to Chihiro no Kamikakushi)", "ja") orelse
        return error.TestUnexpectedResult;
    var ja_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[ja_idx]);
    defer ja_subtitles.deinit();
    const ja_sub_idx = firstDirectSubtitle(ja_subtitles.subtitles) orelse return error.TestUnexpectedResult;
    const ja_download = try common.fetchBytes(&client, std.testing.allocator, ja_subtitles.subtitles[ja_sub_idx].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(ja_download.body);
    try std.testing.expect(ja_download.body.len > 100);
    try std.testing.expect(ja_download.body.len >= 2);
    try std.testing.expect(ja_download.body[0] == 0xff and ja_download.body[1] == 0xfe);

    var tv = try scraper.search("Death Note S01E01");
    defer tv.deinit();
    const tv_idx = findResult(tv.items, "Death Note", "en") orelse return error.TestUnexpectedResult;
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[tv_idx]);
    defer tv_subtitles.deinit();
    if (tv_subtitles.subtitles.len == 0) return error.TestUnexpectedResult;
    try std.testing.expect(filenameMatchesEpisode(tv_subtitles.subtitles[0].filename, 1, 1));

    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "text/plain,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, tv_download.body, "[Script Info]") != null);
}

test "explicit kitsunekko episode queries do not return unrelated fallback files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "<a href='/subtitles/Show/2.srt'>Show.S01E02.srt</a><a href='/subtitles/Show/pack.zip'>Show.zip</a>";
    var item: SearchItem = .{
        .title = "Show",
        .language_code = "en",
        .season = 1,
        .episode = 1,
        .page_url = "https://kitsunekko.net/dirlist.php?dir=subtitles%2FShow%2F",
    };
    const missing = try parseSubtitleFiles(a, body, item);
    try std.testing.expectEqual(@as(usize, 0), missing.len);
    item.episode = 2;
    const matching = try parseSubtitleFiles(a, body, item);
    try std.testing.expectEqual(@as(usize, 1), matching.len);
    try std.testing.expectEqualStrings("Show.S01E02.srt", matching[0].filename);
    item.episode = null;
    const series = try parseSubtitleFiles(a, body, item);
    try std.testing.expectEqual(@as(usize, 2), series.len);
}

test "episode tokens do not match longer episode numbers" {
    for ([_][]const u8{ "Show Episode 10.ass", "Show.S01E010.ass", "Show.01x010.ass", "Show - 010.ass", "010.ass", "Show 1080p.ass" }) |name| try std.testing.expect(!filenameMatchesEpisode(name, 1, 1));
    for ([_][]const u8{ "Show Episode 1.ass", "Show.S01E01.ass", "Show.01x01.ass", "Show - 01.ass", "Show 01v2.ass", "01.ass" }) |name| try std.testing.expect(filenameMatchesEpisode(name, 1, 1));
    try std.testing.expect(!filenameMatchesEpisode("Show - 01.ass", 2, 1));

    for ([_][]const u8{
        "Show - 03 [FLAC 2.0].ass",
        "Show - 03 [02].ass",
        "Show S01E03 [02].ass",
        "Show Episode 3 [02].ass",
        "Show 01x03 [02].ass",
        "Show S02E02 [02].ass",
        "Show [FLAC 2.0].ass",
    }) |name| try std.testing.expect(!filenameMatchesEpisode(name, 1, 2));
    for ([_][]const u8{ "Show S1E2.ass", "Show 1x2.ass", "Show Episode 02.ass", "Show - 02 [FLAC 2.0].ass" }) |name| try std.testing.expect(filenameMatchesEpisode(name, 1, 2));
    try std.testing.expect(filenameMatchesEpisode("[Group-1] Show - 02.ass", 1, 2));
    try std.testing.expect(!filenameMatchesEpisode("[Group-2] Show - 01.ass", 1, 2));
}

test "kitsunekko later-season selection requires a season-qualified episode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        "<a href='/subtitles/Show/ambiguous.srt'>Show Episode 02.srt</a>" ++
        "<a href='/subtitles/Show/short.srt'>Show E02.srt</a>" ++
        "<a href='/subtitles/Show/first.srt'>Show S01E02.srt</a>" ++
        "<a href='/subtitles/Show/second.srt'>Show S02E02.srt</a>";
    const subtitles = try parseSubtitleFiles(arena.allocator(), body, .{
        .title = "Show",
        .language_code = "en",
        .season = 2,
        .episode = 2,
        .page_url = site ++ "/dirlist.php?dir=subtitles%2FShow%2F",
    });
    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings("Show S02E02.srt", subtitles[0].filename);
    try std.testing.expect(filenameMatchesEpisode("Show 2x02.srt", 2, 2));
}

test "kitsunekko E-only markers respect separated season context" {
    for ([_][]const u8{
        "Show S02 E02.ass",
        "Show Season 2 Episode 02.ass",
        "Show Season.2.Episode.02.ass",
        "Show E02 S02.ass",
        "Show 2x03 E02.ass",
        "Show E02 2x03.ass",
    }) |name| {
        try std.testing.expect(!filenameMatchesEpisode(name, 1, 2));
        try std.testing.expect(filenameMatchesEpisode(name, 2, 2));
    }
    for ([_][]const u8{ "Show E02.ass", "Show Episode 02.ass", "Show S01 E02.ass", "Show Season 1 Episode 02.ass" }) |name| {
        try std.testing.expect(filenameMatchesEpisode(name, 1, 2));
        try std.testing.expect(!filenameMatchesEpisode(name, 2, 2));
    }
    try std.testing.expect(!filenameMatchesEpisode("Show S01 Season 2 Episode 02.ass", 1, 2));
    try std.testing.expect(!filenameMatchesEpisode("Show S01 Season 2 Episode 02.ass", 2, 2));
    try std.testing.expect(!filenameMatchesEpisode("Show S02E03 E02.ass", 1, 2));
    try std.testing.expect(filenameMatchesEpisode("Show S02E02.ass", 2, 2));
    try std.testing.expect(filenameMatchesEpisode("Show 100x03 E02.ass", 1, 2));
    try std.testing.expect(filenameMatchesEpisode("Show 2x1000 E02.ass", 1, 2));
    try std.testing.expect(filenameMatchesEpisode("Show 2x03audio E02.ass", 1, 2));
}
