const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();
const suite = @import("test_suite.zig");

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
    has_next_page: bool = false,

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
    pub const SearchOptions = struct {
        page_start: usize = 1,
        max_pages: usize = 1,
    };

    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn deinit(_: *Scraper) void {}

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchWithOptions(query, .{});
    }

    pub fn searchWithOptions(self: *Scraper, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        const page_start = if (options.page_start == 0) 1 else options.page_start;
        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;

        var page: usize = page_start;
        var fetched_pages: usize = 0;
        var has_next_page = false;

        while (fetched_pages < max_pages) : ({
            fetched_pages += 1;
            if (has_next_page) page += 1;
        }) {
            var page_items: std.ArrayListUnmanaged(SearchItem) = .empty;
            defer page_items.deinit(a);

            var page_has_next = false;

            // JSON endpoint (better metadata) only supports first-page suggestions.
            if (page == 1) {
                try self.appendJsonSearchItems(a, query, &page_items);
            }

            try self.appendHtmlSearchItems(a, query, page, &page_items, &page_has_next);
            dedupeSearchItemsById(&page_items);

            try items.appendSlice(a, page_items.items);
            has_next_page = page_has_next;
            if (!has_next_page) break;
        }

        dedupeSearchItemsById(&items);
        return .{
            .arena = arena,
            .items = try items.toOwnedSlice(a),
            .has_next_page = has_next_page,
        };
    }

    fn appendJsonSearchItems(
        self: *Scraper,
        allocator: Allocator,
        query: []const u8,
        out: *std.ArrayListUnmanaged(SearchItem),
    ) !void {
        const encoded = try common.encodeUriComponent(allocator, query);
        const url = try std.fmt.allocPrint(allocator, "{s}/moviedb/search/?keywords={s}", .{ site, encoded });

        const headers = [_]std.http.Header{.{ .name = "x-requested-with", .value = "XMLHttpRequest" }};
        const response = common.fetchBytes(self.client, allocator, url, .{
            .accept = "application/json",
            .extra_headers = &headers,
            .max_attempts = 3,
            .retry_initial_backoff_ms = 1500,
            .retry_on_429 = true,
            .allow_non_ok = true,
        }) catch return;

        if (response.status != .ok) return;

        const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, response.body, .{}) catch return;
        const obj = switch (root) {
            .object => |o| o,
            else => return,
        };

        if (obj.get("status")) |status_val| {
            if (status_val == .string and std.ascii.eqlIgnoreCase(status_val.string, "too-many-requests")) return;
        }

        const data = obj.get("data") orelse return;
        const arr = switch (data) {
            .array => |arr| arr,
            else => return,
        };

        for (arr.items) |entry| {
            const item = switch (entry) {
                .object => |o| o,
                else => continue,
            };
            const id_val = item.get("id") orelse continue;
            if (id_val != .string or id_val.string.len == 0) continue;
            const id = id_val.string;

            const year = blk: {
                const year_val = item.get("year") orelse break :blk null;
                break :blk switch (year_val) {
                    .integer => |v| v,
                    .number_string => |ns| std.fmt.parseInt(i64, ns, 10) catch null,
                    else => null,
                };
            };

            const media_type = blk: {
                const type_val = item.get("type") orelse break :blk "unknown";
                if (type_val != .string or type_val.string.len == 0) break :blk "unknown";
                break :blk type_val.string;
            };

            const title = try deriveJsonItemTitle(allocator, item, id);
            const subtitles_page_url = try std.fmt.allocPrint(allocator, "{s}/subtitles/search/{s}", .{ site, id });

            try out.append(allocator, .{
                .id = id,
                .title = title,
                .media_type = media_type,
                .year = year,
                .subtitles_page_url = subtitles_page_url,
            });
        }
    }

    fn appendHtmlSearchItems(
        self: *Scraper,
        allocator: Allocator,
        query: []const u8,
        page: usize,
        out: *std.ArrayListUnmanaged(SearchItem),
        has_next_page: *bool,
    ) !void {
        const encoded = try common.encodeUriComponent(allocator, query);
        const url = if (page <= 1)
            try std.fmt.allocPrint(allocator, "{s}/subtitles/search/?keywords={s}", .{ site, encoded })
        else
            try std.fmt.allocPrint(allocator, "{s}/subtitles/search/?keywords={s}&page={d}", .{ site, encoded, page });

        const response = common.fetchBytes(self.client, allocator, url, .{
            .accept = "text/html",
            .max_attempts = 3,
            .retry_initial_backoff_ms = 1500,
            .allow_non_ok = true,
            .retry_on_429 = true,
        }) catch return;
        if (response.status != .ok) return;

        var parsed = try common.parseHtmlStable(allocator, response.body);
        defer parsed.deinit();
        has_next_page.* = hasNextHtmlSearchPage(&parsed.doc, page) catch false;

        var anchors = parsed.doc.queryAll("a[href*='/subtitles/search/']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.mem.endsWith(u8, href, "/subtitles/search/")) continue;
            if (std.mem.indexOf(u8, href, "/advanced") != null) continue;

            const absolute = try common.resolveUrl(allocator, site, href);
            const id = parseIdFromSubtitlesSearchUrl(absolute) orelse continue;
            if (std.ascii.eqlIgnoreCase(id, "advanced")) continue;

            const title = try deriveHtmlAnchorTitle(allocator, anchor, absolute, id);
            if (std.ascii.eqlIgnoreCase(title, "search") or std.ascii.eqlIgnoreCase(title, "advanced search")) continue;

            try out.append(allocator, .{
                .id = id,
                .title = title,
                .media_type = "unknown",
                .year = null,
                .subtitles_page_url = absolute,
            });
        }
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
            .retry_initial_backoff_ms = 1500,
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
                try common.innerTextTrimmedOwned(a, node)
            else
                null;

            const release = if (findDescendantSpanWithClass(row, "release")) |node|
                try common.innerTextTrimmedOwned(a, node)
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
    const remainder_raw = url[start + marker.len ..];
    const remainder = std.mem.trimLeft(u8, remainder_raw, "/");
    const end = std.mem.indexOfAny(u8, remainder, "?#/") orelse remainder.len;
    if (end == 0) return null;
    return remainder[0..end];
}

