const std = @import("std");
const common = @import("common.zig");
const cf = @import("opensubtitles_com_cf.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

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

pub const SearchResponse = common.NextSearchResponse(SearchItem);

pub const SubtitlesResponse = common.SubtitlesResponse(SubtitleItem);

pub const Scraper = struct {
    pub const SearchOptions = common.PageOptions;

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

    fn searchWithOptionsUsing(self: *Scraper, comptime fetch: anytype, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        const page_start = if (options.page_start == 0) 1 else options.page_start;
        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;

        var page: usize = page_start;
        var fetched_pages: usize = 0;
        var has_next_page = false;

        while (fetched_pages < max_pages) {
            var page_items: std.ArrayListUnmanaged(SearchItem) = .empty;
            defer page_items.deinit(a);

            var page_has_next = false;

            // JSON endpoint (better metadata) only supports first-page suggestions.
            if (page == 1) {
                try self.appendJsonSearchItemsUsing(fetch, a, trimmed, &page_items);
            }

            try self.appendHtmlSearchItemsUsing(fetch, a, trimmed, page, &page_items, &page_has_next);
            dedupeSearchItemsById(&page_items);

            try items.appendSlice(a, page_items.items);
            has_next_page = page_has_next;
            fetched_pages += 1;
            if (!has_next_page or fetched_pages >= max_pages) break;
            page = try std.math.add(usize, page, 1);
        }

        dedupeSearchItemsById(&items);
        return common.finishResponse(SearchResponse, &arena, .{
            .arena = arena,
            .items = try items.toOwnedSlice(a),
            .has_next_page = has_next_page,
        });
    }

    fn appendJsonSearchItemsUsing(
        self: *Scraper,
        comptime fetch: anytype,
        allocator: Allocator,
        query: []const u8,
        out: *std.ArrayListUnmanaged(SearchItem),
    ) !void {
        const encoded = try common.encodeUriComponent(allocator, query);
        const url = try std.fmt.allocPrint(allocator, "{s}/moviedb/search/?keywords={s}", .{ site, encoded });

        const headers = [_]std.http.Header{.{ .name = "x-requested-with", .value = "XMLHttpRequest" }};
        const response = fetch(self.client, allocator, url, .{
            .accept = "application/json",
            .extra_headers = &headers,
            .cache = false,
            .max_attempts = 3,
            .retry_initial_backoff_ms = 1500,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        }) catch |err| {
            if (common.mustPropagateOptionalFailure(err)) return err;
            return;
        };

        try requireAccessibleResponse(response);
        if (response.status != .ok) return;

        const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, response.body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        const obj = switch (root) {
            .object => |o| o,
            else => return,
        };

        if (obj.get("status")) |status_val| {
            if (status_val == .string and std.ascii.eqlIgnoreCase(status_val.string, "too-many-requests")) return error.RateLimited;
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
            if (!isSafeProviderSegment(id)) continue;

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
            validateProviderEndpoint(subtitles_page_url, .search_result) catch continue;

            try out.append(allocator, .{
                .id = id,
                .title = title,
                .media_type = media_type,
                .year = year,
                .subtitles_page_url = subtitles_page_url,
            });
        }
    }

    fn appendHtmlSearchItemsUsing(
        self: *Scraper,
        comptime fetch: anytype,
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

        const response = try fetch(self.client, allocator, url, .{
            .accept = "text/html",
            .max_attempts = 3,
            .retry_initial_backoff_ms = 1500,
            .allow_non_ok = true,
            .retry_on_429 = false,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        try requireAccessibleResponse(response);
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        var parsed = try common.parseHtmlStable(allocator, response.body);
        has_next_page.* = hasNextHtmlSearchPage(&parsed.doc, page);

        var anchors = parsed.doc.queryAll("a[href*='/subtitles/search/']");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.mem.endsWith(u8, href, "/subtitles/search/")) continue;
            if (std.mem.indexOf(u8, href, "/advanced") != null) continue;

            const absolute = resolveProviderUrl(allocator, href, .search_result) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
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
        return self.fetchSubtitlesBySearchLinkUsing(common.fetchBytes, subtitles_page_url);
    }

    fn fetchSubtitlesBySearchLinkUsing(self: *Scraper, comptime fetch: anytype, subtitles_page_url: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const debug_timing = common.debugTimingEnabled();
        const started_ns = if (debug_timing) common.compatNanoTimestamp() else 0;
        if (debug_timing) {
            const safe_url: []const u8 = common.redactUrlForLog(a, subtitles_page_url) catch "<redacted-url>";
            std.debug.print("[podnapisi.net] subtitles start url={s}\n", .{safe_url});
        }

        try validateProviderEndpoint(subtitles_page_url, .search_result);
        const response = try fetch(self.client, a, subtitles_page_url, .{
            .accept = "text/html",
            .max_attempts = 3,
            .retry_initial_backoff_ms = 1500,
            .allow_non_ok = true,
            .retry_on_429 = false,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        try requireAccessibleResponse(response);
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        var parsed = try common.parseHtmlStable(a, response.body);

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
            const download_url = (try resolveFirstNoFollowDownload(a, row)) orelse continue;

            const language = if (common.findDescendantByTag(row, "abbr")) |node|
                try common.innerTextTrimmedOwned(a, node)
            else
                null;

            const release = if (findDescendantSpanWithClass(row, "release")) |node|
                try common.innerTextTrimmedOwned(a, node)
            else
                null;

            const fps = try common.tableCellTextByColumnIndex(a, row, fps_col);
            const cds = try common.tableCellTextByColumnIndex(a, row, cds_col);
            const rating = try common.tableCellTextByColumnIndex(a, row, rating_col);
            const uploader = try common.tableCellTextByColumnIndex(a, row, uploader_col);
            const uploaded_at = try common.tableCellTextByColumnIndex(a, row, uploaded_at_col);

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
            const elapsed_ns = common.compatNanoTimestamp() - started_ns;
            std.debug.print("[podnapisi.net] subtitles done status={s} rows={d} out={d} in {d} ms\n", .{
                @tagName(response.status),
                row_count,
                out.items.len,
                @divTrunc(elapsed_ns, std.time.ns_per_ms),
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{ .arena = arena, .subtitles = try out.toOwnedSlice(a) });
    }
};

const ProviderRoute = enum { search_result, download };

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
    if (uri.fragment != null) return error.UnsafeHttpTarget;
    var path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (std.mem.indexOf(u8, path, "//") != null) return error.UnsafeHttpTarget;

    var parts: [5][]const u8 = undefined;
    const part_count = splitProviderPath(path, &parts) orelse return error.UnsafeHttpTarget;
    const valid = switch (route) {
        .search_result => (part_count == 3 or part_count == 4) and
            std.mem.eql(u8, parts[0], "subtitles") and
            std.mem.eql(u8, parts[1], "search") and
            isSafeProviderSegment(parts[2]) and
            (part_count == 3 or isSafeProviderSegment(parts[3])) and
            rawQuery(url) == null,
        .download => (part_count == 3 and
            std.mem.eql(u8, parts[0], "subtitles") and
            isSubtitleId(parts[1]) and
            std.mem.eql(u8, parts[2], "download")) or
            (part_count == 5 and
                isProviderLocale(parts[0]) and
                std.mem.eql(u8, parts[1], "subtitles") and
                isSafeProviderSegment(parts[2]) and
                isSubtitleId(parts[3]) and
                std.mem.eql(u8, parts[4], "download")),
    };
    if (!valid) return error.UnsafeHttpTarget;

    if (route == .download) {
        if (rawQuery(url)) |query| {
            if (!std.mem.eql(u8, query, "container=zip")) return error.UnsafeHttpTarget;
        }
    }
}

fn splitProviderPath(path: []const u8, out: *[5][]const u8) ?usize {
    if (path.len < 2 or path[0] != '/') return null;
    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or count == out.len) return null;
        out[count] = segment;
        count += 1;
    }
    return count;
}

fn isSafeProviderSegment(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != '~') return false;
    }
    return true;
}

