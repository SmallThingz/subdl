const std = @import("std");
const common = @import("common.zig");
const cf_shared = @import("opensubtitles_com_cf.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

const Allocator = std.mem.Allocator;
const site = "https://www.opensubtitles.org";
const default_page_size: usize = 40;

pub const SearchOptions = common.PageOptions;

pub const SubtitlesOptions = common.PageOptions;

pub const SearchItem = common.SearchLink;

pub const SubtitleItem = struct {
    language_code: ?[]const u8,
    filename: ?[]const u8,
    release: ?[]const u8,
    fps: ?[]const u8,
    cds: ?[]const u8,
    rating: ?[]const u8,
    downloads: ?[]const u8,
    uploaded_at: ?[]const u8,
    hearing_impaired: bool,
    trusted: bool,
    hd: bool,
    details_url: []const u8,
    direct_zip_url: []const u8,
};

pub const SearchResponse = common.PagedSearchResponse(SearchItem);

pub const SubtitlesResponse = common.PagedTitledSubtitlesResponse(SubtitleItem);

pub const Scraper = struct {
    pub const Options = struct {
        language_code: []const u8 = "all",
    };

    allocator: Allocator,
    client: *std.http.Client,
    options: Options,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client, .options = .{} };
    }

    pub fn initWithOptions(allocator: Allocator, client: *std.http.Client, options: Options) Scraper {
        return .{ .allocator = allocator, .client = client, .options = options };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchWithOptions(query, .{});
    }

    pub fn searchWithOptions(self: *Scraper, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const encoded = try common.encodeUriComponent(a, query);
        const language3 = languageToOpenSubtitles3(self.options.language_code) orelse "all";
        const base_url = try std.fmt.allocPrint(a, "{s}/en/search2/moviename-{s}/sublanguageid-{s}", .{ site, encoded, language3 });
        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
        const page_start = if (options.page_start == 0) 1 else options.page_start;
        var page = page_start;
        var traversed: usize = 0;
        var next_url: ?[]const u8 = if (page_start > 1) try addOrReplaceOffsetPage(a, base_url, page_start) else null;
        var last_page = page_start;
        var has_next_page = false;
        var items: std.ArrayListUnmanaged(SearchItem) = .empty;

        while (traversed < max_pages) : (traversed += 1) {
            last_page = page;
            const page_url = if (next_url) |u| u else if (page == 1) base_url else try addOrReplaceOffsetPage(a, base_url, page);
            const response = try self.fetchHtml(a, page_url);
            var parsed = try common.parseHtmlStable(a, response.body);

            var anchors = parsed.doc.queryAll("table#search_results td[id^='main'] strong a.bnone[href*='/search/'][href*='idmovie-']");
            while (anchors.next()) |anchor| {
                const href = anchor.getAttributeValue("href") orelse continue;
                const title = try common.innerTextTrimmedOwned(a, anchor);
                const movie_page_url = try resolveProviderUrl(a, href);
                try items.append(a, .{ .title = title, .page_url = movie_page_url });
            }

            if (items.items.len == 0) {
                const has_subtitle_rows = parsed.doc.queryOne("table#search_results a[href*='/subtitleserve/sub/']") != null;
                if (has_subtitle_rows) {
                    const inferred_title = blk: {
                        if (parsed.doc.queryOne("h1")) |n| break :blk try common.innerTextTrimmedOwned(a, n);
                        break :blk try a.dupe(u8, query);
                    };
                    try items.append(a, .{ .title = inferred_title, .page_url = try a.dupe(u8, page_url) });
                }
            }

            next_url = try extractNextPageUrl(a, &parsed.doc, page_url);
            has_next_page = next_url != null;
            page += 1;
            if (next_url == null) break;
        }

        return common.finishResponse(SearchResponse, &arena, .{
            .arena = arena,
            .items = try dedupeSearchItems(a, items.items),
            .page = last_page,
            .has_prev_page = last_page > 1,
            .has_next_page = has_next_page,
        });
    }

    pub fn fetchSubtitlesByMoviePage(self: *Scraper, page_url: []const u8) !SubtitlesResponse {
        return self.fetchSubtitlesByMoviePageWithOptions(page_url, .{});
    }

    pub fn fetchSubtitlesByMoviePageWithOptions(self: *Scraper, page_url: []const u8, options: SubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
        const page_start = if (options.page_start == 0) 1 else options.page_start;
        var page = page_start;
        var traversed: usize = 0;
        var next_url: ?[]const u8 = if (page_start > 1) try addOrReplaceOffsetPage(a, page_url, page_start) else null;
        var last_page = page_start;
        var has_next_page = false;
        var title: []const u8 = "";
        var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen_details = std.StringHashMapUnmanaged(void).empty;

        while (traversed < max_pages) : (traversed += 1) {
            last_page = page;
            const url = if (next_url) |u| u else if (page == 1) page_url else try addOrReplaceOffsetPage(a, page_url, page);
            const response = try self.fetchHtml(a, url);
            var parsed = try common.parseHtmlStable(a, response.body);

            if (title.len == 0) {
                title = blk: {
                    if (parsed.doc.queryOne("h1")) |n| break :blk try common.innerTextTrimmedOwned(a, n);
                    if (parsed.doc.queryOne("title")) |n| break :blk try common.innerTextTrimmedOwned(a, n);
                    break :blk "";
                };
            }

            const before_rows = out.items.len;
            var rows = parsed.doc.queryAll("table#search_results tr[id^='name']");
            while (rows.next()) |row| {
                try appendSubtitleFromRow(a, row, &seen_details, &out);
            }
            if (out.items.len == before_rows) {
                var fallback_rows = parsed.doc.queryAll("table#search_results tr.change");
                while (fallback_rows.next()) |row| {
                    try appendSubtitleFromRow(a, row, &seen_details, &out);
                }
            }

            next_url = try extractNextPageUrl(a, &parsed.doc, url);
            has_next_page = next_url != null;
            page += 1;
            if (next_url == null) break;
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
        try validateProviderEndpoint(url);
        return fetchHtmlWith(common.fetchBytes, self.client, allocator, url);
    }
};

