const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.subcentral.de";
const home_url = site ++ "/";
const max_raw_response_bytes = (common.FetchOptions{}).max_response_bytes;

pub const SearchItem = struct {
    title: []const u8,
    season: i64,
    board_url: []const u8,
    thread_url: []const u8,
};

pub const SubtitleItem = struct {
    language_code: []const u8,
    filename: []const u8,
    download_url: []const u8,
    episode: i64,
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const home = try common.fetchBytes(self.client, a, home_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        const board = try findBoard(a, home.body, trimmed) orelse return .{ .arena = arena, .items = &.{} };

        const board_page = try common.fetchBytes(self.client, a, board.url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = home_url }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        const items = try parseBoardThreads(a, board_page.body, board.title, board.url);
        return .{ .arena = arena, .items = items };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemUsing(item, fetchRaw);
    }

    fn fetchSubtitlesBySearchItemUsing(self: *Scraper, item: SearchItem, comptime fetch: anytype) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;

        try validateItemRoute(item.board_url, .board);
        try validateItemRoute(item.thread_url, .thread);

        var thread = try fetch(self.client, a, item.thread_url, null, item.board_url, deadline_ms);
        defer thread.deinit(a);
        try requireOkResponseStatus(thread.status);

        const already_revealed = try parseRevealedAttachments(a, thread.body, item.title, item.season);
        if (already_revealed.len > 0) {
            return common.finishResponse(SubtitlesResponse, &arena, .{
                .arena = arena,
                .title = try a.dupe(u8, item.title),
                .subtitles = already_revealed,
            });
        }

        const gate = try parseGate(a, thread.body);
        const thank_url = try buildThankUrl(a, gate);

        var revealed = try fetch(self.client, a, thank_url, thread.cookie, item.thread_url, deadline_ms);
        defer revealed.deinit(a);
        try requireOkResponseStatus(revealed.status);

        var subtitles = try parseRevealedAttachments(a, revealed.body, item.title, item.season);
        if (subtitles.len == 0) {
            const refresh_cookie = revealed.cookie orelse thread.cookie;
            var refreshed = try fetch(self.client, a, item.thread_url, refresh_cookie, item.board_url, deadline_ms);
            defer refreshed.deinit(a);
            try requireOkResponseStatus(refreshed.status);
            subtitles = try parseRevealedAttachments(a, refreshed.body, item.title, item.season);
        }
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

const Board = struct {
    title: []const u8,
    url: []const u8,
};

fn requireOkResponseStatus(status: std.http.Status) !void {
    if (status == .too_many_requests) return error.RateLimited;
    if (status == .unauthorized or status == .forbidden) return error.ProviderAccessBlocked;
    if (status != .ok) return error.UnexpectedHttpStatus;
}

fn findBoard(allocator: Allocator, body: []const u8, query: []const u8) !?Board {
    const wanted = try common.normalizeTitle(allocator, query);
    defer allocator.free(wanted);
    if (wanted.len == 0) return null;

    var partial: ?Board = null;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, "<option")) |start| {
        const next_option = std.mem.indexOfPos(u8, body, start + "<option".len, "<option");
        const tag_end = std.mem.indexOfPos(u8, body, start, ">") orelse {
            cursor = next_option orelse break;
            continue;
        };
        if (next_option) |next| {
            if (next < tag_end) {
                cursor = next;
                continue;
            }
        }
        const close = std.mem.indexOfPos(u8, body, tag_end + 1, "</option>") orelse {
            cursor = next_option orelse break;
            continue;
        };
        if (next_option) |next| {
            if (next < close) {
                cursor = next;
                continue;
            }
        }
        cursor = close + "</option>".len;

        const tag = body[start .. tag_end + 1];
        const value = attributeValue(tag, "value") orelse continue;
        if (!isCanonicalPositiveId(value)) continue;
        const raw_title = body[tag_end + 1 .. close];
        const title = std.mem.trim(u8, stripSimpleTags(raw_title), " \t\r\n");
        if (title.len == 0) continue;

        const normalized = try common.normalizeTitle(allocator, title);
        defer allocator.free(normalized);
        if (normalized.len == 0) continue;

        const board: Board = .{
            .title = try allocator.dupe(u8, title),
            .url = try std.fmt.allocPrint(allocator, "{s}/index.php?page=Board&boardID={s}", .{ site, value }),
        };
        if (std.mem.eql(u8, normalized, wanted)) return board;
        if (partial == null and normalizedTitlesRelated(normalized, wanted)) {
            partial = board;
        }
    }
    return partial;
}

fn normalizedTitlesRelated(lhs: []const u8, rhs: []const u8) bool {
    return containsNormalizedPhrase(lhs, rhs) or containsNormalizedPhrase(rhs, lhs);
}

