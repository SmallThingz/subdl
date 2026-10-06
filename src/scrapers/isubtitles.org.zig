const std = @import("std");
const common = @import("common.zig");
const cloudflare = @import("opensubtitles_com_cf.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

const Allocator = std.mem.Allocator;
const site = "https://isubtitles.org";

pub const SearchOptions = common.PageOptions;

pub const SubtitlesOptions = common.PageOptions;

pub const SearchItem = struct {
    title: []const u8,
    year: ?[]const u8,
    details_url: []const u8,
};

pub const SubtitleItem = struct {
    language_raw: ?[]const u8,
    language_code: ?[]const u8,
    release: ?[]const u8,
    created_at: ?[]const u8,
    file_count: ?[]const u8,
    size: ?[]const u8,
    comment: ?[]const u8,
    filename: []const u8,
    details_url: []const u8,
    download_page_url: []const u8,
};

pub const SearchResponse = common.PagedSearchResponse(SearchItem);

pub const SubtitlesResponse = common.PagedTitledSubtitlesResponse(SubtitleItem);

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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
        var page = if (options.page_start == 0) 1 else options.page_start;
        const page_start = page;
        var next_url: ?[]const u8 = null;
        var traversed: usize = 0;
        var last_page = page_start;
        var has_next_page = false;

        while (traversed < max_pages) : (traversed += 1) {
            last_page = page;
            const page_url = if (traversed == 0)
                try buildSearchUrl(a, query, page)
            else if (next_url) |u|
                u
            else
                break;
            const response = try self.fetchHtml(a, page_url);
            if (response.body.len == 0) break;

            maybeDebugDumpFirstPage(response.status, page_url, response.body, traversed);

            var parsed = try common.parseHtmlStable(a, response.body);

            const before_len = out.items.len;
            try collectSearchItemsFromSelector(a, &parsed.doc, ".movie-list-info h3 a[href*='-subtitles']", &seen, &out);
            if (out.items.len == before_len) {
                try collectSearchItemsFromSelector(a, &parsed.doc, "h3 a[href*='-subtitles']", &seen, &out);
            }
            if (out.items.len == before_len) {
                try collectSearchItemsFromSelector(a, &parsed.doc, "a[href*='-subtitles']", &seen, &out);
            }
            if (out.items.len == before_len) {
                try collectSearchItemsFromRawHtml(a, response.body, &seen, &out);
            }

            const extracted_next = try extractNextPageUrl(a, &parsed.doc, page_url);
            has_next_page = extracted_next != null;
            next_url = extracted_next;

            if (traversed + 1 >= max_pages) break;
            if (next_url == null) break;
            page += 1;
            if (page > 128) break;
        }

        return common.finishResponse(SearchResponse, &arena, .{
            .arena = arena,
            .items = try out.toOwnedSlice(a),
            .page = last_page,
            .has_prev_page = last_page > 1,
            .has_next_page = has_next_page,
        });
    }

    pub fn fetchSubtitlesByMovieLink(self: *Scraper, details_url: []const u8) !SubtitlesResponse {
        return self.fetchSubtitlesByMovieLinkWithOptions(details_url, .{});
    }

    pub fn fetchSubtitlesByMovieLinkWithOptions(self: *Scraper, details_url: []const u8, options: SubtitlesOptions) !SubtitlesResponse {
        return self.fetchSubtitlesByMovieLinkWithOptionsUsing(common.fetchBytes, details_url, options);
    }

    fn fetchSubtitlesByMovieLinkWithOptionsUsing(self: *Scraper, comptime fetch: anytype, details_url: []const u8, options: SubtitlesOptions) !SubtitlesResponse {
        try validateProviderUrl(details_url);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_details_url = try a.dupe(u8, details_url);

        var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        var title: []const u8 = "";

        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
        var page = if (options.page_start == 0) 1 else options.page_start;
        const page_start = page;
        var next_url: ?[]const u8 = null;
        var last_page = page_start;
        var has_next_page = false;

        var traversed: usize = 0;
        while (traversed < max_pages) : (traversed += 1) {
            last_page = page;
            const page_url = if (traversed == 0)
                (if (page == 1) owned_details_url else try addOrReplacePageQuery(a, owned_details_url, page))
            else if (next_url) |u|
                u
            else
                break;
            const response = try fetchHtmlWith(fetch, self.client, a, page_url);
            if (response.body.len == 0) break;

            var parsed = try common.parseHtmlStable(a, response.body);

            if (title.len == 0) {
                if (parsed.doc.queryOne("h1")) |h1| {
                    title = try common.innerTextTrimmedOwned(a, h1);
                } else if (parsed.doc.queryOne("title")) |t| {
                    title = try common.innerTextTrimmedOwned(a, t);
                }
            }

            var rows = parsed.doc.queryAll("section table.table tr");
            while (rows.next()) |row| {
                const download_anchor = row.queryOne("td[data-title='Download'] a[href]") orelse continue;
                const href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
                const download_page_url = try common.resolveUrl(a, site, href);
                if (!isProviderUrl(download_page_url)) continue;
                if (seen.contains(download_page_url)) continue;
                try seen.put(a, download_page_url, {});

                const fields = try extractSubtitleRowText(row, a);

                const filename = if (fields.release) |r| r else if (title.len > 0) title else "subtitle.srt";

                try out.append(a, .{
                    .language_raw = fields.language_raw,
                    .language_code = if (fields.language_raw) |lang| common.normalizeLanguageCode(lang) else null,
                    .release = fields.release,
                    .created_at = fields.created_at,
                    .file_count = fields.file_count,
                    .size = fields.size,
                    .comment = fields.comment,
                    .filename = filename,
                    .details_url = owned_details_url,
                    .download_page_url = download_page_url,
                });
            }

            next_url = try extractNextPageUrl(a, &parsed.doc, page_url);
            has_next_page = next_url != null;
            if (traversed + 1 >= max_pages) break;
            if (next_url == null) break;
            page += 1;
            if (page > 128) break;
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = title,
            .subtitles = try out.toOwnedSlice(a),
            .page = last_page,
            .has_prev_page = last_page > 1,
            .has_next_page = has_next_page,
        });
    }

    fn fetchHtml(self: *Scraper, allocator: Allocator, url: []const u8) !common.HttpResponse {
        return fetchHtmlWith(common.fetchBytes, self.client, allocator, url);
    }
};

