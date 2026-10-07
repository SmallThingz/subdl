const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://miraianime.net";
const api = site ++ "/wp-json/wp/v2";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    english_title: ?[]const u8,
    anime_id: i64,
    media_kind: MediaKind,
    episodes: ?i64,
    page_url: []const u8,
    subtitle_page_url: []const u8,
};

const SearchCandidate = struct {
    anime_id: i64,
    search_title: []const u8,
    page_url: []const u8,
    slug: []const u8,
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
        return self.searchUsing(common.fetchBytes, query);
    }

    fn searchUsing(self: *Scraper, comptime fetch: anytype, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/search?search={s}&per_page=20", .{ api, encoded });
        const response = try fetch(self.client, a, url, .{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        if (response.status == .too_many_requests) return error.RateLimited;
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const array = switch (root) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var exact_candidates: std.ArrayListUnmanaged(SearchCandidate) = .empty;
        var partial_candidates: std.ArrayListUnmanaged(SearchCandidate) = .empty;

        for (array.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const subtype = common.jsonString(obj, "subtype") orelse continue;
            if (!std.mem.eql(u8, subtype, "anime")) continue;
            const anime_id = common.jsonIntField(obj, "id") orelse continue;
            const search_title = common.jsonString(obj, "title") orelse continue;
            const page_url = common.jsonString(obj, "url") orelse continue;
            if (anime_id <= 0 or search_title.len == 0 or page_url.len == 0) continue;
            const slug = pageSlug(page_url) orelse continue;
            const normalized_search_title = try common.normalizeTitle(a, search_title);
            const candidate: SearchCandidate = .{
                .anime_id = anime_id,
                .search_title = search_title,
                .page_url = page_url,
                .slug = slug,
            };
            if (std.mem.eql(u8, normalized_search_title, wanted))
                try exact_candidates.append(a, candidate)
            else
                try partial_candidates.append(a, candidate);
        }

        var candidates: std.ArrayListUnmanaged(SearchCandidate) = .empty;
        try candidates.appendSlice(a, exact_candidates.items);
        try candidates.appendSlice(a, partial_candidates.items);
        var inspected_ids = std.AutoHashMapUnmanaged(i64, void).empty;
        var inspected: usize = 0;
        for (candidates.items) |candidate| {
            if (inspected_ids.contains(candidate.anime_id)) continue;
            if (inspected >= 10) break;
            try inspected_ids.put(a, candidate.anime_id, {});
            inspected += 1;

            const detail_url = try std.fmt.allocPrint(a, "{s}/anime/{d}", .{ api, candidate.anime_id });
            const detail_response = fetch(self.client, a, detail_url, .{
                .accept = "application/json",
                .cache = false,
                .max_attempts = 2,
                .retry_on_429 = false,
                .allow_non_ok = true,
                .require_public_origin = true,
                .require_https = true,
                .require_same_origin = true,
            }) catch |err| {
                if (common.mustPropagateOptionalFailure(err)) return err;
                continue;
            };
            if (detail_response.status == .too_many_requests) return error.RateLimited;
            if (detail_response.status != .ok) continue;
            const detail = std.json.parseFromSliceLeaky(std.json.Value, a, detail_response.body, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            const detail_obj = switch (detail) {
                .object => |value| value,
                else => continue,
            };
            const detail_id = common.jsonIntField(detail_obj, "id") orelse continue;
            if (detail_id != candidate.anime_id) continue;

            const rendered_title = nestedString(detail_obj, &.{ "title", "rendered" }) orelse candidate.search_title;
            const english_title = nestedString(detail_obj, &.{ "acf", "basic_data", "anime_titles", "english_title" });
            const type_code = nestedString(detail_obj, &.{ "acf", "basic_data", "type" }) orelse "";
            const episodes = nestedInt(detail_obj, &.{ "acf", "basic_data", "episodes" });
            const media_kind: MediaKind = if (std.mem.eql(u8, type_code, "3") or (episodes != null and episodes.? == 1))
                .movie
            else
                .tv;

            const subtitle_page_url = try std.fmt.allocPrint(a, "{s}/subtitle/{s}/", .{ site, candidate.slug });
            const title = try a.dupe(u8, rendered_title);
            const item: SearchItem = .{
                .title = title,
                .english_title = if (english_title) |value| try a.dupe(u8, value) else null,
                .anime_id = candidate.anime_id,
                .media_kind = media_kind,
                .episodes = episodes,
                .page_url = try a.dupe(u8, candidate.page_url),
                .subtitle_page_url = subtitle_page_url,
            };

            const normalized_title = try common.normalizeTitle(a, title);
            const normalized_english = if (english_title) |value| try common.normalizeTitle(a, value) else "";
            if (std.mem.eql(u8, normalized_title, wanted) or
                (normalized_english.len > 0 and std.mem.eql(u8, normalized_english, wanted)))
            {
                try exact.append(a, item);
            } else {
                try partial.append(a, item);
            }
        }

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        try items.appendSlice(a, exact.items);
        try items.appendSlice(a, partial.items);
        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemUsing(common.fetchBytes, item);
    }

    fn fetchSubtitlesBySearchItemUsing(self: *Scraper, comptime fetch: anytype, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const slug = pageSlug(item.page_url) orelse return error.UnsafeHttpTarget;
        const subtitle_slug = subtitlePageSlug(item.subtitle_page_url) orelse return error.UnsafeHttpTarget;
        if (!std.mem.eql(u8, slug, subtitle_slug)) return error.UnsafeHttpTarget;
        const response = try fetch(self.client, a, item.subtitle_page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = item.page_url }},
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        if (response.status == .too_many_requests) return error.RateLimited;
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        const subtitles = try parseSubtitleItems(a, response.body, item.title);

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn parseSubtitleItems(allocator: Allocator, body: []const u8, fallback_title: []const u8) ![]SubtitleItem {
    var parsed = try common.parseHtmlStable(allocator, body);
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var anchors = parsed.doc.queryAll("a.download-file[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (std.ascii.findIgnoreCase(href, "font") != null) continue;
        if (!hasArchiveExtension(href)) continue;
        // Reject malformed absolute URLs before resolution can reinterpret them as paths.
        if (std.mem.indexOfAny(u8, href, ":/?#")) |separator| {
            if (href[separator] == ':') common.validatePublicHttpUrl(href) catch continue;
        }

        const download_url = common.resolveUrl(allocator, site, href) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        common.validatePublicHttpUrl(download_url) catch continue;
        if (seen.contains(download_url)) continue;
        try seen.put(allocator, download_url, {});

        try subtitles.append(allocator, .{
            .language_code = "ar",
            .filename = try filenameFromUrl(allocator, download_url, fallback_title),
            .download_url = download_url,
        });
    }
    return subtitles.toOwnedSlice(allocator);
}

fn validateProviderEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

fn nestedValue(root: std.json.ObjectMap, path: []const []const u8) ?std.json.Value {
    if (path.len == 0) return null;
    var value = root.get(path[0]) orelse return null;
    for (path[1..]) |key| {
        const obj = switch (value) {
            .object => |map| map,
            else => return null,
        };
        value = obj.get(key) orelse return null;
    }
    return value;
}

fn nestedString(root: std.json.ObjectMap, path: []const []const u8) ?[]const u8 {
    const value = nestedValue(root, path) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn nestedInt(root: std.json.ObjectMap, path: []const []const u8) ?i64 {
    const value = nestedValue(root, path) orelse return null;
    return common.jsonInt(value);
}

fn pageSlug(page_url: []const u8) ?[]const u8 {
    return routeSlug(page_url, "/anime/");
}

fn subtitlePageSlug(page_url: []const u8) ?[]const u8 {
    return routeSlug(page_url, "/subtitle/");
}

fn routeSlug(page_url: []const u8, prefix: []const u8) ?[]const u8 {
    validateProviderEndpoint(page_url) catch return null;
    const uri = std.Uri.parse(page_url) catch return null;
    if (uri.query != null or uri.fragment != null) return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, "/")) return null;
    if (path.len <= prefix.len + 1) return null;
    const slug = path[prefix.len .. path.len - 1];
    if (!isCanonicalSlug(slug)) return null;
    return slug;
}

fn isCanonicalSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or value[0] == '-' or value[value.len - 1] == '-') return false;
    var previous_dash = false;
    for (value) |c| {
        if (c == '-') {
            if (previous_dash) return false;
            previous_dash = true;
        } else {
            if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
            previous_dash = false;
        }
    }
    return true;
}

