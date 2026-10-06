const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;
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
    download_hash: []const u8,
    session_cookie: []const u8,
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
        return self.searchWithFetcher(query, fetchRawGet);
    }

    fn searchWithFetcher(self: *Scraper, query: []const u8, comptime fetch: anytype) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var successful_variants: usize = 0;

        for ([_][]const u8{ "org", "en", "pl" }) |title_type| {
            const url = try buildSearchUrl(a, trimmed, title_type);
            var response = try fetch(self.client, a, url);
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
                response.cookie orelse "",
                &seen,
                &exact,
                &partial,
            );
            if (exact.items.len > 0 and title_type[0] != 'o') break;
        }

        if (successful_variants == 0) return error.UnexpectedHttpStatus;
        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        try items.appendSlice(a, exact.items);
        try items.appendSlice(a, partial.items);
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
        return self.fetchDownloadByTokenWithFetchers(allocator, token, fetchRawGet, common.fetchBytes);
    }

    fn fetchDownloadByTokenWithFetchers(
        self: *Scraper,
        allocator: Allocator,
        token: []const u8,
        comptime fetch_search: anytype,
        comptime fetch_download: anytype,
    ) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateProviderUrl(parts.search_url);
        if (parts.download_hash.len > 0 and parts.session_cookie.len > 0) {
            const response = try postDownload(
                self.client,
                allocator,
                parts.subtitle_id,
                parts.download_hash,
                parts.session_cookie,
                parts.search_url,
                fetch_download,
            );
            if (response.status == .too_many_requests) {
                allocator.free(response.body);
                return error.RateLimited;
            }
            if (downloadResponseIsValid(response)) return response;
            allocator.free(response.body);
        }

        var search_response = try fetch_search(self.client, allocator, parts.search_url);
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
) !common.HttpResponse {
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
    session_cookie: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
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
        if (seen.contains(subtitle_id)) continue;
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

        try seen.put(allocator, try allocator.dupe(u8, subtitle_id), {});
        const item: SearchItem = .{
            .title = try allocator.dupe(u8, base_title),
            .media_kind = media_kind,
            .season = if (media_kind == .tv) season orelse 1 else null,
            .episode = episode,
            .subtitle_id = try allocator.dupe(u8, subtitle_id),
            .download_hash = try allocator.dupe(u8, hash),
            .session_cookie = try allocator.dupe(u8, session_cookie),
            .search_query = try allocator.dupe(u8, query),
            .title_type = try allocator.dupe(u8, title_type),
            .page_url = try allocator.dupe(u8, search_url),
        };

        if (std.mem.eql(u8, normalized_base, wanted))
            try exact.append(allocator, item)
        else
            try partial.append(allocator, item);
    }
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
    const marker = "name=\"";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, block, cursor, marker)) |pos| {
        const name_start = pos + marker.len;
        const name_end = std.mem.indexOfScalar(u8, block[name_start..], '"') orelse return null;
        const found_name = block[name_start .. name_start + name_end];
        cursor = name_start + name_end + 1;
        if (!std.mem.eql(u8, found_name, name)) continue;

        const value_pos = std.mem.indexOfPos(u8, block, cursor, "value=\"") orelse return null;
        const value_start = value_pos + "value=\"".len;
        const value_end = std.mem.indexOfScalar(u8, block[value_start..], '"') orelse return null;
        return block[value_start .. value_start + value_end];
    }
    return null;
}

fn findHashForId(body: []const u8, subtitle_id: []const u8) ?[]const u8 {
    const marker = "name=\"id\" value=\"";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        const id_start = pos + marker.len;
        const id_end_rel = std.mem.indexOfScalar(u8, body[id_start..], '"') orelse return null;
        const found_id = body[id_start .. id_start + id_end_rel];
        cursor = id_start + id_end_rel + 1;
        if (!std.mem.eql(u8, found_id, subtitle_id)) continue;
        const sh_pos = std.mem.indexOfPos(u8, body, cursor, "name=\"sh\" value=\"") orelse return null;
        const sh_start = sh_pos + "name=\"sh\" value=\"".len;
        const sh_end_rel = std.mem.indexOfScalar(u8, body[sh_start..], '"') orelse return null;
        return body[sh_start .. sh_start + sh_end_rel];
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
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}|{s}|{s}|{s}",
        .{ download_token_prefix, item.subtitle_id, item.download_hash, item.session_cookie, item.page_url },
    );
}