fn fetchHtmlWith(comptime fetch: anytype, client: *std.http.Client, allocator: Allocator, url: []const u8) !common.HttpResponse {
    const response = try fetch(client, allocator, url, .{
        .accept = "text/html",
        .cache = false,
        .allow_non_ok = true,
        .max_attempts = 2,
        .retry_on_429 = false,
        .require_public_origin = true,
    });
    errdefer allocator.free(response.body);
    if (common.isAustralianWebsiteBlockPage(response.body)) return error.ProviderAccessBlocked;
    if (response.status == .too_many_requests) return error.RateLimited;
    if (cf_shared.isChallengeBody(response.body)) return error.CloudflareChallenge;
    if (response.status != .ok) return error.UnexpectedHttpStatus;
    return response;
}

fn dedupeSearchItems(allocator: Allocator, items: []const SearchItem) ![]const SearchItem {
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);

    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    errdefer out.deinit(allocator);

    for (items) |item| {
        if (seen.contains(item.page_url)) continue;
        try seen.put(allocator, item.page_url, {});
        try out.append(allocator, item);
    }

    return try out.toOwnedSlice(allocator);
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

fn addOrReplaceOffsetPage(allocator: Allocator, base_url: []const u8, page: usize) ![]const u8 {
    const offset: usize = if (page <= 1) 0 else (page - 1) * default_page_size;
    var normalized = base_url;

    if (std.mem.indexOf(u8, normalized, "/offset-")) |idx| {
        var end = idx + "/offset-".len;
        while (end < normalized.len and std.ascii.isDigit(normalized[end])) : (end += 1) {}

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, normalized[0..idx]);
        try out.appendSlice(allocator, normalized[end..]);
        normalized = try out.toOwnedSlice(allocator);
    }

    if (offset == 0) return try allocator.dupe(u8, normalized);

    const suffix_pos = std.mem.indexOfAny(u8, normalized, "?#") orelse normalized.len;
    const head = normalized[0..suffix_pos];
    const tail = normalized[suffix_pos..];
    const sep: []const u8 = if (head.len > 0 and head[head.len - 1] == '/') "" else "/";
    return try std.fmt.allocPrint(allocator, "{s}{s}offset-{d}{s}", .{ head, sep, offset, tail });
}

