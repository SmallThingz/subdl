const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://feliratok.eu";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    language_code: []const u8,
    filename: []const u8,
    page_url: []const u8,
    download_url: []const u8,
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
        const url = try std.fmt.allocPrint(a, "{s}/index.php?search={s}&soriSorszam=&nyelv=&tab=film", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
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
            .filename = try a.dupe(u8, item.filename),
            .download_url = try a.dupe(u8, item.download_url),
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

    const wanted = try normalizeTitle(a, query);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var cursor: usize = 0;
    const marker = "action=letolt";
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        const row_start = std.mem.lastIndexOf(u8, body[0..pos], "<tr") orelse {
            cursor = pos + marker.len;
            continue;
        };
        const row_end = std.mem.indexOfPos(u8, body, pos, "</tr>") orelse break;
        const row = body[row_start .. row_end + "</tr>".len];
        cursor = row_end + "</tr>".len;

        const href = hrefContaining(row, marker) orelse continue;
        const subtitle_id = queryParam(href, "felirat") orelse continue;
        if (seen.contains(subtitle_id)) continue;
        try seen.put(a, try a.dupe(u8, subtitle_id), {});

        const filename_raw = queryParam(href, "fnev") orelse continue;
        const filename = try percentDecode(a, filename_raw);

        const language_label = between(row, "<small>", "</small>") orelse continue;
        const language_code: []const u8 = if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, language_label, " \t\r\n"), "Angol"))
            "en"
        else if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, language_label, " \t\r\n"), "Magyar"))
            "hu"
        else
            continue;

        const original = between(row, "<div class=\"eredeti\">", "</div>") orelse continue;
        const clean_original = std.mem.trim(u8, original, " \t\r\n");
        const split = splitTitleYear(clean_original);
        if (split.title.len == 0) continue;

        const normalized = try normalizeTitle(a, split.title);
        if (std.mem.indexOf(u8, normalized, wanted) == null and
            std.mem.indexOf(u8, wanted, normalized) == null) continue;

        const detail_url = try std.fmt.allocPrint(a, "{s}/index.php?tipus=adatlap&azon=a_{s}", .{ site, subtitle_id });
        const download_url = try common.resolveUrl(a, site, href);
        const item: SearchItem = .{
            .title = try a.dupe(u8, split.title),
            .year = split.year,
            .language_code = try a.dupe(u8, language_code),
            .filename = filename,
            .page_url = detail_url,
            .download_url = download_url,
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

const TitleYear = struct {
    title: []const u8,
    year: ?i64,
};

fn splitTitleYear(value: []const u8) TitleYear {
    var i: usize = 0;
    while (i + 7 <= value.len) : (i += 1) {
        if (value[i] != ' ' or value[i + 1] != '(') continue;
        const digits = value[i + 2 .. i + 6];
        if (value[i + 6] != ')') continue;
        var all_digits = true;
        for (digits) |c| if (!std.ascii.isDigit(c)) {
            all_digits = false;
            break;
        };
        if (!all_digits) continue;
        const year = std.fmt.parseInt(i64, digits, 10) catch continue;
        return .{ .title = std.mem.trimEnd(u8, value[0..i], " \t"), .year = year };
    }
    return .{ .title = std.mem.trim(u8, value, " \t\r\n"), .year = null };
}

fn hrefContaining(row: []const u8, needle: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, row, needle) orelse return null;
    const quote_start = std.mem.lastIndexOfScalar(u8, row[0..pos], '"') orelse return null;
    const tail = row[quote_start + 1 ..];
    const quote_end = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    return tail[0..quote_end];
}

fn between(value: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, value, open) orelse return null;
    const tail = value[start + open.len ..];
    const end = std.mem.indexOf(u8, tail, close) orelse return null;
    return tail[0..end];
}

fn queryParam(url: []const u8, key: []const u8) ?[]const u8 {
    const query = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var parts = std.mem.splitScalar(u8, url[query + 1 ..], '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], key)) return part[eq + 1 ..];
    }
    return null;
}

fn percentDecode(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                try out.append(allocator, @intCast(hi.? * 16 + lo.?));
                i += 3;
                continue;
            }
        }
        try out.append(allocator, if (input[i] == '+') ' ' else input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn normalizeTitle(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            pending_space = out.items.len > 0;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "supersubtitles parses exact movie rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        "<tr><td class=\"lang\"><small>Angol</small></td><td><div class=\"eredeti\">The Matrix (1999) (REMUX.2160p-SA89)</div></td><td><a href=\"/index.php?action=letolt&fnev=The.Matrix.1999.eng.srt&felirat=1742204065\">x</a></td></tr>",
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 1999), response.items[0].year);
    try std.testing.expectEqualStrings("en", response.items[0].language_code);
}

test "live supersubtitles movie search and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "feliratok.eu")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "application/text,text/plain,*/*",
        .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = search.items[0].page_url }},
        .cache = false,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, download.body, "-->") != null);
}
