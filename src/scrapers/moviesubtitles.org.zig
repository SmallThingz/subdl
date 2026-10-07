const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

const Allocator = std.mem.Allocator;
const site = "https://www.moviesubtitles.org";
// Provider result cards are shallow. Keeping this fixed makes the aggregate
// ancestor work linear in the number of candidate subtitle anchors even when
// hostile markup supplies an arbitrarily deep tree.
const max_detail_ancestor_hops: usize = 64;

pub const SearchItem = struct {
    title: []const u8,
    link: []const u8,
};

pub const SubtitleItem = struct {
    language_code: ?[]const u8,
    filename: []const u8,
    details_url: []const u8,
    download_url: []const u8,
    rating_good: ?[]const u8,
    rating_bad: ?[]const u8,
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
        return self.searchUsing(common.fetchBytes, query);
    }

    fn searchUsing(self: *Scraper, comptime fetch: anytype, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        const debug_timing = common.debugTimingEnabled();
        const started_ns = if (debug_timing) common.compatNanoTimestamp() else 0;
        if (debug_timing) std.debug.print("[moviesubtitles.org] search start query_bytes={d}\n", .{trimmed.len});

        const encoded = try common.encodeUriComponent(a, trimmed);
        const payload = try std.fmt.allocPrint(a, "q={s}", .{encoded});
        const response = try fetch(self.client, a, site ++ "/search.php", .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "text/html",
            .allow_non_ok = true,
            .max_attempts = 2,
            .retry_on_429 = false,
            .cache = false,
            .require_public_origin = true,
        });
        try requireSearchResponse(response.status, response.body);

        // This site frequently returns malformed HTML that is unsafe in turbo mode.
        var parsed = try common.parseHtmlStable(a, response.body);

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var raw_anchor_count: usize = 0;
        var links = parsed.doc.queryAll("div[style*='width:500px'] a");
        while (links.next()) |anchor| {
            raw_anchor_count += 1;
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.mem.indexOf(u8, href, "/movie-") == null or !std.mem.endsWith(u8, href, ".html")) continue;
            const text = try common.innerTextTrimmedOwned(a, anchor);
            if (text.len == 0) continue;
            const link = resolveProviderUrl(a, href, .movie) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (seen.contains(link)) continue;
            try seen.put(a, link, {});
            try items.append(a, .{ .title = text, .link = link });
        }

        if (items.items.len == 0) {
            try appendSearchItemsFromRawHtml(a, response.body, &items);
        }

        if (debug_timing) {
            const elapsed_ns = common.compatNanoTimestamp() - started_ns;
            std.debug.print("[moviesubtitles.org] search done status={s} anchors={d} items={d} in {d} ms\n", .{
                @tagName(response.status),
                raw_anchor_count,
                items.items.len,
                @divTrunc(elapsed_ns, std.time.ns_per_ms),
            });
            const preview_len = @min(items.items.len, 8);
            for (items.items[0..preview_len], 0..) |item, idx| {
                const safe_title: []const u8 = common.sanitizeUtf8ForLog(a, item.title) catch "<invalid-text>";
                const safe_link: []const u8 = common.redactUrlForLog(a, item.link) catch "<redacted-url>";
                std.debug.print("[moviesubtitles.org] item[{d}] title='{s}' link={s}\n", .{ idx, safe_title, safe_link });
            }
        }

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesByMovieLink(self: *Scraper, movie_link: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const debug_timing = common.debugTimingEnabled();
        const started_ns = if (debug_timing) common.compatNanoTimestamp() else 0;
        if (debug_timing) {
            const safe_url: []const u8 = common.redactUrlForLog(a, movie_link) catch "<redacted-url>";
            std.debug.print("[moviesubtitles.org] subtitles start url={s}\n", .{safe_url});
        }

        try validateProviderEndpoint(movie_link, .movie);
        const response = try common.fetchBytes(self.client, a, movie_link, .{
            .accept = "text/html",
            .max_attempts = 2,
            .require_public_origin = true,
        });
        var parsed = try common.parseHtmlStable(a, response.body);

        const title = blk: {
            if (parsed.doc.queryOne("h1")) |h1| break :blk try common.innerTextTrimmedOwned(a, h1);
            if (parsed.doc.queryOne("title")) |t| break :blk try common.innerTextTrimmedOwned(a, t);
            break :blk "";
        };

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen_details = std.StringHashMapUnmanaged(void).empty;
        var total_detail_anchors: usize = 0;
        var detail_anchors = parsed.doc.queryAll("a[href*='subtitle-']");
        while (detail_anchors.next()) |detail_anchor| {
            total_detail_anchors += 1;
            const detail_href = common.getAttributeValueSafe(detail_anchor, "href") orelse continue;
            if (std.mem.indexOf(u8, detail_href, "subtitle-") == null) continue;
            const details_url = resolveProviderUrl(a, detail_href, .subtitle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (seen_details.contains(details_url)) continue;
            try seen_details.put(a, details_url, {});

            const block = findBoundedAncestorWithStyleFragment(detail_anchor, "margin-bottom") orelse detail_anchor.parentNode() orelse continue;
            const filename = blk_file: {
                if (block.queryOne("b")) |b_node| {
                    const text = try common.innerTextTrimmedOwned(a, b_node);
                    if (text.len > 0) break :blk_file text;
                }
                const text = try common.innerTextTrimmedOwned(a, block);
                break :blk_file text;
            };

            const language_code = blk_lang: {
                const img = findDescendantImgWithSrcFragment(block, "flags") orelse break :blk_lang null;
                const src = common.getAttributeValueSafe(img, "src") orelse break :blk_lang null;
                const slash = std.mem.lastIndexOfScalar(u8, src, '/') orelse break :blk_lang null;
                const dot = std.mem.lastIndexOfScalar(u8, src, '.') orelse break :blk_lang null;
                if (dot <= slash + 1) break :blk_lang null;
                break :blk_lang try a.dupe(u8, src[slash + 1 .. dot]);
            };

            const rating_bad = blk_bad: {
                if (block.queryOne("span[style*='color:red']")) |node| {
                    const value = try common.innerTextTrimmedOwned(a, node);
                    if (value.len > 0) break :blk_bad value;
                }
                break :blk_bad null;
            };

            const rating_good = blk_good: {
                if (block.queryOne("span[style*='color:green']")) |node| {
                    const value = try common.innerTextTrimmedOwned(a, node);
                    if (value.len > 0) break :blk_good value;
                }
                break :blk_good null;
            };

            const download_url = try detailToDownloadUrl(a, details_url);
            try subtitles.append(a, .{
                .language_code = language_code,
                .filename = filename,
                .details_url = details_url,
                .download_url = download_url,
                .rating_good = rating_good,
                .rating_bad = rating_bad,
            });
        }

        if (debug_timing) {
            const elapsed_ns = common.compatNanoTimestamp() - started_ns;
            std.debug.print("[moviesubtitles.org] subtitles done status={s} anchors={d} unique={d} in {d} ms\n", .{
                @tagName(response.status),
                total_detail_anchors,
                subtitles.items.len,
                @divTrunc(elapsed_ns, std.time.ns_per_ms),
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{ .arena = arena, .title = title, .subtitles = try subtitles.toOwnedSlice(a) });
    }
};

fn appendSearchItemsFromRawHtml(allocator: Allocator, html_body: []const u8, items: *std.ArrayListUnmanaged(SearchItem)) !void {
    var seen = std.StringHashMapUnmanaged(void).empty;
    var pos: usize = 0;
    const marker = "href=\"/movie-";
    while (std.mem.indexOfPos(u8, html_body, pos, marker)) |href_pos| {
        const resume_pos = href_pos + marker.len;
        const next_href = std.mem.indexOfPos(u8, html_body, resume_pos, marker);
        const candidate_end = next_href orelse html_body.len;
        const href_value_start = href_pos + "href=\"".len;
        const href_value_end_rel = std.mem.indexOfScalar(u8, html_body[href_value_start..candidate_end], '"') orelse {
            pos = candidate_end;
            continue;
        };
        const href_value_end = href_value_start + href_value_end_rel;
        const href = html_body[href_value_start..href_value_end];

        const text_start_rel = std.mem.indexOfScalar(u8, html_body[href_value_end..candidate_end], '>') orelse {
            pos = candidate_end;
            continue;
        };
        const text_start_marker = href_value_end + text_start_rel;
        const text_start = text_start_marker + 1;
        const text_end = std.mem.indexOfScalarPos(u8, html_body, text_start, '<') orelse {
            pos = next_href orelse html_body.len;
            continue;
        };
        const title = std.mem.trim(u8, html_body[text_start..text_end], " \t\r\n");
        if (title.len == 0) {
            pos = text_end;
            continue;
        }

        const link = resolveProviderUrl(allocator, href, .movie) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                pos = text_end;
                continue;
            },
        };
        if (seen.contains(link)) {
            pos = text_end;
            continue;
        }
        try seen.put(allocator, link, {});
        try items.append(allocator, .{ .title = title, .link = link });

        pos = text_end;
    }
}

