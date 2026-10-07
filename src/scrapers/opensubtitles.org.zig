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
        return self.searchWithOptionsUsing(common.fetchBytes, query, options);
    }

    fn searchWithOptionsUsing(self: *Scraper, comptime fetch: anytype, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
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
            const response = try self.fetchHtmlUsing(fetch, a, page_url);
            var parsed = try common.parseHtmlStable(a, response.body);

            const before_page_items = items.items.len;
            var anchors = parsed.doc.queryAll("table#search_results td[id^='main'] strong a.bnone[href*='/search/'][href*='idmovie-']");
            while (anchors.next()) |anchor| {
                const href = anchor.getAttributeValue("href") orelse continue;
                const title = try common.innerTextTrimmedOwned(a, anchor);
                const movie_page_url = resolveProviderUrl(a, href, .results_page) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => continue,
                };
                try items.append(a, .{ .title = title, .page_url = movie_page_url });
            }

            if (items.items.len == before_page_items) {
                const has_subtitle_rows = parsed.doc.queryOne("table#search_results a[href*='/subtitleserve/sub/']") != null;
                if (has_subtitle_rows) {
                    const inferred_title = blk: {
                        if (parsed.doc.queryOne("h1")) |n| break :blk try common.innerTextTrimmedOwned(a, n);
                        break :blk try a.dupe(u8, trimmed);
                    };
                    try items.append(a, .{ .title = inferred_title, .page_url = try a.dupe(u8, page_url) });
                }
            }

            next_url = try extractNextPageUrl(a, &parsed.doc, page_url);
            has_next_page = next_url != null;
            if (next_url == null or traversed + 1 >= max_pages) break;
            page = try checkedNextPage(page);
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
        var seen_subtitle_ids = std.StringHashMapUnmanaged(void).empty;

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
                try appendSubtitleFromRow(a, row, &seen_subtitle_ids, &out);
            }
            if (out.items.len == before_rows) {
                var fallback_rows = parsed.doc.queryAll("table#search_results tr.change");
                while (fallback_rows.next()) |row| {
                    try appendSubtitleFromRow(a, row, &seen_subtitle_ids, &out);
                }
            }

            next_url = try extractNextPageUrl(a, &parsed.doc, url);
            has_next_page = next_url != null;
            if (next_url == null or traversed + 1 >= max_pages) break;
            page = try checkedNextPage(page);
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
        return self.fetchHtmlUsing(common.fetchBytes, allocator, url);
    }

    fn fetchHtmlUsing(self: *Scraper, comptime fetch: anytype, allocator: Allocator, url: []const u8) !common.HttpResponse {
        try validateProviderRoute(url, .results_page);
        return fetchHtmlWith(fetch, self.client, allocator, url);
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
        .require_https = true,
        .require_same_origin = true,
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

const ProviderRoute = enum { results_page, subtitle_details, subtitle_serve };

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderRoute(resolved, route);
    return resolved;
}

fn validateProviderRoute(url: []const u8, route: ProviderRoute) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.fragment != null or std.mem.indexOfScalar(u8, url, '?') != null) return error.UnsafeHttpTarget;
    var path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (path.len < 2 or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, '\\') != null)
    {
        return error.UnsafeHttpTarget;
    }

    var parts: [12][]const u8 = undefined;
    const part_count = splitProviderPath(path, &parts) orelse return error.UnsafeHttpTarget;
    if (part_count < 2 or !isProviderLocale(parts[0])) return error.UnsafeHttpTarget;

    const valid = switch (route) {
        .results_page => validateResultsPath(parts[0..part_count]),
        .subtitle_details => part_count >= 3 and part_count <= 4 and
            std.mem.eql(u8, parts[1], "subtitles") and
            isCanonicalPositiveDecimal(parts[2]) and
            (part_count == 3 or isSafeRouteSlug(parts[3])),
        .subtitle_serve => part_count == 4 and
            std.mem.eql(u8, parts[1], "subtitleserve") and
            std.mem.eql(u8, parts[2], "sub") and
            isCanonicalPositiveDecimal(parts[3]),
    };
    if (!valid) return error.UnsafeHttpTarget;
}

fn splitProviderPath(path: []const u8, out: *[12][]const u8) ?usize {
    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or count == out.len or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return null;
        out[count] = segment;
        count += 1;
    }
    return count;
}

