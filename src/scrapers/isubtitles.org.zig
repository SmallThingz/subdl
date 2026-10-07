const std = @import("std");
const common = @import("common.zig");
const cloudflare = @import("opensubtitles_com_cf.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

const Allocator = std.mem.Allocator;
const site = "https://isubtitles.org";
const max_pagination_page: usize = 128;

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
        return self.searchWithOptionsUsing(common.fetchBytes, query, options);
    }

    fn searchWithOptionsUsing(self: *Scraper, comptime fetch: anytype, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const page_start = if (options.page_start == 0) 1 else options.page_start;
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{
            .arena = arena,
            .items = &.{},
            .page = page_start,
            .has_prev_page = page_start > 1,
            .has_next_page = false,
        };
        if (page_start > max_pagination_page) return error.ResponseTooLarge;

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
        var page = page_start;
        var next_url: ?[]const u8 = null;
        var traversed: usize = 0;
        var last_page = page_start;
        var has_next_page = false;

        while (traversed < max_pages) : (traversed += 1) {
            last_page = page;
            const page_url = if (traversed == 0)
                try buildSearchUrl(a, trimmed, page)
            else if (next_url) |u|
                u
            else
                break;
            const response = try fetchHtmlWith(fetch, self.client, a, page_url);
            if (response.body.len == 0) break;

            maybeDebugLogFirstPage(a, response.status, page_url, response.body.len, traversed);

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
            page = (try checkedNextPage(page)) orelse break;
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
        try validateProviderRoute(details_url, .details_root);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_details_url = try a.dupe(u8, details_url);
        const details_title = detailsTitleSegment(owned_details_url) orelse return error.InvalidDownloadUrl;

        var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        var title: []const u8 = "";

        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
        var page = if (options.page_start == 0) 1 else options.page_start;
        const page_start = page;
        if (page_start > max_pagination_page) return error.ResponseTooLarge;
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
                var download_page_url: ?[]const u8 = null;
                var download_anchors = row.queryAll("td[data-title='Download'] a[href]");
                while (download_anchors.next()) |download_anchor| {
                    const href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
                    const candidate = common.resolveUrl(a, site, href) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        continue;
                    };
                    if (!isDownloadForDetailsTitle(candidate, details_title)) continue;
                    if (seen.contains(candidate)) continue;
                    download_page_url = candidate;
                    break;
                }
                const resolved_download_page_url = download_page_url orelse continue;
                try seen.put(a, resolved_download_page_url, {});

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
                    .download_page_url = resolved_download_page_url,
                });
            }

            next_url = try extractNextPageUrl(a, &parsed.doc, page_url);
            has_next_page = next_url != null;
            if (traversed + 1 >= max_pages) break;
            if (next_url == null) break;
            page = (try checkedNextPage(page)) orelse break;
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
    try validateProviderPageUrl(url);
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

const ProviderRoute = enum {
    search_page,
    details_root,
    details_page,
    download_page,
};

fn validateProviderPageUrl(url: []const u8) !void {
    if (isProviderRoute(url, .search_page) or isProviderRoute(url, .details_page)) return;
    return error.InvalidDownloadUrl;
}

fn validateProviderRoute(url: []const u8, route: ProviderRoute) !void {
    common.validatePublicHttpUrl(url) catch return error.InvalidDownloadUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
    if (uri.fragment != null) return error.InvalidDownloadUrl;

    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const query = if (uri.query) |component| switch (component) {
        .raw, .percent_encoded => |value| value,
    } else null;

    const valid = switch (route) {
        .search_page => std.mem.eql(u8, path, "/search") and
            query != null and isCanonicalSearchQuery(query.?),
        .details_root => isCanonicalDetailsPath(path) and query == null,
        .details_page => isCanonicalDetailsPath(path) and
            (query == null or isCanonicalPageQuery(query.?)),
        .download_page => isCanonicalDownloadPath(path) and query == null,
    };
    if (!valid) return error.InvalidDownloadUrl;
}

fn isProviderRoute(url: []const u8, route: ProviderRoute) bool {
    validateProviderRoute(url, route) catch return false;
    return true;
}

