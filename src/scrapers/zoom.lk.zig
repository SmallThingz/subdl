const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://zoom.lk";

pub const MediaKind = enum { movie, tv };

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    season: ?i64,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    language_code: []const u8,
    filename: []const u8,
    download_url: []const u8,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SearchItem,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    subtitles: []const SubtitleItem,

    pub fn deinit(self: *SubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn deinit(_: *Scraper) void {}

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/?s={s}", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
        });

        return parseSearchHtml(arena, response.body, trimmed);
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
        const download_url = try parseDownloadUrl(a, response.body);
        const download_id = trailingNumericSegment(download_url) orelse "subtitle";

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = "si",
            .filename = try std.fmt.allocPrint(a, "zoom-{s}-{s}", .{ download_id, try slug(a, item.title) }),
            .download_url = download_url,
        };
        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        };
    }
};

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    const wanted = try common.normalizeTitle(a, stripQueryNoise(query));
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var cursor: usize = 0;
    const marker = "<h3 class=\"entry-title td-module-title\">";
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |h3_pos| {
        const h3_end = std.mem.indexOfPos(u8, body, h3_pos + marker.len, "</h3>") orelse break;
        const block = body[h3_pos..h3_end];
        cursor = h3_end + "</h3>".len;

        const href = attributeValue(block, "href") orelse continue;
        const raw_title = attributeValue(block, "title") orelse continue;
        if (!std.mem.startsWith(u8, href, site)) continue;
        if (seen.contains(href)) continue;

        const parsed_title = parsePostTitle(raw_title);
        if (parsed_title.title.len == 0) continue;
        const normalized = try common.normalizeTitle(a, parsed_title.title);
        if (normalized.len == 0) continue;
        if (std.mem.indexOf(u8, normalized, wanted) == null and
            std.mem.indexOf(u8, wanted, normalized) == null) continue;

        try seen.put(a, try a.dupe(u8, href), {});
        const item: SearchItem = .{
            .title = try a.dupe(u8, parsed_title.title),
            .year = parsed_title.year,
            .media_kind = parsed_title.media_kind,
            .season = parsed_title.season,
            .page_url = try a.dupe(u8, href),
        };

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

const ParsedTitle = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    season: ?i64,
};

fn parsePostTitle(raw: []const u8) ParsedTitle {
    const suffixes = [_][]const u8{
        " Sinhala Subtitle",
        " Sinhala subtitle",
    };

    var core = std.mem.trim(u8, raw, " \t\r\n");
    for (suffixes) |suffix| {
        if (std.ascii.indexOfIgnoreCase(core, suffix)) |pos| {
            core = std.mem.trimEnd(u8, core[0..pos], " \t");
            break;
        }
    }

    var year: ?i64 = null;
    var season: ?i64 = null;
    var media_kind: MediaKind = .movie;

    if (std.ascii.indexOfIgnoreCase(core, "Complete season ")) |pos| {
        const tail = core[pos + "Complete season ".len ..];
        var end: usize = 0;
        while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
        if (end > 0) season = std.fmt.parseInt(i64, tail[0..end], 10) catch null;
        core = std.mem.trimEnd(u8, core[0..pos], " \t");
        media_kind = .tv;
    } else if (parseSeasonToken(core)) |parsed_season| {
        season = parsed_season;
        media_kind = .tv;
        if (std.ascii.indexOfIgnoreCase(core, " S0")) |pos|
            core = std.mem.trimEnd(u8, core[0..pos], " \t-:");
    }

    if (parseTrailingYear(core)) |year_info| {
        year = year_info.year;
        core = year_info.title;
    }

    return .{
        .title = std.mem.trim(u8, core, " \t\r\n"),
        .year = year,
        .media_kind = media_kind,
        .season = season,
    };
}

const YearInfo = struct {
    title: []const u8,
    year: i64,
};

fn parseTrailingYear(value: []const u8) ?YearInfo {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 6 or trimmed[trimmed.len - 1] != ')') return null;
    const open = std.mem.lastIndexOfScalar(u8, trimmed, '(') orelse return null;
    if (trimmed.len - open != 6) return null;
    const digits = trimmed[open + 1 .. trimmed.len - 1];
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const year = std.fmt.parseInt(i64, digits, 10) catch return null;
    return .{
        .title = std.mem.trimEnd(u8, trimmed[0..open], " \t"),
        .year = year,
    };
}