fn validateResultsPath(parts: []const []const u8) bool {
    if (parts.len < 3) return false;
    const is_search = std.mem.eql(u8, parts[1], "search");
    const is_search2 = std.mem.eql(u8, parts[1], "search2");
    if (!is_search and !is_search2) return false;

    var found_primary = false;
    var found_language = false;
    var found_offset = false;
    for (parts[2..]) |segment| {
        if (stripPrefix(segment, "moviename-")) |value| {
            if (!is_search2 or found_primary or !isSafeRouteValue(value)) return false;
            found_primary = true;
        } else if (stripPrefix(segment, "idmovie-")) |value| {
            if (!is_search or found_primary or !isCanonicalPositiveDecimal(value)) return false;
            found_primary = true;
        } else if (stripPrefix(segment, "sublanguageid-")) |value| {
            if (found_language or !isSubtitleLanguageList(value)) return false;
            found_language = true;
        } else if (stripPrefix(segment, "offset-")) |value| {
            if (found_offset or !isCanonicalNonNegativeDecimal(value)) return false;
            found_offset = true;
        } else {
            return false;
        }
    }
    return found_primary;
}

fn stripPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

fn isCanonicalPositiveDecimal(value: []const u8) bool {
    if (value.len == 0 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isCanonicalNonNegativeDecimal(value: []const u8) bool {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isProviderLocale(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, '-');
    const language = parts.next() orelse return false;
    if (language.len < 2 or language.len > 3) return false;
    for (language) |c| if (c < 'a' or c > 'z') return false;
    if (parts.next()) |region| {
        if (region.len < 2 or region.len > 4 or parts.next() != null) return false;
        for (region) |c| if (c < 'a' or c > 'z') return false;
    }
    return true;
}

fn isSafeRouteValue(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '+') continue;
        if (c != '%' or value.len - i < 3 or !isHex(value[i + 1]) or !isHex(value[i + 2])) return false;
        i += 2;
    }
    return true;
}

fn isSafeRouteSlug(value: []const u8) bool {
    return !isDotRouteSegment(value) and isSafeRouteValue(value) and
        std.ascii.findIgnoreCase(value, "%2f") == null and
        std.ascii.findIgnoreCase(value, "%5c") == null;
}

fn isDotRouteSegment(value: []const u8) bool {
    var dots: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '.') {
            dots += 1;
            i += 1;
            continue;
        }
        if (value.len - i >= 3 and value[i] == '%' and value[i + 1] == '2' and std.ascii.toLower(value[i + 2]) == 'e') {
            dots += 1;
            i += 3;
            continue;
        }
        return false;
    }
    return dots == 1 or dots == 2;
}

fn isHex(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isSubtitleLanguageList(value: []const u8) bool {
    var languages = std.mem.splitScalar(u8, value, ',');
    var count: usize = 0;
    while (languages.next()) |language| {
        count += 1;
        if (std.mem.eql(u8, language, "all")) {
            if (count != 1 or languages.next() != null) return false;
            return true;
        }
        if (language.len != 3) return false;
        for (language) |c| if (c < 'a' or c > 'z') return false;
    }
    return count > 0;
}

fn addOrReplaceOffsetPage(allocator: Allocator, base_url: []const u8, page: usize) ![]const u8 {
    const offset: usize = if (page <= 1) 0 else try std.math.mul(usize, page - 1, default_page_size);
    var normalized = base_url;
    var owned_normalized: ?[]u8 = null;
    defer if (owned_normalized) |value| allocator.free(value);

    if (std.mem.indexOf(u8, normalized, "/offset-")) |idx| {
        var end = idx + "/offset-".len;
        while (end < normalized.len and std.ascii.isDigit(normalized[end])) : (end += 1) {}

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, normalized[0..idx]);
        try out.appendSlice(allocator, normalized[end..]);
        const owned = try out.toOwnedSlice(allocator);
        owned_normalized = owned;
        normalized = owned;
    }

    if (offset == 0) return try allocator.dupe(u8, normalized);

    const suffix_pos = std.mem.indexOfAny(u8, normalized, "?#") orelse normalized.len;
    const head = normalized[0..suffix_pos];
    const tail = normalized[suffix_pos..];
    const sep: []const u8 = if (head.len > 0 and head[head.len - 1] == '/') "" else "/";
    return try std.fmt.allocPrint(allocator, "{s}{s}offset-{d}{s}", .{ head, sep, offset, tail });
}