fn hasArchiveExtension(url: []const u8) bool {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..end];
    return std.ascii.endsWithIgnoreCase(path, ".zip") or
        std.ascii.endsWithIgnoreCase(path, ".rar") or
        std.ascii.endsWithIgnoreCase(path, ".7z");
}

fn filenameFromUrl(allocator: Allocator, url: []const u8, fallback_title: []const u8) ![]u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..end];
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const filename = path[slash + 1 ..];
        if (filename.len > 0) return allocator.dupe(u8, filename);
    }
    return std.fmt.allocPrint(allocator, "{s}.zip", .{fallback_title});
}

test "miraianime parses anime media kind metadata" {
    const allocator = std.testing.allocator;
    const json =
        "{\"title\":{\"rendered\":\"Kimi no Na wa.\"},\"acf\":{\"basic_data\":{\"type\":\"3\",\"episodes\":1,\"anime_titles\":{\"english_title\":\"Your Name.\"}}}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3", nestedString(root, &.{ "acf", "basic_data", "type" }).?);
    try std.testing.expectEqual(@as(?i64, 1), nestedInt(root, &.{ "acf", "basic_data", "episodes" }));
}

test "miraianime rejects unsafe provider URLs before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("http://127.0.0.1/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://user:pass@miraianime.net/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://www.google.com/private"));
}