fn isSubtitleId(value: []const u8) bool {
    if (value.len != 4) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
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

fn rawQuery(url: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    if (start + 1 == url.len) return "";
    return url[start + 1 ..];
}

fn parseIdFromSubtitlesSearchUrl(url: []const u8) ?[]const u8 {
    const marker = "/subtitles/search/";
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.startsWith(u8, path, marker)) return null;
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    const remainder_raw = url[start + marker.len ..];
    const remainder = std.mem.trimStart(u8, remainder_raw, "/");
    const end = std.mem.indexOfAny(u8, remainder, "?#/") orelse remainder.len;
    if (end == 0) return null;
    const id = remainder[0..end];
    if (!isSafeProviderSegment(id)) return null;
    return id;
}

fn parseTitleFromSubtitlesSearchUrl(allocator: Allocator, url: []const u8) !?[]const u8 {
    const marker = "/subtitles/search/";
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    var remainder = url[start + marker.len ..];
    remainder = std.mem.trimStart(u8, remainder, "/");

    const id_end = std.mem.indexOfAny(u8, remainder, "?#/") orelse remainder.len;
    if (id_end >= remainder.len) return null;

    var tail = remainder[id_end..];
    tail = std.mem.trimStart(u8, tail, "/");
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

fn hasNextHtmlSearchPage(doc: *const HtmlDocument, current_page: usize) bool {
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
    const fragment_start = std.mem.indexOfScalar(u8, href, '#') orelse href.len;
    const before_fragment = href[0..fragment_start];
    if (std.mem.indexOfScalar(u8, before_fragment, '?')) |query_start| {
        var fields = std.mem.splitScalar(u8, before_fragment[query_start + 1 ..], '&');
        while (fields.next()) |field| {
            const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            if (!std.mem.eql(u8, field[0..equals], "page")) continue;
            const value = field[equals + 1 ..];
            if (value.len == 0) return null;
            for (value) |c| if (!std.ascii.isDigit(c)) return null;
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }

    const path_end = std.mem.indexOfAny(u8, href, "?#") orelse href.len;
    const path = href[0..path_end];
    if (std.mem.lastIndexOf(u8, path, "/page/")) |idx| {
        const from = path[idx + "/page/".len ..];
        var end: usize = 0;
        while (end < from.len and std.ascii.isDigit(from[end])) : (end += 1) {}
        if (end > 0 and (end == from.len or from[end] == '/'))
            return std.fmt.parseInt(usize, from[0..end], 10) catch null;
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

fn resolveFirstNoFollowDownload(allocator: Allocator, node: HtmlNode) !?[]const u8 {
    var descendants = common.boundedHtmlDescendants(node);
    while (descendants.next()) |child| {
        if (!std.mem.eql(u8, child.tagName(), "a")) continue;
        const rel = common.getAttributeValueSafe(child, "rel") orelse "";
        if (std.mem.indexOf(u8, rel, "nofollow") == null) continue;
        const href = common.getAttributeValueSafe(child, "href") orelse continue;
        const resolved = resolveProviderUrl(allocator, href, .download) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        return resolved;
    }
    return null;
}

fn findDescendantSpanWithClass(node: HtmlNode, class_fragment: []const u8) ?HtmlNode {
    var descendants = common.boundedHtmlDescendants(node);
    while (descendants.next()) |child| {
        if (std.mem.eql(u8, child.tagName(), "span")) {
            const class = common.getAttributeValueSafe(child, "class") orelse "";
            if (std.mem.indexOf(u8, class, class_fragment) != null) return child;
        }
    }
    return null;
}

fn requireAccessibleResponse(response: common.HttpResponse) !void {
    if (response.status == .too_many_requests) return error.RateLimited;
    if (cf.isChallengeBody(response.body)) return error.CloudflareChallenge;
    if (response.status == .unauthorized or response.status == .forbidden or
        common.isAustralianWebsiteBlockPage(response.body)) return error.ProviderAccessBlocked;
}

fn SubtitlesStatusFixture(comptime status: std.http.Status) type {
    return struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            try std.testing.expect(!options.retry_on_429);
            try expectSecureFetchPolicy(options);
            return .{ .status = status, .body = try allocator.dupe(u8, "<html><body>No subtitles found</body></html>") };
        }
    };
}

fn expectSecureFetchPolicy(options: common.FetchOptions) !void {
    try std.testing.expect(options.require_public_origin);
    try std.testing.expect(options.require_https);
    try std.testing.expect(options.require_same_origin);
}

test "podnapisi whitespace search does not fetch" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.TestUnexpectedFetch;
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchWithOptionsUsing(Fixture.fetch, " \t\r\n ", .{});
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "podnapisi pagination rejects page overflow before another fetch" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try expectSecureFetchPolicy(options);
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "<html><head><link rel='next' href='?page=2'></head></html>"),
            };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    try std.testing.expectError(error.Overflow, scraper.searchWithOptionsUsing(Fixture.fetch, "Matrix", .{
        .page_start = std.math.maxInt(usize),
        .max_pages = 2,
    }));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "podnapisi terminal suggestion failures stop before the HTML search fallback" {
    const Scenario = enum { limited, canceled, out_of_memory, forbidden, unauthorized, challenge_ok, challenge_forbidden, challenge_limited };
    const Case = struct { scenario: Scenario, expected_error: anyerror };
    const Fixture = struct {
        client: std.http.Client,
        scenario: Scenario,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqual(@as(usize, 1), self.calls);
            try std.testing.expect(!options.retry_on_429);
            try expectSecureFetchPolicy(options);
            return switch (self.scenario) {
                .limited => .{ .status = .too_many_requests, .body = try allocator.dupe(u8, "limited") },
                .canceled => error.Canceled,
                .out_of_memory => error.OutOfMemory,
                .forbidden => .{ .status = .forbidden, .body = try allocator.dupe(u8, "Forbidden") },
                .unauthorized => .{ .status = .unauthorized, .body = try allocator.dupe(u8, "Unauthorized") },
                .challenge_ok, .challenge_forbidden, .challenge_limited => .{
                    .status = switch (self.scenario) {
                        .challenge_ok => .ok,
                        .challenge_forbidden => .forbidden,
                        else => .too_many_requests,
                    },
                    .body = try allocator.dupe(u8, "<html><title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script></html>"),
                },
            };
        }
    };

    for ([_]Case{
        .{ .scenario = .limited, .expected_error = error.RateLimited },
        .{ .scenario = .canceled, .expected_error = error.Canceled },
        .{ .scenario = .out_of_memory, .expected_error = error.OutOfMemory },
        .{ .scenario = .forbidden, .expected_error = error.ProviderAccessBlocked },
        .{ .scenario = .unauthorized, .expected_error = error.ProviderAccessBlocked },
        .{ .scenario = .challenge_ok, .expected_error = error.CloudflareChallenge },
        .{ .scenario = .challenge_forbidden, .expected_error = error.CloudflareChallenge },
        .{ .scenario = .challenge_limited, .expected_error = error.RateLimited },
    }) |case| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .scenario = case.scenario,
        };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        try std.testing.expectError(case.expected_error, scraper.searchWithOptionsUsing(Fixture.fetch, "Matrix", .{}));
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    }
}