fn containsNormalizedPhrase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len == 0 or needle.len == 0 or needle.len > haystack.len) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        const end = index + needle.len;
        const starts_at_boundary = index == 0 or haystack[index - 1] == ' ';
        const ends_at_boundary = end == haystack.len or haystack[end] == ' ';
        if (starts_at_boundary and ends_at_boundary) return true;
        start = index + 1;
    }
    return false;
}

fn parseBoardThreads(allocator: Allocator, body: []const u8, series_title: []const u8, board_url: []const u8) ![]const SearchItem {
    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var cursor: usize = 0;
    const marker = "page=Thread&amp;threadID=";
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        const id_start = pos + marker.len;
        var id_end = id_start;
        while (id_end < body.len and std.ascii.isDigit(body[id_end])) : (id_end += 1) {}
        if (id_end == id_start) {
            cursor = pos + marker.len;
            continue;
        }
        const thread_id = body[id_start..id_end];
        cursor = id_end;
        if (!isCanonicalPositiveId(thread_id) or !hasQuotedIdTerminator(body, id_end)) continue;
        if (seen.contains(thread_id)) continue;

        const gt = std.mem.indexOfPos(u8, body, id_end, ">") orelse continue;
        if (gt - pos > 600) continue;
        const close = std.mem.indexOfPos(u8, body, gt + 1, "</a>") orelse continue;
        if (close - gt > 600) continue;
        const title = std.mem.trim(u8, stripSimpleTags(body[gt + 1 .. close]), " \t\r\n");
        if (std.ascii.findIgnoreCase(title, "DE-Subs") == null and
            std.ascii.findIgnoreCase(title, "VO-Subs") == null) continue;
        const season = parseSeason(title) orelse continue;

        try seen.put(allocator, try allocator.dupe(u8, thread_id), {});
        try out.append(allocator, .{
            .title = try allocator.dupe(u8, series_title),
            .season = season,
            .board_url = try allocator.dupe(u8, board_url),
            .thread_url = try std.fmt.allocPrint(allocator, "{s}/index.php?page=Thread&threadID={s}", .{ site, thread_id }),
        });
    }

    const owned = try out.toOwnedSlice(allocator);
    std.mem.sort(SearchItem, owned, {}, searchLessThan);
    return owned;
}

fn searchLessThan(_: void, lhs: SearchItem, rhs: SearchItem) bool {
    return lhs.season < rhs.season;
}

const Gate = struct {
    post_id: []const u8,
    token: []const u8,
};

fn buildThankUrl(allocator: Allocator, gate: Gate) ![]u8 {
    if (!isCanonicalPositiveId(gate.post_id) or gate.token.len == 0) return error.MissingField;
    const encoded_token = try common.encodeUriComponent(allocator, gate.token);
    defer allocator.free(encoded_token);
    return std.fmt.allocPrint(
        allocator,
        "{s}/index.php?action=Thank&output=xml&postID={s}&t={s}",
        .{ site, gate.post_id, encoded_token },
    );
}

fn parseGate(allocator: Allocator, body: []const u8) !Gate {
    const token = findGateToken(body) orelse return error.MissingField;
    const post_id = findGatePostId(body) orelse return error.MissingField;

    return .{
        .post_id = try allocator.dupe(u8, post_id),
        .token = try allocator.dupe(u8, token),
    };
}

fn findGateToken(body: []const u8) ?[]const u8 {
    const marker = "SECURITY_TOKEN = '";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |marker_pos| {
        const token_start = marker_pos + marker.len;
        const token_end_offset = std.mem.indexOfScalar(u8, body[token_start..], '\'') orelse {
            cursor = token_start;
            continue;
        };
        const token_end = token_start + token_end_offset;
        if (std.mem.indexOfPos(u8, body, token_start, marker)) |next_marker| {
            if (next_marker < token_end) {
                cursor = next_marker;
                continue;
            }
        }
        if (token_end > token_start) return body[token_start..token_end];
        cursor = token_end + 1;
    }
    return null;
}

fn findGatePostId(body: []const u8) ?[]const u8 {
    const marker = "thankPostButton";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |marker_pos| {
        const id_start = marker_pos + marker.len;
        var id_end = id_start;
        while (id_end < body.len and std.ascii.isDigit(body[id_end])) : (id_end += 1) {}
        cursor = id_start;
        const post_id = body[id_start..id_end];
        if (!isCanonicalPositiveId(post_id) or !hasQuotedIdTerminator(body, id_end)) continue;
        return post_id;
    }
    return null;
}

