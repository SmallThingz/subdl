const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;
// Search and listing pages are small HTML documents. Keep their decoded and
// encoded representations bounded independently of the much larger raw
// subtitle-download allowance below.
const max_html_response_bytes: usize = 4 * 1024 * 1024;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://greeksubs.net";
const search_url = site ++ "/en/search";
// Bound provider-controlled card and row counts independently of response bytes.
const max_search_items: usize = 24;
const max_subtitle_items: usize = 24;
const max_productive_season_pages: usize = 8;
// Fallback follows at most 24 distinct logical pages. Each logical fetch can
// make two transport attempts, for a worst-case 48 season-page attempts.
const max_logical_season_pages: usize = 24;
const max_transport_attempts_per_fetch: usize = 2;
const max_season_transport_attempts: usize = max_logical_season_pages * max_transport_attempts_per_fetch;
const max_fallback_subtitles: usize = max_subtitle_items;

pub const download_token_prefix = "greeksubs-session:";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    id: []const u8,
    language_code: ?[]const u8,
    filename: []const u8,
    download_url: []const u8,
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
        const normalized_query = try common.normalizeTitle(a, trimmed);
        if (normalized_query.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const payload = try std.fmt.allocPrint(a, "searchval={s}&searchtype=all", .{encoded});
        const response = try fetch(self.client, a, search_url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_response_bytes = max_html_response_bytes,
            .max_encoded_response_bytes = max_html_response_bytes,
            .max_attempts = max_transport_attempts_per_fetch,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
        });
        if (response.status == .too_many_requests) return error.RateLimited;
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemUsing(common.fetchBytes, item);
    }

    fn fetchSubtitlesBySearchItemUsing(self: *Scraper, comptime fetch: anytype, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var page_scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer page_scratch.deinit();
        const page_allocator = page_scratch.allocator();

        try validateViewPageUrl(item.page_url);

        const response = try fetch(self.client, page_allocator, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_response_bytes = max_html_response_bytes,
            .max_encoded_response_bytes = max_html_response_bytes,
            .max_attempts = max_transport_attempts_per_fetch,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
        });
        if (response.status == .too_many_requests) return error.RateLimited;
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        try collectSubtitleRows(page_allocator, a, response.body, item.page_url, &subtitles, &seen, max_subtitle_items);

        if (subtitles.items.len == 0 and item.media_kind == .tv) {
            var parsed = try common.parseHtmlStable(page_allocator, response.body);
            defer parsed.deinit();
            var links = parsed.doc.queryAll("a[href*='/en/view/']");
            // Empty and recoverably failed pages consume the fetch budget, but not
            // the smaller productive-page cap. This lets later seasons contribute
            // without allowing an unbounded number of child requests.
            var productive_pages: usize = 0;
            var logical_pages_fetched: usize = 0;
            var seen_pages = std.StringHashMapUnmanaged(void).empty;
            if (viewPageRouteId(item.page_url)) |root_page_id| {
                try seen_pages.put(page_allocator, root_page_id, {});
            }
            var child_scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer child_scratch.deinit();
            while (links.next()) |link| {
                if (productive_pages >= max_productive_season_pages or
                    logical_pages_fetched >= max_logical_season_pages or
                    subtitles.items.len >= max_fallback_subtitles) break;
                const href = common.getAttributeValueSafe(link, "href") orelse continue;
                const text = try common.innerTextTrimmedOwned(page_allocator, link);
                if (std.ascii.findIgnoreCase(text, "Season") == null) continue;
                const page_url = try common.resolveUrl(page_allocator, site, href);
                validateViewPageUrl(page_url) catch continue;
                const page_id = viewPageRouteId(page_url) orelse continue;
                if (seen_pages.contains(page_id)) continue;
                try seen_pages.put(page_allocator, page_id, {});
                logical_pages_fetched += 1;

                _ = child_scratch.reset(.retain_capacity);
                const child_allocator = child_scratch.allocator();
                const child = fetch(self.client, child_allocator, page_url, .{
                    .accept = "text/html,application/xhtml+xml,*/*",
                    .cache = false,
                    .max_response_bytes = max_html_response_bytes,
                    .max_encoded_response_bytes = max_html_response_bytes,
                    .max_attempts = max_transport_attempts_per_fetch,
                    .retry_on_429 = false,
                    .allow_non_ok = true,
                    .require_public_origin = true,
                }) catch |err| {
                    if (common.mustPropagateOptionalFailure(err)) return err;
                    continue;
                };
                if (child.status == .too_many_requests) return error.RateLimited;
                if (child.status != .ok) continue;
                const previous_len = subtitles.items.len;
                try collectSubtitleRows(
                    child_allocator,
                    a,
                    child.body,
                    page_url,
                    &subtitles,
                    &seen,
                    max_fallback_subtitles,
                );
                if (subtitles.items.len > previous_len) productive_pages += 1;
            }
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateViewPageUrl(parts.page_url);
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;
        var page = try fetchRaw(self.client, allocator, parts.page_url, &.{}, deadline_ms);
        defer page.deinit(allocator);
        if (page.status == .too_many_requests) return error.RateLimited;
        if (page.status != .ok) return error.UnexpectedHttpStatus;
        const cookie = page.cookie orelse return error.SessionExpired;

        const sec_code = parseSecCode(page.body) orelse return error.MissingField;
        if (!pageContainsDownloadId(page.body, parts.subtitle_id)) return error.MissingField;

        const url = try std.fmt.allocPrint(allocator, "{s}/dll/{s}/0/{s}", .{ site, parts.subtitle_id, sec_code });
        defer allocator.free(url);
        const headers = [_]std.http.Header{
            .{ .name = "cookie", .value = cookie },
            .{ .name = "referer", .value = parts.page_url },
            .{ .name = "accept", .value = "application/octet-stream,text/plain,*/*" },
        };
        const download = try fetchRaw(self.client, allocator, url, &headers, deadline_ms);
        defer if (download.cookie) |value| allocator.free(value);
        if (download.status != .ok) {
            allocator.free(download.body);
            if (download.status == .too_many_requests) return error.RateLimited;
            return error.UnexpectedHttpStatus;
        }
        return .{ .status = download.status, .body = download.body };
    }
};

