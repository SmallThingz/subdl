const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        for ([_][]const u8{ "org", "en", "pl" }) |title_type| {
            const url = try buildSearchUrl(a, trimmed, title_type);
            var response = try fetchRawGet(self.client, a, url);
            defer response.deinit(a);
            if (response.status != .ok) continue;
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

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        try items.appendSlice(a, exact.items);
        try items.appendSlice(a, partial.items);
        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
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
        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        };
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        if (parts.download_hash.len > 0 and parts.session_cookie.len > 0) {
            const response = try postDownload(
                self.client,
                allocator,
                parts.subtitle_id,
                parts.download_hash,
                parts.session_cookie,
                parts.search_url,
            );
            if (downloadResponseIsValid(response)) return response;
            allocator.free(response.body);
        }

        var search_response = try fetchRawGet(self.client, allocator, parts.search_url);
        defer search_response.deinit(allocator);
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
        );
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

    return common.fetchBytes(client, allocator, download_path, .{
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
    if (std.ascii.indexOfIgnoreCase(value, "season ")) |pos| {
        const tail = value[pos + "season ".len ..];
        var end: usize = 0;
        while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
        if (end > 0) return std.fmt.parseInt(i64, tail[0..end], 10) catch null;
    }
    return null;
}

fn stripEpisodeSuffix(value: []const u8) []const u8 {
    if (std.ascii.indexOfIgnoreCase(value, " ep")) |pos| return std.mem.trimEnd(u8, value[0..pos], " \t-");
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
            if (attempt + 1 >= 4) return err;
            const shift: u6 = @intCast(@min(attempt, 4));
            common.sleepMilliseconds(@as(u64, 250) << shift);
            continue;
        };
    }
}

fn fetchRawGetOnce(client: *std.http.Client, allocator: Allocator, url: []const u8) !RawResponse {
    try common.ensureClientTlsReady(client);
    const normalized = try common.normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized);
    const uri = try std.Uri.parse(normalized);

    var req = try client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = "Sub-Zero/2" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &[_]std.http.Header{
            .{ .name = "accept", .value = "text/html,application/xhtml+xml,*/*" },
        },
    });
    defer req.deinit();
    try req.sendBodiless();

    var head_buffer: [24 * 1024]u8 = undefined;
    var response = try req.receiveHead(&head_buffer);
    const cookie = try extractCookie(allocator, response.head.bytes);

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    _ = try reader.streamRemaining(&writer.writer);

    return .{
        .status = response.head.status,
        .body = try allocator.dupe(u8, writer.writer.buffered()),
        .cookie = cookie,
    };
}

fn extractCookie(allocator: Allocator, headers: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.indexOfIgnoreCase(value, "ansi_sciagnij=") != 0) continue;
        const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        return @as(?[]u8, try allocator.dupe(u8, value[0..end]));
    }
    return null;
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
