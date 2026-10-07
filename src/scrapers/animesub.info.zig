const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;
// Bound the merged org/en/pl result set independently of upstream page size.
const max_search_items = 24;
const site = "http://animesub.info";
const search_path = site ++ "/szukaj.php";
const download_path = site ++ "/sciagnij.php";
pub const download_token_prefix = "animesubinfo-session:";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    media_kind: MediaKind,
    season: ?i64,
    episode: ?i64,
    subtitle_id: []const u8,
    search_query: []const u8,
    title_type: []const u8,
    page_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;
        return self.searchWithFetcher(query, fetchRawGet, deadline_ms);
    }

    fn searchWithFetcher(self: *Scraper, query: []const u8, comptime fetch: anytype, deadline_ms: i64) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var successful_variants: usize = 0;

        for ([_][]const u8{ "org", "en", "pl" }) |title_type| {
            const url = try buildSearchUrl(a, trimmed, title_type);
            var response = try fetch(self.client, a, url, deadline_ms);
            defer response.deinit(a);
            if (response.status == .too_many_requests) return error.RateLimited;
            if (response.status != .ok) continue;
            successful_variants += 1;
            try appendSearchRows(
                a,
                response.body,
                trimmed,
                title_type,
                url,
                &exact,
                &partial,
            );
        }

        if (successful_variants == 0) return error.UnexpectedHttpStatus;
        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        const exact_count = @min(exact.items.len, max_search_items);
        try items.appendSlice(a, exact.items[0..exact_count]);
        if (items.items.len < max_search_items) {
            const remaining = max_search_items - items.items.len;
            try items.appendSlice(a, partial.items[0..@min(remaining, partial.items.len)]);
        }
        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = "pl",
            .filename = try std.fmt.allocPrint(a, "animesubinfo-{s}.pl.zip", .{item.subtitle_id}),
            .download_url = try makeDownloadToken(a, item),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;
        return self.fetchDownloadByTokenWithFetchers(allocator, token, fetchRawGet, common.fetchBytes, deadline_ms);
    }

    fn fetchDownloadByTokenWithFetchers(
        self: *Scraper,
        allocator: Allocator,
        token: []const u8,
        comptime fetch_search: anytype,
        comptime fetch_download: anytype,
        deadline_ms: i64,
    ) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateProviderUrl(parts.search_url);
        var search_response = try fetch_search(self.client, allocator, parts.search_url, deadline_ms);
        defer search_response.deinit(allocator);
        if (search_response.status == .too_many_requests) return error.RateLimited;
        if (search_response.status != .ok) return error.UnexpectedHttpStatus;
        const cookie = search_response.cookie orelse return error.SessionExpired;
        const hash = findHashForId(search_response.body, parts.subtitle_id) orelse return error.MissingField;

        const response = try postDownload(
            self.client,
            allocator,
            parts.subtitle_id,
            hash,
            cookie,
            parts.search_url,
            fetch_download,
            deadline_ms,
        );
        if (response.status == .too_many_requests) {
            allocator.free(response.body);
            return error.RateLimited;
        }
        if (!downloadResponseIsValid(response)) {
            allocator.free(response.body);
            return error.UnexpectedResponseType;
        }
        return response;
    }
};

fn postDownload(
    client: *std.http.Client,
    allocator: Allocator,
    subtitle_id: []const u8,
    hash: []const u8,
    cookie: []const u8,
    search_url: []const u8,
    comptime fetch: anytype,
    deadline_ms: i64,
) !common.HttpResponse {
    try validateProviderUrl(search_url);
    if (!isValidSessionCookie(cookie)) return error.InvalidSessionPayload;
    const id_encoded = try common.encodeUriComponent(allocator, subtitle_id);
    defer allocator.free(id_encoded);
    const hash_encoded = try common.encodeUriComponent(allocator, hash);
    defer allocator.free(hash_encoded);
    const button_encoded = try common.encodeUriComponent(allocator, "Pobierz napisy");
    defer allocator.free(button_encoded);
    const payload = try std.fmt.allocPrint(
        allocator,
        "id={s}&sh={s}&single_file={s}",
        .{ id_encoded, hash_encoded, button_encoded },
    );
    defer allocator.free(payload);

    return fetch(client, allocator, download_path, common.FetchOptions{
        .method = .POST,
        .payload = payload,
        .content_type = "application/x-www-form-urlencoded",
        .accept = "application/zip,application/octet-stream,*/*",
        .extra_headers = &[_]std.http.Header{
            .{ .name = "cookie", .value = cookie },
            .{ .name = "referer", .value = search_url },
        },
        .allow_non_ok = true,
        .cache = false,
        .max_attempts = 2,
        .retry_on_429 = false,
        .require_public_origin = true,
        .deadline_ms = deadline_ms,
    });
}