fn collectSubtitleRows(
    parse_allocator: Allocator,
    result_allocator: Allocator,
    body: []const u8,
    page_url: []const u8,
    subtitles: *std.ArrayListUnmanaged(SubtitleItem),
    seen: *std.StringHashMapUnmanaged(void),
    max_results: ?usize,
) !void {
    var parsed = try common.parseHtmlStable(parse_allocator, body);
    defer parsed.deinit();
    var rows = parsed.doc.queryAll("table tbody tr");
    while (rows.next()) |row| {
        if (max_results) |limit| {
            if (subtitles.items.len >= limit) break;
        }
        var buttons = row.queryAll("button[onclick]");
        var parsed_id: ?[]const u8 = null;
        while (buttons.next()) |button| {
            const onclick = common.getAttributeValueSafe(button, "onclick") orelse continue;
            const candidate = parseDownloadId(onclick) orelse continue;
            if (seen.contains(candidate)) continue;
            parsed_id = candidate;
            break;
        }
        const id = parsed_id orelse continue;
        const filename_base = try tableCellText(parse_allocator, row, 6) orelse continue;
        if (filename_base.len == 0) continue;
        try subtitles.ensureUnusedCapacity(result_allocator, 1);
        try seen.ensureUnusedCapacity(result_allocator, 1);

        const filename = if (hasKnownDownloadExtension(filename_base))
            try result_allocator.dupe(u8, filename_base)
        else
            try std.fmt.allocPrint(result_allocator, "{s}.srt", .{filename_base});
        errdefer result_allocator.free(filename);

        const language_code = if (row.queryOne("img[alt]")) |img|
            try common.dupOptional(result_allocator, common.getAttributeValueSafe(img, "alt"))
        else
            null;
        errdefer if (language_code) |value| result_allocator.free(value);
        const owned_id = try result_allocator.dupe(u8, id);
        errdefer result_allocator.free(owned_id);
        const download_url = try makeDownloadToken(result_allocator, id, page_url);
        errdefer result_allocator.free(download_url);

        const subtitle: SubtitleItem = .{
            .id = owned_id,
            .language_code = language_code,
            .filename = filename,
            .download_url = download_url,
        };
        seen.putAssumeCapacityNoClobber(owned_id, {});
        subtitles.appendAssumeCapacity(subtitle);
    }
}

const RawResponse = common.RawResponse;

fn fetchRaw(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    extra_headers: []const std.http.Header,
    deadline_ms: i64,
) !RawResponse {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;

    const FetchTask = struct {
        fn run(
            result: *?RawResponse,
            task_client: *std.http.Client,
            task_allocator: Allocator,
            task_url: []const u8,
            task_headers: []const std.http.Header,
        ) !void {
            result.* = try fetchRawUnbounded(task_client, task_allocator, task_url, task_headers);
        }
    };
    const FetchResult = @typeInfo(@TypeOf(FetchTask.run)).@"fn".return_type.?;
    const TimeoutResult = @typeInfo(@TypeOf(std.Io.Timeout.sleep)).@"fn".return_type.?;
    const Selection = union(enum) {
        fetch: FetchResult,
        timeout: TimeoutResult,
    };
    var selection_buffer: [2]Selection = undefined;
    var selection = std.Io.Select(Selection).init(client.io, &selection_buffer);
    var owned_response: ?RawResponse = null;
    defer {
        selection.cancelDiscard();
        if (owned_response) |*response| response.deinit(allocator);
    }

    const remaining_ms: i64 = deadline_ms -| now_ms;
    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(client.io, .{
        .raw = std.Io.Duration.fromMilliseconds(remaining_ms),
        .clock = .awake,
    }) };
    try selection.concurrent(.fetch, FetchTask.run, .{ &owned_response, client, allocator, url, extra_headers });
    try selection.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, client.io });

    switch (try selection.await()) {
        .fetch => |result| {
            try result;
            const response = owned_response orelse return error.MissingHttpResponse;
            owned_response = null;
            return response;
        },
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}