fn fetchHtmlWith(comptime fetch: anytype, client: *std.http.Client, allocator: Allocator, url: []const u8) !common.HttpResponse {
    try validateProviderUrl(url);
    const headers = [_]std.http.Header{
        .{ .name = "accept-encoding", .value = "identity" },
        .{ .name = "accept-language", .value = "en-US,en;q=0.8" },
    };
    const response = try fetch(client, allocator, url, .{
        .accept = "text/html",
        .extra_headers = &headers,
        .cache = false,
        .max_attempts = 2,
        // The provider-level classification below owns 429 handling. A rate
        // limit must be terminal instead of becoming a delayed second request.
        .retry_on_429 = false,
        .allow_non_ok = true,
        .require_public_origin = true,
    });
    return acceptHtmlResponse(allocator, response);
}

fn acceptHtmlResponse(allocator: Allocator, response: common.HttpResponse) !common.HttpResponse {
    errdefer allocator.free(response.body);
    if (response.status == .too_many_requests) return error.RateLimited;
    if (common.isAustralianWebsiteBlockPage(response.body)) return error.ProviderAccessBlocked;
    if (cloudflare.isChallengeBody(response.body)) return error.CloudflareChallenge;
    if (response.status != .ok) return error.UnexpectedHttpStatus;
    return response;
}

fn validateProviderUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
}

fn isProviderUrl(url: []const u8) bool {
    validateProviderUrl(url) catch return false;
    return true;
}

fn collectSearchItemsFromSelector(
    allocator: Allocator,
    doc: *const HtmlDocument,
    comptime selector: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(SearchItem),
) !void {
    var anchors = doc.queryAll(selector);
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const details_url = try common.resolveUrl(allocator, site, href);
        if (!isProviderUrl(details_url)) continue;
        if (seen.contains(details_url)) continue;
        try seen.put(allocator, details_url, {});

        const raw_title = try common.innerTextTrimmedOwned(allocator, anchor);
        const split = splitTitleAndYear(raw_title);
        try out.append(allocator, .{
            .title = split.title,
            .year = split.year,
            .details_url = details_url,
        });
    }
}