fn requireSearchResponse(status: std.http.Status, body: []const u8) !void {
    if (status == .too_many_requests) return error.RateLimited;
    if (status == .ok) return;
    // This legacy endpoint commonly returns 500 alongside a complete search
    // page, including valid zero-result pages. Accept only its recognizable
    // page shell plus either results or the provider's no-results marker.
    if (status == .internal_server_error and hasSearchPageMarkup(body)) return;
    return error.UnexpectedHttpStatus;
}

fn hasSearchPageMarkup(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "<title>Moviesubtitles.org") == null or
        std.mem.indexOf(u8, body, "<h2>Search</h2>") == null or
        std.mem.indexOf(u8, body, "Search results") == null) return false;
    return (std.mem.indexOf(u8, body, "/movie-") != null and
        std.mem.indexOf(u8, body, ".html") != null) or
        std.mem.indexOf(u8, body, "No results found") != null;
}

const ProviderRoute = enum { movie, subtitle, download };

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderEndpoint(resolved, route);
    return resolved;
}

fn validateProviderEndpoint(url: []const u8, route: ProviderRoute) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.UnsafeHttpTarget;
    }
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const valid = switch (route) {
        .movie => movieSlug(path) != null,
        .subtitle => routeId(path, "/subtitle-") != null,
        .download => routeId(path, "/download-") != null,
    };
    if (!valid) return error.UnsafeHttpTarget;
}