fn hasQuotedIdTerminator(body: []const u8, id_end: usize) bool {
    return id_end == body.len or body[id_end] == '"' or body[id_end] == '\'';
}

fn parseRevealedAttachments(allocator: Allocator, body: []const u8, series_title: []const u8, season: i64) ![]const SubtitleItem {
    var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var current_language: ?[]const u8 = null;
    var cursor: usize = 0;

    while (cursor < body.len) {
        const de_pos = std.mem.indexOfPos(u8, body, cursor, "flags/de.png");
        const en_uk_pos = std.mem.indexOfPos(u8, body, cursor, "flags/uk.png");
        const en_usa_pos = std.mem.indexOfPos(u8, body, cursor, "flags/usa.png");
        var en_pos = en_uk_pos;
        if (en_usa_pos) |p| {
            if (en_pos == null or p < en_pos.?) en_pos = p;
        }
        // Current pages put the alternating `aktiv` class on only one episode
        // row. The release cell is the stable row discriminator.
        const row_pos = std.mem.indexOfPos(u8, body, cursor, "class=\"release\"");

        var next_pos: ?usize = null;
        var event: enum { de, en, row } = .row;
        if (de_pos) |p| {
            next_pos = p;
            event = .de;
        }
        if (en_pos) |p| {
            if (next_pos == null or p < next_pos.?) {
                next_pos = p;
                event = .en;
            }
        }
        if (row_pos) |p| {
            if (next_pos == null or p < next_pos.?) {
                next_pos = p;
                event = .row;
            }
        }
        const pos = next_pos orelse break;

        switch (event) {
            .de => {
                current_language = "de";
                cursor = pos + "flags/de.png".len;
            },
            .en => {
                current_language = "en";
                // Both supported flag names start here; advancing one byte is
                // enough to prevent rediscovering the same marker.
                cursor = pos + 1;
            },
            .row => {
                const row_end = std.mem.indexOfPos(u8, body, pos, "</tr>") orelse break;
                const row = body[pos .. row_end + "</tr>".len];
                cursor = row_end + "</tr>".len;
                const language = current_language orelse continue;

                const release_marker = "class=\"release\"";
                const release_pos = std.mem.indexOf(u8, row, release_marker) orelse continue;
                const release_gt = std.mem.indexOfPos(u8, row, release_pos, ">") orelse continue;
                const release_close = std.mem.indexOfPos(u8, row, release_gt + 1, "</td>") orelse continue;
                const release = std.mem.trim(u8, stripSimpleTags(row[release_gt + 1 .. release_close]), " \t\r\n");
                const episode = parseEpisode(release) orelse continue;

                var link_cursor: usize = 0;
                const attach_marker = "page=Attachment";
                while (std.mem.indexOfPos(u8, row, link_cursor, attach_marker)) |attach_pos| {
                    const href_start = std.mem.lastIndexOfScalar(u8, row[0..attach_pos], '"') orelse {
                        link_cursor = attach_pos + attach_marker.len;
                        continue;
                    };
                    const href_tail = row[href_start + 1 ..];
                    const href_end = std.mem.indexOfScalar(u8, href_tail, '"') orelse break;
                    const href_raw = href_tail[0..href_end];
                    link_cursor = href_start + 1 + href_end + 1;

                    const attachment_id = queryParam(href_raw, "attachmentID") orelse continue;
                    if (seen.contains(attachment_id)) continue;
                    const decoded_href = try htmlUnescapeUrl(allocator, href_raw);
                    const download_url = resolveAttachmentUrl(allocator, decoded_href) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => continue,
                    };
                    const slugged = try common.asciiSlug(allocator, series_title);
                    const language_code = try allocator.dupe(u8, language);
                    const filename = try std.fmt.allocPrint(allocator, "subcentral-{s}-s{d}e{d}-{s}", .{ slugged, season, episode, language });
                    const seen_id = try allocator.dupe(u8, attachment_id);
                    try seen.ensureUnusedCapacity(allocator, 1);
                    try out.ensureUnusedCapacity(allocator, 1);
                    seen.putAssumeCapacityNoClobber(seen_id, {});
                    out.appendAssumeCapacity(.{
                        .language_code = language_code,
                        .filename = filename,
                        .download_url = download_url,
                        .episode = episode,
                    });
                }
            },
        }
    }

    const owned = try out.toOwnedSlice(allocator);
    std.mem.sort(SubtitleItem, owned, {}, subtitleLessThan);
    return owned;
}

fn subtitleLessThan(_: void, lhs: SubtitleItem, rhs: SubtitleItem) bool {
    if (lhs.episode != rhs.episode) return lhs.episode < rhs.episode;
    const lang_order = std.mem.order(u8, lhs.language_code, rhs.language_code);
    if (lang_order != .eq) return lang_order == .lt;
    return std.mem.lessThan(u8, lhs.filename, rhs.filename);
}