fn fetchRawUnbounded(client: *std.http.Client, allocator: Allocator, url: []const u8, extra_headers: []const std.http.Header) !RawResponse {
    try validateProviderUrl(url);
    try common.validateHttpHeaders(extra_headers);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

    var public_client: std.http.Client = undefined;
    try common.initPublicOriginClient(client, &public_client);
    defer public_client.deinit();
    const pinned_connection = try common.connectPinnedPublicHttpUrl(&public_client, allocator, normalized);
    pinned_connection.closing = true;

    var req = public_client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .handle_continue = false,
        .keep_alive = false,
        .connection = pinned_connection,
        .headers = .{
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra_headers,
    }) catch |err| {
        public_client.connection_pool.release(pinned_connection, public_client.io);
        return err;
    };
    defer req.deinit();
    errdefer req.connection.?.closing = true;
    req.sendBodiless() catch |err| return common.normalizeRequestWriteError(&req, err);

    var head_buffer: [16 * 1024]u8 = undefined;
    var response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    var interim_count: usize = 0;
    while (response.head.status.class() == .informational) {
        if (response.head.status == .switching_protocols) return error.UnsupportedProtocolUpgrade;
        try validateRawSessionResponseHead(response.head);
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    try validateRawSessionResponseHead(response.head);
    const status = response.head.status;
    const cookie = try common.extractPhpSessionCookie(allocator, response.head.bytes);
    errdefer if (cookie) |value| allocator.free(value);

    const body = try common.readStrictResponseBody(&req, &response, allocator, max_raw_response_bytes);
    errdefer allocator.free(body);

    return .{
        .status = status,
        .body = body,
        .cookie = cookie,
    };
}

fn validateRawSessionResponseHead(head: std.http.Client.Response.Head) !void {
    try common.validateResponseFraming(head);
}

fn validateProviderUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
}

fn validateViewPageUrl(url: []const u8) !void {
    try validateProviderUrl(url);
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    var segments = std.mem.splitScalar(u8, path, '/');
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidDownloadUrl, "") or
        !std.mem.eql(u8, segments.next() orelse return error.InvalidDownloadUrl, "en") or
        !std.mem.eql(u8, segments.next() orelse return error.InvalidDownloadUrl, "view"))
    {
        return error.InvalidDownloadUrl;
    }
    const source_id = segments.next() orelse return error.InvalidDownloadUrl;
    const slug = segments.next() orelse return error.InvalidDownloadUrl;
    if (segments.next() != null or !isCanonicalViewId(source_id) or !isCanonicalViewSlug(slug))
        return error.InvalidDownloadUrl;
}

fn isCanonicalViewId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or value[0] == ':' or value[value.len - 1] == ':') return false;
    var previous_colon = false;
    for (value) |byte| {
        if (byte == ':') {
            if (previous_colon) return false;
            previous_colon = true;
            continue;
        }
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
        previous_colon = false;
    }
    return true;
}

fn isCanonicalViewSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 512 or
        !std.ascii.isAlphanumeric(value[0]) or
        !std.ascii.isAlphanumeric(value[value.len - 1])) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ',')) return false;
    }
    return true;
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);

    const normalized_query = try common.normalizeTitle(a, query);
    if (normalized_query.len == 0) return .{ .arena = owned_arena, .items = &.{} };
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var anchors = parsed.doc.queryAll("a[href*='/en/view/']");
    while (anchors.next()) |anchor| {
        const h3 = anchor.queryOne("h3") orelse continue;
        const title = try common.innerTextTrimmedOwned(a, h3);
        if (title.len == 0) continue;
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const media_kind = try cardMediaKind(a, anchor) orelse continue;
        const normalized_title = try common.normalizeTitle(a, title);
        if (normalized_title.len == 0) continue;
        if (std.mem.indexOf(u8, normalized_title, normalized_query) == null and
            std.mem.indexOf(u8, normalized_query, normalized_title) == null) continue;

        const page_url = try common.resolveUrl(a, site, href);
        validateViewPageUrl(page_url) catch continue;
        const route_id = viewPageRouteId(page_url) orelse continue;
        const is_exact = std.mem.eql(u8, normalized_title, normalized_query);
        if (is_exact) {
            if (searchItemIndex(exact.items, route_id) != null or
                exact.items.len >= max_search_items) continue;
            if (searchItemIndex(partial.items, route_id)) |index| {
                _ = partial.orderedRemove(index);
            }
        } else {
            if (searchItemIndex(exact.items, route_id) != null or
                searchItemIndex(partial.items, route_id) != null or
                partial.items.len >= max_search_items) continue;
        }

        const item: SearchItem = .{
            .title = title,
            .year = parseYear(try common.innerTextTrimmedOwned(a, anchor)),
            .media_kind = media_kind,
            .page_url = page_url,
        };
        if (is_exact) {
            try exact.append(a, item);
        } else {
            try partial.append(a, item);
        }
    }

    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    const exact_count = @min(exact.items.len, max_search_items);
    try out.appendSlice(a, exact.items[0..exact_count]);
    if (out.items.len < max_search_items) {
        const remaining = max_search_items - out.items.len;
        try out.appendSlice(a, partial.items[0..@min(remaining, partial.items.len)]);
    }
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try out.toOwnedSlice(a) });
}

fn viewPageRouteId(url: []const u8) ?[]const u8 {
    validateViewPageUrl(url) catch return null;
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    var segments = std.mem.splitScalar(u8, path, '/');
    _ = segments.next();
    _ = segments.next();
    _ = segments.next();
    return segments.next();
}

fn searchItemIndex(items: []const SearchItem, route_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        const item_id = viewPageRouteId(item.page_url) orelse continue;
        if (std.mem.eql(u8, item_id, route_id)) return index;
    }
    return null;
}