fn downloadResponseIsValid(response: common.HttpResponse) bool {
    return response.status == .ok and
        response.body.len >= 4 and
        std.mem.eql(u8, response.body[0..2], "PK");
}

fn appendSearchRows(
    allocator: Allocator,
    body: []const u8,
    query: []const u8,
    title_type: []const u8,
    search_url: []const u8,
    exact: *std.ArrayListUnmanaged(SearchItem),
    partial: *std.ArrayListUnmanaged(SearchItem),
) !void {
    const marker = "<table cellspacing=\"2\" cellpadding=\"2\" width=\"100%\" class=\"Napisy\" style=\"text-align:center\">";
    const wanted = try common.normalizeTitle(allocator, query);
    defer allocator.free(wanted);

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |start| {
        const next = std.mem.indexOfPos(u8, body, start + marker.len, marker) orelse body.len;
        const block = body[start..next];
        cursor = next;

        const subtitle_id = inputValue(block, "id") orelse continue;
        if (!isPositiveDecimal(subtitle_id)) continue;
        const hash = inputValue(block, "sh") orelse continue;
        if (hash.len < 16) continue;

        const titles = firstThreeLeftCells(block);
        const title_org = titles[0] orelse "";
        const title_eng = titles[1] orelse "";
        const title_alt = titles[2] orelse "";

        const normalized_org = try common.normalizeTitle(allocator, title_org);
        defer allocator.free(normalized_org);
        const normalized_eng = try common.normalizeTitle(allocator, title_eng);
        defer allocator.free(normalized_eng);
        const normalized_alt = try common.normalizeTitle(allocator, title_alt);
        defer allocator.free(normalized_alt);

        const matches = containsTitle(normalized_org, wanted) or
            containsTitle(normalized_eng, wanted) or
            containsTitle(normalized_alt, wanted);
        if (!matches) continue;

        const display_title = if (title_eng.len > 0) title_eng else if (title_org.len > 0) title_org else title_alt;
        const episode = parseEpisode(display_title) orelse parseEpisode(title_org) orelse parseEpisode(title_alt);
        const season = parseSeason(display_title) orelse parseSeason(title_org) orelse parseSeason(title_alt);
        const media_kind: MediaKind = if (episode != null) .tv else .movie;
        const base_title = stripEpisodeSuffix(display_title);
        const normalized_base = try common.normalizeTitle(allocator, base_title);
        defer allocator.free(normalized_base);

        const is_exact = std.mem.eql(u8, normalized_base, wanted);
        if (is_exact) {
            if (searchItemIndex(exact.items, subtitle_id) != null or
                exact.items.len >= max_search_items) continue;
            if (searchItemIndex(partial.items, subtitle_id)) |index| {
                _ = partial.orderedRemove(index);
            }
        } else {
            if (searchItemIndex(exact.items, subtitle_id) != null or
                searchItemIndex(partial.items, subtitle_id) != null or
                partial.items.len >= max_search_items) continue;
        }

        const item: SearchItem = .{
            .title = try allocator.dupe(u8, base_title),
            .media_kind = media_kind,
            .season = if (media_kind == .tv) season orelse 1 else null,
            .episode = episode,
            .subtitle_id = try allocator.dupe(u8, subtitle_id),
            .search_query = try allocator.dupe(u8, query),
            .title_type = try allocator.dupe(u8, title_type),
            .page_url = try allocator.dupe(u8, search_url),
        };

        if (is_exact)
            try exact.append(allocator, item)
        else
            try partial.append(allocator, item);
    }
}

fn searchItemIndex(items: []const SearchItem, subtitle_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.subtitle_id, subtitle_id)) return index;
    }
    return null;
}

fn firstThreeLeftCells(block: []const u8) [3]?[]const u8 {
    var out: [3]?[]const u8 = .{ null, null, null };
    var cursor: usize = 0;
    var idx: usize = 0;
    while (idx < out.len) {
        const pos = std.mem.indexOfPos(u8, block, cursor, "<td align=\"left\"") orelse break;
        const gt = std.mem.indexOfPos(u8, block, pos, ">") orelse break;
        const close = std.mem.indexOfPos(u8, block, gt + 1, "</td>") orelse break;
        const raw = block[gt + 1 .. close];
        out[idx] = trimVisibleText(raw);
        idx += 1;
        cursor = close + "</td>".len;
    }
    return out;
}

fn trimVisibleText(raw: []const u8) []const u8 {
    const first_tag = std.mem.indexOfScalar(u8, raw, '<') orelse raw.len;
    return std.mem.trim(u8, raw[0..first_tag], " \t\r\n");
}