fn parseTitleFromSubtitlesSearchUrl(allocator: Allocator, url: []const u8) !?[]const u8 {
    const marker = "/subtitles/search/";
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    var remainder = url[start + marker.len ..];
    remainder = std.mem.trimLeft(u8, remainder, "/");

    const id_end = std.mem.indexOfAny(u8, remainder, "?#/") orelse remainder.len;
    if (id_end >= remainder.len) return null;

    var tail = remainder[id_end..];
    tail = std.mem.trimLeft(u8, tail, "/");
    const title_end = std.mem.indexOfAny(u8, tail, "?#/") orelse tail.len;
    if (title_end == 0) return null;

    const raw = tail[0..title_end];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (raw) |c| {
        if (c == '-' or c == '_') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, c);
        }
    }

    const value = try out.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(value);
        return null;
    }
    if (trimmed.len == value.len) return value;
    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(value);
    return duped;
}

fn deriveJsonItemTitle(allocator: Allocator, obj: anytype, id: []const u8) ![]const u8 {
    const candidates = [_][]const u8{ "title", "name", "movie", "show", "label" };
    for (candidates) |key| {
        const v = obj.get(key) orelse continue;
        if (v != .string) continue;
        const trimmed = std.mem.trim(u8, v.string, " \t\r\n");
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    }

    if (obj.get("slug")) |slug_val| {
        if (slug_val == .string and slug_val.string.len > 0) {
            const slug_title = try slugToTitle(allocator, slug_val.string);
            if (slug_title.len > 0) return slug_title;
            allocator.free(slug_title);
        }
    }

    return std.fmt.allocPrint(allocator, "Podnapisi #{s}", .{id});
}