fn cardMediaKind(allocator: Allocator, anchor: anytype) !?MediaKind {
    var spans = anchor.queryAll("span");
    while (spans.next()) |span| {
        const text = try common.innerTextTrimmedOwned(allocator, span);
        if (std.ascii.eqlIgnoreCase(text, "Movie")) return .movie;
        if (std.ascii.eqlIgnoreCase(text, "Series")) return .tv;
    }
    return null;
}

fn tableCellText(allocator: Allocator, row: anytype, wanted: usize) !?[]const u8 {
    var cells = row.queryAll("td");
    var idx: usize = 0;
    while (cells.next()) |cell| : (idx += 1) {
        if (idx == wanted) return try common.innerTextTrimmedOwned(allocator, cell);
    }
    return null;
}

fn parseDownloadId(onclick: []const u8) ?[]const u8 {
    const marker = "downloadMe('";
    const start = std.mem.indexOf(u8, onclick, marker) orelse return null;
    const tail = onclick[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, tail, '\'') orelse return null;
    const value = tail[0..end];
    if (!isCanonicalDownloadSegment(value)) return null;
    return value;
}

fn pageContainsDownloadId(body: []const u8, wanted: []const u8) bool {
    const marker = "downloadMe('";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |position| {
        const candidate = parseDownloadId(body[position..]) orelse {
            cursor = position + marker.len;
            continue;
        };
        if (std.mem.eql(u8, candidate, wanted)) return true;
        cursor = position + marker.len + candidate.len;
    }
    return false;
}

fn isCanonicalDownloadSegment(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn hasKnownDownloadExtension(value: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(value, ".srt") or
        std.ascii.endsWithIgnoreCase(value, ".ass") or
        std.ascii.endsWithIgnoreCase(value, ".ssa") or
        std.ascii.endsWithIgnoreCase(value, ".vtt") or
        std.ascii.endsWithIgnoreCase(value, ".sub") or
        std.ascii.endsWithIgnoreCase(value, ".zip") or
        std.ascii.endsWithIgnoreCase(value, ".rar") or
        std.ascii.endsWithIgnoreCase(value, ".7z");
}

fn parseSecCode(body: []const u8) ?[]const u8 {
    const marker = "id=\"secCode\"";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |id_pos| {
        cursor = id_pos + marker.len;
        const tag_start = std.mem.lastIndexOfScalar(u8, body[0..id_pos], '<') orelse continue;
        if (std.mem.indexOfScalar(u8, body[tag_start..id_pos], '>') != null) continue;

        const tag_tail = body[cursor..];
        const tag_end_rel = std.mem.indexOfScalar(u8, tag_tail, '>') orelse return null;
        if (std.mem.indexOfScalar(u8, tag_tail[0..tag_end_rel], '<') != null) continue;
        const tag = body[tag_start .. cursor + tag_end_rel + 1];
        const value_marker = "value=\"";
        const value_pos = std.mem.indexOf(u8, tag, value_marker) orelse continue;
        const tail = tag[value_pos + value_marker.len ..];
        const end = std.mem.indexOfScalar(u8, tail, '"') orelse continue;
        const value = tail[0..end];
        if (!isCanonicalDownloadSegment(value)) continue;
        return value;
    }
    return null;
}

pub fn makeDownloadToken(allocator: Allocator, subtitle_id: []const u8, page_url: []const u8) ![]u8 {
    if (!isCanonicalDownloadSegment(subtitle_id)) return error.InvalidDownloadUrl;
    try validateViewPageUrl(page_url);
    return std.fmt.allocPrint(allocator, "{s}{s}|{s}", .{ download_token_prefix, subtitle_id, page_url });
}

const DownloadToken = common.SubtitleDownloadToken;

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    const sep = std.mem.indexOfScalar(u8, payload, '|') orelse return null;
    if (sep == 0 or sep + 1 >= payload.len) return null;
    const subtitle_id = payload[0..sep];
    const page_url = payload[sep + 1 ..];
    if (!isCanonicalDownloadSegment(subtitle_id)) return null;
    validateViewPageUrl(page_url) catch return null;
    return .{ .subtitle_id = subtitle_id, .page_url = page_url };
}

fn parseYear(value: []const u8) ?i64 {
    var i: usize = 0;
    while (i + 4 <= value.len) : (i += 1) {
        const slice = value[i .. i + 4];
        var all_digits = true;
        for (slice) |c| if (!std.ascii.isDigit(c)) {
            all_digits = false;
            break;
        };
        if (!all_digits) continue;
        const year = std.fmt.parseInt(i64, slice, 10) catch continue;
        if (year >= 1900 and year <= 2100) return year;
    }
    return null;
}

fn readBoundedBody(allocator: Allocator, reader: *std.Io.Reader, max_bytes: usize) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var received: usize = 0;
    while (true) {
        if (received == max_bytes) {
            _ = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            return error.ResponseTooLarge;
        }
        const count = reader.stream(&writer.writer, .limited(max_bytes - received)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return common.normalizeAllocatingWriterError(err),
        };
        received += count;
    }
    var body = writer.toArrayList();
    errdefer body.deinit(allocator);
    return body.toOwnedSlice(allocator);
}