fn parseSeasonToken(value: []const u8) ?i64 {
    var i: usize = 0;
    while (i + 2 < value.len) : (i += 1) {
        if (value[i] != 's' and value[i] != 'S') continue;
        if (i > 0 and std.ascii.isAlphanumeric(value[i - 1])) continue;
        var p = i + 1;
        while (p < value.len and value[p] == '0') : (p += 1) {}
        const start = p;
        while (p < value.len and std.ascii.isDigit(value[p])) : (p += 1) {}
        if (p == start) continue;
        return std.fmt.parseInt(i64, value[start..p], 10) catch null;
    }
    return null;
}

fn stripQueryNoise(value: []const u8) []const u8 {
    if (std.ascii.indexOfIgnoreCase(value, " S0")) |pos|
        return std.mem.trimEnd(u8, value[0..pos], " \t-:");
    return std.mem.trim(u8, value, " \t\r\n");
}

fn parseDownloadUrl(allocator: Allocator, body: []const u8) ![]const u8 {
    const marker = "https://zoom.lk/sub-download/";
    const pos = std.mem.indexOf(u8, body, marker) orelse return error.MissingField;
    var end = pos + marker.len;
    while (end < body.len and std.ascii.isDigit(body[end])) : (end += 1) {}
    if (end == pos + marker.len) return error.MissingField;
    return allocator.dupe(u8, body[pos..end]);
}

fn trailingNumericSegment(url: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
    if (slash + 1 >= url.len) return null;
    const value = url[slash + 1 ..];
    if (value.len == 0) return null;
    for (value) |c| if (!std.ascii.isDigit(c)) return null;
    return value;
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, tag, cursor, name)) |pos| {
        const after = pos + name.len;
        if (after >= tag.len or tag[after] != '=') {
            cursor = after;
            continue;
        }
        if (after + 1 >= tag.len) return null;
        const quote = tag[after + 1];
        if (quote != '"' and quote != '\'') return null;
        const start = after + 2;
        const end_rel = std.mem.indexOfScalar(u8, tag[start..], quote) orelse return null;
        return tag[start .. start + end_rel];
    }
    return null;
}

fn slug(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var dash = false;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and out.items.len > 0) try out.append(allocator, '-');
            dash = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            dash = out.items.len > 0;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "zoom parses movie and tv titles" {
    const movie = parsePostTitle("Centigrade (2020) Sinhala Subtitle (සිංහල උපසිරැසි)");
    try std.testing.expectEqualStrings("Centigrade", movie.title);
    try std.testing.expectEqual(@as(?i64, 2020), movie.year);
    try std.testing.expect(movie.media_kind == .movie);

    const tv = parsePostTitle("Teen Wolf (2012) Complete season 02 Sinhala Subtitle (සිංහල උපසිරැසි)");
    try std.testing.expectEqualStrings("Teen Wolf", tv.title);
    try std.testing.expectEqual(@as(?i64, 2012), tv.year);
    try std.testing.expectEqual(@as(?i64, 2), tv.season);
    try std.testing.expect(tv.media_kind == .tv);
}

test "live zoom movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "zoom.lk")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Centigrade");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    try std.testing.expectEqualStrings("Centigrade", movie.items[0].title);
    var movie_subs = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subs.deinit();
    const movie_dl = try common.fetchBytes(&client, std.testing.allocator, movie_subs.subtitles[0].download_url, .{
        .accept = "application/octet-stream,application/x-rar-compressed,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(movie_dl.body);
    try std.testing.expect(movie_dl.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, movie_dl.body, "Rar!"));

    var tv = try scraper.search("Teen Wolf");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    const tv_item = for (tv.items) |item| {
        if (item.media_kind == .tv and item.season != null) break item;
    } else return error.TestUnexpectedResult;
    var tv_subs = try scraper.fetchSubtitlesBySearchItem(tv_item);
    defer tv_subs.deinit();
    const tv_dl = try common.fetchBytes(&client, std.testing.allocator, tv_subs.subtitles[0].download_url, .{
        .accept = "application/octet-stream,application/x-rar-compressed,*/*",
        .cache = false,
    });
    defer std.testing.allocator.free(tv_dl.body);
    try std.testing.expect(tv_dl.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, tv_dl.body, "Rar!"));
}