fn inputValue(block: []const u8, name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < block.len) {
        const rel = std.ascii.findIgnoreCase(block[cursor..], "<input") orelse return null;
        const start = cursor + rel;
        const after_name = start + "<input".len;
        if (after_name < block.len and
            !std.ascii.isWhitespace(block[after_name]) and
            block[after_name] != '/' and block[after_name] != '>')
        {
            cursor = after_name;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, block, after_name, '>') orelse return null;
        const tag = block[start .. end + 1];
        cursor = end + 1;
        const found_name = tagAttributeValue(tag, "name") orelse continue;
        if (!std.ascii.eqlIgnoreCase(found_name, name)) continue;
        return tagAttributeValue(tag, "value");
    }
    return null;
}

fn tagAttributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var marker: usize = 0;
    while (marker + name.len <= tag.len) : (marker += 1) {
        if (!std.ascii.eqlIgnoreCase(tag[marker .. marker + name.len], name)) continue;
        if (marker > 0 and tag[marker - 1] != '<' and !std.ascii.isWhitespace(tag[marker - 1])) continue;

        var cursor = marker + name.len;
        if (cursor < tag.len and
            (std.ascii.isAlphanumeric(tag[cursor]) or tag[cursor] == '-' or tag[cursor] == '_'))
        {
            continue;
        }
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] != '=') continue;
        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len) return null;

        const quote = tag[cursor];
        if (quote == '"' or quote == '\'') {
            const start = cursor + 1;
            const end = std.mem.indexOfScalarPos(u8, tag, start, quote) orelse return null;
            return tag[start..end];
        }
        const end = std.mem.indexOfAnyPos(u8, tag, cursor, " \t\r\n>") orelse tag.len;
        if (end == cursor) return null;
        return tag[cursor..end];
    }
    return null;
}

fn findHashForId(body: []const u8, subtitle_id: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, "<form")) |form_start| {
        const next_form = std.mem.indexOfPos(u8, body, form_start + "<form".len, "<form");
        const close_start = std.mem.indexOfPos(u8, body, form_start + "<form".len, "</form>") orelse {
            cursor = if (next_form) |next| next else body.len;
            continue;
        };
        if (next_form) |next| {
            if (next < close_start) {
                cursor = next;
                continue;
            }
        }
        const form_end = close_start + "</form>".len;
        const form = body[form_start..form_end];
        cursor = form_end;
        const found_id = inputValue(form, "id") orelse continue;
        if (!std.mem.eql(u8, found_id, subtitle_id)) continue;
        const hash = inputValue(form, "sh") orelse continue;
        if (hash.len < 16 or hash.len > 4096) continue;
        return hash;
    }
    return null;
}

fn containsTitle(candidate: []const u8, wanted: []const u8) bool {
    if (candidate.len == 0 or wanted.len == 0) return false;
    return std.mem.indexOf(u8, candidate, wanted) != null or std.mem.indexOf(u8, wanted, candidate) != null;
}

fn parseEpisode(value: []const u8) ?i64 {
    const lower = "ep";
    var i: usize = 0;
    while (i + 2 < value.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(value[i .. i + 2], lower)) continue;
        var p = i + 2;
        while (p < value.len and (value[p] == ' ' or value[p] == '.' or value[p] == '-' or value[p] == '_')) : (p += 1) {}
        while (p < value.len and value[p] == '0') : (p += 1) {}
        const start = p;
        while (p < value.len and std.ascii.isDigit(value[p])) : (p += 1) {}
        if (p == start) continue;
        return std.fmt.parseInt(i64, value[start..p], 10) catch null;
    }
    return null;
}

fn parseSeason(value: []const u8) ?i64 {
    if (std.ascii.findIgnoreCase(value, "season ")) |pos| {
        const tail = value[pos + "season ".len ..];
        var end: usize = 0;
        while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
        if (end > 0) return std.fmt.parseInt(i64, tail[0..end], 10) catch null;
    }
    return null;
}

fn stripEpisodeSuffix(value: []const u8) []const u8 {
    if (std.ascii.findIgnoreCase(value, " ep")) |pos| return std.mem.trimEnd(u8, value[0..pos], " \t-");
    return std.mem.trim(u8, value, " \t\r\n");
}

fn buildSearchUrl(allocator: Allocator, query: []const u8, title_type: []const u8) ![]u8 {
    const encoded = try common.encodeUriComponent(allocator, query);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{s}?szukane={s}&pTitle={s}&pSortuj=pobrn", .{ search_path, encoded, title_type });
}

