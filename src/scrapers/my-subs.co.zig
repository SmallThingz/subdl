const std = @import("std");
const common = @import("common.zig");
const cloudflare = @import("opensubtitles_com_cf.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

const Allocator = std.mem.Allocator;
const site = "https://my-subs.co";
const max_season_page_requests: usize = 128;
const max_download_resolution_requests: usize = 256;

pub const MediaKind = common.MediaKind;

pub const SearchOptions = struct {};

pub const SubtitlesOptions = struct {
    include_seasons: bool = true,
    resolve_download_links: bool = false,
};

pub const SearchItem = struct {
    title: []const u8,
    details_url: []const u8,
    media_kind: MediaKind,
};

pub const SubtitleItem = struct {
    language_raw: ?[]const u8,
    language_code: ?[]const u8,
    filename: []const u8,
    release_version: ?[]const u8,
    details_url: []const u8,
    download_page_url: []const u8,
    resolved_download_url: ?[]const u8,
    is_archive: ?bool,
};

pub const SearchResponse = common.PagedSearchResponse(SearchItem);

pub const SubtitlesResponse = common.PagedSubtitlesResponse(SubtitleItem);

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchWithOptions(query, .{});
    }

    pub fn searchWithOptions(self: *Scraper, query: []const u8, options: SearchOptions) !SearchResponse {
        return self.searchWithOptionsUsing(common.fetchBytes, query, options);
    }

    fn searchWithOptionsUsing(self: *Scraper, comptime fetch: anytype, query: []const u8, _: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        const page_url = try buildSearchUrl(a, trimmed);
        try validateProviderRoute(page_url, .search);
        const response = try fetchHtmlWith(fetch, self.client, a, page_url);
        if (response.body.len > 0) {
            var parsed = try common.parseHtmlStable(a, response.body);

            var anchors = parsed.doc.queryAll("a[href*='/showlistsubtitles-'], a[href*='/film-versions-']");
            while (anchors.next()) |anchor| {
                const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                const details_url = resolveProviderRoute(a, site, href, .details) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => continue,
                };
                if (seen.contains(details_url)) continue;
                try seen.put(a, details_url, {});

                const title = blk: {
                    if (common.getAttributeValueSafe(anchor, "title")) |title_attr| {
                        const clean = std.mem.trim(u8, title_attr, " \t\r\n");
                        if (clean.len > 0) break :blk try a.dupe(u8, clean);
                    }
                    const txt = try common.innerTextTrimmedOwned(a, anchor);
                    if (txt.len > 0) break :blk txt;
                    break :blk try a.dupe(u8, trimmed);
                };

                try out.append(a, .{
                    .title = title,
                    .details_url = details_url,
                    .media_kind = if (std.mem.indexOf(u8, href, "/showlistsubtitles-") != null) .tv else .movie,
                });
            }
        }

        return common.finishResponse(SearchResponse, &arena, .{
            .arena = arena,
            .items = try out.toOwnedSlice(a),
            .page = 1,
            .has_prev_page = false,
            .has_next_page = false,
        });
    }

    pub fn fetchSubtitlesByDetailsLink(self: *Scraper, details_url: []const u8, media_kind: MediaKind) !SubtitlesResponse {
        return self.fetchSubtitlesByDetailsLinkWithOptions(details_url, media_kind, .{});
    }

    pub fn fetchSubtitlesByDetailsLinkWithOptions(self: *Scraper, details_url: []const u8, media_kind: MediaKind, options: SubtitlesOptions) !SubtitlesResponse {
        return self.fetchSubtitlesByDetailsLinkUsing(common.fetchBytes, details_url, media_kind, options);
    }

    fn fetchSubtitlesByDetailsLinkUsing(self: *Scraper, comptime fetch: anytype, details_url: []const u8, media_kind: MediaKind, options: SubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        var page_urls: std.ArrayListUnmanaged([]const u8) = .empty;
        var page_url_seen = std.StringHashMapUnmanaged(void).empty;
        try validateProviderRoute(details_url, .details);
        const owned_details_url = try a.dupe(u8, details_url);
        try page_urls.append(a, owned_details_url);
        try page_url_seen.put(a, owned_details_url, {});

        const root_response = try fetchHtmlWith(fetch, self.client, a, details_url);
        if (root_response.body.len == 0) return .{ .arena = arena, .subtitles = &.{} };

        var root = try common.parseHtmlStable(a, root_response.body);

        if (media_kind == .tv and options.include_seasons) {
            var season_request_count: usize = 0;
            var season_links = root.doc.queryAll("#saison a[href*='/versions-'][href*='-subtitles']");
            while (season_links.next()) |anchor| {
                const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                const url = resolveProviderRoute(a, details_url, href, .season) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => continue,
                };
                if (page_url_seen.contains(url)) continue;
                try consumeRequestBudget(&season_request_count, max_season_page_requests);
                try page_url_seen.put(a, url, {});
                try page_urls.append(a, url);
            }
        }

        var entry_seen = std.StringHashMapUnmanaged(void).empty;
        var download_resolution_count: usize = 0;

        for (page_urls.items, 0..) |entry_url, entry_index| {
            if (entry_seen.contains(entry_url)) continue;
            try entry_seen.put(a, entry_url, {});

            const response = if (entry_index == 0) root_response else try fetchHtmlWith(fetch, self.client, a, entry_url);
            if (response.body.len == 0) continue;

            var parsed = try common.parseHtmlStable(a, response.body);

            const page_title = if (parsed.doc.queryOne("h1")) |h1|
                try common.innerTextTrimmedOwned(a, h1)
            else
                "";

            var anchors = parsed.doc.queryAll("a[href*='/downloads/']");
            while (anchors.next()) |anchor| {
                const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                const download_page_url = resolveProviderRoute(a, entry_url, href, .download_page) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => continue,
                };
                if (seen.contains(download_page_url)) continue;
                try seen.put(a, download_page_url, {});

                const lang_meta = extractLanguage(anchor);
                const release_version = try extractReleaseVersion(anchor, a);

                var filename = if (release_version) |rv| rv else page_title;
                if (filename.len == 0) {
                    filename = try common.innerTextTrimmedOwned(a, anchor);
                }
                if (filename.len == 0) filename = "subtitle.srt";

                const language_raw = if (lang_meta.raw) |raw| try a.dupe(u8, raw) else null;
                const language_code = if (lang_meta.code) |code| try a.dupe(u8, code) else null;

                var resolved_download_url: ?[]const u8 = null;
                var is_archive: ?bool = null;
                if (options.resolve_download_links) {
                    try consumeRequestBudget(&download_resolution_count, max_download_resolution_requests);
                    const url = try self.resolveDownloadPageUsing(fetch, a, download_page_url);
                    resolved_download_url = url;
                    is_archive = looksArchive(url);
                }

                try subtitles.append(a, .{
                    .language_raw = language_raw,
                    .language_code = language_code,
                    .filename = filename,
                    .release_version = release_version,
                    .details_url = entry_url,
                    .download_page_url = download_page_url,
                    .resolved_download_url = resolved_download_url,
                    .is_archive = is_archive,
                });
            }
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .subtitles = try subtitles.toOwnedSlice(a),
            .page = 1,
            .has_prev_page = false,
            .has_next_page = false,
        });
    }

    pub fn resolveDownloadPageUrl(self: *Scraper, allocator: Allocator, download_page_url: []const u8) ![]const u8 {
        return self.resolveDownloadPage(allocator, download_page_url);
    }

    fn resolveDownloadPage(self: *Scraper, allocator: Allocator, download_page_url: []const u8) ![]const u8 {
        return self.resolveDownloadPageUsing(common.fetchBytes, allocator, download_page_url);
    }

    fn resolveDownloadPageUsing(self: *Scraper, comptime fetch: anytype, allocator: Allocator, download_page_url: []const u8) ![]const u8 {
        try validateProviderRoute(download_page_url, .download_page);
        const response = try fetchHtmlWith(fetch, self.client, allocator, download_page_url);
        defer allocator.free(response.body);

        const resolved = (try resolveRealUrlFromPage(allocator, download_page_url, response.body)) orelse return error.MissingField;
        return resolved;
    }
};