test "podnapisi uses HTML fallback after an ordinary suggestion failure" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try expectSecureFetchPolicy(options);
            if (self.calls == 1) {
                try std.testing.expect(std.mem.indexOf(u8, url, "/moviedb/search/") != null);
                try std.testing.expect(!options.cache);
                return error.ConnectionResetByPeer;
            }
            try std.testing.expect(std.mem.indexOf(u8, url, "/subtitles/search/") != null);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<html><body>No results</body></html>") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchWithOptionsUsing(Fixture.fetch, "Matrix", .{});
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "podnapisi rejects non-ok subtitle pages before empty parsing" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    inline for (.{ std.http.Status.internal_server_error, std.http.Status.bad_gateway, std.http.Status.service_unavailable }) |status| {
        try std.testing.expectError(error.UnexpectedHttpStatus, scraper.fetchSubtitlesBySearchLinkUsing(
            SubtitlesStatusFixture(status).fetch,
            "https://www.podnapisi.net/subtitles/search/12345",
        ));
    }
    inline for (.{ std.http.Status.unauthorized, std.http.Status.forbidden }) |status| {
        try std.testing.expectError(error.ProviderAccessBlocked, scraper.fetchSubtitlesBySearchLinkUsing(
            SubtitlesStatusFixture(status).fetch,
            "https://www.podnapisi.net/subtitles/search/12345",
        ));
    }
    try std.testing.expectError(error.RateLimited, scraper.fetchSubtitlesBySearchLinkUsing(
        SubtitlesStatusFixture(.too_many_requests).fetch,
        "https://www.podnapisi.net/subtitles/search/12345",
    ));
    var response = try scraper.fetchSubtitlesBySearchLinkUsing(
        SubtitlesStatusFixture(.ok).fetch,
        "https://www.podnapisi.net/subtitles/search/12345",
    );
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.subtitles.len);
}