pub fn makeDownloadToken(allocator: Allocator, item: SearchItem) ![]u8 {
    if (!isPositiveDecimal(item.subtitle_id)) return error.InvalidDownloadUrl;
    try validateProviderUrl(item.page_url);
    return std.fmt.allocPrint(
        allocator,
        "{s}v2:{d}:{s}{d}:{s}",
        .{
            download_token_prefix,
            item.subtitle_id.len,
            item.subtitle_id,
            item.page_url.len,
            item.page_url,
        },
    );
}

const DownloadToken = struct {
    subtitle_id: []const u8,
    search_url: []const u8,
};

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    if (!std.mem.startsWith(u8, payload, "v2:")) return null;
    var cursor: usize = "v2:".len;
    const subtitle_id = takeTokenField(payload, &cursor) orelse return null;
    const search_url = takeTokenField(payload, &cursor) orelse return null;
    if (cursor != payload.len or !isPositiveDecimal(subtitle_id)) return null;
    validateProviderUrl(search_url) catch return null;
    return .{
        .subtitle_id = subtitle_id,
        .search_url = search_url,
    };
}

fn takeTokenField(payload: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= payload.len) return null;
    const length_end_rel = std.mem.indexOfScalar(u8, payload[cursor.*..], ':') orelse return null;
    const length_end = cursor.* + length_end_rel;
    if (length_end == cursor.*) return null;
    const length_text = payload[cursor.*..length_end];
    if (length_text.len > 1 and length_text[0] == '0') return null;
    for (length_text) |c| if (!std.ascii.isDigit(c)) return null;
    const field_len = std.fmt.parseInt(usize, length_text, 10) catch return null;
    const field_start = length_end + 1;
    const field_end = std.math.add(usize, field_start, field_len) catch return null;
    if (field_end > payload.len) return null;
    cursor.* = field_end;
    return payload[field_start..field_end];
}

fn isPositiveDecimal(value: []const u8) bool {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return value[0] != '0';
}

fn isValidSessionCookie(value: []const u8) bool {
    const prefix = "ansi_sciagnij=";
    if (!std.mem.startsWith(u8, value, prefix) or value.len == prefix.len) return false;
    for (value[prefix.len..]) |c| {
        if (c < 0x21 or c == ';' or c == 0x7f) return false;
    }
    return true;
}

const RawResponse = common.RawResponse;

fn fetchRawGet(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    deadline_ms: i64,
) !RawResponse {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;

    const FetchTask = struct {
        fn run(result: *?RawResponse, task_client: *std.http.Client, task_allocator: Allocator, task_url: []const u8) !void {
            result.* = try fetchRawGetUnbounded(task_client, task_allocator, task_url);
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
    try selection.concurrent(.fetch, FetchTask.run, .{ &owned_response, client, allocator, url });
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

fn fetchRawGetUnbounded(client: *std.http.Client, allocator: Allocator, url: []const u8) !RawResponse {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return fetchRawGetOnce(client, allocator, url) catch |err| {
            if (common.mustNotRetryFetchError(err)) return err;
            if (attempt + 1 >= 4) return err;
            const shift: u6 = @intCast(@min(attempt, 4));
            try common.sleepMillisecondsCancelable(@as(u64, 250) << shift);
            continue;
        };
    }
}

fn fetchRawGetOnce(client: *std.http.Client, allocator: Allocator, url: []const u8) !RawResponse {
    try validateProviderUrl(url);
    try common.validateHttpHeaders(&.{.{ .name = "accept", .value = "text/html,application/xhtml+xml,*/*" }});
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
            .user_agent = .{ .override = "Sub-Zero/2" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &[_]std.http.Header{
            .{ .name = "accept", .value = "text/html,application/xhtml+xml,*/*" },
        },
    }) catch |err| {
        public_client.connection_pool.release(pinned_connection, public_client.io);
        return err;
    };
    defer req.deinit();
    errdefer req.connection.?.closing = true;
    req.sendBodiless() catch |err| return common.normalizeRequestWriteError(&req, err);

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    var interim_count: usize = 0;
    while (response.head.status.class() == .informational) {
        if (response.head.status == .switching_protocols) return error.UnsupportedProtocolUpgrade;
        try validateRawSearchResponseHead(response.head);
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    try validateRawSearchResponseHead(response.head);
    const cookie = try extractCookie(allocator, response.head.bytes);
    errdefer if (cookie) |value| allocator.free(value);

    const body = try common.readStrictResponseBody(&req, &response, allocator, max_raw_response_bytes);
    errdefer allocator.free(body);

    return .{
        .status = response.head.status,
        .body = body,
        .cookie = cookie,
    };
}

fn validateRawSearchResponseHead(head: std.http.Client.Response.Head) !void {
    try common.validateResponseFraming(head);
}

fn validateProviderUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
    if (uri.fragment != null) return error.InvalidDownloadUrl;

    const prefix = search_path ++ "?szukane=";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidDownloadUrl;
    const query_tail = url[prefix.len..];
    const title_marker = "&pTitle=";
    const title_pos = std.mem.indexOf(u8, query_tail, title_marker) orelse return error.InvalidDownloadUrl;
    const encoded_query = query_tail[0..title_pos];
    if (encoded_query.len == 0 or !isCanonicalUriComponent(encoded_query)) return error.InvalidDownloadUrl;
    const title_and_sort = query_tail[title_pos + title_marker.len ..];
    const sort_marker = "&pSortuj=pobrn";
    if (!std.mem.endsWith(u8, title_and_sort, sort_marker)) return error.InvalidDownloadUrl;
    const title_type = title_and_sort[0 .. title_and_sort.len - sort_marker.len];
    if (!(std.mem.eql(u8, title_type, "org") or
        std.mem.eql(u8, title_type, "en") or
        std.mem.eql(u8, title_type, "pl")))
    {
        return error.InvalidDownloadUrl;
    }
}

fn isCanonicalUriComponent(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            i += 1;
            continue;
        }
        if (c != '%' or i + 2 >= value.len or
            !std.ascii.isHex(value[i + 1]) or !std.ascii.isHex(value[i + 2]))
        {
            return false;
        }
        i += 3;
    }
    return true;
}