test "raw response body limit accepts exact bounds and rejects excess" {
    const a = std.testing.allocator;
    var exact: std.Io.Reader = .fixed("1234");
    const body = try readBoundedBody(a, &exact, 4);
    defer a.free(body);
    try std.testing.expectEqualStrings("1234", body);
    var oversized: std.Io.Reader = .fixed("12345");
    try std.testing.expectError(error.ResponseTooLarge, readBoundedBody(a, &oversized, 4));
    var empty: std.Io.Reader = .fixed("");
    const empty_body = try readBoundedBody(a, &empty, 0);
    defer a.free(empty_body);
    try std.testing.expectEqual(@as(usize, 0), empty_body.len);
    var zero_limit: std.Io.Reader = .fixed("1");
    try std.testing.expectError(error.ResponseTooLarge, readBoundedBody(a, &zero_limit, 0));
}

test "greeksubs token and download id parsing" {
    try std.testing.expectEqualStrings("abc-123", parseDownloadId("downloadMe('abc-123')").?);
    const allocator = std.testing.allocator;
    const token = try makeDownloadToken(allocator, "abc", "https://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar");
    defer allocator.free(token);
    const parsed = parseDownloadToken(token).?;
    try std.testing.expectEqualStrings("abc", parsed.subtitle_id);
    try std.testing.expectEqualStrings("https://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar", parsed.page_url);
    try std.testing.expect(!hasKnownDownloadExtension("Interstellar.2014.1080p.BluRay.x264-YIFY"));
    try std.testing.expect(hasKnownDownloadExtension("Interstellar.2014.srt"));
    try std.testing.expect(hasKnownDownloadExtension("Game of Thrones Season 1.zip"));
}

test "greeksubs download route segments are canonical and exactly correlated" {
    try std.testing.expectEqualStrings("Abc_123-xyz", parseDownloadId("downloadMe('Abc_123-xyz')").?);
    try std.testing.expect(pageContainsDownloadId("x downloadMe('12') y downloadMe('123')", "123"));
    try std.testing.expect(!pageContainsDownloadId("x downloadMe('1234')", "123"));
    try std.testing.expectEqualStrings("Sec_123-xyz", parseSecCode("<input id=\"secCode\" value=\"Sec_123-xyz\">").?);

    for ([_][]const u8{
        "",
        "../admin",
        "id/next",
        "id?query",
        "id#fragment",
        "id%2fnext",
        "id.with-dot",
        "id\nnext",
    }) |unsafe| {
        try std.testing.expect(!isCanonicalDownloadSegment(unsafe));
        const onclick = try std.fmt.allocPrint(std.testing.allocator, "downloadMe('{s}')", .{unsafe});
        defer std.testing.allocator.free(onclick);
        try std.testing.expect(parseDownloadId(onclick) == null);
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            makeDownloadToken(std.testing.allocator, unsafe, "https://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar"),
        );
    }

    const oversized: [129]u8 = @splat('a');
    try std.testing.expect(!isCanonicalDownloadSegment(&oversized));
    try std.testing.expect(parseSecCode("<input id=\"secCode\" value=\"../admin\">") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "id/next|https://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "id|https://greeksubs.net.example/en/view/tt0816692/subtitle-for-interstellar") == null);
}

test "greeksubs raw fetch rejects an expired deadline before I/O" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(
        error.Timeout,
        fetchRaw(&client, std.testing.allocator, site ++ "/en/view/tt0816692/subtitle-for-interstellar", &.{}, common.compatMilliTimestamp()),
    );
}

test "greeksubs malformed duplicate does not suppress a valid subtitle row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    try collectSubtitleRows(
        allocator,
        allocator,
        "<table><tbody>" ++
            "<tr><td>missing filename</td><td><button onclick=\"downloadMe('7')\">x</button></td></tr>" ++
            "<tr><td></td><td></td><td></td><td></td><td></td><td></td><td>Matrix.Release</td><td><button onclick=\"downloadMe('7')\">x</button></td></tr>" ++
            "<tr><td></td><td></td><td></td><td></td><td></td><td></td><td>Duplicate.Release</td><td><button onclick=\"downloadMe('7')\">x</button></td></tr>" ++
            "</tbody></table>",
        "https://greeksubs.net/en/view/tt0133093/subtitle-for-the-matrix",
        &subtitles,
        &seen,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), subtitles.items.len);
    try std.testing.expectEqualStrings("Matrix.Release.srt", subtitles.items[0].filename);
}

test "greeksubs scans past malformed row controls and security-code tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    try collectSubtitleRows(
        allocator,
        allocator,
        "<table><tbody><tr>" ++
            "<td></td><td></td><td></td><td></td><td></td><td></td><td>Matrix.Release</td>" ++
            "<td><button onclick=\"downloadMe('../bad')\">bad</button>" ++
            "<button onclick=\"downloadMe('7')\">good</button></td>" ++
            "</tr></tbody></table>",
        "https://greeksubs.net/en/view/tt0133093/subtitle-for-the-matrix",
        &subtitles,
        &seen,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), subtitles.items.len);
    try std.testing.expectEqualStrings("7", subtitles.items[0].id);
    try std.testing.expectEqualStrings(
        "Sec_123",
        parseSecCode("<input id=\"secCode\" value=\"../admin\"><input id=\"secCode\" value=\"Sec_123\">").?,
    );
}