test "podnapisi HTML challenges do not become empty search or subtitle results" {
    const Fixture = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "<html><title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script></html>"),
            };
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    try std.testing.expectError(error.CloudflareChallenge, scraper.searchWithOptionsUsing(Fixture.fetch, "Matrix", .{ .page_start = 2 }));
    try std.testing.expectError(error.CloudflareChallenge, scraper.fetchSubtitlesBySearchLinkUsing(
        Fixture.fetch,
        "https://www.podnapisi.net/subtitles/search/12345",
    ));
}

test "podnapisi rejects unsafe provider links before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/subtitles/search/1", .search_result));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@www.podnapisi.net/subtitles/search/1", .search_result));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://www.google.com/subtitles/search/1", .search_result));
}

test "podnapisi accepts only exact search and download routes" {
    inline for (.{
        "https://www.podnapisi.net/subtitles/search/12345",
        "https://www.podnapisi.net/subtitles/search/tt0133093/the-matrix",
    }) |url| try validateProviderEndpoint(url, .search_result);

    inline for (.{
        "https://www.podnapisi.net/subtitles/GMso/download",
        "https://www.podnapisi.net/subtitles/d_Im/download?container=zip",
        "https://www.podnapisi.net/subtitles/GMso/download?container=zip",
        "https://www.podnapisi.net/en/subtitles/en-man-of-steel-2013/WMgp/download",
        "https://www.podnapisi.net/pt-br/subtitles/man-of-steel-2013/WMgp/download?container=zip",
    }) |url| try validateProviderEndpoint(url, .download);

    const cases = [_]struct { url: []const u8, route: ProviderRoute }{
        .{ .url = "https://www.podnapisi.net/admin", .route = .search_result },
        .{ .url = "https://www.podnapisi.net/subtitles/search/../../admin", .route = .search_result },
        .{ .url = "https://www.podnapisi.net/subtitles/search/%2e%2e/admin", .route = .search_result },
        .{ .url = "https://www.podnapisi.net/subtitles/search/12345?next=/admin", .route = .search_result },
        .{ .url = "https://www.podnapisi.net/admin?next=download", .route = .download },
        .{ .url = "https://www.podnapisi.net/subtitles/too-long/download", .route = .download },
        .{ .url = "https://www.podnapisi.net/subtitles/a%2fb/download", .route = .download },
        .{ .url = "https://www.podnapisi.net/subtitles/GMso/download?next=/admin", .route = .download },
        .{ .url = "https://www.podnapisi.net/admin/subtitles/title/WMgp/download", .route = .download },
        .{ .url = "https://www.podnapisi.net/EN/subtitles/title/WMgp/download", .route = .download },
        .{ .url = "https://www.podnapisi.net/en/subtitles/title/../admin/download", .route = .download },
        .{ .url = "https://www.podnapisi.net/en/subtitles/title/WMgp/download#fragment", .route = .download },
    };
    for (cases) |case| try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(case.url, case.route));

    try std.testing.expect(isSafeProviderSegment("WMgp"));
    try std.testing.expect(isSafeProviderSegment("d_Im"));
    inline for (.{ "", ".", "..", "a/b", "a?b", "%2e%2e" }) |id|
        try std.testing.expect(!isSafeProviderSegment(id));
}