fn extractCookie(allocator: Allocator, headers: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.findIgnoreCase(value, "ansi_sciagnij=") != 0) continue;
        const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        return @as(?[]u8, try allocator.dupe(u8, value[0..end]));
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

test "animesubinfo rejects non-provider session targets before fetching" {
    try validateProviderUrl("http://animesub.info/szukaj.php?szukane=test&pTitle=org&pSortuj=pobrn");
    for ([_][]const u8{
        "http://127.0.0.1/szukaj.php",
        "http://animesub.info.example/szukaj.php",
        "http://user@animesub.info/szukaj.php",
        "https://animesub.info/szukaj.php",
        "http://animesub.info/private?szukane=test&pTitle=org&pSortuj=pobrn",
        "http://animesub.info/szukaj.php?szukane=test&pTitle=org&pSortuj=pobrn&next=/private",
        "http://animesub.info/szukaj.php?szukane=test&pTitle=other&pSortuj=pobrn",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url));
    }
}

test "animesubinfo token is length delimited and contains no session material" {
    const page_url = search_path ++ "?szukane=A%7CB&pTitle=org&pSortuj=pobrn";
    const token = try makeDownloadToken(std.testing.allocator, .{
        .title = "fixture",
        .media_kind = .movie,
        .season = null,
        .episode = null,
        .subtitle_id = "7",
        .search_query = "fixture",
        .title_type = "org",
        .page_url = page_url,
    });
    defer std.testing.allocator.free(token);
    const parsed = parseDownloadToken(token).?;
    try std.testing.expectEqualStrings("7", parsed.subtitle_id);
    try std.testing.expectEqualStrings(page_url, parsed.search_url);
    try std.testing.expect(std.mem.indexOf(u8, token, "hash|with|pipes") == null);
    try std.testing.expect(std.mem.indexOf(u8, token, "ansi_sciagnij=sentinel") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "v1:1:74:hash24:ansi_sciagnij=sentinel1:x") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "v2:01:7") == null);
}

test "animesubinfo binds id and hash values to their own input elements" {
    const reordered = "<form><input value='7' name='id'><input value='fresh-hash-123456' name='sh'></form>";
    try std.testing.expectEqualStrings("fresh-hash-123456", findHashForId(reordered, "7").?);

    const malformed = "<form><input name=\"id\"><input name=\"decoy\" value=\"7\"><input name=\"sh\" value=\"fresh-hash-123456\"></form>";
    try std.testing.expect(findHashForId(malformed, "7") == null);

    const malformed_duplicate =
        "<form><input name='id' value='7'><input name='sh' value='short'></form>" ++
        "<form><input name='id' value='7'></form>" ++
        "<form><input name='id' value='7'><input name='sh' value='fresh-hash-123456'></form>";
    try std.testing.expectEqualStrings("fresh-hash-123456", findHashForId(malformed_duplicate, "7").?);
}

test "animesubinfo raw request policy does not retry invalid provider URLs" {
    try std.testing.expect(common.mustNotRetryFetchError(error.InvalidDownloadUrl));
    try std.testing.expect(common.mustNotRetryFetchError(error.ResponseTooLarge));
    try std.testing.expect(!common.mustNotRetryFetchError(error.ConnectionResetByPeer));
}