fn consumeRequestBudget(count: *usize, limit: usize) !void {
    const next = std.math.add(usize, count.*, 1) catch return error.ResponseTooLarge;
    if (next > limit) return error.ResponseTooLarge;
    count.* = next;
}

fn fetchHtmlWith(comptime fetch: anytype, client: *std.http.Client, allocator: Allocator, url: []const u8) !common.HttpResponse {
    const response = try fetch(client, allocator, url, .{
        .accept = "text/html",
        .max_attempts = 2,
        .allow_non_ok = true,
        .require_public_origin = true,
        .require_https = true,
        .require_same_origin = true,
    });
    errdefer allocator.free(response.body);
    if (common.isAustralianWebsiteBlockPage(response.body)) return error.ProviderAccessBlocked;
    if (cloudflare.isChallengeBody(response.body)) return error.CloudflareChallenge;
    if (response.status == .too_many_requests) return error.RateLimited;
    if (response.status != .ok) return error.UnexpectedHttpStatus;
    return response;
}

fn buildSearchUrl(allocator: Allocator, query: []const u8) ![]const u8 {
    const encoded = try common.encodeUriComponent(allocator, query);
    return std.fmt.allocPrint(allocator, "{s}/search.php?key={s}", .{ site, encoded });
}

const ProviderRoute = enum {
    search,
    details,
    season,
    download_page,
    download_file,
};