test "miraianime accepts only canonical anime and subtitle page routes" {
    try std.testing.expectEqualStrings("death-note", pageSlug("https://miraianime.net/anime/death-note/").?);
    try std.testing.expectEqualStrings("death-note", subtitlePageSlug("https://miraianime.net/subtitle/death-note/").?);
    for ([_][]const u8{
        "https://miraianime.net/anime/death-note",
        "https://miraianime.net/anime/death-note/extra/",
        "https://miraianime.net/anime/death-note/?next=/admin",
        "https://miraianime.net/anime/%2e%2e/",
        "https://miraianime.net/anime/death%2fnote/",
        "https://miraianime.net/other/death-note/",
    }) |url| try std.testing.expect(pageSlug(url) == null);
}

test "miraianime provider fetches require public HTTPS same-origin" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);
            try std.testing.expect(options.require_same_origin);

            if (std.mem.indexOf(u8, url, "/search?") != null) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "[{\"subtype\":\"anime\",\"id\":7,\"title\":\"Target\",\"url\":\"https://miraianime.net/anime/target/\"}]"),
            };
            if (std.mem.endsWith(u8, url, "/anime/7")) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "{\"id\":7,\"title\":{\"rendered\":\"Target\"},\"acf\":{\"basic_data\":{\"type\":\"3\",\"episodes\":1}}}"),
            };

            try std.testing.expectEqualStrings(site ++ "/subtitle/target/", url);
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "<a class='download-file' href='/files/target.zip'>download</a>"),
            };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var search_response = try scraper.searchUsing(Fixture.fetch, "Target");
    defer search_response.deinit();
    try std.testing.expectEqual(@as(usize, 1), search_response.items.len);

    var subtitles_response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, search_response.items[0]);
    defer subtitles_response.deinit();
    try std.testing.expectEqual(@as(usize, 1), subtitles_response.subtitles.len);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}