fn parseSeason(value: []const u8) ?i64 {
    const markers = [_][]const u8{ "Staffel ", "Season " };
    for (markers) |marker| {
        const pos = std.ascii.findIgnoreCase(value, marker) orelse continue;
        const tail = value[pos + marker.len ..];
        var end: usize = 0;
        while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
        if (end == 0) continue;
        return std.fmt.parseInt(i64, tail[0..end], 10) catch null;
    }
    return null;
}

fn parseEpisode(value: []const u8) ?i64 {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] != 'E' and value[i] != 'e') continue;
        var p = i + 1;
        while (p < value.len and value[p] == '0') : (p += 1) {}
        const start = p;
        while (p < value.len and std.ascii.isDigit(value[p])) : (p += 1) {}
        if (p == start) continue;
        return std.fmt.parseInt(i64, value[start..p], 10) catch null;
    }
    return null;
}

fn queryParam(url: []const u8, key: []const u8) ?[]const u8 {
    const marker_len = key.len + 1;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, url, i, key)) |pos| {
        if (pos + marker_len <= url.len and url[pos + key.len] == '=') {
            const start = pos + marker_len;
            const end = std.mem.indexOfAnyPos(u8, url, start, "&#") orelse url.len;
            return url[start..end];
        }
        i = pos + key.len;
    }
    return null;
}

fn htmlUnescapeUrl(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "&amp;")) {
            try out.append(allocator, '&');
            i += 5;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, search_pos, name)) |pos| {
        const after = pos + name.len;
        if (after >= tag.len or tag[after] != '=') {
            search_pos = after;
            continue;
        }
        if (after + 1 >= tag.len) return null;
        const quote = tag[after + 1];
        if (quote == '"' or quote == '\'') {
            const tail = tag[after + 2 ..];
            const end = std.mem.indexOfScalar(u8, tail, quote) orelse return null;
            return tail[0..end];
        }
        const tail = tag[after + 1 ..];
        const end = std.mem.indexOfAny(u8, tail, " \t\r\n>") orelse tail.len;
        return tail[0..end];
    }
    return null;
}

fn stripSimpleTags(input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '<') == null) return input;
    // All call sites use this only for simple option/anchor/cell text. Returning the
    // largest visible segment avoids allocations and is sufficient for provider IDs.
    var best = input;
    var best_len: usize = 0;
    var cursor: usize = 0;
    var in_tag = false;
    var segment_start: usize = 0;
    while (cursor <= input.len) : (cursor += 1) {
        if (cursor == input.len) {
            if (!in_tag and cursor - segment_start > best_len) best = input[segment_start..cursor];
            break;
        }
        if (!in_tag and input[cursor] == '<') {
            if (cursor - segment_start > best_len) {
                best = input[segment_start..cursor];
                best_len = cursor - segment_start;
            }
            in_tag = true;
        } else if (in_tag and input[cursor] == '>') {
            in_tag = false;
            segment_start = cursor + 1;
        }
    }
    return best;
}

fn isCanonicalPositiveId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

const RawResponse = common.RawResponse;

fn fetchRaw(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    cookie: ?[]const u8,
    referer: ?[]const u8,
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
            task_cookie: ?[]const u8,
            task_referer: ?[]const u8,
        ) !void {
            result.* = try fetchRawUnbounded(task_client, task_allocator, task_url, task_cookie, task_referer);
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

    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(client.io, .{
        .raw = std.Io.Duration.fromMilliseconds(deadline_ms -| now_ms),
        .clock = .awake,
    }) };
    try selection.concurrent(.fetch, FetchTask.run, .{ &owned_response, client, allocator, url, cookie, referer });
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

fn fetchRawUnbounded(client: *std.http.Client, allocator: Allocator, url: []const u8, cookie: ?[]const u8, referer: ?[]const u8) !RawResponse {
    try validateProviderEndpoint(url);
    if (referer) |value| try validateProviderEndpoint(value);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

    var headers: [3]std.http.Header = undefined;
    var count: usize = 0;
    if (cookie) |value| {
        headers[count] = .{ .name = "cookie", .value = value };
        count += 1;
    }
    if (referer) |value| {
        headers[count] = .{ .name = "referer", .value = value };
        count += 1;
    }
    headers[count] = .{ .name = "accept", .value = "text/html,application/xhtml+xml,application/xml,*/*" };
    count += 1;
    try common.validateHttpHeaders(headers[0..count]);

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
        .extra_headers = headers[0..count],
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
        try validateRawBoardResponseHead(response.head);
        interim_count += 1;
        if (interim_count > 16) return error.TooManyInformationalResponses;
        response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
    }
    try validateRawBoardResponseHead(response.head);
    const cookie_value = try extractCookie(allocator, response.head.bytes);
    errdefer if (cookie_value) |value| allocator.free(value);

    const body = try common.readStrictResponseBody(&req, &response, allocator, max_raw_response_bytes);
    errdefer allocator.free(body);

    return .{
        .status = response.head.status,
        .body = body,
        .cookie = cookie_value,
    };
}