fn resolveProviderRoute(
    allocator: Allocator,
    base_url: []const u8,
    href: []const u8,
    route: ProviderRoute,
) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, base_url, href);
    errdefer allocator.free(resolved);
    try validateProviderRoute(resolved, route);
    return resolved;
}

fn validateProviderRoute(url: []const u8, route: ProviderRoute) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsafeHttpTarget;
    if (uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const query = if (uri.query) |component| switch (component) {
        .raw, .percent_encoded => |value| value,
    } else null;
    if (hasUnsafeProviderPath(path)) return error.UnsafeHttpTarget;

    const valid = switch (route) {
        .search => std.mem.eql(u8, path, "/search.php") and
            query != null and isCanonicalSearchQuery(query.?),
        .details => query == null and
            (hasNonEmptyRouteSuffix(path, "/showlistsubtitles-") or
                hasNonEmptyRouteSuffix(path, "/film-versions-")),
        .season => query == null and
            hasNonEmptyRouteSuffix(path, "/versions-") and
            std.mem.endsWith(u8, path, "-subtitles"),
        .download_page => query == null and hasNonEmptyRouteSuffix(path, "/downloads/"),
        .download_file => hasNonEmptyRouteSuffix(path, "/files/") and
            std.mem.endsWith(u8, path, ".zip"),
    };
    if (!valid) return error.UnsafeHttpTarget;
}

fn isCanonicalSearchQuery(query: []const u8) bool {
    const prefix = "key=";
    if (!std.mem.startsWith(u8, query, prefix)) return false;
    const value = query[prefix.len..];
    if (value.len == 0) return false;

    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            index += 1;
            continue;
        }
        if (byte != '%' or value.len - index < 3 or
            !isUpperHexDigit(value[index + 1]) or !isUpperHexDigit(value[index + 2])) return false;
        index += 3;
    }
    return true;
}

fn isUpperHexDigit(byte: u8) bool {
    return std.ascii.isDigit(byte) or (byte >= 'A' and byte <= 'F');
}

fn hasNonEmptyRouteSuffix(path: []const u8, prefix: []const u8) bool {
    if (path.len <= prefix.len or !std.mem.startsWith(u8, path, prefix)) return false;
    return std.mem.indexOfScalar(u8, path[prefix.len..], '/') == null;
}

fn hasUnsafeProviderPath(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '\\') != null or
        std.ascii.findIgnoreCase(path, "%2f") != null or
        std.ascii.findIgnoreCase(path, "%5c") != null or
        std.ascii.findIgnoreCase(path, "%2e") != null)
    {
        return true;
    }
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

fn extractLanguage(anchor: HtmlNode) struct { raw: ?[]const u8, code: ?[]const u8 } {
    if (anchor.queryOne("span[class*='flag-icon-']")) |flag| {
        const class_name = common.getAttributeValueSafe(flag, "class") orelse "";
        const flag_code = parseFlagCodeFromClass(class_name);

        const raw = blk: {
            const title = common.getAttributeValueSafe(flag, "title") orelse break :blk null;
            const clean = std.mem.trim(u8, title, " \t\r\n");
            if (clean.len == 0) break :blk null;
            break :blk clean;
        };

        return .{ .raw = raw, .code = languageFromFlag(flag_code, raw) };
    }

    return .{ .raw = null, .code = null };
}