fn extractNextPageUrl(allocator: Allocator, doc: *HtmlDocument, current_url: []const u8) !?[]const u8 {
    if (doc.queryOne("link[rel='next'][href]")) |n| {
        if (n.getAttributeValue("href")) |href| {
            const resolved = try resolveProviderUrl(allocator, href);
            if (!std.mem.eql(u8, resolved, current_url)) return resolved;
        }
    }

    if (doc.queryOne("#pager a[href*='/offset-']")) |anchor| {
        const href = anchor.getAttributeValue("href") orelse return null;
        const text = try common.innerTextTrimmedOwned(allocator, anchor);
        if (std.mem.eql(u8, text, ">>") or std.mem.eql(u8, text, "›") or std.mem.eql(u8, text, ">")) {
            const resolved = try resolveProviderUrl(allocator, href);
            if (!std.mem.eql(u8, resolved, current_url)) return resolved;
        }
    }

    return null;
}

fn extractFlagLanguage(row: HtmlNode, allocator: Allocator) !?[]const u8 {
    const flag_div = row.queryOne("td:nth-child(2) div[class*='flag']") orelse return null;
    const class = flag_div.getAttributeValue("class") orelse return null;
    var it = std.mem.tokenizeScalar(u8, class, ' ');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "flag")) continue;
        return try allocator.dupe(u8, part);
    }
    return null;
}

fn extractFilename(row: HtmlNode, allocator: Allocator) !?[]const u8 {
    const main = row.queryOne("td[id^='main']") orelse return null;
    if (main.queryOne("span[title]")) |n| {
        if (n.getAttributeValue("title")) |title| {
            if (title.len > 0) return try allocator.dupe(u8, title);
        }
    }
    if (main.queryOne("strong a.bnone")) |n| {
        const text = try common.innerTextTrimmedOwned(allocator, n);
        if (text.len > 0) return text;
    }
    return null;
}

fn extractSubCellText(row: HtmlNode, allocator: Allocator, cell_idx_one_based: usize) !?[]const u8 {
    var cells = row.queryAll("td");
    var idx: usize = 1;
    while (cells.next()) |cell| : (idx += 1) {
        if (idx != cell_idx_one_based) continue;
        const text = try common.innerTextTrimmedOwned(allocator, cell);
        if (text.len == 0) return null;
        return text;
    }
    return null;
}

fn appendSubtitleFromRow(
    allocator: Allocator,
    row: HtmlNode,
    seen_details: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(SubtitleItem),
) !void {
    const subtitle_anchor = row.queryOne("td[id^='main'] strong a.bnone[href*='/subtitles/']") orelse
        row.queryOne("a.bnone[href*='/subtitles/']") orelse
        row.queryOne("a[href*='/subtitles/']") orelse return;
    const details_href = subtitle_anchor.getAttributeValue("href") orelse return;
    const details_url = try resolveProviderUrl(allocator, details_href);
    if (seen_details.contains(details_url)) return;
    try seen_details.put(allocator, details_url, {});

    const subtitle_id = blk_id: {
        const serve_anchor = row.queryOne("a[href*='/subtitleserve/sub/']") orelse break :blk_id null;
        const href = serve_anchor.getAttributeValue("href") orelse break :blk_id null;
        const marker = "/subtitleserve/sub/";
        const start = std.mem.indexOf(u8, href, marker) orelse break :blk_id null;
        const tail = href[start + marker.len ..];
        const end = std.mem.indexOfAny(u8, tail, "/?#") orelse tail.len;
        break :blk_id tail[0..end];
    };
    const direct_zip_url = if (subtitle_id) |sid|
        try std.fmt.allocPrint(allocator, "https://dl.opensubtitles.org/en/download/sub/{s}", .{sid})
    else
        "";

    const language_code = try extractFlagLanguage(row, allocator);
    const filename = try extractFilename(row, allocator);
    const release = try extractSubCellText(row, allocator, 1);
    const fps = try extractSubCellText(row, allocator, 5);
    const cds = try extractSubCellText(row, allocator, 4);
    const rating = try extractSubCellText(row, allocator, 8);
    const downloads = try extractSubCellText(row, allocator, 7);
    const uploaded_at = try extractSubCellText(row, allocator, 6);

    const row_text = try common.innerTextTrimmedOwned(allocator, row);
    const lower_row = try lowerDup(allocator, row_text);

    try out.append(allocator, .{
        .language_code = language_code,
        .filename = filename,
        .release = release,
        .fps = fps,
        .cds = cds,
        .rating = rating,
        .downloads = downloads,
        .uploaded_at = uploaded_at,
        .hearing_impaired = std.mem.indexOf(u8, lower_row, "hearing") != null,
        .trusted = std.mem.indexOf(u8, lower_row, "trusted") != null,
        .hd = std.mem.indexOf(u8, lower_row, "hd") != null,
        .details_url = details_url,
        .direct_zip_url = direct_zip_url,
    });
}