fn movieSlug(path: []const u8) ?[]const u8 {
    const prefix = "/movie-";
    const suffix = ".html";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const slug = path[prefix.len .. path.len - suffix.len];
    if (!isSafeEncodedSegment(slug)) return null;
    return slug;
}

fn routeId(path: []const u8, prefix: []const u8) ?[]const u8 {
    const suffix = ".html";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const id = path[prefix.len .. path.len - suffix.len];
    if (id.len == 0 or id.len > 19 or id[0] == '0') return null;
    for (id) |c| if (!std.ascii.isDigit(c)) return null;
    return id;
}

fn isSafeEncodedSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 512 or
        std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    var index: usize = 0;
    while (index < segment.len) {
        const c = segment[index];
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@", c) != null) {
            index += 1;
            continue;
        }
        if (c != '%' or segment.len - index < 3 or
            !std.ascii.isHex(segment[index + 1]) or !std.ascii.isHex(segment[index + 2])) return false;
        const decoded = std.fmt.parseInt(u8, segment[index + 1 .. index + 3], 16) catch return false;
        if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
            decoded == '?' or decoded == '#' or decoded == '%') return false;
        index += 3;
    }
    return true;
}

fn findBoundedAncestorWithStyleFragment(node: HtmlNode, style_fragment: []const u8) ?HtmlNode {
    var current = node.parentNode();
    var hops: usize = 0;
    while (current) |n| : (current = n.parentNode()) {
        if (hops == max_detail_ancestor_hops) return null;
        hops += 1;
        if (!std.mem.eql(u8, n.tagName(), "div")) continue;
        const style = common.getAttributeValueSafe(n, "style") orelse continue;
        if (std.mem.indexOf(u8, style, style_fragment) != null) return n;
    }
    return null;
}

fn findDescendantImgWithSrcFragment(node: HtmlNode, src_fragment: []const u8) ?HtmlNode {
    var descendants = common.boundedHtmlDescendants(node);
    while (descendants.next()) |child| {
        if (std.mem.eql(u8, child.tagName(), "img")) {
            const src = common.getAttributeValueSafe(child, "src") orelse "";
            if (std.mem.indexOf(u8, src, src_fragment) != null) return child;
        }
    }
    return null;
}

fn detailToDownloadUrl(allocator: Allocator, details_url: []const u8) ![]const u8 {
    try validateProviderEndpoint(details_url, .subtitle);
    const uri = std.Uri.parse(details_url) catch return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const id = routeId(path, "/subtitle-") orelse return error.UnsafeHttpTarget;
    const out = try std.fmt.allocPrint(allocator, site ++ "/download-{s}.html", .{id});
    errdefer allocator.free(out);
    try validateProviderEndpoint(out, .download);
    return out;
}