test "greeksubs scans past duplicate controls within a subtitle row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    try collectSubtitleRows(
        allocator,
        allocator,
        "<table><tbody>" ++
            "<tr><td></td><td></td><td></td><td></td><td></td><td></td><td>First.Release</td>" ++
            "<td><button onclick=\"downloadMe('7')\">first</button></td></tr>" ++
            "<tr><td></td><td></td><td></td><td></td><td></td><td></td><td>Second.Release</td>" ++
            "<td><button onclick=\"downloadMe('7')\">duplicate</button>" ++
            "<button onclick=\"downloadMe('8')\">unique</button></td></tr>" ++
            "</tbody></table>",
        "https://greeksubs.net/en/view/tt0133093/subtitle-for-the-matrix",
        &subtitles,
        &seen,
        null,
    );

    try std.testing.expectEqual(@as(usize, 2), subtitles.items.len);
    try std.testing.expectEqualStrings("7", subtitles.items[0].id);
    try std.testing.expectEqualStrings("8", subtitles.items[1].id);
}

test "greeksubs rejects non-provider session targets" {
    try validateViewPageUrl("https://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar");
    try validateViewPageUrl("https://greeksubs.net/en/view/legacy:season:tt0944947:1/subtitle-for-game-of-thrones-season-1-complete-pack");
    for ([_][]const u8{
        "http://127.0.0.1/en/view/tt0816692/subtitle-for-interstellar",
        "https://greeksubs.net.example/en/view/tt0816692/subtitle-for-interstellar",
        "https://user@greeksubs.net/en/view/tt0816692/subtitle-for-interstellar",
        "http://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateViewPageUrl(url));
    }
}

test "greeksubs rejects noncanonical view-page routes" {
    for ([_][]const u8{
        "https://greeksubs.net/en/view/",
        "https://greeksubs.net/en/view/tt0816692",
        "https://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar/extra",
        "https://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar?next=1",
        "https://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar#fragment",
        "https://greeksubs.net/en/view/tt0816692%2Fextra/subtitle-for-interstellar",
        "https://greeksubs.net/en/view/tt0816692/subtitle.for.interstellar",
        "https://greeksubs.net/en/view/legacy::season/subtitle-for-show",
        "https://greeksubs.net/en/admin/show",
        "https://greeksubs.net/en/view/tt0816692/subtitle-for-interstellar\\extra",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateViewPageUrl(url));
        try std.testing.expectError(error.InvalidDownloadUrl, makeDownloadToken(std.testing.allocator, "id", url));
        const token = try std.fmt.allocPrint(std.testing.allocator, "{s}id|{s}", .{ download_token_prefix, url });
        defer std.testing.allocator.free(token);
        try std.testing.expect(parseDownloadToken(token) == null);
    }
}

test "greeksubs stops season fallback on rate limits and cancellation" {
    const Scenario = enum { limited, canceled, out_of_memory };
    const Case = struct { scenario: Scenario, expected_error: anyerror };
    const Fixture = struct {
        client: std.http.Client,
        scenario: Scenario,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expectEqual(max_transport_attempts_per_fetch, options.max_attempts);
            if (std.mem.eql(u8, url, "https://greeksubs.net/en/view/tt0000001/subtitle-for-show")) {
                return .{
                    .status = .ok,
                    .body = try allocator.dupe(u8, "<a href='/en/view/legacy:season:tt0000001:1/subtitle-for-show-season-1'>Season 1</a>" ++
                        "<a href='/en/view/legacy:season:tt0000001:2/subtitle-for-show-season-2'>Season 2</a>"),
                };
            }
            try std.testing.expectEqual(@as(usize, 2), self.calls);
            return switch (self.scenario) {
                .limited => .{ .status = .too_many_requests, .body = try allocator.dupe(u8, "limited") },
                .canceled => error.Canceled,
                .out_of_memory => error.OutOfMemory,
            };
        }
    };

    for ([_]Case{
        .{ .scenario = .limited, .expected_error = error.RateLimited },
        .{ .scenario = .canceled, .expected_error = error.Canceled },
        .{ .scenario = .out_of_memory, .expected_error = error.OutOfMemory },
    }) |case| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .scenario = case.scenario,
        };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        try std.testing.expectError(case.expected_error, scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
            .title = "Show",
            .year = null,
            .media_kind = .tv,
            .page_url = "https://greeksubs.net/en/view/tt0000001/subtitle-for-show",
        }));
        try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    }
}

test "greeksubs punctuation-only normalized query avoids the search request" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.UnexpectedFetch;
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetch, "... !!! ---");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "greeksubs search caps partials and promotes later exact route duplicates" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(search_url, url);
            try std.testing.expectEqual(std.http.Method.POST, options.method);

            var body: std.Io.Writer.Allocating = .init(allocator);
            defer body.deinit();
            try body.writer.writeAll("<html><body>");
            for (1..max_search_items + 4) |index| {
                try body.writer.print(
                    "<a href='/en/view/title-{d}/subtitle-for-target-variant-{d}'><h3>Target Variant {d}</h3><span>Movie</span></a>",
                    .{ index, index, index },
                );
            }
            try body.writer.writeAll(
                "<a href='/en/view/title-1/subtitle-for-target'><h3>Target</h3><span>Movie</span></a>" ++
                    "<a href='/en/view/title-exact/subtitle-for-target'><h3>Target</h3><span>Movie</span></a>" ++
                    "</body></html>",
            );
            return .{ .status = .ok, .body = try body.toOwnedSlice() };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetch, "Target");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(usize, max_search_items), response.items.len);
    try std.testing.expectEqualStrings("title-1", viewPageRouteId(response.items[0].page_url).?);
    try std.testing.expectEqualStrings("title-exact", viewPageRouteId(response.items[1].page_url).?);
    try std.testing.expectEqualStrings("title-2", viewPageRouteId(response.items[2].page_url).?);
    try std.testing.expectEqualStrings("title-23", viewPageRouteId(response.items[max_search_items - 1].page_url).?);
}