test "animesubinfo raw request rejects an expired deadline before I/O" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const now_ms = common.compatMilliTimestamp();
    try std.testing.expectError(
        error.Timeout,
        fetchRawGet(&client, std.testing.allocator, search_path, now_ms),
    );
}

test "animesubinfo distinguishes failed variants from a successful fallback" {
    const Mock = struct {
        fn blocked(_: *std.http.Client, a: Allocator, _: []const u8, _: i64) !RawResponse {
            return .{ .status = .forbidden, .body = try a.dupe(u8, "blocked"), .cookie = null };
        }
        fn limited(_: *std.http.Client, a: Allocator, _: []const u8, _: i64) !RawResponse {
            return .{ .status = .too_many_requests, .body = try a.dupe(u8, "limited"), .cookie = null };
        }
        fn fallback(_: *std.http.Client, a: Allocator, url: []const u8, _: i64) !RawResponse {
            return .{
                .status = if (std.mem.indexOf(u8, url, "pTitle=en") != null) .ok else .forbidden,
                .body = try a.dupe(u8, ""),
                .cookie = null,
            };
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    try std.testing.expectError(error.UnexpectedHttpStatus, scraper.searchWithFetcher("Show", Mock.blocked, std.math.maxInt(i64)));
    try std.testing.expectError(error.RateLimited, scraper.searchWithFetcher("Show", Mock.limited, std.math.maxInt(i64)));
    var fallback = try scraper.searchWithFetcher("Show", Mock.fallback, std.math.maxInt(i64));
    defer fallback.deinit();
    try std.testing.expectEqual(@as(usize, 0), fallback.items.len);
}

test "animesubinfo stops at a rate-limited title variant" {
    const Fixture = struct {
        client: std.http.Client,
        limited_call: usize,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, a: Allocator, _: []const u8, _: i64) !RawResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return .{
                .status = if (self.calls == self.limited_call) .too_many_requests else .ok,
                .body = try a.dupe(u8, ""),
                .cookie = null,
            };
        }
    };
    for ([_]usize{ 1, 2 }) |limited_call| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .limited_call = limited_call,
        };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        try std.testing.expectError(error.RateLimited, scraper.searchWithFetcher("Show", Fixture.fetch, std.math.maxInt(i64)));
        try std.testing.expectEqual(limited_call, fixture.calls);
    }
}

test "animesubinfo searches Polish after an exact English result" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        const marker = "<table cellspacing=\"2\" cellpadding=\"2\" width=\"100%\" class=\"Napisy\" style=\"text-align:center\">";
        const english_body = marker ++
            "<td align=\"left\">Show</td><form><input name='id' value='7'><input name='sh' value='valid-hash-12345678'></form>";
        const polish_body = marker ++
            "<td align=\"left\">Show</td><form><input name='id' value='7'><input name='sh' value='valid-hash-12345678'></form>" ++
            marker ++
            "<td align=\"left\">Show</td><form><input name='id' value='8'><input name='sh' value='valid-hash-87654321'></form>";

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, deadline_ms: i64) !RawResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqual(std.math.maxInt(i64), deadline_ms);
            const body = if (std.mem.indexOf(u8, url, "pTitle=en") != null)
                english_body
            else if (std.mem.indexOf(u8, url, "pTitle=pl") != null)
                polish_body
            else
                "";
            return .{ .status = .ok, .body = try allocator.dupe(u8, body), .cookie = null };
        }
    };

    var fixture: Fixture = .{
        .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
    };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchWithFetcher("Show", Fixture.fetch, std.math.maxInt(i64));
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings("7", response.items[0].subtitle_id);
    try std.testing.expectEqualStrings("en", response.items[0].title_type);
    try std.testing.expectEqualStrings("8", response.items[1].subtitle_id);
    try std.testing.expectEqualStrings("pl", response.items[1].title_type);
}