const DownloadToken = struct {
    subtitle_id: []const u8,
    download_hash: []const u8,
    session_cookie: []const u8,
    search_url: []const u8,
};

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    const a = std.mem.indexOfScalar(u8, payload, '|') orelse return null;
    const rest1 = payload[a + 1 ..];
    const b_rel = std.mem.indexOfScalar(u8, rest1, '|') orelse return null;
    const b = a + 1 + b_rel;
    const rest2 = payload[b + 1 ..];
    const c_rel = std.mem.indexOfScalar(u8, rest2, '|') orelse return null;
    const c = b + 1 + c_rel;
    if (a == 0 or b <= a + 1 or c <= b + 1 or c + 1 >= payload.len) return null;
    return .{
        .subtitle_id = payload[0..a],
        .download_hash = payload[a + 1 .. b],
        .session_cookie = payload[b + 1 .. c],
        .search_url = payload[c + 1 ..],
    };
}

const RawResponse = common.RawResponse;

fn fetchRawGet(client: *std.http.Client, allocator: Allocator, url: []const u8) !RawResponse {
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
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    const cookie = try extractCookie(allocator, response.head.bytes);
    errdefer if (cookie) |value| allocator.free(value);

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = readBoundedBody(allocator, reader, max_raw_response_bytes) catch |err| {
        if (err == error.ReadFailed) {
            if (response.bodyErr()) |body_err| return body_err;
            return common.normalizeRequestReadError(&req, err);
        }
        return err;
    };
    errdefer allocator.free(body);
    switch (req.reader.state) {
        .body_remaining_content_length => |left| if (left != 0) return error.HttpBodyTruncated,
        .body_remaining_chunk_len => return error.HttpChunkTruncated,
        else => {},
    }

    return .{
        .status = response.head.status,
        .body = body,
        .cookie = cookie,
    };
}

fn validateProviderUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
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
    try validateProviderUrl("http://animesub.info/szukaj.php?szukane=test");
    for ([_][]const u8{
        "http://127.0.0.1/szukaj.php",
        "http://animesub.info.example/szukaj.php",
        "http://user@animesub.info/szukaj.php",
        "https://animesub.info/szukaj.php",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url));
    }
}

test "animesubinfo raw request policy does not retry invalid provider URLs" {
    try std.testing.expect(common.mustNotRetryFetchError(error.InvalidDownloadUrl));
    try std.testing.expect(common.mustNotRetryFetchError(error.ResponseTooLarge));
    try std.testing.expect(!common.mustNotRetryFetchError(error.ConnectionResetByPeer));
}