test "miraianime skips detail responses for a different anime id" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            if (std.mem.indexOf(u8, url, "/search?") != null) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "[{\"subtype\":\"anime\",\"id\":1,\"title\":\"Target\",\"url\":\"https://miraianime.net/anime/target/\"}]"),
            };
            try std.testing.expect(std.mem.endsWith(u8, url, "/anime/1"));
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "{\"id\":2,\"title\":{\"rendered\":\"Target\"},\"acf\":{\"basic_data\":{\"type\":\"3\",\"episodes\":1}}}"),
            };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetch, "Target");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "miraianime rejects normalized-empty searches before I/O" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.TestUnexpectedResult;
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetch, "---");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "miraianime duplicate ids do not consume the detail request budget" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            if (std.mem.indexOf(u8, url, "/search?") != null) return .{
                .status = .ok,
                .body = try allocator.dupe(u8,
                    \\[
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":1,"title":"Target","url":"https://miraianime.net/anime/duplicate/"},
                    \\  {"subtype":"anime","id":2,"title":"Target","url":"https://miraianime.net/anime/target/"}
                    \\]
                ),
            };
            if (std.mem.endsWith(u8, url, "/anime/1"))
                return .{ .status = .not_found, .body = try allocator.dupe(u8, "missing") };
            try std.testing.expect(std.mem.endsWith(u8, url, "/anime/2"));
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "{\"id\":2,\"title\":{\"rendered\":\"Target\"},\"acf\":{\"basic_data\":{\"type\":\"3\",\"episodes\":1}}}"),
            };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetch, "Target");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqual(@as(i64, 2), response.items[0].anime_id);
}

test "miraianime skips malformed archive links before a valid candidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const subtitles = try parseSubtitleItems(
        arena.allocator(),
        "<a class='download-file' href='https://miraianime.net:bad/broken.zip'>bad uri</a>" ++
            "<a class='download-file' href='https://miraianime.net:99999/overflow.zip'>bad port</a>" ++
            "<a class='download-file' href='//miraianime.net:bad/broken.zip'>bad authority</a>" ++
            "<a class='download-file' href='javascript:broken.zip'>bad scheme</a>" ++
            "<a class='download-file' href='http://127.0.0.1/private.zip'>unsafe</a>" ++
            "<a class='download-file' href='/files/target.zip'>valid</a>",
        "Target",
    );
    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings(site ++ "/files/target.zip", subtitles[0].download_url);
}

test "miraianime preserves relative and public external archive links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const subtitles = try parseSubtitleItems(
        arena.allocator(),
        "<a class='download-file' href='files/part:1.zip'>relative</a>" ++
            "<a class='download-file' href='https://example.com:8443/target.zip'>external</a>" ++
            "<a class='download-file' href='//example.com/target.rar'>scheme relative</a>",
        "Target",
    );
    try std.testing.expectEqual(@as(usize, 3), subtitles.len);
    try std.testing.expectEqualStrings(site ++ "/files/part:1.zip", subtitles[0].download_url);
    try std.testing.expectEqualStrings("https://example.com:8443/target.zip", subtitles[1].download_url);
    try std.testing.expectEqualStrings("https://example.com/target.rar", subtitles[2].download_url);
}