fn parseFlagCodeFromClass(class_name: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, class_name, " \t\r\n");
    while (it.next()) |token| {
        if (!std.mem.startsWith(u8, token, "flag-icon-")) continue;
        const code = token["flag-icon-".len..];
        if (code.len == 2) return code;
    }
    return null;
}

fn languageFromFlag(flag_code: ?[]const u8, raw: ?[]const u8) ?[]const u8 {
    if (flag_code) |code| {
        if (std.ascii.eqlIgnoreCase(code, "br")) return "pt-br";
        if (std.ascii.eqlIgnoreCase(code, "gb")) return "en";
        if (std.ascii.eqlIgnoreCase(code, "gr")) return "el";
        if (std.ascii.eqlIgnoreCase(code, "sa")) return "ar";
        if (std.ascii.eqlIgnoreCase(code, "ua")) return "uk";
        if (std.ascii.eqlIgnoreCase(code, "jp")) return "ja";
        if (std.ascii.eqlIgnoreCase(code, "kr")) return "ko";
        if (std.ascii.eqlIgnoreCase(code, "cn")) return "zh";
        if (std.ascii.eqlIgnoreCase(code, "cz")) return "cs";
        if (std.ascii.eqlIgnoreCase(code, "dk")) return "da";
        return common.normalizeLanguageCode(code) orelse code;
    }
    if (raw) |name| return common.normalizeLanguageCode(name);
    return null;
}

fn extractReleaseVersion(anchor: HtmlNode, allocator: Allocator) !?[]const u8 {
    if (anchor.queryOne("strong")) |strong| {
        const text = try common.innerTextTrimmedOwned(allocator, strong);
        if (text.len > 0) return text;
    }

    if (anchor.parentNode()) |p1| {
        if (p1.parentNode()) |p2| {
            if (p2.queryOne("small")) |small| {
                const text = try common.innerTextTrimmedOwned(allocator, small);
                if (text.len > 0) return text;
            }
        }
    }

    return null;
}

fn parseRealUrlFromPage(allocator: Allocator, body: []const u8) !?[]const u8 {
    var search_start: usize = 0;
    return nextRealUrlFromPage(allocator, body, &search_start);
}

fn resolveRealUrlFromPage(allocator: Allocator, base_url: []const u8, body: []const u8) !?[]const u8 {
    var search_start: usize = 0;
    var saw_rejected_candidate = false;
    while (try nextRealUrlFromPage(allocator, body, &search_start)) |candidate| {
        const resolved = resolveProviderRoute(allocator, base_url, candidate, .download_file) catch |err| {
            allocator.free(candidate);
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    saw_rejected_candidate = true;
                    continue;
                },
            }
        };
        allocator.free(candidate);
        return resolved;
    }
    if (saw_rejected_candidate) return error.UnsafeHttpTarget;
    return null;
}

fn nextRealUrlFromPage(allocator: Allocator, body: []const u8, search_start: *usize) !?[]const u8 {
    const marker = "REAL_URL";
    while (std.mem.indexOfPos(u8, body, search_start.*, marker)) |marker_idx| {
        const after_marker_start = marker_idx + marker.len;
        // Marker text may be part of a valid quoted URL. Scan to its closing
        // quote, but retain a resume point before that quote: if the resolver
        // rejects an unterminated candidate closed by a later assignment, it
        // must still be able to inspect that later assignment.
        search_start.* = after_marker_start;
        const candidate = body[after_marker_start..];

        var cursor: usize = 0;
        while (cursor < candidate.len and std.ascii.isWhitespace(candidate[cursor])) : (cursor += 1) {}
        if (cursor >= candidate.len or candidate[cursor] != '=') continue;
        cursor += 1;
        while (cursor < candidate.len and std.ascii.isWhitespace(candidate[cursor])) : (cursor += 1) {}
        if (cursor >= candidate.len) continue;

        const quote = candidate[cursor];
        if (quote != '\'' and quote != '"') continue;
        cursor += 1;

        const start = cursor;
        while (cursor < candidate.len) : (cursor += 1) {
            if (candidate[cursor] == quote and !isJsStringByteEscaped(candidate, cursor)) {
                return try decodeJsStringLiteral(allocator, candidate[start..cursor]);
            }
        }
    }
    return null;
}