test "animesubinfo download binds a fresh cookie and hash from one search response" {
    const Scenario = struct {
        search_status: std.http.Status = .ok,
        search_body: []const u8 = "<form><input name=\"id\" value=\"7\"><input name=\"sh\" value=\"fresh-hash-123456\"></form>",
        cookie: ?[]const u8 = "ansi_sciagnij=fresh",
        download_status: std.http.Status = .ok,
        expected_error: ?anyerror = null,
        expected_posts: usize,
    };
    const Fixture = struct {
        client: std.http.Client,
        scenario: Scenario,
        requests: usize = 0,
        posts: usize = 0,
        searches: usize = 0,

        fn search(client: *std.http.Client, a: Allocator, url: []const u8, deadline_ms: i64) !RawResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.requests += 1;
            self.searches += 1;
            try std.testing.expectEqual(@as(usize, 1), self.requests);
            try std.testing.expectEqual(@as(usize, 1), self.searches);
            try std.testing.expectEqual(std.math.maxInt(i64), deadline_ms);
            try std.testing.expectEqualStrings(search_path ++ "?szukane=fixture&pTitle=org&pSortuj=pobrn", url);
            const body = try a.dupe(u8, self.scenario.search_body);
            errdefer a.free(body);
            const cookie = if (self.scenario.cookie) |value| try a.dupe(u8, value) else null;
            return .{
                .status = self.scenario.search_status,
                .body = body,
                .cookie = cookie,
            };
        }

        fn download(client: *std.http.Client, a: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.requests += 1;
            self.posts += 1;
            try std.testing.expectEqual(@as(usize, 1), self.posts);
            try std.testing.expectEqual(@as(usize, 2), self.requests);
            try std.testing.expectEqualStrings(download_path, url);
            try std.testing.expectEqual(std.http.Method.POST, options.method);
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expectEqual(std.math.maxInt(i64), options.deadline_ms.?);
            try std.testing.expectEqualStrings("ansi_sciagnij=fresh", options.extra_headers[0].value);
            try std.testing.expectEqualStrings(search_path ++ "?szukane=fixture&pTitle=org&pSortuj=pobrn", options.extra_headers[1].value);
            try std.testing.expect(std.mem.indexOf(u8, options.payload.?, "id=7") != null);
            try std.testing.expect(std.mem.indexOf(u8, options.payload.?, "sh=fresh-hash-123456") != null);
            const status = self.scenario.download_status;
            return .{
                .status = status,
                .body = try a.dupe(u8, if (status == .ok) "PK\x03\x04fixture" else "Unavailable"),
            };
        }
    };
    const scenarios = [_]Scenario{
        .{ .expected_posts = 1 },
        .{ .search_status = .too_many_requests, .expected_error = error.RateLimited, .expected_posts = 0 },
        .{ .search_status = .forbidden, .expected_error = error.UnexpectedHttpStatus, .expected_posts = 0 },
        .{ .cookie = null, .expected_error = error.SessionExpired, .expected_posts = 0 },
        .{ .search_body = "<form><input name=\"id\" value=\"8\"><input name=\"sh\" value=\"other-hash\"></form>", .expected_error = error.MissingField, .expected_posts = 0 },
        .{ .search_body = "<form><input name=\"id\" value=\"7\"></form><form><input name=\"id\" value=\"8\"><input name=\"sh\" value=\"fresh-hash-123456\"></form>", .expected_error = error.MissingField, .expected_posts = 0 },
        .{ .download_status = .too_many_requests, .expected_error = error.RateLimited, .expected_posts = 1 },
        .{ .download_status = .forbidden, .expected_error = error.UnexpectedResponseType, .expected_posts = 1 },
    };
    const token = try makeDownloadToken(std.testing.allocator, .{
        .title = "fixture",
        .media_kind = .movie,
        .season = null,
        .episode = null,
        .subtitle_id = "7",
        .search_query = "fixture",
        .title_type = "org",
        .page_url = search_path ++ "?szukane=fixture&pTitle=org&pSortuj=pobrn",
    });
    defer std.testing.allocator.free(token);
    for (scenarios) |scenario| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .scenario = scenario,
        };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        if (scenario.expected_error) |expected_error| {
            try std.testing.expectError(expected_error, scraper.fetchDownloadByTokenWithFetchers(std.testing.allocator, token, Fixture.search, Fixture.download, std.math.maxInt(i64)));
        } else {
            const response = try scraper.fetchDownloadByTokenWithFetchers(std.testing.allocator, token, Fixture.search, Fixture.download, std.math.maxInt(i64));
            defer std.testing.allocator.free(response.body);
            try std.testing.expect(downloadResponseIsValid(response));
        }
        try std.testing.expectEqual(scenario.expected_posts, fixture.posts);
        try std.testing.expectEqual(@as(usize, 1), fixture.searches);
    }
}

test "animesubinfo parses movie and episode rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    try appendSearchRows(
        a,
        "<table cellspacing=\"2\" cellpadding=\"2\" width=\"100%\" class=\"Napisy\" style=\"text-align:center\"><tr class=\"KNap\"><td align=\"left\" width=\"45%\">Death Note ep01</td></tr><tr class=\"KNap\"><td align=\"left\">Death Note ep01</td></tr><tr class=\"KNap\"><td align=\"left\">Notatnik smierci ep01</td></tr><tr class=\"KKom\"><td><form><input type=\"hidden\" name=\"id\" value=\"13785\"><input type=\"hidden\" name=\"sh\" value=\"abc123456789012345\"></form></td></tr></table>",
        "Death Note",
        "org",
        "http://animesub.info/szukaj.php?x",
        &exact,
        &partial,
    );
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqual(MediaKind.tv, exact.items[0].media_kind);
    try std.testing.expectEqual(@as(?i64, 1), exact.items[0].episode);
}