fn checkedNextPage(page: usize) !usize {
    return std.math.add(usize, page, 1);
}

const ResultsPageIdentity = struct {
    locale: []const u8,
    route: []const u8,
    primary: []const u8,
    language: ?[]const u8,
    offset: usize,
    has_offset: bool,
};

fn resultsPageIdentity(url: []const u8) ?ResultsPageIdentity {
    validateProviderRoute(url, .results_page) catch return null;
    const uri = std.Uri.parse(url) catch return null;
    var path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];

    var parts: [12][]const u8 = undefined;
    const part_count = splitProviderPath(path, &parts) orelse return null;
    var primary: ?[]const u8 = null;
    var language: ?[]const u8 = null;
    var offset: usize = 0;
    var has_offset = false;
    for (parts[2..part_count]) |segment| {
        if (std.mem.startsWith(u8, segment, "moviename-") or
            std.mem.startsWith(u8, segment, "idmovie-"))
        {
            primary = segment;
        } else if (std.mem.startsWith(u8, segment, "sublanguageid-")) {
            language = segment;
        } else if (stripPrefix(segment, "offset-")) |value| {
            offset = std.fmt.parseInt(usize, value, 10) catch return null;
            has_offset = true;
        }
    }

    return .{
        .locale = parts[0],
        .route = parts[1],
        .primary = primary orelse return null,
        .language = language,
        .offset = offset,
        .has_offset = has_offset,
    };
}

fn isCanonicalResultsSuccessor(current_url: []const u8, candidate_url: []const u8) bool {
    const current = resultsPageIdentity(current_url) orelse return false;
    const candidate = resultsPageIdentity(candidate_url) orelse return false;
    if (!candidate.has_offset or
        !std.mem.eql(u8, current.locale, candidate.locale) or
        !std.mem.eql(u8, current.route, candidate.route) or
        !std.mem.eql(u8, current.primary, candidate.primary))
    {
        return false;
    }
    if ((current.language == null) != (candidate.language == null)) return false;
    if (current.language) |current_language| {
        if (!std.mem.eql(u8, current_language, candidate.language.?)) return false;
    }
    const expected_offset = std.math.add(usize, current.offset, default_page_size) catch return false;
    return candidate.offset == expected_offset;
}

fn resolveNextPageUrl(allocator: Allocator, href: []const u8, current_url: []const u8) !?[]const u8 {
    const resolved = common.resolveUrl(allocator, current_url, href) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    errdefer allocator.free(resolved);
    if (!isCanonicalResultsSuccessor(current_url, resolved)) {
        allocator.free(resolved);
        return null;
    }
    return resolved;
}

fn extractNextPageUrl(allocator: Allocator, doc: *HtmlDocument, current_url: []const u8) !?[]const u8 {
    var next_links = doc.queryAll("link[rel='next'][href]");
    while (next_links.next()) |link| {
        const href = link.getAttributeValue("href") orelse continue;
        if (try resolveNextPageUrl(allocator, href, current_url)) |value| return value;
    }

    var pager_links = doc.queryAll("#pager a[href*='offset-']");
    while (pager_links.next()) |anchor| {
        const href = anchor.getAttributeValue("href") orelse continue;
        const text = try common.innerTextTrimmedOwned(allocator, anchor);
        if (std.mem.eql(u8, text, ">>") or std.mem.eql(u8, text, "›") or std.mem.eql(u8, text, ">")) {
            if (try resolveNextPageUrl(allocator, href, current_url)) |value| return value;
        }
    }

    return null;
}

fn extractFlagLanguage(row: HtmlNode, allocator: Allocator) !?[]const u8 {
    var flag_divs = row.queryAll("td:nth-child(2) div[class*='flag']");
    defer flag_divs.deinit();
    while (flag_divs.next()) |flag_div| {
        const class = flag_div.getAttributeValue("class") orelse continue;
        var it = std.mem.tokenizeScalar(u8, class, ' ');
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "flag")) continue;
            return try allocator.dupe(u8, part);
        }
    }
    return null;
}