fn validateRawBoardResponseHead(head: std.http.Client.Response.Head) !void {
    try common.validateResponseFraming(head);
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

fn validateProviderEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

const ItemRoute = enum { board, thread };

fn validateItemRoute(url: []const u8, route: ItemRoute) !void {
    try validateProviderEndpoint(url);
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.fragment != null) return error.UnsafeHttpTarget;

    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/index.php")) return error.UnsafeHttpTarget;

    const query_component = uri.query orelse return error.UnsafeHttpTarget;
    const query = switch (query_component) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = switch (route) {
        .board => "page=Board&boardID=",
        .thread => "page=Thread&threadID=",
    };
    if (!std.mem.startsWith(u8, query, prefix)) return error.UnsafeHttpTarget;
    if (!isCanonicalPositiveId(query[prefix.len..])) return error.UnsafeHttpTarget;
}

fn resolveAttachmentUrl(allocator: Allocator, href: []const u8) ![]const u8 {
    const legacy_prefix = "http://www.subcentral.de/index.php?page=Attachment";
    const has_exact_legacy_prefix = std.mem.startsWith(u8, href, legacy_prefix) and
        (href.len == legacy_prefix.len or href[legacy_prefix.len] == '&' or href[legacy_prefix.len] == '#');

    const resolved = if (has_exact_legacy_prefix)
        try std.fmt.allocPrint(allocator, "https://www.subcentral.de{s}", .{href["http://www.subcentral.de".len..]})
    else
        try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateAttachmentRoute(resolved);
    return resolved;
}

fn validateAttachmentRoute(url: []const u8) !void {
    try validateProviderEndpoint(url);
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/index.php")) return error.UnsafeHttpTarget;
    const query_component = uri.query orelse return error.UnsafeHttpTarget;
    const query = switch (query_component) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "page=Attachment&attachmentID=";
    if (!std.mem.startsWith(u8, query, prefix)) return error.UnsafeHttpTarget;
    const tail = query[prefix.len..];
    const separator = std.mem.indexOfScalar(u8, tail, '&');
    const id = if (separator) |pos| tail[0..pos] else tail;
    if (!isCanonicalPositiveId(id)) return error.UnsafeHttpTarget;

    if (separator) |pos| {
        const suffix = tail[pos + 1 ..];
        const hash_prefix = "h=";
        if (!std.mem.startsWith(u8, suffix, hash_prefix)) return error.UnsafeHttpTarget;
        const hash = suffix[hash_prefix.len..];
        if (hash.len != 40 or !allLowerHex(hash)) return error.UnsafeHttpTarget;
    }
}

fn allLowerHex(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
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
        if (std.ascii.findIgnoreCase(value, "wcf_cookieHash=") != 0) continue;
        const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        return @as(?[]u8, try allocator.dupe(u8, value[0..end]));
    }
    return null;
}

const cookie_flow_gate_fixture = "SECURITY_TOKEN = 'fixture-token'; thankPostButton42";
const cookie_flow_attachment_fixture =
    "<img src=\"flags/de.png\">" ++
    "<tr><td class=\"release\">S01E01 - Pilot</td>" ++
    "<td><a href=\"http://www.subcentral.de/index.php?page=Attachment&amp;attachmentID=42\">Download</a></td></tr>";

fn makeFixtureRawResponse(allocator: Allocator, body: []const u8, cookie: ?[]const u8) !RawResponse {
    const owned_body = try allocator.dupe(u8, body);
    errdefer allocator.free(owned_body);
    const owned_cookie = if (cookie) |value| try allocator.dupe(u8, value) else null;
    return .{ .status = .ok, .body = owned_body, .cookie = owned_cookie };
}

test "subcentral parses season and episode" {
    try std.testing.expectEqual(@as(?i64, 1), parseSeason("Breaking Bad - Staffel 1 - [DE-Subs]"));
    try std.testing.expectEqual(@as(?i64, 1), parseEpisode("E01 - Pilot"));
}

test "subcentral classifies raw response failures" {
    try requireOkResponseStatus(.ok);
    try std.testing.expectError(error.RateLimited, requireOkResponseStatus(.too_many_requests));
    try std.testing.expectError(error.ProviderAccessBlocked, requireOkResponseStatus(.unauthorized));
    try std.testing.expectError(error.ProviderAccessBlocked, requireOkResponseStatus(.forbidden));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireOkResponseStatus(.internal_server_error));
}