fn deriveHtmlAnchorTitle(allocator: Allocator, anchor: HtmlNode, absolute_url: []const u8, id: []const u8) ![]const u8 {
    const text = try common.innerTextTrimmedOwned(allocator, anchor);
    if (text.len > 0) return text;

    if (common.getAttributeValueSafe(anchor, "title")) |attr_title| {
        const trimmed = std.mem.trim(u8, attr_title, " \t\r\n");
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    }

    if (try parseTitleFromSubtitlesSearchUrl(allocator, absolute_url)) |slug_title| {
        if (slug_title.len > 0) return slug_title;
        allocator.free(slug_title);
    }

    return std.fmt.allocPrint(allocator, "Podnapisi #{s}", .{id});
}

fn slugToTitle(allocator: Allocator, slug: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (slug) |c| {
        if (c == '-' or c == '_') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, c);
        }
    }
    const value = try out.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == value.len) return value;
    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(value);
    return duped;
}

fn hasNextHtmlSearchPage(doc: *const HtmlDocument, current_page: usize) !bool {
    if (doc.queryOne("link[rel='next'][href]")) |_| return true;
    if (doc.queryOne("a[rel='next'][href]")) |_| return true;
    if (doc.queryOne("a.next[href]")) |_| return true;
    if (doc.queryOne(".pagination a.next[href]")) |_| return true;
    if (doc.queryOne("a.page-link[aria-label='Next'][href]")) |_| return true;
    if (doc.queryOne("a.page-link[aria-label*='Next'][href]")) |_| return true;

    var anchors = doc.queryAll("a[href*='page='], a[href*='/page/']");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const page = parsePageNumberFromHref(href) orelse continue;
        if (page > current_page) return true;
    }

    return false;
}

fn parsePageNumberFromHref(href: []const u8) ?usize {
    if (std.mem.indexOf(u8, href, "page=")) |idx| {
        const from = href[idx + "page=".len ..];
        var end: usize = 0;
        while (end < from.len and std.ascii.isDigit(from[end])) : (end += 1) {}
        if (end > 0) return std.fmt.parseInt(usize, from[0..end], 10) catch null;
    }

    if (std.mem.indexOf(u8, href, "/page/")) |idx| {
        const from = href[idx + "/page/".len ..];
        var end: usize = 0;
        while (end < from.len and std.ascii.isDigit(from[end])) : (end += 1) {}
        if (end > 0) return std.fmt.parseInt(usize, from[0..end], 10) catch null;
    }
    return null;
}

fn dedupeSearchItemsById(items: *std.ArrayListUnmanaged(SearchItem)) void {
    var write_idx: usize = 0;
    for (items.items, 0..) |item, read_idx| {
        var seen = false;
        var i: usize = 0;
        while (i < write_idx) : (i += 1) {
            if (std.mem.eql(u8, items.items[i].id, item.id)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (write_idx != read_idx) items.items[write_idx] = item;
        write_idx += 1;
    }
    items.items.len = write_idx;
}

fn debugTimingEnabled() bool {
    const value = std.posix.getenv("SCRAPERS_DEBUG_TIMING") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn findDescendantByTag(node: HtmlNode, tag_name: []const u8) ?HtmlNode {
    for (node.children()) |child_idx| {
        const child = node.doc.nodeAt(child_idx) orelse continue;
        if (std.mem.eql(u8, child.tagName(), tag_name)) return child;
        if (findDescendantByTag(child, tag_name)) |nested| return nested;
    }
    return null;
}

fn findDescendantAnchorByRelNoFollow(node: HtmlNode) ?HtmlNode {
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

fn findDescendantSpanWithClass(node: HtmlNode, class_fragment: []const u8) ?HtmlNode {
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

test "parse podnapisi title slug from url" {
    const allocator = std.testing.allocator;
    const parsed = try parseTitleFromSubtitlesSearchUrl(allocator, "https://www.podnapisi.net/subtitles/search/12345/the-matrix-reloaded");
    defer if (parsed) |value| allocator.free(value);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualStrings("the matrix reloaded", parsed.?);
}

test "live podnapisi search and subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "PODNAPISI")) return error.SkipZigTest;
    if (suite.shouldRunExtensiveLiveSuite(std.testing.allocator)) return error.SkipZigTest;

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