fn extractFilename(row: HtmlNode, subtitle_anchor: HtmlNode, allocator: Allocator) !?[]const u8 {
    const main = row.queryOne("td[id^='main']") orelse return null;
    var titled_spans = main.queryAll("span[title]");
    while (titled_spans.next()) |n| {
        if (n.getAttributeValue("title")) |title| {
            if (title.len > 0) return try allocator.dupe(u8, title);
        }
    }
    const text = try common.innerTextTrimmedOwned(allocator, subtitle_anchor);
    if (text.len > 0) return text;
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
    seen_subtitle_ids: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(SubtitleItem),
) !void {
    var selected_anchor: ?HtmlNode = null;
    var selected_details_url: ?[]const u8 = null;
    var selected_subtitle_id: ?[]const u8 = null;
    var subtitle_anchors = row.queryAll("a[href*='/subtitles/']");
    while (subtitle_anchors.next()) |subtitle_anchor| {
        const details_href = subtitle_anchor.getAttributeValue("href") orelse continue;

        // Avoid retaining one resolved URL per duplicate row in the response arena.
        // This is only an early-out hint: unseen rows still go through the complete
        // same-origin and exact-route validation below before the ID is trusted.
        if (subtitleIdForRoute(details_href, .subtitle_details)) |hinted_id| {
            if (seen_subtitle_ids.contains(hinted_id)) continue;
        }

        const details_url = resolveProviderUrl(allocator, details_href, .subtitle_details) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const details_id = subtitleIdForRoute(details_url, .subtitle_details) orelse {
            allocator.free(details_url);
            continue;
        };
        if (seen_subtitle_ids.contains(details_id)) {
            allocator.free(details_url);
            continue;
        }

        var serve_anchors = row.queryAll("a[href*='/subtitleserve/sub/']");
        while (serve_anchors.next()) |serve_anchor| {
            const serve_href = serve_anchor.getAttributeValue("href") orelse continue;
            const serve_url = resolveProviderUrl(allocator, serve_href, .subtitle_serve) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            const serve_id = subtitleIdForRoute(serve_url, .subtitle_serve);
            const matches = if (serve_id) |id| std.mem.eql(u8, details_id, id) else false;
            allocator.free(serve_url);
            if (!matches) continue;

            selected_anchor = subtitle_anchor;
            selected_details_url = details_url;
            selected_subtitle_id = details_id;
            break;
        }
        if (selected_details_url != null) break;
        allocator.free(details_url);
    }

    const subtitle_anchor = selected_anchor orelse return;
    const details_url = selected_details_url orelse return;
    const subtitle_id = selected_subtitle_id orelse return;
    const direct_zip_url = try std.fmt.allocPrint(allocator, "https://dl.opensubtitles.org/en/download/sub/{s}", .{subtitle_id});

    const language_code = try extractFlagLanguage(row, allocator);
    const filename = try extractFilename(row, subtitle_anchor, allocator);
    const release = try extractSubCellText(row, allocator, 1);
    const fps = try extractSubCellText(row, allocator, 5);
    const cds = try extractSubCellText(row, allocator, 4);
    const rating = try extractSubCellText(row, allocator, 8);
    const downloads = try extractSubCellText(row, allocator, 7);
    const uploaded_at = try extractSubCellText(row, allocator, 6);

    const row_text = try common.innerTextTrimmedOwned(allocator, row);
    const lower_row = try lowerDup(allocator, row_text);

    // Reserve both containers before committing either one. Once construction
    // succeeds, the accepted ID and output row are published atomically with
    // respect to allocation failure, so a failed row cannot poison deduping.
    try seen_subtitle_ids.ensureUnusedCapacity(allocator, 1);
    try out.ensureUnusedCapacity(allocator, 1);
    seen_subtitle_ids.putAssumeCapacityNoClobber(subtitle_id, {});
    out.appendAssumeCapacity(.{
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

fn subtitleIdForRoute(url: []const u8, route: ProviderRoute) ?[]const u8 {
    // Provider pages normally expose root-relative hrefs. `Uri.parse` only
    // accepts references with a scheme, so fall back to parsing a relative
    // reference before using this helper as the allocation-free dedupe hint.
    const uri = std.Uri.parse(url) catch
        (std.Uri.parseAfterScheme("", url) catch return null);
    var path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    var parts: [12][]const u8 = undefined;
    const part_count = splitProviderPath(path, &parts) orelse return null;
    return switch (route) {
        .subtitle_details => if ((part_count == 3 or part_count == 4) and
            isProviderLocale(parts[0]) and
            std.mem.eql(u8, parts[1], "subtitles") and
            isCanonicalPositiveDecimal(parts[2])) parts[2] else null,
        .subtitle_serve => if (part_count == 4 and
            isProviderLocale(parts[0]) and
            std.mem.eql(u8, parts[1], "subtitleserve") and
            std.mem.eql(u8, parts[2], "sub") and
            isCanonicalPositiveDecimal(parts[3])) parts[3] else null,
        .results_page => null,
    };
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

test "opensubtitles.org trims queries and does not fetch empty searches" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(site ++ "/en/search2/moviename-Matrix/sublanguageid-all", url);
            try std.testing.expect(!options.cache);
            try expectSecureFetchPolicy(options);
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
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "opensubtitles.org applies direct-row search fallback per page" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(!options.cache);
            try expectSecureFetchPolicy(options);
            const body = switch (self.calls) {
                1 => blk: {
                    try std.testing.expectEqualStrings(
                        site ++ "/en/search2/moviename-Matrix/sublanguageid-all",
                        url,
                    );
                    break :blk "<link rel='next' href='/en/search2/moviename-Matrix/sublanguageid-all/offset-40'>" ++
                        "<table id='search_results'><tr><td id='main1'><strong>" ++
                        "<a class='bnone' href='/en/search/sublanguageid-all/idmovie-154'>The Matrix</a>" ++
                        "</strong></td></tr></table>";
                },
                2 => blk: {
                    try std.testing.expectEqualStrings(
                        site ++ "/en/search2/moviename-Matrix/sublanguageid-all/offset-40",
                        url,
                    );
                    break :blk "<h1>The Matrix direct subtitles</h1>" ++
                        "<table id='search_results'><tr><td>" ++
                        "<a href='/en/subtitleserve/sub/195287'>download</a>" ++
                        "</td></tr></table>";
                },
                else => return error.UnexpectedRequest,
            };
            return .{ .status = .ok, .body = try allocator.dupe(u8, body) };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchWithOptionsUsing(Fixture.fetch, "Matrix", .{ .max_pages = 2 });
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings(
        site ++ "/en/search2/moviename-Matrix/sublanguageid-all/offset-40",
        response.items[1].page_url,
    );
}

test "opensubtitles optional row metadata preserves allocation failures" {
    const source =
        \\<table><tr>
        \\  <td id="main1"><span title="Movie.srt">Release</span><a>Fallback</a></td>
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
    try std.testing.expectError(
        error.OutOfMemory,
        extractFilename(
            row,
            row.queryOne("a") orelse return error.TestUnexpectedResult,
            failing_filename.allocator(),
        ),
    );
    try std.testing.expect(failing_filename.has_induced_failure);

    var failing_cell = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, extractSubCellText(row, failing_cell.allocator(), 1));
    try std.testing.expect(failing_cell.has_induced_failure);
}

test "opensubtitles.org rejects unsafe provider links before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/search/idmovie-1", .results_page));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@www.opensubtitles.org/search/idmovie-1", .results_page));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://www.google.com/search/idmovie-1", .results_page));
}