test "subcentral refresh prefers a cookie rotated by the Thank response" {
    const board_url = site ++ "/index.php?page=Board&boardID=12";
    const thread_url = site ++ "/index.php?page=Thread&threadID=34";
    const Mock = struct {
        var calls: usize = 0;

        fn fetch(
            _: *std.http.Client,
            allocator: Allocator,
            url: []const u8,
            cookie: ?[]const u8,
            referer: ?[]const u8,
            _: i64,
        ) !RawResponse {
            calls += 1;
            return switch (calls) {
                1 => blk: {
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Thread&threadID=34", url);
                    try std.testing.expect(cookie == null);
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Board&boardID=12", referer.?);
                    break :blk makeFixtureRawResponse(allocator, cookie_flow_gate_fixture, "wcf_cookieHash=old");
                },
                2 => blk: {
                    try std.testing.expect(std.mem.indexOf(u8, url, "action=Thank") != null);
                    try std.testing.expectEqualStrings("wcf_cookieHash=old", cookie.?);
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Thread&threadID=34", referer.?);
                    break :blk makeFixtureRawResponse(allocator, "<xml>ok</xml>", "wcf_cookieHash=rotated");
                },
                3 => blk: {
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Thread&threadID=34", url);
                    try std.testing.expectEqualStrings("wcf_cookieHash=rotated", cookie.?);
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Board&boardID=12", referer.?);
                    break :blk makeFixtureRawResponse(allocator, cookie_flow_attachment_fixture, null);
                },
                else => error.TestUnexpectedResult,
            };
        }
    };
    Mock.calls = 0;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(.{
        .title = "Example",
        .season = 1,
        .board_url = board_url,
        .thread_url = thread_url,
    }, Mock.fetch);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 3), Mock.calls);
    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
}

test "subcentral refresh retains the thread cookie when Thank sets none" {
    const board_url = site ++ "/index.php?page=Board&boardID=12";
    const thread_url = site ++ "/index.php?page=Thread&threadID=34";
    const Mock = struct {
        var calls: usize = 0;

        fn fetch(
            _: *std.http.Client,
            allocator: Allocator,
            url: []const u8,
            cookie: ?[]const u8,
            referer: ?[]const u8,
            _: i64,
        ) !RawResponse {
            calls += 1;
            return switch (calls) {
                1 => blk: {
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Thread&threadID=34", url);
                    try std.testing.expect(cookie == null);
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Board&boardID=12", referer.?);
                    break :blk makeFixtureRawResponse(allocator, cookie_flow_gate_fixture, "wcf_cookieHash=old");
                },
                2 => blk: {
                    try std.testing.expect(std.mem.indexOf(u8, url, "action=Thank") != null);
                    try std.testing.expectEqualStrings("wcf_cookieHash=old", cookie.?);
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Thread&threadID=34", referer.?);
                    break :blk makeFixtureRawResponse(allocator, "<xml>ok</xml>", null);
                },
                3 => blk: {
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Thread&threadID=34", url);
                    try std.testing.expectEqualStrings("wcf_cookieHash=old", cookie.?);
                    try std.testing.expectEqualStrings(site ++ "/index.php?page=Board&boardID=12", referer.?);
                    break :blk makeFixtureRawResponse(allocator, cookie_flow_attachment_fixture, null);
                },
                else => error.TestUnexpectedResult,
            };
        }
    };
    Mock.calls = 0;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(.{
        .title = "Example",
        .season = 1,
        .board_url = board_url,
        .thread_url = thread_url,
    }, Mock.fetch);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 3), Mock.calls);
    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
}

test "subcentral raw fetch rejects an expired deadline before I/O" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(
        error.Timeout,
        fetchRaw(&client, std.testing.allocator, home_url, null, null, common.compatMilliTimestamp()),
    );
}