fn collectSearchItemsFromRawHtml(
    allocator: Allocator,
    body: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(SearchItem),
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, "href=\"")) |href_marker| {
        const href_start = href_marker + "href=\"".len;
        const href_end = std.mem.indexOfScalarPos(u8, body, href_start, '"') orelse break;
        cursor = href_end + 1;

        const href = body[href_start..href_end];
        if (!std.mem.startsWith(u8, href, "/")) continue;
        if (!std.mem.endsWith(u8, href, "-subtitles")) continue;
        if (std.mem.indexOf(u8, href, "/gender/") != null) continue;
        if (std.mem.indexOf(u8, href, "/country/") != null) continue;
        if (std.mem.indexOf(u8, href, "/search") != null) continue;

        const tag_end = std.mem.indexOfScalarPos(u8, body, href_end, '>') orelse continue;
        const text_end = std.mem.indexOfPos(u8, body, tag_end + 1, "</a>") orelse continue;
        const raw_title = std.mem.trim(u8, body[tag_end + 1 .. text_end], " \t\r\n");
        if (raw_title.len == 0) continue;

        const details_url = try common.resolveUrl(allocator, site, href);
        if (!isProviderUrl(details_url)) continue;
        if (seen.contains(details_url)) continue;
        try seen.put(allocator, details_url, {});

        const split = splitTitleAndYear(raw_title);
        try out.append(allocator, .{
            .title = split.title,
            .year = split.year,
            .details_url = details_url,
        });
    }
}

fn textAt(node: HtmlNode, allocator: Allocator, comptime selector: []const u8) !?[]const u8 {
    const found = node.queryOne(selector) orelse return null;
    const text = try common.innerTextTrimmedOwned(allocator, found);
    if (text.len == 0) return null;
    return text;
}

const SubtitleRowText = struct {
    language_raw: ?[]const u8,
    release: ?[]const u8,
    created_at: ?[]const u8,
    file_count: ?[]const u8,
    size: ?[]const u8,
    comment: ?[]const u8,
};

fn extractSubtitleRowText(row: HtmlNode, allocator: Allocator) !SubtitleRowText {
    return .{
        .language_raw = try textAt(row, allocator, "td[data-title='Language'] a"),
        .release = try textAt(row, allocator, "td[data-title='Release / Movie'] a"),
        .created_at = try textAt(row, allocator, "td[data-title='Created']"),
        .file_count = try textAt(row, allocator, "td[data-title='File']"),
        .size = try textAt(row, allocator, "td[data-title='Size']"),
        .comment = try textAt(row, allocator, "td[data-title='Comment']"),
    };
}

fn buildSearchUrl(allocator: Allocator, query: []const u8, page: usize) ![]const u8 {
    const encoded = try common.encodeUriComponent(allocator, query);
    defer allocator.free(encoded);
    const form_query = try replaceEncodedSpaces(allocator, encoded);
    defer allocator.free(form_query);
    if (page <= 1) return std.fmt.allocPrint(allocator, "{s}/search?kwd={s}", .{ site, form_query });
    return std.fmt.allocPrint(allocator, "{s}/search?kwd={s}&p={d}", .{ site, form_query, page });
}