test "moviesubtitles.org trims queries and does not fetch empty searches" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(site ++ "/search.php", url);
            try std.testing.expectEqualStrings("q=Matrix", options.payload orelse return error.TestUnexpectedResult);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<html></html>") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);

    var empty = try scraper.searchUsing(Fixture.fetch, " \t\r\n ");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    var trimmed = try scraper.searchUsing(Fixture.fetch, "  Matrix\t");
    defer trimmed.deinit();
    try std.testing.expectEqual(@as(usize, 0), trimmed.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "moviesubtitles.org detail url rewrite" {
    const allocator = std.testing.allocator;
    const src = "https://www.moviesubtitles.org/subtitle-12345.html";
    const out = try detailToDownloadUrl(allocator, src);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(site ++ "/download-12345.html", out);
}

test "moviesubtitles.org bounds result-card ancestor lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const shallow = try common.parseHtmlStable(
        allocator,
        "<div style=\"margin-bottom: 8px\"><div><a id=\"target\"></a></div></div>",
    );
    const shallow_target = shallow.doc.queryOne("a") orelse return error.TestUnexpectedResult;
    try std.testing.expect(findBoundedAncestorWithStyleFragment(shallow_target, "margin-bottom") != null);

    var deep_source: std.ArrayListUnmanaged(u8) = .empty;
    try deep_source.appendSlice(allocator, "<div style=\"margin-bottom: 8px\">");
    for (0..max_detail_ancestor_hops) |_| try deep_source.appendSlice(allocator, "<div>");
    try deep_source.appendSlice(allocator, "<a id=\"deep-target\"></a>");
    for (0..max_detail_ancestor_hops) |_| try deep_source.appendSlice(allocator, "</div>");
    try deep_source.appendSlice(allocator, "</div>");

    const deep = try common.parseHtmlStable(allocator, deep_source.items);
    const deep_target = deep.doc.queryOne("a") orelse return error.TestUnexpectedResult;
    try std.testing.expect(findBoundedAncestorWithStyleFragment(deep_target, "margin-bottom") == null);
}

test "moviesubtitles.org raw fallback recovers after malformed results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try appendSearchItemsFromRawHtml(
        arena.allocator(),
        "<a href=\"/movie-missing-quote " ++
            "<a href=\"/movie-missing-angle.html\" " ++
            "<a href=\"/movie-valid.html\">Valid Movie</a>",
        &items,
    );
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("Valid Movie", items.items[0].title);
    try std.testing.expectEqualStrings(site ++ "/movie-valid.html", items.items[0].link);
}

test "moviesubtitles.org accepts only recognizable legacy 500 results" {
    try requireSearchResponse(.ok, "<html></html>");
    const shell = "<title>Moviesubtitles.org - Top</title><h2>Search</h2><p>Search results</p>";
    try requireSearchResponse(.internal_server_error, shell ++ "<a href=\"/movie-the-matrix-1999.html\">The Matrix</a>");
    try requireSearchResponse(.internal_server_error, shell ++ "<div>No results found</div>");
    try std.testing.expectError(error.RateLimited, requireSearchResponse(.too_many_requests, "busy"));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireSearchResponse(.internal_server_error, "<h1>Internal Server Error</h1>"));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireSearchResponse(.service_unavailable, shell ++ "<a href=\"/movie-valid.html\">x</a>"));
}

test "moviesubtitles.org detail url rewrite preserves allocation errors" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        detailToDownloadUrl(failing.allocator(), "https://www.moviesubtitles.org/subtitle-12345.html"),
    );
}

test "moviesubtitles.org rejects unsafe provider links before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/movie-1.html", .movie));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@www.moviesubtitles.org/movie-1.html", .movie));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://www.google.com/movie-1.html", .movie));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/movie-1.html?next=/download-2.html", .movie));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/movie-a%252fb.html", .movie));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/subtitle-0.html", .subtitle));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/subtitle-123/extra.html", .subtitle));
    try std.testing.expectError(error.UnsafeHttpTarget, detailToDownloadUrl(std.testing.allocator, site ++ "/download-123.html"));
}

test "live moviesubtitles.org search and subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "MOVIESUBTITLES_ORG")) return error.SkipZigTest;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][moviesubtitles.org][search][{d}]\n", .{idx});
        try common.livePrintField(std.testing.allocator, "title", item.title);
        try common.livePrintField(std.testing.allocator, "link", item.link);
    }

    var subtitles = try scraper.fetchSubtitlesByMovieLink(search.items[0].link);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    try common.livePrintField(std.testing.allocator, "subtitles_title", subtitles.title);
    for (subtitles.subtitles, 0..) |sub, idx| {
        std.debug.print("[live][moviesubtitles.org][subtitle][{d}]\n", .{idx});
        try common.livePrintOptionalField(std.testing.allocator, "language_code", sub.language_code);
        try common.livePrintField(std.testing.allocator, "filename", sub.filename);
        try common.livePrintField(std.testing.allocator, "details_url", sub.details_url);
        try common.livePrintField(std.testing.allocator, "download_url", sub.download_url);
        try common.livePrintOptionalField(std.testing.allocator, "rating_good", sub.rating_good);
        try common.livePrintOptionalField(std.testing.allocator, "rating_bad", sub.rating_bad);
    }
}