test "greeksubs primary subtitle page obeys the global row cap" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            var body: std.Io.Writer.Allocating = .init(allocator);
            defer body.deinit();
            try body.writer.writeAll("<table><tbody>");
            for (1..max_subtitle_items + 6) |index| {
                try body.writer.print(
                    "<tr><td></td><td></td><td></td><td></td><td></td><td></td>" ++
                        "<td>Movie.Release.{d}</td><td><button onclick=\"downloadMe('{d}')\">download</button></td></tr>",
                    .{ index, index },
                );
            }
            try body.writer.writeAll("</tbody></table>");
            return .{ .status = .ok, .body = try body.toOwnedSlice() };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
        .title = "Movie",
        .year = null,
        .media_kind = .movie,
        .page_url = "https://greeksubs.net/en/view/tt0000001/subtitle-for-movie",
    });
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(usize, max_subtitle_items), response.subtitles.len);
    try std.testing.expectEqualStrings("1", response.subtitles[0].id);
    try std.testing.expectEqualStrings("24", response.subtitles[max_subtitle_items - 1].id);
}

test "greeksubs continues after one ordinary season failure" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            if (std.mem.eql(u8, url, "https://greeksubs.net/en/view/tt0000001/subtitle-for-show")) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "<a href='/en/view/legacy:season:tt0000001:1/subtitle-for-show-season-1'>Season 1</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:2/subtitle-for-show-season-2'>Season 2</a>"),
            };
            if (std.mem.endsWith(u8, url, "show-season-1")) return error.ConnectionResetByPeer;
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<html><body>No rows</body></html>") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
        .title = "Show",
        .year = null,
        .media_kind = .tv,
        .page_url = "https://greeksubs.net/en/view/tt0000001/subtitle-for-show",
    });
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.subtitles.len);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}

test "greeksubs season fallback reaches later useful pages within its logical-page budget" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqual(max_transport_attempts_per_fetch, options.max_attempts);
            if (std.mem.eql(u8, url, "https://greeksubs.net/en/view/tt0000001/subtitle-for-show")) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "<a href='/en/view/legacy:season:tt0000001:1/subtitle-for-show-season-1'>Season 1</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:2/subtitle-for-show-season-2'>Season 2</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:3/subtitle-for-show-season-3'>Season 3</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:4/subtitle-for-show-season-4'>Season 4</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:5/subtitle-for-show-season-5'>Season 5</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:6/subtitle-for-show-season-6'>Season 6</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:7/subtitle-for-show-season-7'>Season 7</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:8/subtitle-for-show-season-8'>Season 8</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:9/subtitle-for-show-season-9'>Season 9</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:10/subtitle-for-show-season-10'>Season 10</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:11/subtitle-for-show-season-11'>Season 11</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:12/subtitle-for-show-season-12'>Season 12</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:13/subtitle-for-show-season-13'>Season 13</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:14/subtitle-for-show-season-14'>Season 14</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:15/subtitle-for-show-season-15'>Season 15</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:16/subtitle-for-show-season-16'>Season 16</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:17/subtitle-for-show-season-17'>Season 17</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:18/subtitle-for-show-season-18'>Season 18</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:19/subtitle-for-show-season-19'>Season 19</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:20/subtitle-for-show-season-20'>Season 20</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:21/subtitle-for-show-season-21'>Season 21</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:22/subtitle-for-show-season-22'>Season 22</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:23/subtitle-for-show-season-23'>Season 23</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:24/subtitle-for-show-season-24'>Season 24</a>" ++
                    "<a href='/en/view/legacy:season:tt0000001:25/subtitle-for-show-season-25'>Season 25</a>"),
            };
            for ([_][]const u8{ "show-season-1", "show-season-2", "show-season-3", "show-season-4" }) |suffix| {
                if (std.mem.endsWith(u8, url, suffix)) return error.ConnectionResetByPeer;
            }
            if (std.mem.endsWith(u8, url, "show-season-9")) return .{
                .status = .ok,
                .body = try allocator.dupe(u8, "<table><tbody><tr>" ++
                    "<td></td><td></td><td></td><td></td><td></td><td></td><td>Show.S09.Release</td>" ++
                    "<td><button onclick=\"downloadMe('season-nine')\">download</button></td>" ++
                    "</tr></tbody></table>"),
            };
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<html><body>No rows</body></html>") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
        .title = "Show",
        .year = null,
        .media_kind = .tv,
        .page_url = "https://greeksubs.net/en/view/tt0000001/subtitle-for-show",
    });
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    try std.testing.expectEqualStrings("season-nine", response.subtitles[0].id);
    try std.testing.expectEqual(@as(usize, 1 + max_logical_season_pages), fixture.calls);
    try std.testing.expectEqual(@as(usize, 48), max_season_transport_attempts);
}