fn isCanonicalSearchQuery(query: []const u8) bool {
    const prefix = "kwd=";
    if (!std.mem.startsWith(u8, query, prefix)) return false;
    const rest = query[prefix.len..];
    const page_marker = std.mem.indexOf(u8, rest, "&p=");
    const keyword = if (page_marker) |index| rest[0..index] else rest;
    if (!isCanonicalQueryValue(keyword)) return false;
    if (page_marker) |index| return isCanonicalPageNumber(rest[index + "&p=".len ..]);
    return true;
}

fn isCanonicalQueryValue(value: []const u8) bool {
    if (value.len == 0) return false;
    var index: usize = 0;
    while (index < value.len) {
        const c = value[index];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '+') {
            index += 1;
            continue;
        }
        if (c != '%' or value.len - index < 3 or
            !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return false;
        index += 3;
    }
    return true;
}

fn isCanonicalDetailsPath(path: []const u8) bool {
    const suffix = "-subtitles";
    if (path.len <= 1 + suffix.len or path[0] != '/' or !std.mem.endsWith(u8, path, suffix)) return false;
    return isCanonicalPathSegment(path[1 .. path.len - suffix.len]);
}

fn isCanonicalDownloadPath(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    if (!std.mem.eql(u8, segments.next() orelse return false, "")) return false;
    if (!std.mem.eql(u8, segments.next() orelse return false, "download")) return false;
    const title = segments.next() orelse return false;
    const language = segments.next() orelse return false;
    const id = segments.next() orelse return false;
    return segments.next() == null and
        isCanonicalPathSegment(title) and
        isCanonicalPathSegment(language) and
        isCanonicalPositiveDecimal(id);
}

fn detailsTitleSegment(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const suffix = "-subtitles";
    if (!isCanonicalDetailsPath(path)) return null;
    return path[1 .. path.len - suffix.len];
}

fn downloadTitleSegment(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    var segments = std.mem.splitScalar(u8, path, '/');
    if (!std.mem.eql(u8, segments.next() orelse return null, "") or
        !std.mem.eql(u8, segments.next() orelse return null, "download"))
    {
        return null;
    }
    return segments.next();
}

fn isDownloadForDetailsTitle(url: []const u8, details_title: []const u8) bool {
    if (!isProviderRoute(url, .download_page)) return false;
    const download_title = downloadTitleSegment(url) orelse return false;
    return encodedPathSegmentsEqual(details_title, download_title);
}

fn encodedPathSegmentsEqual(lhs: []const u8, rhs: []const u8) bool {
    var lhs_index: usize = 0;
    var rhs_index: usize = 0;
    while (lhs_index < lhs.len and rhs_index < rhs.len) {
        const lhs_byte = nextEncodedPathByte(lhs, &lhs_index) orelse return false;
        const rhs_byte = nextEncodedPathByte(rhs, &rhs_index) orelse return false;
        if (lhs_byte != rhs_byte) return false;
    }
    return lhs_index == lhs.len and rhs_index == rhs.len;
}

fn nextEncodedPathByte(value: []const u8, index: *usize) ?u8 {
    if (index.* >= value.len) return null;
    const byte = value[index.*];
    if (byte != '%') {
        index.* += 1;
        return byte;
    }
    if (value.len - index.* < 3) return null;
    const high = std.fmt.charToDigit(value[index.* + 1], 16) catch return null;
    const low = std.fmt.charToDigit(value[index.* + 2], 16) catch return null;
    index.* += 3;
    return @intCast(high * 16 + low);
}