test "subcentral rejects unsafe raw request targets before fetch" {
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("http://127.0.0.1/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://user:pass@www.subcentral.de/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint("https://www.google.com/private"));
}

test "subcentral accepts only canonical board and thread item routes" {
    try validateItemRoute(site ++ "/index.php?page=Board&boardID=12", .board);
    try validateItemRoute(site ++ "/index.php?page=Thread&threadID=34", .thread);

    for ([_]struct { url: []const u8, route: ItemRoute }{
        .{ .url = site ++ "/admin?page=Board&boardID=12", .route = .board },
        .{ .url = site ++ "/index.php/extra?page=Board&boardID=12", .route = .board },
        .{ .url = site ++ "/index.php?page=Thread&threadID=12", .route = .board },
        .{ .url = site ++ "/index.php?page=Board&boardID=", .route = .board },
        .{ .url = site ++ "/index.php?page=Board&boardID=0", .route = .board },
        .{ .url = site ++ "/index.php?page=Board&boardID=012", .route = .board },
        .{ .url = site ++ "/index.php?page=Board&boardID=12x", .route = .board },
        .{ .url = site ++ "/index.php?page=Board&boardID=12/3", .route = .board },
        .{ .url = site ++ "/index.php?page=Board&boardID=12%2F3", .route = .board },
        .{ .url = site ++ "/index.php?page=Board&boardID=12&action=Delete", .route = .board },
        .{ .url = site ++ "/index.php?boardID=12&page=Board", .route = .board },
        .{ .url = site ++ "/index.php?page=Thread&threadID=34#fragment", .route = .thread },
    }) |invalid| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateItemRoute(invalid.url, invalid.route));
    }
}

test "subcentral encodes the security token as one query value" {
    const url = try buildThankUrl(std.testing.allocator, .{
        .post_id = "42",
        .token = "token&/?#%\\\r\n",
    });
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        site ++ "/index.php?action=Thank&output=xml&postID=42&t=token%26%2F%3F%23%25%5C%0D%0A",
        url,
    );
    try std.testing.expect(std.mem.indexOfAny(u8, url, "#\\\r\n") == null);
    try std.testing.expectError(error.MissingField, buildThankUrl(std.testing.allocator, .{ .post_id = "0", .token = "token" }));
    try std.testing.expectError(error.MissingField, buildThankUrl(std.testing.allocator, .{ .post_id = "042", .token = "token" }));
}

test "subcentral gate scanner recovers after malformed markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        "SECURITY_TOKEN = 'unterminated " ++
        "SECURITY_TOKEN = ''; " ++
        "SECURITY_TOKEN = 'fixture-token'; " ++
        "thankPostButton thankPostButton0\" thankPostButton12evil\" thankPostButton42\"";
    const gate = try parseGate(arena.allocator(), body);
    try std.testing.expectEqualStrings("fixture-token", gate.token);
    try std.testing.expectEqualStrings("42", gate.post_id);
}

test "subcentral normalizes only the exact legacy HTTP attachment prefix" {
    const legacy = try resolveAttachmentUrl(
        std.testing.allocator,
        "http://www.subcentral.de/index.php?page=Attachment&attachmentID=42",
    );
    defer std.testing.allocator.free(legacy);
    try std.testing.expectEqualStrings(
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=42",
        legacy,
    );

    const relative = try resolveAttachmentUrl(
        std.testing.allocator,
        "/index.php?page=Attachment&attachmentID=43",
    );
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings(
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=43",
        relative,
    );

    const signed = try resolveAttachmentUrl(
        std.testing.allocator,
        "http://www.subcentral.de/index.php?page=Attachment&attachmentID=44&h=0123456789abcdef0123456789abcdef01234567",
    );
    defer std.testing.allocator.free(signed);
    try std.testing.expectEqualStrings(
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=44&h=0123456789abcdef0123456789abcdef01234567",
        signed,
    );

    for ([_][]const u8{
        "http://user:pass@www.subcentral.de/index.php?page=Attachment&attachmentID=1",
        "http://www.subcentral.de:80/index.php?page=Attachment&attachmentID=1",
        "http://www.subcentral.de.evil.example/index.php?page=Attachment&attachmentID=1",
        "http://subcentral.de/index.php?page=Attachment&attachmentID=1",
        "http://www.subcentral.de/elsewhere?page=Attachment&attachmentID=1",
        "http://www.subcentral.de/index.php?page=AttachmentLookalike&attachmentID=1",
        "https://www.subcentral.de/elsewhere?page=Attachment&attachmentID=1",
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=1&action=Delete",
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=1&h=0123456789abcdef0123456789abcdef0123456",
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=1&h=0123456789abcdef0123456789abcdef0123456g",
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=1&h=0123456789abcdef0123456789abcdef01234567&action=Delete",
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=01",
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=1#fragment",
    }) |unsafe| {
        try std.testing.expectError(error.UnsafeHttpTarget, resolveAttachmentUrl(std.testing.allocator, unsafe));
    }
}

test "subcentral board scanner recovers after malformed options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const board = (try findBoard(
        arena.allocator(),
        "<option value=\"0\">Breaking Bad</option>" ++
            "<option value=\"012\">Breaking Bad</option>" ++
            "<option value=\"broken\" <option value=\"12\">Breaking Bad</option>",
        "Breaking Bad",
    )).?;
    try std.testing.expectEqualStrings("Breaking Bad", board.title);
    try std.testing.expectEqualStrings(site ++ "/index.php?page=Board&boardID=12", board.url);
}