test "animesubinfo invalid exact ids do not shadow a later valid row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    const marker = "<table cellspacing=\"2\" cellpadding=\"2\" width=\"100%\" class=\"Napisy\" style=\"text-align:center\">";
    const body = marker ++
        "<td align=\"left\">Target</td><form><input name='id' value='0'><input name='sh' value='invalid-hash-123456'></form>" ++
        marker ++
        "<td align=\"left\">Target</td><form><input name='id' value='007'><input name='sh' value='invalid-hash-123456'></form>" ++
        marker ++
        "<td align=\"left\">Target</td><form><input name='id' value='7'><input name='sh' value='valid-hash-12345678'></form>";
    try appendSearchRows(
        allocator,
        body,
        "Target",
        "en",
        search_path ++ "?szukane=Target&pTitle=en&pSortuj=pobrn",
        &exact,
        &partial,
    );
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqual(@as(usize, 0), partial.items.len);
    try std.testing.expectEqualStrings("7", exact.items[0].subtitle_id);
}

test "animesubinfo caps merged variants and promotes later exact duplicates" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        const marker = "<table cellspacing=\"2\" cellpadding=\"2\" width=\"100%\" class=\"Napisy\" style=\"text-align:center\">";

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, deadline_ms: i64) !RawResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqual(std.math.maxInt(i64), deadline_ms);

            var body: std.Io.Writer.Allocating = .init(allocator);
            defer body.deinit();
            if (std.mem.indexOf(u8, url, "pTitle=org") != null) {
                for (0..max_search_items + 1) |index| {
                    try body.writer.print(
                        "{s}<td align=\"left\">Target Variant {d}</td><form><input name='id' value='{d}'><input name='sh' value='valid-hash-12345678'></form>",
                        .{ marker, index + 1, index + 1 },
                    );
                }
            } else if (std.mem.indexOf(u8, url, "pTitle=en") != null) {
                try body.writer.print(
                    "{s}<td align=\"left\">Target</td><form><input name='id' value='1'><input name='sh' value='valid-hash-12345678'></form>" ++
                        "{s}<td align=\"left\">Target</td><form><input name='id' value='{d}'><input name='sh' value='valid-hash-12345678'></form>",
                    .{ marker, marker, max_search_items + 2 },
                );
            }
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8, body.written()),
                .cookie = null,
            };
        }
    };

    var fixture: Fixture = .{
        .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
    };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchWithFetcher("Target", Fixture.fetch, std.math.maxInt(i64));
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqual(@as(usize, max_search_items), response.items.len);
    try std.testing.expectEqualStrings("1", response.items[0].subtitle_id);
    try std.testing.expectEqualStrings("en", response.items[0].title_type);
    try std.testing.expectEqualStrings("Target", response.items[0].title);
    try std.testing.expectEqualStrings("26", response.items[1].subtitle_id);
    try std.testing.expectEqualStrings("2", response.items[2].subtitle_id);
}

test "animesubinfo raw search transport rejects ambiguous response framing" {
    for ([_][]const u8{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
    }) |raw_head| {
        const head = try std.http.Client.Response.Head.parse(raw_head);
        try std.testing.expectError(error.AmbiguousHttpFraming, validateRawSearchResponseHead(head));
    }
}

test "live animesubinfo movie and episode downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "animesub.info")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Spirited Away");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subs = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subs.deinit();
    const movie_dl = try scraper.fetchDownloadByToken(std.testing.allocator, movie_subs.subtitles[0].download_url);
    defer std.testing.allocator.free(movie_dl.body);
    try std.testing.expect(movie_dl.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_dl.body[0..2], "PK"));

    var tv = try scraper.search("Death Note");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    const first_tv = for (tv.items) |item| {
        if (item.media_kind == .tv and item.episode == 1) break item;
    } else return error.TestUnexpectedResult;
    var tv_subs = try scraper.fetchSubtitlesBySearchItem(first_tv);
    defer tv_subs.deinit();
    const tv_dl = try scraper.fetchDownloadByToken(std.testing.allocator, tv_subs.subtitles[0].download_url);
    defer std.testing.allocator.free(tv_dl.body);
    try std.testing.expect(tv_dl.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_dl.body[0..2], "PK"));
}