fn isCanonicalPathSegment(value: []const u8) bool {
    if (value.len == 0 or value.len > 512 or
        std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    var decoded: [512]u8 = undefined;
    var decoded_len: usize = 0;
    var index: usize = 0;
    while (index < value.len) {
        const c = value[index];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            decoded[decoded_len] = c;
            decoded_len += 1;
            index += 1;
            continue;
        }
        if (c != '%' or value.len - index < 3 or
            !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return false;
        const byte = percentEncodedByte(value[index + 1], value[index + 2]) orelse return false;
        // ASCII has a canonical unescaped spelling in provider path segments.
        // Rejecting its escaped form also closes double-decoded separators,
        // controls, query/fragment delimiters, and encoded percent signs.
        if (byte < 0x80) return false;
        decoded[decoded_len] = byte;
        decoded_len += 1;
        index += 3;
    }
    return std.unicode.utf8ValidateSlice(decoded[0..decoded_len]);
}

fn percentEncodedByte(high: u8, low: u8) ?u8 {
    const high_value = hexNibble(high) orelse return null;
    const low_value = hexNibble(low) orelse return null;
    return (high_value << 4) | low_value;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn isCanonicalPageQuery(query: []const u8) bool {
    const prefix = "p=";
    return std.mem.startsWith(u8, query, prefix) and
        isCanonicalPageNumber(query[prefix.len..]);
}

fn isCanonicalPageNumber(value: []const u8) bool {
    if (!isCanonicalPositiveDecimal(value)) return false;
    _ = std.fmt.parseInt(usize, value, 10) catch return false;
    return true;
}

fn isCanonicalPositiveDecimal(value: []const u8) bool {
    if (value.len == 0 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
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
        const raw_title = try common.innerTextTrimmedOwned(allocator, anchor);
        errdefer allocator.free(raw_title);
        const split = splitTitleAndYear(raw_title);
        if (split.title.len == 0) {
            allocator.free(raw_title);
            continue;
        }

        const details_url = common.resolveUrl(allocator, site, href) catch |err| {
            if (err == error.OutOfMemory) return err;
            allocator.free(raw_title);
            continue;
        };
        errdefer allocator.free(details_url);
        if (!isProviderRoute(details_url, .details_root)) {
            allocator.free(details_url);
            allocator.free(raw_title);
            continue;
        }
        if (seen.contains(details_url)) {
            allocator.free(details_url);
            allocator.free(raw_title);
            continue;
        }

        try out.ensureUnusedCapacity(allocator, 1);
        try seen.ensureUnusedCapacity(allocator, 1);
        seen.putAssumeCapacityNoClobber(details_url, {});
        out.appendAssumeCapacity(.{
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
    const href_prefix = "href=\"";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, href_prefix)) |href_marker| {
        const href_start = href_marker + href_prefix.len;
        const next_href_marker = std.mem.indexOfPos(u8, body, href_start, href_prefix);
        const href_end = std.mem.indexOfScalarPos(u8, body, href_start, '"') orelse break;
        if (next_href_marker) |next_marker| {
            if (next_marker < href_end) {
                cursor = next_marker;
                continue;
            }
        }
        cursor = href_end + 1;

        const href = body[href_start..href_end];
        if (!std.mem.startsWith(u8, href, "/")) continue;
        if (!std.mem.endsWith(u8, href, "-subtitles")) continue;
        if (std.mem.indexOf(u8, href, "/gender/") != null) continue;
        if (std.mem.indexOf(u8, href, "/country/") != null) continue;
        if (std.mem.indexOf(u8, href, "/search") != null) continue;

        const tag_end = std.mem.indexOfScalarPos(u8, body, href_end, '>') orelse continue;
        if (next_href_marker) |next_marker| {
            if (next_marker < tag_end) {
                cursor = next_marker;
                continue;
            }
        }
        const text_end = std.mem.indexOfPos(u8, body, tag_end + 1, "</a>") orelse continue;
        if (next_href_marker) |next_marker| {
            if (next_marker < text_end) {
                cursor = next_marker;
                continue;
            }
        }
        const raw_title = std.mem.trim(u8, body[tag_end + 1 .. text_end], " \t\r\n");
        if (raw_title.len == 0) continue;

        const details_url = common.resolveUrl(allocator, site, href) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        errdefer allocator.free(details_url);
        if (!isProviderRoute(details_url, .details_root)) {
            allocator.free(details_url);
            continue;
        }
        if (seen.contains(details_url)) {
            allocator.free(details_url);
            continue;
        }

        const split = splitTitleAndYear(raw_title);
        if (split.title.len == 0) {
            allocator.free(details_url);
            continue;
        }

        try out.ensureUnusedCapacity(allocator, 1);
        try seen.ensureUnusedCapacity(allocator, 1);
        seen.putAssumeCapacityNoClobber(details_url, {});
        out.appendAssumeCapacity(.{
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

fn checkedNextPage(page: usize) !?usize {
    if (page >= max_pagination_page) return null;
    return try std.math.add(usize, page, 1);
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

    var best_next_url: ?[]const u8 = null;
    var best_next_page: ?usize = null;

    var anchors = doc.queryAll("a[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const resolved = common.resolveUrl(temp, site, href) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        if (!isCanonicalPaginationSuccessor(current_url, resolved)) continue;

        if (pageFromUrl(resolved)) |candidate_page| {
            if (candidate_page > current_page) {
                if (best_next_page == null or candidate_page < best_next_page.?) {
                    best_next_page = candidate_page;
                    best_next_url = resolved;
                }
            }
        }
    }

    if (best_next_url) |resolved| return try allocator.dupe(u8, resolved);
    return null;
}

fn isCanonicalPaginationSuccessor(current_url: []const u8, candidate_url: []const u8) bool {
    const current_route = providerPageRoute(current_url) orelse return false;
    const candidate_route = providerPageRoute(candidate_url) orelse return false;
    if (current_route != candidate_route) return false;

    const current_uri = std.Uri.parse(current_url) catch return false;
    const candidate_uri = std.Uri.parse(candidate_url) catch return false;
    const current_path = switch (current_uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const candidate_path = switch (candidate_uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, current_path, candidate_path)) return false;

    if (current_route == .search_page) {
        const current_keyword = searchKeywordFromUrl(current_url) orelse return false;
        const candidate_keyword = searchKeywordFromUrl(candidate_url) orelse return false;
        if (!std.mem.eql(u8, current_keyword, candidate_keyword)) return false;
    }

    const current_page = pageFromUrl(current_url) orelse 1;
    const expected_page = (checkedNextPage(current_page) catch return false) orelse return false;
    const candidate_page = pageFromUrl(candidate_url) orelse return false;
    return candidate_page == expected_page;
}

fn providerPageRoute(url: []const u8) ?ProviderRoute {
    if (isProviderRoute(url, .search_page)) return .search_page;
    if (isProviderRoute(url, .details_page)) return .details_page;
    return null;
}

fn searchKeywordFromUrl(url: []const u8) ?[]const u8 {
    if (!isProviderRoute(url, .search_page)) return null;
    const uri = std.Uri.parse(url) catch return null;
    const component = uri.query orelse return null;
    const query = switch (component) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "kwd=";
    const rest = query[prefix.len..];
    const end = std.mem.indexOf(u8, rest, "&p=") orelse rest.len;
    return rest[0..end];
}

fn maybeDebugLogFirstPage(allocator: Allocator, status: std.http.Status, page_url: []const u8, body_len: usize, traversed: usize) void {
    if (traversed != 0) return;
    if (common.getenv("SCRAPERS_DEBUG_ISUB") == null) return;

    const safe_url: []const u8 = common.redactUrlForLog(allocator, page_url) catch "<redacted-url>";
    std.debug.print("[isubtitles] status={d} body_len={d} url={s}\n", .{ @backingInt(status), body_len, safe_url });
}

fn isLikelyNextText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.ascii.findIgnoreCase(text, "next") != null) return true;
    return std.mem.eql(u8, text, ">") or std.mem.eql(u8, text, "›") or std.mem.eql(u8, text, "»");
}

fn pageFromUrl(url: []const u8) ?usize {
    const uri = std.Uri.parse(url) catch return null;
    const component = uri.query orelse return null;
    const query = switch (component) {
        .raw, .percent_encoded => |value| value,
    };

    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..eq_idx];
        if (!std.mem.eql(u8, key, "p")) continue;

        const value = field[eq_idx + 1 ..];
        if (!isCanonicalPositiveDecimal(value)) continue;
        return std.fmt.parseInt(usize, value, 10) catch return null;
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

test "isubtitles pagination counter is checked and capped" {
    try std.testing.expectEqual(@as(?usize, 2), try checkedNextPage(1));
    try std.testing.expectEqual(@as(?usize, max_pagination_page), try checkedNextPage(max_pagination_page - 1));
    try std.testing.expect((try checkedNextPage(max_pagination_page)) == null);
    try std.testing.expect((try checkedNextPage(std.math.maxInt(usize))) == null);
}

test "isubtitles rejects page starts beyond its request ceiling before I/O" {
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
    try std.testing.expectError(error.ResponseTooLarge, scraper.searchWithOptionsUsing(Fixture.fetch, "Matrix", .{
        .page_start = max_pagination_page + 1,
    }));
    try std.testing.expectError(error.ResponseTooLarge, scraper.fetchSubtitlesByMovieLinkWithOptionsUsing(
        Fixture.fetch,
        site ++ "/the-matrix-subtitles",
        .{ .page_start = max_pagination_page + 1 },
    ));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "isubtitles pagination accepts only the checked immediate successor" {
    try std.testing.expect(isCanonicalPaginationSuccessor(
        site ++ "/search?kwd=matrix&p=2",
        site ++ "/search?kwd=matrix&p=3",
    ));
    try std.testing.expect(!isCanonicalPaginationSuccessor(
        site ++ "/search?kwd=matrix&p=2",
        site ++ "/search?kwd=matrix&p=5",
    ));
    try std.testing.expect(!isCanonicalPaginationSuccessor(
        site ++ "/search?kwd=matrix&p=128",
        site ++ "/search?kwd=matrix&p=129",
    ));
}

test "isubtitles accepts only exact canonical provider routes" {
    try validateProviderRoute(site ++ "/search?kwd=the+matrix&p=2", .search_page);
    try validateProviderRoute(site ++ "/the-matrix-subtitles", .details_root);
    try validateProviderRoute(site ++ "/the-matrix-subtitles?p=2", .details_page);
    try validateProviderRoute(site ++ "/download/the-matrix/english/123", .download_page);

    const invalid = [_]struct { url: []const u8, route: ProviderRoute }{
        .{ .url = "http://127.0.0.1/the-matrix-subtitles", .route = .details_page },
        .{ .url = "https://isubtitles.org.example/the-matrix-subtitles", .route = .details_page },
        .{ .url = "https://user@isubtitles.org/the-matrix-subtitles", .route = .details_page },
        .{ .url = "http://isubtitles.org/the-matrix-subtitles", .route = .details_page },
        .{ .url = site ++ "/admin?p=2", .route = .details_page },
        .{ .url = site ++ "/the-matrix-subtitles?p=2", .route = .details_root },
        .{ .url = site ++ "/the-matrix-subtitles/extra", .route = .details_page },
        .{ .url = site ++ "/the-matrix-subtitles?page=2", .route = .details_page },
        .{ .url = site ++ "/the-matrix-subtitles?p=2&next=/admin", .route = .details_page },
        .{ .url = site ++ "/the-matrix-subtitles#fragment", .route = .details_page },
        .{ .url = site ++ "/search?kwd=matrix&next=/admin", .route = .search_page },
        .{ .url = site ++ "/search?kwd=matrix&p=02", .route = .search_page },
        .{ .url = site ++ "/download/123", .route = .download_page },
        .{ .url = site ++ "/download/the-matrix/english/123?next=/admin", .route = .download_page },
        .{ .url = site ++ "/download/the-matrix/english/123/extra", .route = .download_page },
        .{ .url = site ++ "/download/the-matrix%2f..%2fadmin/english/123", .route = .download_page },
        .{ .url = site ++ "/download/the-matrix%252f..%252fadmin/english/123", .route = .download_page },
        .{ .url = site ++ "/download/the-matrix%00/english/123", .route = .download_page },
        .{ .url = site ++ "/download/the-matrix%3fnext/english/123", .route = .download_page },
        .{ .url = site ++ "/download/the-matrix%23fragment/english/123", .route = .download_page },
        .{ .url = site ++ "/download/the-matrix%C0%AFadmin/english/123", .route = .download_page },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderRoute(case.url, case.route));
    }

    try validateProviderRoute(site ++ "/am%C3%A9lie-subtitles", .details_root);
    try validateProviderRoute(site ++ "/download/am%C3%A9lie/french/123", .download_page);
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
                    "<section><table class='table'>" ++
                        "<tr><td data-title='Download'><a href='/admin?download=123'>Bad</a></td></tr>" ++
                        "<tr><td data-title='Download'><a href='/download/123'>Bad</a></td></tr>" ++
                        "<tr><td data-title='Download'><a href='/download/the-matrix/english/123/extra'>Bad</a></td></tr>" ++
                        "<tr>" ++
                        "<td data-title='Language'><a>English</a></td>" ++
                        "<td data-title='Release / Movie'><a>The.Matrix.1999</a></td>" ++
                        "<td data-title='Download'><a href='/download/the-matrix/english/123'>Download</a></td>" ++
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
    try std.testing.expectEqualStrings(site ++ "/download/the-matrix/english/123", response.subtitles[0].download_page_url);
    @memset(&details_url, 'x');
    try std.testing.expectEqualStrings(site ++ "/the-matrix-subtitles", response.subtitles[0].details_url);
}

test "isubtitles binds download title and scans all row anchors" {
    const Fixture = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{
                .status = .ok,
                .body = try allocator.dupe(
                    u8,
                    "<section><table class='table'><tr>" ++
                        "<td data-title='Language'><a>English</a></td>" ++
                        "<td data-title='Release / Movie'><a>The.Matrix.1999</a></td>" ++
                        "<td data-title='Download'>" ++
                        "<a href='/download/another-title/english/123'>Wrong title</a>" ++
                        "<a href='/download/123'>Malformed</a>" ++
                        "<a href='/download/the-matrix/english/456'>Download</a>" ++
                        "</td></tr></table></section>",
                ),
            };
        }
    };

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.fetchSubtitlesByMovieLinkWithOptionsUsing(
        Fixture.fetch,
        site ++ "/the-matrix-subtitles",
        .{},
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    try std.testing.expectEqualStrings(
        site ++ "/download/the-matrix/english/456",
        response.subtitles[0].download_page_url,
    );
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

test "isubtitles trims queries and does not fetch empty searches" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(site ++ "/search?kwd=Matrix", url);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);

    var empty = try scraper.searchWithOptionsUsing(Fixture.fetch, " \t\r\n ", .{ .page_start = 3 });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectEqual(@as(usize, 3), empty.page);
    try std.testing.expect(empty.has_prev_page);
    try std.testing.expect(!empty.has_next_page);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    var trimmed = try scraper.searchWithOptionsUsing(Fixture.fetch, "  Matrix\t", .{});
    defer trimmed.deinit();
    try std.testing.expectEqual(@as(usize, 0), trimmed.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "isubtitles malformed duplicate does not suppress a valid search title" {
    const Fixture = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{
                .status = .ok,
                .body = try allocator.dupe(
                    u8,
                    "<div class=\"movie-list-info\"><h3>" ++
                        "<a href=\"/admin/the-matrix-subtitles?next=/private\">Malicious sibling</a>" ++
                        "<a href=\"/the-matrix-subtitles\"></a>" ++
                        "<a href=\"/the-matrix-subtitles\">The Matrix - (1999)</a>" ++
                        "</h3></div>",
                ),
            };
        }
    };

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.searchWithOptionsUsing(Fixture.fetch, "The Matrix", .{});
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqualStrings("1999", response.items[0].year.?);
}

test "isubtitles raw fallback recovers after a malformed first anchor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var seen = std.StringHashMapUnmanaged(void).empty;
    var out = std.ArrayListUnmanaged(SearchItem).empty;
    try collectSearchItemsFromRawHtml(
        a,
        "<a href=\"/broken-subtitles<a href=\"/the-matrix-subtitles\">The Matrix - (1999)</a>",
        &seen,
        &out,
    );

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("The Matrix", out.items[0].title);
    try std.testing.expectEqualStrings("1999", out.items[0].year.?);
    try std.testing.expectEqualStrings(site ++ "/the-matrix-subtitles", out.items[0].details_url);
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

test "isubtitles pager ignores malicious and cross-query siblings" {
    const a = std.testing.allocator;
    const html_source =
        \\<div class="paging">
        \\  <a rel="next" href="/admin?p=2">Next</a>
        \\  <a href="/search?kwd=other&p=2">2</a>
        \\  <a href="/the-matrix-subtitles?p=2">2</a>
        \\  <a href="/search?kwd=matrix&page=2">2</a>
        \\  <a href="/search?kwd=matrix&p=3">3</a>
        \\  <a href="/search?kwd=matrix&p=2">2</a>
        \\</div>
    ;

    var parsed = try common.parseHtmlStable(a, html_source);
    defer parsed.deinit();

    const next = try extractNextPageUrl(a, &parsed.doc, site ++ "/search?kwd=matrix");
    try std.testing.expect(next != null);
    defer a.free(next.?);
    try std.testing.expectEqualStrings(site ++ "/search?kwd=matrix&p=2", next.?);
}