test "subcentral invalid thread ids do not precede a later valid thread" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        "<a href=\"index.php?page=Thread&amp;threadID=0\">Example - Staffel 1 - [DE-Subs]</a>" ++
        "<a href=\"index.php?page=Thread&amp;threadID=012\">Example - Staffel 1 - [DE-Subs]</a>" ++
        "<a href=\"index.php?page=Thread&amp;threadID=13evil\">Example - Staffel 1 - [DE-Subs]</a>" ++
        "<a href=\"index.php?page=Thread&amp;threadID=12\">Example - Staffel 1 - [DE-Subs]</a>";
    const items = try parseBoardThreads(arena.allocator(), body, "Example", site ++ "/index.php?page=Board&boardID=1");
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings(site ++ "/index.php?page=Thread&threadID=12", items[0].thread_url);
}

test "subcentral board relevance rejects empty and partial-word matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        "<option value=\"1\">Preacher</option>" ++
        "<option value=\"2\">Jack Reacher</option>";
    const board = (try findBoard(arena.allocator(), body, "Reacher")).?;
    try std.testing.expectEqualStrings("Jack Reacher", board.title);
    try std.testing.expect((try findBoard(arena.allocator(), body, "---")) == null);
}

test "subcentral parser normalizes legacy HTTP attachment links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        "<img src=\"flags/de.png\">" ++
        "<tr class=\"aktiv\"><td class=\"release\">S01E01 - Pilot</td>" ++
        "<td><a href=\"http://www.subcentral.de/index.php?page=Attachment&amp;attachmentID=42\">Download</a></td></tr>";
    const subtitles = try parseRevealedAttachments(arena.allocator(), body, "Example", 1);
    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings(
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=42",
        subtitles[0].download_url,
    );
}

test "subcentral parser accepts current plain rows, USA flag, and signed attachment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        "<img src=\"creative/bilder/flags/usa.png\">" ++
        "<tr><td class=\"release\">E02 - Example</td>" ++
        "<td><a href=\"http://www.subcentral.de/index.php?page=Attachment&amp;attachmentID=44&amp;h=0123456789abcdef0123456789abcdef01234567\">Download</a></td></tr>";
    const subtitles = try parseRevealedAttachments(arena.allocator(), body, "Example", 1);

    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings("en", subtitles[0].language_code);
    try std.testing.expectEqual(@as(i64, 2), subtitles[0].episode);
    try std.testing.expectEqualStrings(
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=44&h=0123456789abcdef0123456789abcdef01234567",
        subtitles[0].download_url,
    );
}

test "subcentral malformed attachment does not suppress a valid sibling id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        "<img src=\"flags/de.png\">" ++
        "<tr class=\"aktiv\"><td class=\"release\">S01E01 - Pilot</td>" ++
        "<td><a href=\"https://evil.test/index.php?page=Attachment&amp;attachmentID=42\">bad</a>" ++
        "<a href=\"http://www.subcentral.de/index.php?page=Attachment&amp;attachmentID=42\">good</a></td></tr>";
    const subtitles = try parseRevealedAttachments(arena.allocator(), body, "Example", 1);

    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings(
        "https://www.subcentral.de/index.php?page=Attachment&attachmentID=42",
        subtitles[0].download_url,
    );
}

test "subcentral raw board transport rejects ambiguous response framing" {
    for ([_][]const u8{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
    }) |raw_head| {
        const head = try std.http.Client.Response.Head.parse(raw_head);
        try std.testing.expectError(error.AmbiguousHttpFraming, validateRawBoardResponseHead(head));
    }
}

test "live subcentral breaking bad listing and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subcentral.de")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("Breaking Bad");
    defer search.deinit();
    try std.testing.expect(search.items.len >= 5);

    var subtitles_opt: ?SubtitlesResponse = null;
    defer if (subtitles_opt) |*subtitles| subtitles.deinit();
    for (search.items) |item| {
        var candidate = try scraper.fetchSubtitlesBySearchItem(item);
        if (candidate.subtitles.len == 0) {
            candidate.deinit();
            continue;
        }
        subtitles_opt = candidate;
        break;
    }
    const subtitles = if (subtitles_opt) |*value| value else return error.TestUnexpectedResult;
    try std.testing.expect(subtitles.subtitles.len >= 1);
    try std.testing.expectEqual(@as(i64, 1), subtitles.subtitles[0].episode);

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, download.body, "Rar!") or std.mem.startsWith(u8, download.body, "PK"));
}
