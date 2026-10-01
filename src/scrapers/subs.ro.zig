const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const site = "https://subs.ro";
const search_path = "/cautare";
const search_endpoint = site ++ "/ajax/search";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    language_code: []const u8,
    release: []const u8,
    page_url: []const u8,
    download_url: []const u8,
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
        const search_page_url = try std.fmt.allocPrint(
            a,
            "{s}{s}?termen-general={s}",
            .{ site, search_path, encoded },
        );
        const page = try common.fetchBytes(self.client, a, search_page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 3,
        });
        const antispam = try parseAntispamToken(a, page.body);

        const payload = try std.fmt.allocPrint(
            a,
            "termen-general={s}&type=subtitrari&antispam={s}",
            .{ encoded, antispam },
        );
        const headers = [_]std.http.Header{
            .{ .name = "origin", .value = site },
            .{ .name = "referer", .value = search_page_url },
            .{ .name = "hx-request", .value = "true" },
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
        };
        const response = try common.fetchBytes(self.client, a, search_endpoint, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded; charset=UTF-8",
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .cache = false,
            .max_attempts = 3,
        });

        return parseSearchHtml(arena, response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = try subtitleFilename(a, item.release, item.download_url),
            .download_url = try a.dupe(u8, item.download_url),
        };
        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        };
    }
};

fn parseAntispamToken(allocator: Allocator, body: []const u8) ![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var parsed = try common.parseHtmlStable(scratch.allocator(), body);
    const input = parsed.doc.queryOne("input[name='antispam'][value]") orelse return error.MissingField;
    const value = common.getAttributeValueSafe(input, "value") orelse return error.MissingField;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 16 or trimmed.len > 128) return error.UnexpectedResponseType;
    return allocator.dupe(u8, trimmed);
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);

    const wanted = try common.normalizeTitle(a, query);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var rows = parsed.doc.queryAll("div[data-subtitle-result='true']");
    while (rows.next()) |row| {
        const title_anchor = row.queryOne("a[data-search-result-link='true'][href]") orelse continue;
        const download_anchor = row.queryOne("a[data-download-source='search-results'][href]") orelse continue;

        const page_href = common.getAttributeValueSafe(title_anchor, "href") orelse continue;
        const download_href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
        if (seen.contains(download_href)) continue;
        try seen.put(a, try a.dupe(u8, download_href), {});

        const title_attr = common.getAttributeValueSafe(title_anchor, "data-movie-name");
        const raw_title = if (title_attr) |value|
            std.mem.trim(u8, value, " \t\r\n")
        else blk: {
            const heading = row.queryOne("h2") orelse continue;
            break :blk std.mem.trim(u8, try common.innerTextTrimmedOwned(a, heading), " \t\r\n");
        };
        if (raw_title.len == 0) continue;

        const heading_text = if (row.queryOne("h2")) |heading|
            try common.innerTextTrimmedOwned(a, heading)
        else
            raw_title;
        const year = parseYear(heading_text);
        const language_code = try parseLanguageCode(a, row);
        const release = try parseRelease(a, title_anchor, raw_title);

        const item: SearchItem = .{
            .title = try a.dupe(u8, raw_title),
            .year = year,
            .media_kind = inferMediaKind(raw_title, page_href),
            .language_code = language_code,
            .release = release,
            .page_url = try common.resolveUrl(a, site, page_href),
            .download_url = try common.resolveUrl(a, site, download_href),
        };

        const normalized = try common.normalizeTitle(a, raw_title);
        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) };
}

fn parseLanguageCode(allocator: Allocator, row: anytype) ![]const u8 {
    const flag = row.queryOne("img[src*='/flags/'][alt]") orelse return allocator.dupe(u8, "ro");
    const alt = common.getAttributeValueSafe(flag, "alt") orelse return allocator.dupe(u8, "ro");
    const sep = std.mem.lastIndexOf(u8, alt, " - ") orelse return allocator.dupe(u8, "ro");
    const raw = std.mem.trim(u8, alt[sep + 3 ..], " \t\r\n");
    if (raw.len < 2 or raw.len > 8) return allocator.dupe(u8, "ro");
    return allocator.dupe(u8, common.normalizeLanguageCode(raw) orelse raw);
}