test "opensubtitles.org accepts only documented page and subtitle routes" {
    const valid = [_]struct { url: []const u8, route: ProviderRoute }{
        .{ .url = "https://www.opensubtitles.org/en/search2/moviename-The%20Matrix/sublanguageid-eng/offset-40", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search2/moviename-AC%2FDC/sublanguageid-all", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search/sublanguageid-all/idmovie-154", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/pt-br/search/idmovie-154/offset-0", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/subtitles/195287/the-matrix-en", .route = .subtitle_details },
        .{ .url = "https://www.opensubtitles.org/en/subtitleserve/sub/195287", .route = .subtitle_serve },
    };
    for (valid) |case| try validateProviderRoute(case.url, case.route);

    const invalid = [_]struct { url: []const u8, route: ProviderRoute }{
        .{ .url = "https://www.opensubtitles.org/en/admin", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search2/sublanguageid-all", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search/idmovie-0", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search/idmovie-0154", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search/idmovie-not-a-number", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search/idmovie-154/offset-00", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search/idmovie-154/offset-040", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search/idmovie-154/next-admin", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/search/idmovie-154?next=/admin", .route = .results_page },
        .{ .url = "https://www.opensubtitles.org/en/subtitles/0/title", .route = .subtitle_details },
        .{ .url = "https://www.opensubtitles.org/en/subtitles/0195287/title", .route = .subtitle_details },
        .{ .url = "https://www.opensubtitles.org/en/subtitles/not-an-id/title", .route = .subtitle_details },
        .{ .url = "https://www.opensubtitles.org/en/subtitles/195287/a%2fb", .route = .subtitle_details },
        .{ .url = "https://www.opensubtitles.org/en/subtitles/195287/.%2e", .route = .subtitle_details },
        .{ .url = "https://www.opensubtitles.org/en/subtitleserve/sub/0", .route = .subtitle_serve },
        .{ .url = "https://www.opensubtitles.org/en/subtitleserve/sub/0195287", .route = .subtitle_serve },
        .{ .url = "https://www.opensubtitles.org/en/subtitleserve/sub/../admin", .route = .subtitle_serve },
        .{ .url = "https://www.opensubtitles.org/en/subtitleserve/sub/195287/extra", .route = .subtitle_serve },
        .{ .url = "https://www.opensubtitles.org/en/subtitleserve/sub/195287#ignored", .route = .subtitle_serve },
    };
    for (invalid) |case| try std.testing.expectError(error.UnsafeHttpTarget, validateProviderRoute(case.url, case.route));
}

