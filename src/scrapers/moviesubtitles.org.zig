const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const site = "https://www.moviesubtitles.org";

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
        const debug_timing = debugTimingEnabled();
        const started_ns = if (debug_timing) std.time.nanoTimestamp() else 0;
        if (debug_timing) std.debug.print("[moviesubtitles.org] search start query='{s}'\n", .{query});

        const encoded = try common.encodeUriComponent(a, query);
        const payload = try std.fmt.allocPrint(a, "q={s}", .{encoded});
        const response = try common.fetchBytes(self.client, a, site ++ "/search.php", .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "text/html",
            .allow_non_ok = true,
            .max_attempts = 2,
        });
        // This endpoint commonly returns 500 with usable HTML.
        _ = response.status;

        // This site frequently returns malformed HTML that is unsafe in turbo mode.
        var parsed = try common.parseHtmlStable(a, response.body);
        defer parsed.deinit();

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var raw_anchor_count: usize = 0;
        var links = parsed.doc.queryAll("div[style*='width:500px'] a");
        while (links.next()) |anchor| {
            raw_anchor_count += 1;
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.mem.indexOf(u8, href, "/movie-") == null or !std.mem.endsWith(u8, href, ".html")) continue;
            const text = common.trimAscii(try anchor.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
            if (text.len == 0) continue;
            const link = try common.resolveUrl(a, site, href);
            if (seen.contains(link)) continue;
            try seen.put(a, link, {});
            try items.append(a, .{ .title = text, .link = link });
        }

        if (items.items.len == 0) {
            try appendSearchItemsFromRawHtml(a, response.body, &items);
        }

        if (debug_timing) {
            const elapsed_ns = std.time.nanoTimestamp() - started_ns;
            std.debug.print("[moviesubtitles.org] search done status={s} anchors={d} items={d} in {d} ms\n", .{
                @tagName(response.status),
                raw_anchor_count,
                items.items.len,
                @divTrunc(elapsed_ns, std.time.ns_per_ms),
            });
            const preview_len = @min(items.items.len, 8);
            for (items.items[0..preview_len], 0..) |item, idx| {
                std.debug.print("[moviesubtitles.org] item[{d}] title='{s}' link={s}\n", .{ idx, item.title, item.link });
            }
        }

        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesByMovieLink(self: *Scraper, movie_link: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const debug_timing = debugTimingEnabled();
        const started_ns = if (debug_timing) std.time.nanoTimestamp() else 0;
        if (debug_timing) std.debug.print("[moviesubtitles.org] subtitles start url={s}\n", .{movie_link});

        const response = try common.fetchBytes(self.client, a, movie_link, .{ .accept = "text/html", .max_attempts = 2 });
        var parsed = try common.parseHtmlStable(a, response.body);
        defer parsed.deinit();

        const title = blk: {
            if (parsed.doc.queryOne("h1")) |h1| break :blk common.trimAscii(try h1.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
            if (parsed.doc.queryOne("title")) |t| break :blk common.trimAscii(try t.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
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
            const details_url = try common.resolveUrl(a, site, detail_href);
            if (seen_details.contains(details_url)) continue;
            try seen_details.put(a, details_url, {});

            const block = findAncestorWithStyleFragment(detail_anchor, "margin-bottom") orelse detail_anchor.parentNode() orelse continue;
            const filename = blk_file: {
                if (block.queryOne("b")) |b_node| {
                    const text = common.trimAscii(try b_node.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
                    if (text.len > 0) break :blk_file text;
                }
                const text = common.trimAscii(try block.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
                break :blk_file text;
            };

            const language_code = blk_lang: {
                const img = findDescendantImgWithSrcFragment(block, "flags") orelse break :blk_lang null;
                const src = common.getAttributeValueSafe(img, "src") orelse break :blk_lang null;
                const slash = std.mem.lastIndexOfScalar(u8, src, '/') orelse break :blk_lang null;
                const dot = std.mem.lastIndexOfScalar(u8, src, '.') orelse break :blk_lang null;
                if (dot <= slash + 1) break :blk_lang null;
                break :blk_lang src[slash + 1 .. dot];
            };

            const rating_bad = blk_bad: {
                if (block.queryOne("span[style*='color:red']")) |node| {
                    const value = common.trimAscii(try node.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
                    if (value.len > 0) break :blk_bad value;
                }
                break :blk_bad null;
            };

            const rating_good = blk_good: {
                if (block.queryOne("span[style*='color:green']")) |node| {
                    const value = common.trimAscii(try node.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
                    if (value.len > 0) break :blk_good value;
                }
                break :blk_good null;
            };

            const download_url = detailToDownloadUrl(a, details_url) orelse details_url;
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
            const elapsed_ns = std.time.nanoTimestamp() - started_ns;
            std.debug.print("[moviesubtitles.org] subtitles done status={s} anchors={d} unique={d} in {d} ms\n", .{
                @tagName(response.status),
                total_detail_anchors,
                subtitles.items.len,
                @divTrunc(elapsed_ns, std.time.ns_per_ms),
            });
        }

        return .{ .arena = arena, .title = title, .subtitles = try subtitles.toOwnedSlice(a) };
    }
};

fn appendSearchItemsFromRawHtml(allocator: Allocator, html_body: []const u8, items: *std.ArrayListUnmanaged(SearchItem)) !void {
    var seen = std.StringHashMapUnmanaged(void).empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, html_body, pos, "href=\"/movie-")) |href_pos| {
        const href_value_start = href_pos + "href=\"".len;
        const href_value_end = std.mem.indexOfScalarPos(u8, html_body, href_value_start, '"') orelse break;
        const href = html_body[href_value_start..href_value_end];

        const text_start_marker = std.mem.indexOfScalarPos(u8, html_body, href_value_end, '>') orelse break;
        const text_start = text_start_marker + 1;
        const text_end = std.mem.indexOfScalarPos(u8, html_body, text_start, '<') orelse break;
        const title = common.trimAscii(html_body[text_start..text_end]);

        const link = try common.resolveUrl(allocator, site, href);
        if (seen.contains(link)) {
            pos = text_end;
            continue;
        }
        try seen.put(allocator, link, {});
        try items.append(allocator, .{ .title = title, .link = link });

        pos = text_end;
    }
}

fn findAncestorWithStyleFragment(node: html.Node, style_fragment: []const u8) ?html.Node {
    var current = node.parentNode();
    while (current) |n| : (current = n.parentNode()) {
        if (!std.mem.eql(u8, n.tagName(), "div")) continue;
        const style = common.getAttributeValueSafe(n, "style") orelse continue;
        if (std.mem.indexOf(u8, style, style_fragment) != null) return n;
    }
    return null;
}

fn findDescendantImgWithSrcFragment(node: html.Node, src_fragment: []const u8) ?html.Node {
    for (node.children()) |child_idx| {
        const child = node.doc.nodeAt(child_idx) orelse continue;
        if (std.mem.eql(u8, child.tagName(), "img")) {
            const src = common.getAttributeValueSafe(child, "src") orelse "";
            if (std.mem.indexOf(u8, src, src_fragment) != null) return child;
        }
        if (findDescendantImgWithSrcFragment(child, src_fragment)) |nested| return nested;
    }
    return null;
}

fn detailToDownloadUrl(allocator: Allocator, details_url: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, details_url, "/subtitle-") orelse return null;
    var out = allocator.dupe(u8, details_url) catch return null;
    std.mem.copyForwards(u8, out[idx + 1 .. idx + "subtitle".len + 1], "download");
    return out;
}

fn debugTimingEnabled() bool {
    const value = std.posix.getenv("SCRAPERS_DEBUG_TIMING") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

test "moviesubtitles.org detail url rewrite" {
    const allocator = std.testing.allocator;
    const src = "https://www.moviesubtitles.org/subtitle-12345.html";
    const out = detailToDownloadUrl(allocator, src) orelse return error.TestUnexpectedResult;
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "/download-") != null);
}

test "live moviesubtitles.org search and subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesByMovieLink(search.items[0].link);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
}