fn replaceEncodedSpaces(allocator: Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var index: usize = 0;
    while (index < encoded.len) {
        if (index + 3 <= encoded.len and std.ascii.eqlIgnoreCase(encoded[index .. index + 3], "%20")) {
            try out.append(allocator, '+');
            index += 3;
        } else {
            try out.append(allocator, encoded[index]);
            index += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn addOrReplacePageQuery(allocator: Allocator, base_url: []const u8, page: usize) ![]const u8 {
    const hash_idx = std.mem.indexOfScalar(u8, base_url, '#');
    const without_fragment = if (hash_idx) |idx| base_url[0..idx] else base_url;
    const fragment = if (hash_idx) |idx| base_url[idx..] else "";

    const question_idx = std.mem.indexOfScalar(u8, without_fragment, '?');
    if (question_idx == null) {
        return std.fmt.allocPrint(allocator, "{s}?p={d}{s}", .{ without_fragment, page, fragment });
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const q_idx = question_idx.?;
    const path = without_fragment[0 .. q_idx + 1];
    const query = without_fragment[q_idx + 1 ..];

    try out.appendSlice(allocator, path);

    var replaced = false;
    var wrote_any = false;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;

        const eq_idx = std.mem.indexOfScalar(u8, pair, '=');
        const key = if (eq_idx) |idx| pair[0..idx] else pair;
        const is_page_key = std.mem.eql(u8, key, "p") or std.mem.eql(u8, key, "page");

        if (wrote_any) try out.append(allocator, '&');
        wrote_any = true;

        if (is_page_key) {
            try out.print(allocator, "p={d}", .{page});
            replaced = true;
        } else {
            try out.appendSlice(allocator, pair);
        }
    }

    if (!replaced) {
        if (wrote_any) try out.append(allocator, '&');
        try out.print(allocator, "p={d}", .{page});
    }

    try out.appendSlice(allocator, fragment);
    return try out.toOwnedSlice(allocator);
}

fn extractNextPageUrl(allocator: Allocator, doc: *const HtmlDocument, current_url: []const u8) !?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const temp = scratch.allocator();

    const current_page = pageFromUrl(current_url) orelse 1;

    if (doc.queryOne("a[rel='next'][href]")) |a| {
        if (common.getAttributeValueSafe(a, "href")) |href| {
            const resolved = try common.resolveUrl(temp, site, href);
            if (isProviderUrl(resolved) and !std.mem.eql(u8, resolved, current_url))
                return try allocator.dupe(u8, resolved);
        }
    }

    var best_next_url: ?[]const u8 = null;
    var best_next_page: ?usize = null;

    var anchors = doc.queryAll("a[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const resolved = try common.resolveUrl(temp, site, href);
        if (!isProviderUrl(resolved)) continue;
        if (std.mem.eql(u8, resolved, current_url)) continue;

        if (pageFromUrl(resolved)) |candidate_page| {
            if (candidate_page > current_page) {
                if (best_next_page == null or candidate_page < best_next_page.?) {
                    best_next_page = candidate_page;
                    best_next_url = resolved;
                }
                continue;
            }
        }

        const text = try common.innerTextTrimmedOwned(temp, anchor);
        if (isLikelyNextText(text) and best_next_url == null) {
            best_next_url = resolved;
        }
    }

    if (best_next_url) |resolved| return try allocator.dupe(u8, resolved);
    return null;
}

fn maybeDebugDumpFirstPage(status: std.http.Status, page_url: []const u8, body: []const u8, traversed: usize) void {
    if (traversed != 0) return;
    if (common.getenv("SCRAPERS_DEBUG_ISUB") == null) return;

    std.debug.print("[isubtitles] status={d} body_len={d} url={s}\n", .{ @backingInt(status), body.len, page_url });
    if (status != .ok) std.debug.print("[isubtitles] response={s}\n", .{body[0..@min(body.len, 1200)]});
}

fn isLikelyNextText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.ascii.findIgnoreCase(text, "next") != null) return true;
    return std.mem.eql(u8, text, ">") or std.mem.eql(u8, text, "›") or std.mem.eql(u8, text, "»");
}

fn pageFromUrl(url: []const u8) ?usize {
    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var query = url[query_start + 1 ..];
    if (std.mem.indexOfScalar(u8, query, '#')) |hash_idx| {
        query = query[0..hash_idx];
    }

    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..eq_idx];
        if (!std.mem.eql(u8, key, "p") and !std.mem.eql(u8, key, "page")) continue;

        const value = field[eq_idx + 1 ..];
        if (value.len == 0) continue;
        return std.fmt.parseInt(usize, value, 10) catch continue;
    }

    return null;
}

fn splitTitleAndYear(raw_title: []const u8) struct { title: []const u8, year: ?[]const u8 } {
    const trimmed = std.mem.trim(u8, raw_title, " \t\r\n");
    if (trimmed.len < 7) return .{ .title = trimmed, .year = null };

    if (trimmed[trimmed.len - 1] != ')') return .{ .title = trimmed, .year = null };
    const open_idx = std.mem.lastIndexOfScalar(u8, trimmed, '(') orelse return .{ .title = trimmed, .year = null };
    if (open_idx + 5 != trimmed.len - 1) return .{ .title = trimmed, .year = null };

    const year = trimmed[open_idx + 1 .. trimmed.len - 1];
    for (year) |c| {
        if (c < '0' or c > '9') return .{ .title = trimmed, .year = null };
    }

    var title = std.mem.trim(u8, trimmed[0..open_idx], " \t\r\n");
    if (std.mem.endsWith(u8, title, "-")) {
        title = std.mem.trim(u8, title[0 .. title.len - 1], " \t\r\n");
    }

    return .{ .title = title, .year = year };
}

