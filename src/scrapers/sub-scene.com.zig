const std = @import("std");
const common = @import("common.zig");
const cf = @import("opensubtitles_com_cf.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const site = "https://sub-scene.com";
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlNode = HtmlParseOptions.GetNode();

pub const SearchItem = common.SearchLink;

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
        const encoded = try common.encodeUriComponent(a, std.mem.trim(u8, query, " \t\r\n"));
        const url = try std.fmt.allocPrint(a, "{s}/suggest?query={s}", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .allow_non_ok = true,
            .max_attempts = 2,
            .cache = false,
            .require_public_origin = true,
        });
        if (isCloudflareChallenge(response.status, response.body)) return error.CloudflareChallenge;
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        return parseSuggestJson(common.takeArena(&arena), response.body);
    }

    pub fn fetchSubtitles(self: *Scraper, page_url: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        try validateProviderEndpoint(page_url);
        const response = try common.fetchBytes(self.client, a, page_url, .{
            .accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            .allow_non_ok = true,
            .max_attempts = 2,
            .cache = false,
            .require_public_origin = true,
        });
        if (isCloudflareChallenge(response.status, response.body)) return error.CloudflareChallenge;
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        return parseSubtitlesHtml(common.takeArena(&arena), response.body);
    }
};

fn parseSuggestJson(arena: std.heap.ArenaAllocator, body: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const obj = switch (root) {
        .object => |value| value,
        else => return error.InvalidFieldType,
    };

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.AutoHashMapUnmanaged(i64, void).empty;
    for ([_][]const u8{ "film", "tv" }) |group_name| {
        const group_value = obj.get(group_name) orelse continue;
        const group = switch (group_value) {
            .array => |value| value,
            else => continue,
        };
        for (group.items) |entry| {
            const entry_obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const id_value = entry_obj.get("id") orelse continue;
            const id: i64 = switch (id_value) {
                .integer => |value| value,
                .number_string => |value| std.fmt.parseInt(i64, value, 10) catch continue,
                else => continue,
            };
            if (id <= 0 or seen.contains(id)) continue;
            const name_value = entry_obj.get("name") orelse continue;
            const name = switch (name_value) {
                .string => |value| std.mem.trim(u8, value, " \t\r\n"),
                else => continue,
            };
            if (name.len == 0) continue;

            try seen.put(a, id, {});
            const year = if (entry_obj.get("year")) |year_value| switch (year_value) {
                .string => |value| std.mem.trim(u8, value, " \t\r\n"),
                .number_string => |value| value,
                .integer => |value| try std.fmt.allocPrint(a, "{d}", .{value}),
                else => "",
            } else "";
            const title = if (year.len > 0)
                try std.fmt.allocPrint(a, "{s} ({s})", .{ name, year })
            else
                try a.dupe(u8, name);
            try items.append(a, .{
                .title = title,
                .page_url = try std.fmt.allocPrint(a, "{s}/subscene/{d}", .{ site, id }),
            });
        }
    }

    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

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
            .page_url = try resolveProviderUrl(a, href),
        });
    }
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
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
            .details_url = try resolveProviderUrl(a, href),
            .download_url = try std.fmt.allocPrint(a, "{s}/download/{s}", .{ site, id }),
        });
    }
    return common.finishResponse(SubtitlesResponse, &owned_arena, .{ .arena = owned_arena, .title = title, .subtitles = try subtitles.toOwnedSlice(a) });
}

fn optionalText(allocator: Allocator, node: ?HtmlNode) !?[]const u8 {
    const value = try common.innerTextTrimmedOwned(allocator, node orelse return null);
    return if (isBlankCell(value)) null else value;
}

fn isBlankCell(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "&nbsp;") or std.mem.eql(u8, trimmed, "\xc2\xa0");
}

fn isCloudflareChallenge(_: std.http.Status, body: []const u8) bool {
    return cf.isChallengeBody(body);
}

fn resolveProviderUrl(allocator: Allocator, href: []const u8) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderEndpoint(resolved);
    return resolved;
}

fn validateProviderEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

test "sub-scene rejects unsafe provider endpoints" {
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("http://127.0.0.1/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://user:pass@sub-scene.com/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://sub-scene.com.evil.com/private"));
}

test "sub-scene detects positive challenge pages independently of status" {
    const challenge = "<!DOCTYPE html><html><title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script></html>";
    for ([_]std.http.Status{ .ok, .forbidden, .service_unavailable }) |status| {
        try std.testing.expect(isCloudflareChallenge(status, challenge));
        try std.testing.expect(!isCloudflareChallenge(status, "{\"name\":\"Just a moment\",\"description\":\"cf-chl-test\"}"));
        try std.testing.expect(!isCloudflareChallenge(status, "<html><body>Just a moment: a movie title</body></html>"));
        try std.testing.expect(!isCloudflareChallenge(status, "<html><body>Subtitle details<script src='/cdn-cgi/challenge-platform/scripts/jsd/main.js'></script></body></html>"));
    }
}

test "sub-scene parses search and subtitle pages" {
    const suggest_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var suggest = try parseSuggestJson(
        suggest_arena,
        "{\"film\":[{\"id\":114030,\"name\":\"The Matrix\",\"year\":\"1999\"}],\"tv\":[{\"id\":115788,\"name\":\"Chernobyl - First Season\",\"year\":\"2019\"}]}",
    );
    defer suggest.deinit();
    try std.testing.expectEqual(@as(usize, 2), suggest.items.len);
    try std.testing.expectEqualStrings("The Matrix (1999)", suggest.items[0].title);
    try std.testing.expectEqualStrings("https://sub-scene.com/subscene/114030", suggest.items[0].page_url);
    try std.testing.expectEqualStrings("Chernobyl - First Season (2019)", suggest.items[1].title);

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