test "podnapisi malformed first nofollow link does not shadow a valid download" {
    const allocator = std.testing.allocator;
    var parsed = try common.parseHtmlStable(
        allocator,
        "<table><tbody><tr>" ++
            "<td><a rel='nofollow' href='/subtitles/too-long/download'>bad</a></td>" ++
            "<td><a rel='nofollow' href='/subtitles/GMso/download?container=zip'>valid</a></td>" ++
            "</tr></tbody></table>",
    );
    defer parsed.deinit();
    const row = parsed.doc.queryOne("tr") orelse return error.TestUnexpectedResult;
    const url = (try resolveFirstNoFollowDownload(allocator, row)) orelse return error.TestUnexpectedResult;
    defer allocator.free(url);
    try std.testing.expectEqualStrings(site ++ "/subtitles/GMso/download?container=zip", url);
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

test "podnapisi page parser requires the exact query key" {
    try std.testing.expectEqual(@as(?usize, 2), parsePageNumberFromHref("?notpage=9&page=2"));
    try std.testing.expectEqual(@as(?usize, 3), parsePageNumberFromHref("?page_size=9&page=3#page=99"));
    try std.testing.expectEqual(@as(?usize, 4), parsePageNumberFromHref("/subtitles/page/4/?notpage=8"));
    try std.testing.expect(parsePageNumberFromHref("?notpage=9") == null);
    try std.testing.expect(parsePageNumberFromHref("?page_size=9") == null);
    try std.testing.expect(parsePageNumberFromHref("?page=2x") == null);
    try std.testing.expect(parsePageNumberFromHref("/subtitles#page=99") == null);
}

test "live podnapisi search and subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "PODNAPISI")) return error.SkipZigTest;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
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