test "greeksubs season fallback dedupes canonical page ids and owns scratch results" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,
        self_route_calls: usize = 0,
        duplicate_route_calls: usize = 0,
        useful_route_calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqual(max_transport_attempts_per_fetch, options.max_attempts);
            try std.testing.expectEqual(max_html_response_bytes, options.max_response_bytes);
            try std.testing.expectEqual(max_html_response_bytes, options.max_encoded_response_bytes);

            if (std.mem.eql(u8, url, "https://greeksubs.net/en/view/tt0000001/subtitle-for-show")) {
                var body: std.Io.Writer.Allocating = .init(allocator);
                defer body.deinit();
                try body.writer.writeAll(
                    "<a href='/en/view/tt0000001/subtitle-for-show-alternate-slug'>Season overview</a>",
                );
                for (0..max_logical_season_pages) |index| {
                    try body.writer.print(
                        "<a href='/en/view/legacy:season:tt0000001:1/subtitle-for-show-season-one-{d}'>Season 1 duplicate {d}</a>",
                        .{ index, index },
                    );
                }
                try body.writer.writeAll(
                    "<a href='/en/view/legacy:season:tt0000001:2/subtitle-for-show-season-two'>Season 2</a>",
                );
                return .{ .status = .ok, .body = try body.toOwnedSlice() };
            }

            const route_id = viewPageRouteId(url) orelse return error.UnexpectedFixtureUrl;
            if (std.mem.eql(u8, route_id, "tt0000001")) {
                self.self_route_calls += 1;
                return .{ .status = .ok, .body = try allocator.dupe(u8, "<html><body>No rows</body></html>") };
            }
            if (std.mem.eql(u8, route_id, "legacy:season:tt0000001:1")) {
                self.duplicate_route_calls += 1;
                return .{ .status = .ok, .body = try allocator.dupe(u8, "<html><body>No rows</body></html>") };
            }
            if (std.mem.eql(u8, route_id, "legacy:season:tt0000001:2")) {
                self.useful_route_calls += 1;
                return .{
                    .status = .ok,
                    .body = try allocator.dupe(u8, "<table><tbody><tr>" ++
                        "<td><img alt=\"el\"></td><td></td><td></td><td></td><td></td><td></td>" ++
                        "<td>Show.S02.Release</td>" ++
                        "<td><button onclick=\"downloadMe('season-two')\">download</button></td>" ++
                        "</tr></tbody></table>"),
                };
            }
            return error.UnexpectedFixtureUrl;
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
        .title = "Show",
        .year = null,
        .media_kind = .tv,
        .page_url = "https://greeksubs.net/en/view/tt0000001/subtitle-for-show",
    });
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.self_route_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.duplicate_route_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.useful_route_calls);
    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    try std.testing.expectEqualStrings("season-two", response.subtitles[0].id);
    try std.testing.expectEqualStrings("el", response.subtitles[0].language_code.?);
    try std.testing.expectEqualStrings("Show.S02.Release.srt", response.subtitles[0].filename);
    const token = parseDownloadToken(response.subtitles[0].download_url).?;
    try std.testing.expectEqualStrings("legacy:season:tt0000001:2", viewPageRouteId(token.page_url).?);
}

test "greeksubs season fallback caps results within a productive page" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            if (std.mem.eql(u8, url, "https://greeksubs.net/en/view/tt0000001/subtitle-for-show")) return .{
                .status = .ok,
                .body = try allocator.dupe(
                    u8,
                    "<a href='/en/view/legacy:season:tt0000001:1/subtitle-for-show-season-1'>Season 1</a>",
                ),
            };

            var body: std.ArrayListUnmanaged(u8) = .empty;
            errdefer body.deinit(allocator);
            try body.appendSlice(allocator, "<table><tbody>");
            var index: usize = 0;
            while (index < max_fallback_subtitles + 5) : (index += 1) {
                const row = try std.fmt.allocPrint(
                    allocator,
                    "<tr><td></td><td></td><td></td><td></td><td></td><td></td>" ++
                        "<td>Show.S01E{d}</td><td><button onclick=\"downloadMe('{d}')\">download</button></td></tr>",
                    .{ index + 1, index + 1 },
                );
                defer allocator.free(row);
                try body.appendSlice(allocator, row);
            }
            try body.appendSlice(allocator, "</tbody></table>");
            return .{ .status = .ok, .body = try body.toOwnedSlice(allocator) };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
        .title = "Show",
        .year = null,
        .media_kind = .tv,
        .page_url = "https://greeksubs.net/en/view/tt0000001/subtitle-for-show",
    });
    defer response.deinit();

    try std.testing.expectEqual(max_fallback_subtitles, response.subtitles.len);
    try std.testing.expectEqualStrings("24", response.subtitles[max_fallback_subtitles - 1].id);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "greeksubs raw session transport rejects ambiguous response framing" {
    for ([_][]const u8{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
    }) |raw_head| {
        const head = try std.http.Client.Response.Head.parse(raw_head);
        try std.testing.expectError(error.AmbiguousHttpFraming, validateRawSessionResponseHead(head));
    }
}

test "live greeksubs movie search, listing and session download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "greeksubs.net")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Interstellar");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);

    const response = try scraper.fetchDownloadByToken(std.testing.allocator, subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(response.body);
    try std.testing.expect(response.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "-->") != null);
}