fn isJsStringByteEscaped(input: []const u8, index: usize) bool {
    var cursor = index;
    var escaped = false;
    while (cursor > 0 and input[cursor - 1] == '\\') {
        escaped = !escaped;
        cursor -= 1;
    }
    return escaped;
}

fn decodeJsStringLiteral(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const esc = input[i + 1];
            i += 1;
            try out.append(allocator, switch (esc) {
                '/' => '/',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\'' => '\'',
                '\\' => '\\',
                else => esc,
            });
            continue;
        }
        try out.append(allocator, input[i]);
    }

    return try out.toOwnedSlice(allocator);
}

fn looksArchive(url: []const u8) bool {
    return std.mem.endsWith(u8, url, ".zip") or
        std.mem.indexOf(u8, url, ".zip?") != null;
}

fn SubtitleFixture(comptime resolver_error: ?anyerror, comptime resolver_status: std.http.Status, comptime resolver_body: []const u8) type {
    return struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            try expectSecureFetchPolicy(options);
            if (std.mem.indexOf(u8, url, "/downloads/") != null) {
                if (resolver_error) |err| return err;
                return .{ .status = resolver_status, .body = try allocator.dupe(u8, resolver_body) };
            }
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<h1>The Matrix</h1><a href='/downloads/matrix'><strong>The.Matrix.1999.en</strong></a>") };
        }
    };
}

fn RejectedPageFixture(comptime status: std.http.Status) type {
    return struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            try expectSecureFetchPolicy(options);
            return .{ .status = status, .body = try allocator.dupe(u8, "<html><body>No results</body></html>") };
        }
    };
}

fn expectSecureFetchPolicy(options: common.FetchOptions) !void {
    try std.testing.expect(options.require_public_origin);
    try std.testing.expect(options.require_https);
    try std.testing.expect(options.require_same_origin);
}

test "my-subs trims queries and does not fetch empty searches" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try expectSecureFetchPolicy(options);
            try std.testing.expectEqualStrings(site ++ "/search.php?key=Matrix", url);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<html></html>") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);

    var empty = try scraper.searchWithOptionsUsing(Fixture.fetch, " \t\r\n ", .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    var trimmed = try scraper.searchWithOptionsUsing(Fixture.fetch, "  Matrix\t", .{});
    defer trimmed.deinit();
    try std.testing.expectEqual(@as(usize, 0), trimmed.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

fn checkSubtitleOwnership(allocator: Allocator) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(allocator, &client);
    var details_url = "https://my-subs.co/film-versions-matrix".*;
    var response = try scraper.fetchSubtitlesByDetailsLinkUsing(
        SubtitleFixture(null, .ok, "var REAL_URL='/files/matrix.zip';").fetch,
        &details_url,
        .movie,
        .{ .resolve_download_links = true },
    );
    defer response.deinit();
    @memset(&details_url, 'x');
    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    const subtitle = response.subtitles[0];
    try std.testing.expectEqualStrings("https://my-subs.co/film-versions-matrix", subtitle.details_url);
    try std.testing.expectEqualStrings("The.Matrix.1999.en", subtitle.release_version.?);
    try std.testing.expectEqualStrings("https://my-subs.co/files/matrix.zip", subtitle.resolved_download_url.?);
    try std.testing.expectEqual(@as(?bool, true), subtitle.is_archive);
}

const RootFetchOnceFixture = struct {
    client: std.http.Client,
    root_requests: usize = 0,
    season_requests: usize = 0,

    fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
        try expectSecureFetchPolicy(options);
        const self: *RootFetchOnceFixture = @fieldParentPtr("client", client);
        const body = if (std.mem.eql(u8, url, "https://my-subs.co/showlistsubtitles-matrix")) blk: {
            self.root_requests += 1;
            if (self.root_requests > 1) return error.TestUnexpectedDuplicateRequest;
            break :blk "<h1>The Matrix</h1><div id='saison'><a href='/versions-matrix-season-1-subtitles'>Season 1</a></div><a href='/downloads/root'>Root subtitle</a>";
        } else if (std.mem.eql(u8, url, "https://my-subs.co/versions-matrix-season-1-subtitles")) blk: {
            self.season_requests += 1;
            break :blk "<h1>The Matrix Season 1</h1><a href='/downloads/season'>Season subtitle</a>";
        } else return error.TestUnexpectedUrl;
        return .{ .status = .ok, .body = try allocator.dupe(u8, body) };
    }
};