test "miraianime promotes an exact eleventh candidate into the detail budget" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,
        first_detail_was_exact: bool = false,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            if (std.mem.indexOf(u8, url, "/search?") != null) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "[{\"subtype\":\"anime\",\"id\":1,\"title\":\"Partial 1\",\"url\":\"https://miraianime.net/anime/partial-1/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":2,\"title\":\"Partial 2\",\"url\":\"https://miraianime.net/anime/partial-2/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":3,\"title\":\"Partial 3\",\"url\":\"https://miraianime.net/anime/partial-3/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":4,\"title\":\"Partial 4\",\"url\":\"https://miraianime.net/anime/partial-4/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":5,\"title\":\"Partial 5\",\"url\":\"https://miraianime.net/anime/partial-5/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":6,\"title\":\"Partial 6\",\"url\":\"https://miraianime.net/anime/partial-6/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":7,\"title\":\"Partial 7\",\"url\":\"https://miraianime.net/anime/partial-7/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":8,\"title\":\"Partial 8\",\"url\":\"https://miraianime.net/anime/partial-8/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":9,\"title\":\"Partial 9\",\"url\":\"https://miraianime.net/anime/partial-9/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":10,\"title\":\"Partial 10\",\"url\":\"https://miraianime.net/anime/partial-10/\"}," ++
                    "{\"subtype\":\"anime\",\"id\":11,\"title\":\"Target\",\"url\":\"https://miraianime.net/anime/target/\"}]"),
            };

            if (self.calls == 2) self.first_detail_was_exact = std.mem.endsWith(u8, url, "/anime/11");
            if (std.mem.endsWith(u8, url, "/anime/11")) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "{\"id\":11,\"title\":{\"rendered\":\"Target\"},\"acf\":{\"basic_data\":{\"type\":\"3\",\"episodes\":1}}}"),
            };
            return .{ .status = .not_found, .body = try allocator.dupe(u8, "missing") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetch, "Target");
    defer response.deinit();
    try std.testing.expect(fixture.first_detail_was_exact);
    try std.testing.expectEqual(@as(usize, 11), fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Target", response.items[0].title);
}

test "miraianime stops detail fallback on rate limits and cancellation" {
    const Scenario = enum { limited, canceled, out_of_memory };
    const Case = struct { scenario: Scenario, expected_error: anyerror };
    const Fixture = struct {
        client: std.http.Client,
        scenario: Scenario,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(!options.retry_on_429);
            if (std.mem.indexOf(u8, url, "/search?") != null) {
                return .{
                    .status = .ok,
                    .body = try allocator.dupe(u8, "[{\"subtype\":\"anime\",\"id\":1,\"title\":\"First\",\"url\":\"https://miraianime.net/anime/first/\"}," ++
                        "{\"subtype\":\"anime\",\"id\":2,\"title\":\"Second\",\"url\":\"https://miraianime.net/anime/second/\"}]"),
                };
            }
            try std.testing.expectEqual(@as(usize, 2), self.calls);
            return switch (self.scenario) {
                .limited => .{ .status = .too_many_requests, .body = try allocator.dupe(u8, "limited") },
                .canceled => error.Canceled,
                .out_of_memory => error.OutOfMemory,
            };
        }
    };

    for ([_]Case{
        .{ .scenario = .limited, .expected_error = error.RateLimited },
        .{ .scenario = .canceled, .expected_error = error.Canceled },
        .{ .scenario = .out_of_memory, .expected_error = error.OutOfMemory },
    }) |case| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .scenario = case.scenario,
        };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        try std.testing.expectError(case.expected_error, scraper.searchUsing(Fixture.fetch, "First"));
        try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    }
}

test "miraianime skips one ordinary detail failure" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            if (std.mem.indexOf(u8, url, "/search?") != null) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "[{\"subtype\":\"anime\",\"id\":1,\"title\":\"Broken\",\"url\":\"https://miraianime.net/anime/broken/\"},{\"subtype\":\"anime\",\"id\":2,\"title\":\"Second\",\"url\":\"https://miraianime.net/anime/second/\"}]"),
            };
            if (std.mem.endsWith(u8, url, "/anime/1")) return error.ConnectionResetByPeer;
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "{\"id\":2,\"title\":{\"rendered\":\"Second\"},\"acf\":{\"basic_data\":{\"type\":\"3\",\"episodes\":1}}}"),
            };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetch, "Second");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Second", response.items[0].title);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}

test "live miraianime movie and tv subtitle packs" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "miraianime.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Kimi no Na wa");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    try std.testing.expect(movie.items[0].media_kind == .movie);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    try std.testing.expect(movie_subtitles.subtitles.len > 0);
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Death Note");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    try std.testing.expect(tv.items[0].media_kind == .tv);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    try std.testing.expect(tv_subtitles.subtitles.len > 0);
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}