fn lowerDup(allocator: Allocator, input: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, input);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn languageToOpenSubtitles3(code: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(code, "en")) return "eng";
    if (std.ascii.eqlIgnoreCase(code, "es")) return "spa";
    if (std.ascii.eqlIgnoreCase(code, "fr")) return "fre";
    if (std.ascii.eqlIgnoreCase(code, "de")) return "ger";
    if (std.ascii.eqlIgnoreCase(code, "it")) return "ita";
    if (std.ascii.eqlIgnoreCase(code, "pt")) return "por";
    if (std.ascii.eqlIgnoreCase(code, "pt-br")) return "pob";
    if (std.ascii.eqlIgnoreCase(code, "tr")) return "tur";
    if (std.ascii.eqlIgnoreCase(code, "ar")) return "ara";
    if (std.ascii.eqlIgnoreCase(code, "ru")) return "rus";
    if (std.ascii.eqlIgnoreCase(code, "pl")) return "pol";
    if (std.ascii.eqlIgnoreCase(code, "nl")) return "dut";
    if (std.ascii.eqlIgnoreCase(code, "sv")) return "swe";
    if (std.ascii.eqlIgnoreCase(code, "fi")) return "fin";
    if (std.ascii.eqlIgnoreCase(code, "zh")) return "chi";
    if (std.ascii.eqlIgnoreCase(code, "zh-tw")) return "zht";
    return null;
}

test "opensubtitles language mapping" {
    try std.testing.expectEqualStrings("eng", languageToOpenSubtitles3("en").?);
    try std.testing.expect(languageToOpenSubtitles3("xx") == null);
}

test "opensubtitles optional row metadata preserves allocation failures" {
    const source =
        \\<table><tr>
        \\  <td id="main1"><span title="Movie.srt">Release</span></td>
        \\  <td><div class="flag en"></div></td>
        \\</tr></table>
    ;
    var parsed = try common.parseHtmlStable(std.testing.allocator, source);
    defer parsed.deinit();
    const row = parsed.doc.queryOne("tr") orelse return error.TestUnexpectedResult;

    var failing_language = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, extractFlagLanguage(row, failing_language.allocator()));
    try std.testing.expect(failing_language.has_induced_failure);

    var failing_filename = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, extractFilename(row, failing_filename.allocator()));
    try std.testing.expect(failing_filename.has_induced_failure);

    var failing_cell = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, extractSubCellText(row, failing_cell.allocator(), 1));
    try std.testing.expect(failing_cell.has_induced_failure);
}

test "opensubtitles.org rejects unsafe provider links before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/search/idmovie-1"));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@www.opensubtitles.org/search/idmovie-1"));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://www.google.com/search/idmovie-1"));
}

const OwnedHtmlFixture = struct {
    fn fetch(_: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
        try std.testing.expect(!options.cache);
        const body = if (std.mem.endsWith(u8, url, "/blocked"))
            "Access to Website Disabled Federal Court of Australia"
        else
            "<html><body>ordinary provider page</body></html>";
        return .{ .status = .ok, .body = try allocator.dupe(u8, body) };
    }
};

fn checkHtmlOwnership(allocator: Allocator) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();
    for (0..4) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const response = try fetchHtmlWith(OwnedHtmlFixture.fetch, &client, arena.allocator(), "https://fixture.invalid/page");
        try std.testing.expectEqualStrings("<html><body>ordinary provider page</body></html>", response.body);
    }
    try checkBlockedHtml(&client, allocator, "https://fixture.invalid/blocked");
}

fn checkBlockedHtml(client: *std.http.Client, allocator: Allocator, url: []const u8) !void {
    const rejected = fetchHtmlWith(OwnedHtmlFixture.fetch, client, allocator, url) catch |err| switch (err) {
        error.ProviderAccessBlocked => return,
        else => return err,
    };
    allocator.free(rejected.body);
    return error.TestUnexpectedResult;
}

test "opensubtitles html bodies belong to caller and free on rejection" {
    try checkHtmlOwnership(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkHtmlOwnership, .{});
}