test "my-subs fetches the root only once for movie and season results" {
    inline for (.{ MediaKind.movie, MediaKind.tv }) |media_kind| {
        var fixture: RootFetchOnceFixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        var details_url = "https://my-subs.co/showlistsubtitles-matrix".*;
        var response = try scraper.fetchSubtitlesByDetailsLinkUsing(RootFetchOnceFixture.fetch, &details_url, media_kind, .{});
        defer response.deinit();
        @memset(&details_url, 'x');
        const expected_seasons: usize = if (media_kind == .tv) 1 else 0;
        try std.testing.expectEqual(@as(usize, 1), fixture.root_requests);
        try std.testing.expectEqual(expected_seasons, fixture.season_requests);
        try std.testing.expectEqual(1 + expected_seasons, response.subtitles.len);
        try std.testing.expectEqualStrings("https://my-subs.co/showlistsubtitles-matrix", response.subtitles[0].details_url);
    }
}

test "my-subs bounds season page fanout before issuing season requests" {
    const Fixture = struct {
        client: std.http.Client,
        root_body: []const u8,
        root_requests: usize = 0,
        season_requests: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            try expectSecureFetchPolicy(options);
            const self: *@This() = @fieldParentPtr("client", client);
            if (std.mem.eql(u8, url, site ++ "/showlistsubtitles-fixture")) {
                self.root_requests += 1;
                return .{ .status = .ok, .body = try allocator.dupe(u8, self.root_body) };
            }
            self.season_requests += 1;
            return error.UnexpectedSeasonRequest;
        }
    };

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, "<div id='saison'>");
    for (0..max_season_page_requests + 1) |index| {
        try body.print(std.testing.allocator, "<a href='/versions-fixture-{d}-subtitles'>Season</a>", .{index + 1});
    }
    try body.appendSlice(std.testing.allocator, "</div>");

    var fixture: Fixture = .{
        .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
        .root_body = body.items,
    };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    try std.testing.expectError(error.ResponseTooLarge, scraper.fetchSubtitlesByDetailsLinkUsing(
        Fixture.fetch,
        site ++ "/showlistsubtitles-fixture",
        .tv,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 1), fixture.root_requests);
    try std.testing.expectEqual(@as(usize, 0), fixture.season_requests);
}

test "my-subs caps eager download resolution requests" {
    const Fixture = struct {
        client: std.http.Client,
        root_body: []const u8,
        root_requests: usize = 0,
        resolver_requests: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            try expectSecureFetchPolicy(options);
            const self: *@This() = @fieldParentPtr("client", client);
            if (std.mem.eql(u8, url, site ++ "/film-versions-fixture")) {
                self.root_requests += 1;
                return .{ .status = .ok, .body = try allocator.dupe(u8, self.root_body) };
            }
            if (std.mem.startsWith(u8, url, site ++ "/downloads/fixture-")) {
                self.resolver_requests += 1;
                return .{ .status = .ok, .body = try allocator.dupe(u8, "var REAL_URL='/files/fixture.zip';") };
            }
            return error.UnexpectedUrl;
        }
    };

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (0..max_download_resolution_requests + 1) |index| {
        try body.print(std.testing.allocator, "<a href='/downloads/fixture-{d}'>Subtitle</a>", .{index + 1});
    }

    var fixture: Fixture = .{
        .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
        .root_body = body.items,
    };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    try std.testing.expectError(error.ResponseTooLarge, scraper.fetchSubtitlesByDetailsLinkUsing(
        Fixture.fetch,
        site ++ "/film-versions-fixture",
        .movie,
        .{ .resolve_download_links = true },
    ));
    try std.testing.expectEqual(@as(usize, 1), fixture.root_requests);
    try std.testing.expectEqual(max_download_resolution_requests, fixture.resolver_requests);
}