fn parseRelease(allocator: Allocator, title_anchor: anytype, fallback: []const u8) ![]const u8 {
    const title_attr = common.getAttributeValueSafe(title_anchor, "title") orelse return allocator.dupe(u8, fallback);
    var release = std.mem.trim(u8, title_attr, " \t\r\n");
    if (std.ascii.startsWithIgnoreCase(release, "Subtitrare")) {
        release = std.mem.trim(u8, release["Subtitrare".len..], " \t\r\n");
    }
    if (release.len == 0) release = fallback;
    return allocator.dupe(u8, release);
}

fn inferMediaKind(title: []const u8, page_url: []const u8) MediaKind {
    if (std.ascii.indexOfIgnoreCase(title, "sezonul") != null) return .tv;
    if (std.ascii.indexOfIgnoreCase(page_url, "-sezonul-") != null) return .tv;
    return .movie;
}

fn parseYear(text: []const u8) ?i64 {
    var idx: usize = 0;
    while (idx + 6 <= text.len) : (idx += 1) {
        if (text[idx] != '(' or text[idx + 5] != ')') continue;
        const digits = text[idx + 1 .. idx + 5];
        for (digits) |c| if (!std.ascii.isDigit(c)) break else {};
        const year = std.fmt.parseInt(i64, digits, 10) catch continue;
        if (year >= 1890 and year <= 2200) return year;
    }
    return null;
}

fn subtitleFilename(allocator: Allocator, release: []const u8, download_url: []const u8) ![]u8 {
    const id = pathBaseName(download_url);
    if (release.len == 0) return std.fmt.allocPrint(allocator, "subs-ro-{s}.zip", .{id});
    return std.fmt.allocPrint(allocator, "{s}.zip", .{release});
}

fn pathBaseName(path: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    const trimmed = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[slash + 1 ..];
}

test "subs ro parses antispam token" {
    const allocator = std.testing.allocator;
    const token = try parseAntispamToken(
        allocator,
        "<form><input type=\"hidden\" name=\"antispam\" value=\"771b40bc37c0fcbb73bac1156406ef3a165901cd\"></form>",
    );
    defer allocator.free(token);
    try std.testing.expectEqualStrings("771b40bc37c0fcbb73bac1156406ef3a165901cd", token);
}

test "subs ro parses movie and tv search rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<div data-subtitle-result="true">
        \\  <a href="https://subs.ro/subtitrare/the-matrix-1999/135"
        \\     title="Subtitrare The Matrix DVDRIP"
        \\     data-search-result-link="true"
        \\     data-movie-name="The Matrix"><h2>The Matrix <span>(1999)</span></h2></a>
        \\  <img src="https://cdn.subs.ro/img/flags/flag-rom-big.png" alt="Subtitrare The Matrix - ro">
        \\  <a href="https://subs.ro/subtitrare/descarca/the-matrix-1999/135" data-download-source="search-results">Descarca</a>
        \\</div>
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/chernobyl-sezonul-1-2019/129054"
        \\     title="Subtitrare Chernobyl - Sezonul 1"
        \\     data-search-result-link="true"
        \\     data-movie-name="Chernobyl - Sezonul 1"><h2>Chernobyl - Sezonul 1 <span>(2019)</span></h2></a>
        \\  <img src="/img/flags/flag-rom-big.png" alt="Subtitrare Chernobyl - Sezonul 1 - ro">
        \\  <a href="/subtitrare/descarca/chernobyl-sezonul-1-2019/129054" data-download-source="search-results">Descarca</a>
        \\</div>
    ,
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 1999), response.items[0].year);
    try std.testing.expectEqual(MediaKind.movie, response.items[0].media_kind);
    try std.testing.expectEqualStrings("ro", response.items[0].language_code);
    try std.testing.expectEqualStrings("https://subs.ro/subtitrare/descarca/the-matrix-1999/135", response.items[0].download_url);

    try std.testing.expectEqual(MediaKind.tv, response.items[1].media_kind);
    try std.testing.expectEqual(@as(?i64, 2019), response.items[1].year);
}

test "live subs ro movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subs.ro")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    const movie_item = findMediaKind(movie.items, .movie) orelse return error.TestUnexpectedResult;
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie_item);
    defer movie_subtitles.deinit();
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Chernobyl");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    const tv_item = findMediaKind(tv.items, .tv) orelse return error.TestUnexpectedResult;
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv_item);
    defer tv_subtitles.deinit();
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}

fn findMediaKind(items: []const SearchItem, kind: MediaKind) ?SearchItem {
    for (items) |item| {
        if (item.media_kind == kind) return item;
    }
    return null;
}