test "opensubtitles.org skips malformed rows without poisoning later valid rows" {
    const source =
        \\<table id="search_results">
        \\  <tr id="name1"><td id="main1"><strong><a class="bnone" href="/en/subtitles/not-an-id/title">bad details</a></strong></td><td><a href="/en/subtitleserve/sub/111111">download</a></td></tr>
        \\  <tr id="name2"><td id="main2"><strong><a class="bnone" href="/en/subtitles/195287/the-matrix-en">missing serve</a></strong></td></tr>
        \\  <tr id="name3"><td id="main3"><strong><a class="bnone" href="/en/subtitles/195287/the-matrix-en">bad serve</a></strong></td><td><a href="/en/subtitleserve/sub/not-an-id">download</a></td></tr>
        \\  <tr id="name4"><td id="main4"><strong><a class="bnone" href="/en/subtitles/195287/the-matrix-en">mismatched serve</a></strong></td><td><a href="/en/subtitleserve/sub/195288">download</a></td></tr>
        \\  <tr id="name5"><td id="main5"><strong><a class="bnone" href="/en/subtitles/195287/the-matrix-en">valid</a></strong></td><td><a href="/en/subtitleserve/sub/195287">download</a></td></tr>
        \\</table>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try common.parseHtmlStable(allocator, source);
    defer parsed.deinit();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var rows = parsed.doc.queryAll("tr[id^='name']");
    while (rows.next()) |row| try appendSubtitleFromRow(allocator, row, &seen, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("https://www.opensubtitles.org/en/subtitles/195287/the-matrix-en", out.items[0].details_url);
    try std.testing.expectEqualStrings("https://dl.opensubtitles.org/en/download/sub/195287", out.items[0].direct_zip_url);
}

test "opensubtitles.org scans same-row route candidates and preserves id binding" {
    const source =
        \\<table id="search_results">
        \\  <tr id="name1"><td id="main1"><strong>
        \\    <a class="bnone" href="/en/subtitles/not-an-id/title">bad details</a>
        \\    <a class="bnone" href="/en/subtitles/111111/wrong-title">unmatched details</a>
        \\    <a class="bnone" href="/en/subtitles/195287/the-matrix-en">valid details</a>
        \\  </strong></td><td>
        \\    <a href="/en/subtitleserve/sub/not-an-id">bad serve</a>
        \\    <a href="/en/subtitleserve/sub/195288">mismatched serve</a>
        \\    <a href="/en/subtitleserve/sub/195287">valid serve</a>
        \\  </td></tr>
        \\</table>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try common.parseHtmlStable(allocator, source);
    defer parsed.deinit();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;

    try appendSubtitleFromRow(
        allocator,
        parsed.doc.queryOne("tr") orelse return error.TestUnexpectedResult,
        &seen,
        &out,
    );

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("valid details", out.items[0].filename.?);
    try std.testing.expectEqualStrings("https://www.opensubtitles.org/en/subtitles/195287/the-matrix-en", out.items[0].details_url);
    try std.testing.expectEqualStrings("https://dl.opensubtitles.org/en/download/sub/195287", out.items[0].direct_zip_url);
}

test "opensubtitles.org duplicate IDs allocate no per-row data" {
    const source =
        \\<table id="search_results">
        \\  <tr id="name1"><td id="main1"><strong><a class="bnone" href="/en/subtitles/195287/the-matrix-en">valid</a></strong></td><td><a href="/en/subtitleserve/sub/195287">download</a></td></tr>
        \\  <tr id="name2"><td id="main2"><strong><a class="bnone" href="/en/subtitles/195287/alternate-slug">duplicate</a></strong></td><td><a href="/en/subtitleserve/sub/195287">download</a></td></tr>
        \\</table>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try common.parseHtmlStable(allocator, source);
    defer parsed.deinit();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var rows = parsed.doc.queryAll("tr[id^='name']");

    try appendSubtitleFromRow(allocator, rows.next() orelse return error.TestUnexpectedResult, &seen, &out);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try appendSubtitleFromRow(failing.allocator(), rows.next() orelse return error.TestUnexpectedResult, &seen, &out);

    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}

test "opensubtitles.org examines every pager link for the next page" {
    const source =
        \\<div id="pager">
        \\  <a href="/en/search2/moviename-matrix/offset-40">›</a>
        \\  <a href="/en/search2/moviename-matrix/offset-80">›</a>
        \\</div>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try common.parseHtmlStable(allocator, source);
    defer parsed.deinit();
    const next = (try extractNextPageUrl(
        allocator,
        &parsed.doc,
        "https://www.opensubtitles.org/en/search2/moviename-matrix/offset-40",
    )) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "https://www.opensubtitles.org/en/search2/moviename-matrix/offset-80",
        next,
    );
}