test "isubtitles split title/year" {
    const a = splitTitleAndYear("The Matrix  - (1999)");
    try std.testing.expectEqualStrings("The Matrix", a.title);
    try std.testing.expectEqualStrings("1999", a.year.?);

    const b = splitTitleAndYear("No Year Title");
    try std.testing.expectEqualStrings("No Year Title", b.title);
    try std.testing.expect(b.year == null);
}

test "isubtitles rejects non-provider navigation targets" {
    try validateProviderUrl("https://isubtitles.org/the-matrix-subtitles");
    for ([_][]const u8{
        "http://127.0.0.1/the-matrix-subtitles",
        "https://isubtitles.org.example/the-matrix-subtitles",
        "https://user@isubtitles.org/the-matrix-subtitles",
        "http://isubtitles.org/the-matrix-subtitles",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url));
    }
}

test "isubtitles subtitle response owns the caller details URL" {
    const Fixture = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            try std.testing.expectEqualStrings(site ++ "/the-matrix-subtitles", url);
            try std.testing.expect(!options.cache);
            return .{
                .status = .ok,
                .body = try allocator.dupe(
                    u8,
                    "<section><table class='table'><tr>" ++
                        "<td data-title='Language'><a>English</a></td>" ++
                        "<td data-title='Release / Movie'><a>The.Matrix.1999</a></td>" ++
                        "<td data-title='Download'><a href='/download/123'>Download</a></td>" ++
                        "</tr></table></section>",
                ),
            };
        }
    };

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var details_url = (site ++ "/the-matrix-subtitles").*;
    var response = try scraper.fetchSubtitlesByMovieLinkWithOptionsUsing(Fixture.fetch, &details_url, .{});
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    @memset(&details_url, 'x');
    try std.testing.expectEqualStrings(site ++ "/the-matrix-subtitles", response.subtitles[0].details_url);
}

fn HtmlResponseFixture(comptime status: std.http.Status, comptime body: []const u8) type {
    return struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) !common.HttpResponse {
            try std.testing.expect(!options.cache);
            return .{ .status = status, .body = try allocator.dupe(u8, body) };
        }
    };
}

fn HtmlErrorFixture(comptime fetch_error: anyerror) type {
    return struct {
        fn fetch(_: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            return fetch_error;
        }
    };
}

test "isubtitles classifies failed and deceptive HTML responses" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    const challenge = "<!doctype html><html><title>Just a moment...</title><script>window._cf_chl_opt = {};</script></html>";
    inline for (.{ std.http.Status.ok, std.http.Status.forbidden, std.http.Status.service_unavailable }) |status| {
        try std.testing.expectError(error.CloudflareChallenge, fetchHtmlWith(
            HtmlResponseFixture(status, challenge).fetch,
            &client,
            std.testing.allocator,
            site ++ "/search?kwd=matrix",
        ));
    }

    const access_block = "<h2>Access to Website Disabled</h2><p>The Federal Court of Australia has determined that this website infringes copyright.</p>";
    inline for (.{ std.http.Status.ok, std.http.Status.forbidden }) |status| {
        try std.testing.expectError(error.ProviderAccessBlocked, fetchHtmlWith(
            HtmlResponseFixture(status, access_block).fetch,
            &client,
            std.testing.allocator,
            site ++ "/search?kwd=matrix",
        ));
    }

    inline for (.{ std.http.Status.forbidden, std.http.Status.not_found, std.http.Status.internal_server_error }) |status| {
        try std.testing.expectError(error.UnexpectedHttpStatus, fetchHtmlWith(
            HtmlResponseFixture(status, "<html><body>ordinary error page</body></html>").fetch,
            &client,
            std.testing.allocator,
            site ++ "/search?kwd=matrix",
        ));
    }

    const accepted = try fetchHtmlWith(
        HtmlResponseFixture(.ok, "<html><body>ordinary provider page</body></html>").fetch,
        &client,
        std.testing.allocator,
        site ++ "/search?kwd=matrix",
    );
    defer std.testing.allocator.free(accepted.body);
    try std.testing.expectEqualStrings("<html><body>ordinary provider page</body></html>", accepted.body);
}

