const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const site = "https://sub-scene.com";
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlNode = HtmlParseOptions.GetNode();

pub const SearchItem = struct {
    title: []const u8,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    language: ?[]const u8,
    language_code: ?[]const u8,
    release: ?[]const u8,
    files: ?[]const u8,
    hearing_impaired: bool,
    uploader: ?[]const u8,
    comment: ?[]const u8,
    details_url: []const u8,
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
        const encoded = try common.encodeUriComponent(a, std.mem.trim(u8, query, " \t\r\n"));
        const url = try std.fmt.allocPrint(a, "{s}/search?query={s}", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            .allow_non_ok = true,
            .max_attempts = 2,
            .cache = false,
        });
        if (isCloudflareChallenge(response.status, response.body)) return error.CloudflareChallenge;
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        return parseSearchHtml(arena, response.body);
    }

    pub fn fetchSubtitles(self: *Scraper, page_url: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const response = try common.fetchBytes(self.client, a, page_url, .{
            .accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            .allow_non_ok = true,
            .max_attempts = 2,
        });
        if (isCloudflareChallenge(response.status, response.body)) return error.CloudflareChallenge;
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        return parseSubtitlesHtml(arena, response.body);
    }
};

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);
    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var links = parsed.doc.queryAll("a[href^='/subscene/'], a[href^='/subtitles/']");
    while (links.next()) |link| {
        const href = link.getAttributeValue("href") orelse continue;
        if (seen.contains(href)) continue;
        const title = try common.innerTextTrimmedOwned(a, link);
        if (title.len == 0 or std.ascii.eqlIgnoreCase(title, "Imdb")) continue;
        try seen.put(a, href, {});
        try items.append(a, .{
            .title = title,
            .page_url = try common.resolveUrl(a, site, href),
        });
    }
    return .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) };
}

fn parseSubtitlesHtml(arena: std.heap.ArenaAllocator, body: []const u8) !SubtitlesResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);
    const title = if (parsed.doc.queryOne(".byFilm .title span")) |node|
        try common.innerTextTrimmedOwned(a, node)
    else if (parsed.doc.queryOne(".subtitle .title a[href^='/subscene/']")) |node|
        try common.innerTextTrimmedOwned(a, node)
    else
        "";

    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var rows = parsed.doc.queryAll("table tbody tr");
    while (rows.next()) |row| {
        const anchor = row.queryOne("a[href^='/subtitle/']") orelse continue;
        const href = anchor.getAttributeValue("href") orelse continue;
        const id = std.mem.trimStart(u8, href["/subtitle/".len..], "/");
        if (id.len == 0) continue;
        const language = try optionalText(a, row.queryOne("span.l"));
        const release = try optionalText(a, row.queryOne("span.new"));
        const hi_text = try optionalText(a, row.queryOne("td.a40"));
        try subtitles.append(a, .{
            .language = language,
            .language_code = if (language) |value| common.normalizeLanguageCode(value) else null,
            .release = release,
            .files = try optionalText(a, row.queryOne("td.a3")),
            .hearing_impaired = if (hi_text) |value| !isBlankCell(value) else false,
            .uploader = try optionalText(a, row.queryOne("td.a5")),
            .comment = try optionalText(a, row.queryOne("td.a6")),
            .details_url = try common.resolveUrl(a, site, href),
            .download_url = try std.fmt.allocPrint(a, "{s}/download/{s}", .{ site, id }),
        });
    }
    return .{ .arena = owned_arena, .title = title, .subtitles = try subtitles.toOwnedSlice(a) };
}

fn optionalText(allocator: Allocator, node: ?HtmlNode) !?[]const u8 {
    const value = try common.innerTextTrimmedOwned(allocator, node orelse return null);
    return if (isBlankCell(value)) null else value;
}

fn isBlankCell(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "&nbsp;") or std.mem.eql(u8, trimmed, "\xc2\xa0");
}

fn isCloudflareChallenge(status: std.http.Status, body: []const u8) bool {
    if (status != .forbidden and status != .service_unavailable) return false;
    return std.mem.indexOf(u8, body, "cf-chl-") != null or
        std.mem.indexOf(u8, body, "Just a moment") != null or
        std.mem.indexOf(u8, body, "challenge-platform") != null;
}

test "sub-scene parses search and subtitle pages" {
    const search_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var search = try parseSearchHtml(search_arena, "<div class=\"search-result\"><ul><li><a href=\"/subscene/42\">The Matrix (1999)</a></li></ul></div>");
    defer search.deinit();
    try std.testing.expectEqual(@as(usize, 1), search.items.len);
    try std.testing.expectEqualStrings("https://sub-scene.com/subscene/42", search.items[0].page_url);

    const subs_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var subs = try parseSubtitlesHtml(
        subs_arena,
        "<div class=\"box byFilm\"><div class=\"title\"><span>The Matrix</span></div></div>" ++
            "<table><tbody><tr><td class=\"a1\"><a href=\"/subtitle/99\"><span class=\"l\">English</span><span class=\"new\">Matrix.1999.BluRay</span></a></td><td class=\"a3\">1</td><td class=\"a40\">HI</td><td class=\"a5\"><a>Uploader</a></td><td class=\"a6\"><div>Retail</div></td></tr>" ++
            "<tr><td class=\"a1\"><a href=\"/subtitle/99\"><span class=\"l\">English</span><span class=\"new\">Matrix.1999.WEB</span></a></td><td class=\"a3\">1</td><td class=\"a40\">&nbsp;</td><td class=\"a5\"></td><td class=\"a6\"></td></tr></tbody></table>",
    );
    defer subs.deinit();
    try std.testing.expectEqual(@as(usize, 2), subs.subtitles.len);
    try std.testing.expectEqualStrings("en", subs.subtitles[0].language_code.?);
    try std.testing.expectEqualStrings("https://sub-scene.com/download/99", subs.subtitles[0].download_url);
    try std.testing.expect(subs.subtitles[0].hearing_impaired);
    try std.testing.expect(!subs.subtitles[1].hearing_impaired);
}