test "animesubinfo distinguishes failed variants from a successful fallback" {
    const Mock = struct {
        fn blocked(_: *std.http.Client, a: Allocator, _: []const u8) !RawResponse {
            return .{ .status = .forbidden, .body = try a.dupe(u8, "blocked"), .cookie = null };
        }
        fn limited(_: *std.http.Client, a: Allocator, _: []const u8) !RawResponse {
            return .{ .status = .too_many_requests, .body = try a.dupe(u8, "limited"), .cookie = null };
        }
        fn fallback(_: *std.http.Client, a: Allocator, url: []const u8) !RawResponse {
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
    try std.testing.expectError(error.UnexpectedHttpStatus, scraper.searchWithFetcher("Show", Mock.blocked));
    try std.testing.expectError(error.RateLimited, scraper.searchWithFetcher("Show", Mock.limited));
    var fallback = try scraper.searchWithFetcher("Show", Mock.fallback);
    defer fallback.deinit();
    try std.testing.expectEqual(@as(usize, 0), fallback.items.len);
}

test "animesubinfo stops at a rate-limited title variant" {
    const Fixture = struct {
        client: std.http.Client,
        limited_call: usize,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, a: Allocator, _: []const u8) !RawResponse {
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
        try std.testing.expectError(error.RateLimited, scraper.searchWithFetcher("Show", Fixture.fetch));
        try std.testing.expectEqual(limited_call, fixture.calls);
    }
}

test "animesubinfo download recovery stops on rate limits and refreshes at most once" {
    const Scenario = struct {
        initial_status: std.http.Status = .forbidden,
        search_status: std.http.Status = .ok,
        retry_status: std.http.Status = .ok,
        expected_error: ?anyerror = null,
        expected_posts: usize,
        expected_searches: usize,
    };
    const Fixture = struct {
        client: std.http.Client,
        scenario: Scenario,
        requests: usize = 0,
        posts: usize = 0,
        searches: usize = 0,

        fn search(client: *std.http.Client, a: Allocator, url: []const u8) !RawResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.requests += 1;
            self.searches += 1;
            try std.testing.expectEqual(@as(usize, 2), self.requests);
            try std.testing.expectEqual(@as(usize, 1), self.searches);
            try std.testing.expectEqualStrings(search_path ++ "?fixture=1", url);
            const body = try a.dupe(u8, "<input name=\"id\" value=\"7\"><input name=\"sh\" value=\"fresh-hash\">");
            errdefer a.free(body);
            return .{
                .status = self.scenario.search_status,
                .body = body,
                .cookie = try a.dupe(u8, "ansi_sciagnij=fresh"),
            };
        }

        fn download(client: *std.http.Client, a: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.requests += 1;
            self.posts += 1;
            try std.testing.expect(self.posts <= 2);
            try std.testing.expectEqual(@as(usize, if (self.posts == 1) 1 else 3), self.requests);
            try std.testing.expectEqualStrings(download_path, url);
            try std.testing.expectEqual(std.http.Method.POST, options.method);
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expectEqualStrings(
                if (self.posts == 1) "ansi_sciagnij=initial" else "ansi_sciagnij=fresh",
                options.extra_headers[0].value,
            );
            const expected_hash = if (self.posts == 1) "sh=initial-hash" else "sh=fresh-hash";
            try std.testing.expect(std.mem.indexOf(u8, options.payload.?, expected_hash) != null);
            const status = if (self.posts == 1) self.scenario.initial_status else self.scenario.retry_status;
            return .{
                .status = status,
                .body = try a.dupe(u8, if (status == .ok) "PK\x03\x04fixture" else "Unavailable"),
            };
        }
    };
    const scenarios = [_]Scenario{
        .{ .initial_status = .too_many_requests, .expected_error = error.RateLimited, .expected_posts = 1, .expected_searches = 0 },
        .{ .search_status = .too_many_requests, .expected_error = error.RateLimited, .expected_posts = 1, .expected_searches = 1 },
        .{ .retry_status = .too_many_requests, .expected_error = error.RateLimited, .expected_posts = 2, .expected_searches = 1 },
        .{ .initial_status = .ok, .expected_posts = 1, .expected_searches = 0 },
        .{ .expected_posts = 2, .expected_searches = 1 },
        .{ .search_status = .forbidden, .expected_error = error.UnexpectedHttpStatus, .expected_posts = 1, .expected_searches = 1 },
        .{ .retry_status = .forbidden, .expected_error = error.UnexpectedResponseType, .expected_posts = 2, .expected_searches = 1 },
    };
    const token = download_token_prefix ++ "7|initial-hash|ansi_sciagnij=initial|" ++ search_path ++ "?fixture=1";
    for (scenarios) |scenario| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .scenario = scenario,
        };
        defer fixture.client.deinit();
        var scraper = Scraper.init(std.testing.allocator, &fixture.client);
        if (scenario.expected_error) |expected_error| {
            try std.testing.expectError(expected_error, scraper.fetchDownloadByTokenWithFetchers(std.testing.allocator, token, Fixture.search, Fixture.download));
        } else {
            const response = try scraper.fetchDownloadByTokenWithFetchers(std.testing.allocator, token, Fixture.search, Fixture.download);
            defer std.testing.allocator.free(response.body);
            try std.testing.expect(downloadResponseIsValid(response));
        }
        try std.testing.expectEqual(scenario.expected_posts, fixture.posts);
        try std.testing.expectEqual(scenario.expected_searches, fixture.searches);
    }
}

test "animesubinfo parses movie and episode rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    try appendSearchRows(
        a,
        "<table cellspacing=\"2\" cellpadding=\"2\" width=\"100%\" class=\"Napisy\" style=\"text-align:center\"><tr class=\"KNap\"><td align=\"left\" width=\"45%\">Death Note ep01</td></tr><tr class=\"KNap\"><td align=\"left\">Death Note ep01</td></tr><tr class=\"KNap\"><td align=\"left\">Notatnik smierci ep01</td></tr><tr class=\"KKom\"><td><form><input type=\"hidden\" name=\"id\" value=\"13785\"><input type=\"hidden\" name=\"sh\" value=\"abc123456789012345\"></form></td></tr></table>",
        "Death Note",
        "org",
        "http://animesub.info/szukaj.php?x",
        "ansi_sciagnij=test",
        &seen,
        &exact,
        &partial,
    );
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqual(MediaKind.tv, exact.items[0].media_kind);
    try std.testing.expectEqual(@as(?i64, 1), exact.items[0].episode);
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