test "isubtitles rate limits are terminal after one request" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(!options.retry_on_429);
            return .{ .status = .too_many_requests, .body = try allocator.dupe(u8, "rate limited") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    try std.testing.expectError(error.RateLimited, fetchHtmlWith(
        Fixture.fetch,
        &fixture.client,
        std.testing.allocator,
        site ++ "/search?kwd=matrix",
    ));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "isubtitles preserves cancellation and allocation failures" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    inline for (.{ error.Canceled, error.OutOfMemory }) |fetch_error| {
        try std.testing.expectError(fetch_error, fetchHtmlWith(
            HtmlErrorFixture(fetch_error).fetch,
            &client,
            std.testing.allocator,
            site ++ "/search?kwd=matrix",
        ));
    }
}

test "isubtitles propagates subtitle row text allocation failure" {
    const source =
        \\<table><tr>
        \\  <td data-title="Language"><a>English</a></td>
        \\  <td data-title="Release / Movie"><a>The.Matrix.1999</a></td>
        \\</tr></table>
    ;
    var parsed = try common.parseHtmlStable(std.testing.allocator, source);
    defer parsed.deinit();
    const row = parsed.doc.queryOne("tr") orelse return error.TestUnexpectedResult;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, extractSubtitleRowText(row, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
}

test "isubtitles next-link text" {
    try std.testing.expect(isLikelyNextText("Next"));
    try std.testing.expect(isLikelyNextText(">"));
    try std.testing.expect(!isLikelyNextText("2"));
}

test "isubtitles build search url uses p query" {
    const a = std.testing.allocator;
    const page1 = try buildSearchUrl(a, "matrix", 1);
    defer a.free(page1);
    try std.testing.expectEqualStrings("https://isubtitles.org/search?kwd=matrix", page1);

    const page2 = try buildSearchUrl(a, "matrix", 2);
    defer a.free(page2);
    try std.testing.expectEqualStrings("https://isubtitles.org/search?kwd=matrix&p=2", page2);
}

test "isubtitles addOrReplacePageQuery supports p and page" {
    const a = std.testing.allocator;

    const first = try addOrReplacePageQuery(a, "https://isubtitles.org/search?kwd=matrix", 3);
    defer a.free(first);
    try std.testing.expectEqualStrings("https://isubtitles.org/search?kwd=matrix&p=3", first);

    const second = try addOrReplacePageQuery(a, "https://isubtitles.org/search?kwd=matrix&p=2", 4);
    defer a.free(second);
    try std.testing.expectEqualStrings("https://isubtitles.org/search?kwd=matrix&p=4", second);

    const third = try addOrReplacePageQuery(a, "https://isubtitles.org/search?kwd=matrix&page=2", 5);
    defer a.free(third);
    try std.testing.expectEqualStrings("https://isubtitles.org/search?kwd=matrix&p=5", third);
}

test "isubtitles extractNextPageUrl from numeric pager without next text" {
    const a = std.testing.allocator;
    const html_source =
        \\<div class="pageing-container">
        \\  <div class="paging">
        \\    <a href="javascript:;" class="current">1</a>
        \\    <a href="/search?kwd=matrix&p=2">2</a>
        \\  </div>
        \\</div>
    ;

    var parsed = try common.parseHtmlStable(a, html_source);
    defer parsed.deinit();

    const next = try extractNextPageUrl(a, &parsed.doc, "https://isubtitles.org/search?kwd=matrix");
    try std.testing.expect(next != null);
    defer a.free(next.?);
    try std.testing.expectEqualStrings("https://isubtitles.org/search?kwd=matrix&p=2", next.?);
}

test "isubtitles extractNextPageUrl prefers nearest greater numeric page" {
    const a = std.testing.allocator;
    const html_source =
        \\<div class="paging">
        \\  <a href="/search?kwd=matrix&p=1">1</a>
        \\  <a href="/search?kwd=matrix&p=2" class="current">2</a>
        \\  <a href="/search?kwd=matrix&p=3">3</a>
        \\  <a href="/search?kwd=matrix&p=10">10</a>
        \\</div>
    ;

    var parsed = try common.parseHtmlStable(a, html_source);
    defer parsed.deinit();

    const next = try extractNextPageUrl(a, &parsed.doc, "https://isubtitles.org/search?kwd=matrix&p=2");
    try std.testing.expect(next != null);
    defer a.free(next.?);
    try std.testing.expectEqualStrings("https://isubtitles.org/search?kwd=matrix&p=3", next.?);
}
