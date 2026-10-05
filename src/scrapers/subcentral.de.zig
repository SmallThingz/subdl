const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.subcentral.de";
const home_url = site ++ "/";

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

        const home = try common.fetchBytes(self.client, a, home_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
        });
        const board = try findBoard(a, home.body, trimmed) orelse return .{ .arena = arena, .items = &.{} };

        const board_page = try common.fetchBytes(self.client, a, board.url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = home_url }},
            .cache = false,
            .max_attempts = 2,
        });

        const items = try parseBoardThreads(a, board_page.body, board.title, board.url);
        return .{ .arena = arena, .items = items };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var thread = try fetchRaw(self.client, a, item.thread_url, null, item.board_url);
        defer thread.deinit(a);
        if (thread.status != .ok) return error.UnexpectedHttpStatus;

        const already_revealed = try parseRevealedAttachments(a, thread.body, item.title, item.season);
        if (already_revealed.len > 0) {
            return common.finishResponse(SubtitlesResponse, &arena, .{
                .arena = arena,
                .title = try a.dupe(u8, item.title),
                .subtitles = already_revealed,
            });
        }

        const gate = try parseGate(a, thread.body);
        const thank_url = try std.fmt.allocPrint(
            a,
            "{s}/index.php?action=Thank&output=xml&postID={s}&t={s}",
            .{ site, gate.post_id, gate.token },
        );

        var revealed = try fetchRaw(self.client, a, thank_url, thread.cookie, item.thread_url);
        defer revealed.deinit(a);
        if (revealed.status != .ok) return error.UnexpectedHttpStatus;

        var subtitles = try parseRevealedAttachments(a, revealed.body, item.title, item.season);
        if (subtitles.len == 0) {
            var refreshed = try fetchRaw(self.client, a, item.thread_url, thread.cookie, item.board_url);
            defer refreshed.deinit(a);
            if (refreshed.status == .ok) {
                subtitles = try parseRevealedAttachments(a, refreshed.body, item.title, item.season);
            }
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

fn findBoard(allocator: Allocator, body: []const u8, query: []const u8) !?Board {
    const wanted = try common.normalizeTitle(allocator, query);
    defer allocator.free(wanted);

    var partial: ?Board = null;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, "<option")) |start| {
        const tag_end = std.mem.indexOfPos(u8, body, start, ">") orelse break;
        const close = std.mem.indexOfPos(u8, body, tag_end + 1, "</option>") orelse break;
        cursor = close + "</option>".len;

        const tag = body[start .. tag_end + 1];
        const value = attributeValue(tag, "value") orelse continue;
        if (value.len == 0 or !allDigits(value)) continue;
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
        if (partial == null and
            (std.mem.indexOf(u8, normalized, wanted) != null or std.mem.indexOf(u8, wanted, normalized) != null))
        {
            partial = board;
        }
    }
    return partial;
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

fn parseGate(allocator: Allocator, body: []const u8) !Gate {
    const token_marker = "SECURITY_TOKEN = '";
    const token_start = std.mem.indexOf(u8, body, token_marker) orelse return error.MissingField;
    const token_tail = body[token_start + token_marker.len ..];
    const token_end = std.mem.indexOfScalar(u8, token_tail, '\'') orelse return error.MissingField;

    const post_marker = "thankPostButton";
    const post_start = std.mem.indexOf(u8, body, post_marker) orelse return error.MissingField;
    const post_tail = body[post_start + post_marker.len ..];
    var post_end: usize = 0;
    while (post_end < post_tail.len and std.ascii.isDigit(post_tail[post_end])) : (post_end += 1) {}
    if (post_end == 0) return error.MissingField;

    return .{
        .post_id = try allocator.dupe(u8, post_tail[0..post_end]),
        .token = try allocator.dupe(u8, token_tail[0..token_end]),
    };
}

fn parseRevealedAttachments(allocator: Allocator, body: []const u8, series_title: []const u8, season: i64) ![]const SubtitleItem {
    var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var current_language: ?[]const u8 = null;
    var cursor: usize = 0;

    while (cursor < body.len) {
        const de_pos = std.mem.indexOfPos(u8, body, cursor, "flags/de.png");
        const en_pos = std.mem.indexOfPos(u8, body, cursor, "flags/uk.png");
        const row_pos = std.mem.indexOfPos(u8, body, cursor, "<tr class=\"aktiv\">");

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
                cursor = pos + "flags/uk.png".len;
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
                    try seen.put(allocator, try allocator.dupe(u8, attachment_id), {});

                    const decoded_href = try htmlUnescapeUrl(allocator, href_raw);
                    const download_url = try common.resolveUrl(allocator, site, decoded_href);
                    const slugged = try common.asciiSlug(allocator, series_title);
                    try out.append(allocator, .{
                        .language_code = try allocator.dupe(u8, language),
                        .filename = try std.fmt.allocPrint(allocator, "subcentral-{s}-s{d}e{d}-{s}", .{ slugged, season, episode, language }),
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

fn allDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

const RawResponse = common.RawResponse;

fn fetchRaw(client: *std.http.Client, allocator: Allocator, url: []const u8, cookie: ?[]const u8, referer: ?[]const u8) !RawResponse {
    try common.ensureClientTlsReady(client);
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

    var req = try client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = common.default_user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = headers[0..count],
    });
    defer req.deinit();
    try req.sendBodiless();

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = try req.receiveHead(&head_buffer);
    const cookie_value = try extractCookie(allocator, response.head.bytes);
    errdefer if (cookie_value) |value| allocator.free(value);

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    _ = try reader.streamRemaining(&writer.writer);

    return .{
        .status = response.head.status,
        .body = try allocator.dupe(u8, writer.writer.buffered()),
        .cookie = cookie_value,
    };
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

test "subcentral parses season and episode" {
    try std.testing.expectEqual(@as(?i64, 1), parseSeason("Breaking Bad - Staffel 1 - [DE-Subs]"));
    try std.testing.expectEqual(@as(?i64, 1), parseEpisode("E01 - Pilot"));
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
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, download.body, "Rar!") or std.mem.startsWith(u8, download.body, "PK"));
}