test "my-subs owns caller details URL and propagates allocation failures" {
    try checkSubtitleOwnership(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSubtitleOwnership, .{});
}

test "my-subs rejects failed details pages and propagates resolver failures" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    const details_url = "https://my-subs.co/film-versions-matrix";
    inline for (.{ std.http.Status.forbidden, std.http.Status.internal_server_error, std.http.Status.service_unavailable }) |status| {
        try std.testing.expectError(error.UnexpectedHttpStatus, scraper.fetchSubtitlesByDetailsLinkUsing(
            RejectedPageFixture(status).fetch,
            details_url,
            .movie,
            .{},
        ));
        try std.testing.expectError(error.UnexpectedHttpStatus, scraper.fetchSubtitlesByDetailsLinkUsing(
            SubtitleFixture(null, status, "No results").fetch,
            details_url,
            .movie,
            .{ .resolve_download_links = true },
        ));
    }
    inline for (.{ error.Canceled, error.OutOfMemory, error.ProviderAccessBlocked }) |err| {
        try std.testing.expectError(err, scraper.fetchSubtitlesByDetailsLinkUsing(
            SubtitleFixture(err, .ok, "").fetch,
            details_url,
            .movie,
            .{ .resolve_download_links = true },
        ));
    }
    try std.testing.expectError(error.ProviderAccessBlocked, scraper.fetchSubtitlesByDetailsLinkUsing(
        SubtitleFixture(null, .ok, "Access to Website Disabled Federal Court of Australia").fetch,
        details_url,
        .movie,
        .{ .resolve_download_links = true },
    ));
    inline for ([_][]const u8{
        "<script src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script>",
        "\xef\xbb\xbf <!-- preface --><HTML><SCRIPT>window._cf_chl_opt = {};</SCRIPT></HTML>",
        "<!-- preface -->\n<HEAD><SCRIPT SRC='/CDN-CGI/CHALLENGE-PLATFORM/h/g/orchestrate/chl_page/v1'></SCRIPT></HEAD>",
        "<BODY><DIV CLASS='CF-CHL-WIDGET'></DIV></BODY>",
    }) |challenge_body| {
        try std.testing.expectError(error.CloudflareChallenge, scraper.fetchSubtitlesByDetailsLinkUsing(
            SubtitleFixture(null, .ok, challenge_body).fetch,
            details_url,
            .movie,
            .{ .resolve_download_links = true },
        ));
    }
}