test "opensubtitles.org never downgrades failed HTTPS diagnostics" {
    const Mock = struct {
        var calls: usize = 0;

        fn fetch(_: *std.http.Client, _: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            calls += 1;
            try std.testing.expect(std.mem.startsWith(u8, url, "https://"));
            try std.testing.expect(options.require_public_origin);
            return error.ConnectionRefused;
        }
    };

    Mock.calls = 0;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(error.ConnectionRefused, fetchHtmlWith(
        Mock.fetch,
        &client,
        std.testing.allocator,
        "https://www.opensubtitles.org/search/sublanguageid-all/idmovie-1?q=private",
    ));
    try std.testing.expectEqual(@as(usize, 1), Mock.calls);
}

fn HtmlStatusFixture(comptime status: std.http.Status, comptime body: []const u8) type {
    return struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            try std.testing.expect(!options.cache);
            try std.testing.expect(!options.retry_on_429);
            return .{ .status = status, .body = try allocator.dupe(u8, body) };
        }
    };
}

test "opensubtitles rejects non-ok HTML and frees rejected bodies" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    inline for (.{ std.http.Status.forbidden, std.http.Status.not_found, std.http.Status.internal_server_error, std.http.Status.service_unavailable, std.http.Status.moved_permanently }) |status| {
        try std.testing.expectError(error.UnexpectedHttpStatus, fetchHtmlWith(
            HtmlStatusFixture(status, "<html><body>No results</body></html>").fetch,
            &client,
            std.testing.allocator,
            "https://fixture.invalid/page",
        ));
    }
    try std.testing.expectError(error.RateLimited, fetchHtmlWith(
        HtmlStatusFixture(.too_many_requests, "<html><body>Try again later</body></html>").fetch,
        &client,
        std.testing.allocator,
        "https://fixture.invalid/page",
    ));
    try std.testing.expectError(error.ProviderAccessBlocked, fetchHtmlWith(
        HtmlStatusFixture(.forbidden, "Access to Website Disabled Federal Court of Australia").fetch,
        &client,
        std.testing.allocator,
        "https://fixture.invalid/page",
    ));
    const challenge = "<html><script>window._cf_chl_opt = {};</script></html>";
    inline for (.{ std.http.Status.ok, std.http.Status.forbidden }) |status| {
        try std.testing.expectError(error.CloudflareChallenge, fetchHtmlWith(
            HtmlStatusFixture(status, challenge).fetch,
            &client,
            std.testing.allocator,
            "https://fixture.invalid/page",
        ));
    }
}

test "live opensubtitles.org search and subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "OPENSUBTITLES_ORG")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    const item = search.items[0];
    std.debug.print("[live][opensubtitles.org][search][0]\n", .{});
    try common.livePrintField(std.testing.allocator, "title", item.title);
    try common.livePrintField(std.testing.allocator, "page_url", item.page_url);

    var subtitles = try scraper.fetchSubtitlesByMoviePage(item.page_url);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    try common.livePrintField(std.testing.allocator, "subtitles_title", subtitles.title);
    const sub = subtitles.subtitles[0];
    std.debug.print("[live][opensubtitles.org][subtitle][0]\n", .{});
    try common.livePrintOptionalField(std.testing.allocator, "language_code", sub.language_code);
    try common.livePrintOptionalField(std.testing.allocator, "filename", sub.filename);
    try common.livePrintOptionalField(std.testing.allocator, "release", sub.release);
    try common.livePrintOptionalField(std.testing.allocator, "fps", sub.fps);
    try common.livePrintOptionalField(std.testing.allocator, "cds", sub.cds);
    try common.livePrintOptionalField(std.testing.allocator, "rating", sub.rating);
    try common.livePrintOptionalField(std.testing.allocator, "downloads", sub.downloads);
    try common.livePrintOptionalField(std.testing.allocator, "uploaded_at", sub.uploaded_at);
    std.debug.print("[live] hearing_impaired={any}\n", .{sub.hearing_impaired});
    std.debug.print("[live] trusted={any}\n", .{sub.trusted});
    std.debug.print("[live] hd={any}\n", .{sub.hd});
    try common.livePrintField(std.testing.allocator, "details_url", sub.details_url);
    try common.livePrintField(std.testing.allocator, "direct_zip_url", sub.direct_zip_url);
}
