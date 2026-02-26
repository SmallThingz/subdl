const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const site = "https://www.podnapisi.net";

pub const SearchItem = struct {
    id: []const u8,
    title: []const u8,
    media_type: []const u8,
    year: ?i64,
    subtitles_page_url: []const u8,
};

pub const SubtitleItem = struct {
    language: ?[]const u8,
    release: ?[]const u8,
    fps: ?[]const u8,
    cds: ?[]const u8,
    rating: ?[]const u8,
    uploader: ?[]const u8,
    uploaded_at: ?[]const u8,
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

        const encoded = try common.encodeUriComponent(a, query);
        const url = try std.fmt.allocPrint(a, "{s}/moviedb/search/?keywords={s}", .{ site, encoded });

        const headers = [_]std.http.Header{.{ .name = "x-requested-with", .value = "XMLHttpRequest" }};
        const response = common.fetchBytes(self.client, a, url, .{
            .accept = "application/json",
            .extra_headers = &headers,
            .max_attempts = 3,
            .retry_on_429 = true,
            .allow_non_ok = true,
        }) catch {
            return self.searchFallbackHtml(query);
        };

        if (response.status == .too_many_requests or response.status == .service_unavailable) {
            return self.searchFallbackHtml(query);
        }

        if (response.status != .ok) {
            return self.searchFallbackHtml(query);
        }

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const obj = switch (root) {
            .object => |o| o,
            else => return self.searchFallbackHtml(query),
        };

        const data = obj.get("data") orelse return self.searchFallbackHtml(query);
        const arr = switch (data) {
            .array => |arr| arr,
            else => return self.searchFallbackHtml(query),
        };

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (arr.items) |entry| {
            const item = switch (entry) {
                .object => |o| o,
                else => continue,
            };
            const id = item.get("id") orelse continue;
            const title = item.get("title") orelse continue;
            const media_type = item.get("type") orelse continue;
            if (id != .string or title != .string or media_type != .string) continue;

            const year_val = item.get("year");
            const year = if (year_val) |yv| switch (yv) {
                .integer => |v| v,
                .number_string => |ns| std.fmt.parseInt(i64, ns, 10) catch null,
                else => null,
            } else null;

            const subtitles_page_url = try std.fmt.allocPrint(a, "{s}/subtitles/search/{s}", .{ site, id.string });
            try items.append(a, .{
                .id = id.string,
                .title = title.string,
                .media_type = media_type.string,
                .year = year,
                .subtitles_page_url = subtitles_page_url,
            });
        }

        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    fn searchFallbackHtml(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const encoded = try common.encodeUriComponent(a, query);
        const url = try std.fmt.allocPrint(a, "{s}/subtitles/search/?keywords={s}", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html",
            .max_attempts = 3,
            .allow_non_ok = true,
            .retry_on_429 = true,
        });

        var parsed = try common.parseHtmlStable(a, response.body);
        defer parsed.deinit();

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var anchors = parsed.doc.queryAll("a[href*='/subtitles/search/']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.mem.endsWith(u8, href, "/subtitles/search/")) continue;
            const title = common.trimAscii(try anchor.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
            const absolute = try common.resolveUrl(a, site, href);
            const id = parseIdFromSubtitlesSearchUrl(absolute) orelse continue;

            try items.append(a, .{
                .id = id,
                .title = title,
                .media_type = "unknown",
                .year = null,
                .subtitles_page_url = absolute,
            });
        }

        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesBySearchLink(self: *Scraper, subtitles_page_url: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const debug_timing = debugTimingEnabled();
        const started_ns = if (debug_timing) std.time.nanoTimestamp() else 0;
        if (debug_timing) std.debug.print("[podnapisi.net] subtitles start url={s}\n", .{subtitles_page_url});

        const response = try common.fetchBytes(self.client, a, subtitles_page_url, .{
            .accept = "text/html",
            .max_attempts = 3,
            .allow_non_ok = true,
            .retry_on_429 = true,
        });

        if (response.status == .too_many_requests) return error.RateLimited;

        var parsed = try common.parseHtmlStable(a, response.body);
        defer parsed.deinit();

        const header_row = blk: {
            const table = parsed.doc.queryOne("table") orelse break :blk null;
            break :blk common.firstTableHeaderRow(table);
        };
        const fps_col = if (header_row) |row| try common.findTableColumnIndexByAliases(a, row, &.{ "fps", "frame rate" }) else null;
        const cds_col = if (header_row) |row| try common.findTableColumnIndexByAliases(a, row, &.{ "cds", "cd", "discs", "disc" }) else null;
        const rating_col = if (header_row) |row| try common.findTableColumnIndexByAliases(a, row, &.{"rating"}) else null;
        const uploader_col = if (header_row) |row| try common.findTableColumnIndexByAliases(a, row, &.{ "uploader", "uploaded by", "author" }) else null;
        const uploaded_at_col = if (header_row) |row| try common.findTableColumnIndexByAliases(a, row, &.{ "uploaded", "upload date", "date added" }) else null;
        var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var row_count: usize = 0;
        var rows = parsed.doc.queryAll("tbody tr");
        while (rows.next()) |row| {
            row_count += 1;
            const download_anchor = findDescendantAnchorByRelNoFollow(row) orelse continue;
            const href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
            const download_url = try common.resolveUrl(a, site, href);

            const language = if (findDescendantByTag(row, "abbr")) |node|
                common.trimAscii(try node.innerTextWithOptions(a, .{ .normalize_whitespace = true }))
            else
                null;

            const release = if (findDescendantSpanWithClass(row, "release")) |node|
                common.trimAscii(try node.innerTextWithOptions(a, .{ .normalize_whitespace = true }))
            else
                null;

            const fps = common.tableCellTextByColumnIndex(a, row, fps_col) catch null;
            const cds = common.tableCellTextByColumnIndex(a, row, cds_col) catch null;
            const rating = common.tableCellTextByColumnIndex(a, row, rating_col) catch null;
            const uploader = common.tableCellTextByColumnIndex(a, row, uploader_col) catch null;
            const uploaded_at = common.tableCellTextByColumnIndex(a, row, uploaded_at_col) catch null;

            try out.append(a, .{
                .language = language,
                .release = release,
                .fps = fps,
                .cds = cds,
                .rating = rating,
                .uploader = uploader,
                .uploaded_at = uploaded_at,
                .download_url = download_url,
            });
        }

        if (debug_timing) {
            const elapsed_ns = std.time.nanoTimestamp() - started_ns;
            std.debug.print("[podnapisi.net] subtitles done status={s} rows={d} out={d} in {d} ms\n", .{
                @tagName(response.status),
                row_count,
                out.items.len,
                @divTrunc(elapsed_ns, std.time.ns_per_ms),
            });
        }

        return .{ .arena = arena, .subtitles = try out.toOwnedSlice(a) };
    }
};

fn parseIdFromSubtitlesSearchUrl(url: []const u8) ?[]const u8 {
    const marker = "/subtitles/search/";
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    const remainder = url[start + marker.len ..];
    const end = std.mem.indexOfAny(u8, remainder, "?#/") orelse remainder.len;
    if (end == 0) return null;
    return remainder[0..end];
}

fn debugTimingEnabled() bool {
    const value = std.posix.getenv("SCRAPERS_DEBUG_TIMING") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn findDescendantByTag(node: html.Node, tag_name: []const u8) ?html.Node {
    for (node.children()) |child_idx| {
        const child = node.doc.nodeAt(child_idx) orelse continue;
        if (std.mem.eql(u8, child.tagName(), tag_name)) return child;
        if (findDescendantByTag(child, tag_name)) |nested| return nested;
    }
    return null;
}

fn findDescendantAnchorByRelNoFollow(node: html.Node) ?html.Node {
    for (node.children()) |child_idx| {
        const child = node.doc.nodeAt(child_idx) orelse continue;
        if (std.mem.eql(u8, child.tagName(), "a")) {
            const rel = common.getAttributeValueSafe(child, "rel") orelse "";
            if (std.mem.indexOf(u8, rel, "nofollow") != null) return child;
        }
        if (findDescendantAnchorByRelNoFollow(child)) |nested| return nested;
    }
    return null;
}

fn findDescendantSpanWithClass(node: html.Node, class_fragment: []const u8) ?html.Node {
    for (node.children()) |child_idx| {
        const child = node.doc.nodeAt(child_idx) orelse continue;
        if (std.mem.eql(u8, child.tagName(), "span")) {
            const class = common.getAttributeValueSafe(child, "class") orelse "";
            if (std.mem.indexOf(u8, class, class_fragment) != null) return child;
        }
        if (findDescendantSpanWithClass(child, class_fragment)) |nested| return nested;
    }
    return null;
}

test "parse podnapisi id" {
    try std.testing.expectEqualStrings("12345", parseIdFromSubtitlesSearchUrl("https://www.podnapisi.net/subtitles/search/12345").?);
}

test "live podnapisi search and subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][podnapisi.net][search][{d}]\n", .{idx});
        try common.livePrintField(std.testing.allocator, "id", item.id);
        try common.livePrintField(std.testing.allocator, "title", item.title);
        try common.livePrintField(std.testing.allocator, "media_type", item.media_type);
        if (item.year) |year| {
            std.debug.print("[live] year={d}\n", .{year});
        } else {
            std.debug.print("[live] year=<null>\n", .{});
        }
        try common.livePrintField(std.testing.allocator, "subtitles_page_url", item.subtitles_page_url);
    }

    var subtitles = try scraper.fetchSubtitlesBySearchLink(search.items[0].subtitles_page_url);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    for (subtitles.subtitles, 0..) |sub, idx| {
        std.debug.print("[live][podnapisi.net][subtitle][{d}]\n", .{idx});
        try common.livePrintOptionalField(std.testing.allocator, "language", sub.language);
        try common.livePrintOptionalField(std.testing.allocator, "release", sub.release);
        try common.livePrintOptionalField(std.testing.allocator, "fps", sub.fps);
        try common.livePrintOptionalField(std.testing.allocator, "cds", sub.cds);
        try common.livePrintOptionalField(std.testing.allocator, "rating", sub.rating);
        try common.livePrintOptionalField(std.testing.allocator, "uploader", sub.uploader);
        try common.livePrintOptionalField(std.testing.allocator, "uploaded_at", sub.uploaded_at);
        try common.livePrintField(std.testing.allocator, "download_url", sub.download_url);
    }
}