test "my-subs parse REAL_URL" {
    const body = "var REAL_URL='\\/files\\/The.Matrix.1999.en.zip';";
    const parsed = (try parseRealUrlFromPage(std.testing.allocator, body)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(parsed);
    try std.testing.expect(std.mem.indexOf(u8, parsed, "files/") != null);

    const trailing_slash = (try parseRealUrlFromPage(std.testing.allocator, "var REAL_URL='value\\\\';")) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(trailing_slash);
    try std.testing.expectEqualStrings("value\\", trailing_slash);
}

test "my-subs skips malformed and unsafe REAL_URL candidates" {
    const body =
        "var REAL_URL='/files/unclosed.zip;" ++
        "var REAL_URL='https://www.google.com/files/decoy.zip';" ++
        "var REAL_URL='/downloads/not-a-file.zip';" ++
        "var REAL_URL='/files/matrix.zip';";
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    const resolved = try scraper.resolveDownloadPageUsing(
        SubtitleFixture(null, .ok, body).fetch,
        std.testing.allocator,
        site ++ "/downloads/matrix",
    );
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(site ++ "/files/matrix.zip", resolved);
}

test "my-subs archive classification matches the accepted download route" {
    try std.testing.expect(looksArchive("https://my-subs.co/files/archive.zip"));
    try std.testing.expect(looksArchive("https://my-subs.co/files/archive.zip?token=public"));
    try std.testing.expect(!looksArchive("https://my-subs.co/files/archive.rar"));
}

test "my-subs restricts every provider URL to its HTTPS route" {
    try validateProviderRoute("https://my-subs.co/search.php?key=matrix", .search);
    try validateProviderRoute("https://my-subs.co/film-versions-matrix", .details);
    try validateProviderRoute("https://my-subs.co/showlistsubtitles-matrix", .details);
    try validateProviderRoute("https://my-subs.co/versions-matrix-season-1-subtitles", .season);
    try validateProviderRoute("https://my-subs.co/downloads/matrix", .download_page);
    try validateProviderRoute("https://my-subs.co/files/matrix.zip?token=public", .download_file);

    const cases = [_]struct { url: []const u8, route: ProviderRoute }{
        .{ .url = "http://my-subs.co/film-versions-matrix", .route = .details },
        .{ .url = "https://user:pass@my-subs.co/film-versions-matrix", .route = .details },
        .{ .url = "https://www.google.com/film-versions-matrix", .route = .details },
        .{ .url = "https://my-subs.co/admin", .route = .details },
        .{ .url = "https://my-subs.co/search.php", .route = .search },
        .{ .url = "https://my-subs.co/search.php?key=matrix&next=/admin", .route = .search },
        .{ .url = "https://my-subs.co/film-versions-matrix?next=/admin", .route = .details },
        .{ .url = "https://my-subs.co/film-versions-matrix/admin", .route = .details },
        .{ .url = "https://my-subs.co/downloads/../admin", .route = .download_page },
        .{ .url = "https://my-subs.co/downloads/matrix/extra", .route = .download_page },
        .{ .url = "https://my-subs.co/downloads/matrix?next=/admin", .route = .download_page },
        .{ .url = "https://my-subs.co/downloads/%2e%2e/admin", .route = .download_page },
        .{ .url = "https://my-subs.co/files/archive.zip#ignored", .route = .download_file },
        .{ .url = "https://my-subs.co/downloads/not-a-file.zip", .route = .download_file },
        .{ .url = "https://my-subs.co/files/archive.rar", .route = .download_file },
    };
    for (cases) |case| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderRoute(case.url, case.route));
    }
}

test "my-subs rejects unsafe REAL_URL values" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    inline for (.{
        "var REAL_URL='http://my-subs.co/files/matrix.zip';",
        "var REAL_URL='https://www.google.com/files/matrix.zip';",
        "var REAL_URL='/downloads/matrix.zip';",
        "var REAL_URL='/files/../admin';",
    }) |body| {
        try std.testing.expectError(error.UnsafeHttpTarget, scraper.resolveDownloadPageUsing(
            SubtitleFixture(null, .ok, body).fetch,
            std.testing.allocator,
            "https://my-subs.co/downloads/matrix",
        ));
    }
}

test "my-subs flag language map" {
    try std.testing.expectEqualStrings("pt-br", languageFromFlag("br", null).?);
    try std.testing.expectEqualStrings("en", languageFromFlag("gb", null).?);
    try std.testing.expectEqualStrings("el", languageFromFlag("gr", null).?);
}

test "my-subs preserves REAL_URL inside valid literals and recovers malformed candidates" {
    const cases = .{
        .{ "var REAL_URL='/files/REAL_URL.zip';", "/files/REAL_URL.zip" },
        .{ "var REAL_URL='/files/movie.zip?label=REAL_URL';", "/files/movie.zip?label=REAL_URL" },
        .{ "var REAL_URL='/files/unclosed.zip;var REAL_URL='/files/REAL_URL.zip';", "/files/REAL_URL.zip" },
        .{ "var REAL_URL='/files/unclosed.zip;var REAL_URL=\"/files/movie.zip?label=REAL_URL\";", "/files/movie.zip?label=REAL_URL" },
        .{ "var REAL_URL='https://www.google.com/files/decoy.zip?label=REAL_URL';var REAL_URL='/files/REAL_URL.zip';", "/files/REAL_URL.zip" },
    };
    inline for (cases) |case| {
        const resolved = (try resolveRealUrlFromPage(std.testing.allocator, site ++ "/downloads/movie", case[0])) orelse return error.TestUnexpectedResult;
        defer std.testing.allocator.free(resolved);
        try std.testing.expectEqualStrings(site ++ case[1], resolved);
    }
}