test "opensubtitles.org pager stays bound to the query and immediate offset" {
    const source =
        \\<link rel="next" href="/en/search2/moviename-other/sublanguageid-eng/offset-80">
        \\<link rel="next" href="/en/search2/moviename-matrix/sublanguageid-eng/offset-120">
        \\<div id="pager">
        \\  <a href="/en/search2/moviename-matrix/sublanguageid-eng/offset-120">›</a>
        \\  <a href="/en/search2/moviename-matrix/sublanguageid-spa/offset-80">›</a>
        \\  <a href="offset-80">›</a>
        \\</div>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try common.parseHtmlStable(allocator, source);
    defer parsed.deinit();
    const next = (try extractNextPageUrl(
        allocator,
        &parsed.doc,
        site ++ "/en/search2/moviename-matrix/sublanguageid-eng/offset-40",
    )) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        site ++ "/en/search2/moviename-matrix/sublanguageid-eng/offset-80",
        next,
    );

    var invalid = try common.parseHtmlStable(
        allocator,
        "<link rel='next' href='/en/search/sublanguageid-all/idmovie-999/offset-40'>",
    );
    defer invalid.deinit();
    try std.testing.expect((try extractNextPageUrl(
        allocator,
        &invalid.doc,
        site ++ "/en/search/sublanguageid-all/idmovie-154",
    )) == null);
}

test "opensubtitles.org pagination rejects offset overflow" {
    try std.testing.expectError(
        error.Overflow,
        addOrReplaceOffsetPage(
            std.testing.allocator,
            "https://www.opensubtitles.org/en/search/idmovie-154",
            std.math.maxInt(usize),
        ),
    );
}

test "opensubtitles.org pagination counter rejects overflow" {
    try std.testing.expectEqual(@as(usize, 2), try checkedNextPage(1));
    try std.testing.expectError(error.Overflow, checkedNextPage(std.math.maxInt(usize)));
}

const OwnedHtmlFixture = struct {
    fn fetch(_: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
        try std.testing.expect(!options.cache);
        try expectSecureFetchPolicy(options);
        const body = if (std.mem.endsWith(u8, url, "/blocked"))
            "Access to Website Disabled Federal Court of Australia"
        else
            "<html><body>ordinary provider page</body></html>";
        return .{ .status = .ok, .body = try allocator.dupe(u8, body) };
    }
};

fn expectSecureFetchPolicy(options: common.FetchOptions) !void {
    try std.testing.expect(options.require_public_origin);
    try std.testing.expect(options.require_https);
    try std.testing.expect(options.require_same_origin);
}

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
            try expectSecureFetchPolicy(options);
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
            try expectSecureFetchPolicy(options);
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
