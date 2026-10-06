const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://indexsubtitle.cc";
pub const download_token_prefix = "indexsubtitle:";

pub const SearchItem = common.SearchLink;

pub const SubtitleItem = struct {
    title: []const u8,
    language: []const u8,
    row_url: []const u8,
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const payload = try std.fmt.allocPrint(a, "query={s}", .{encoded});
        const headers = [_]std.http.Header{
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
            .{ .name = "referer", .value = site ++ "/" },
        };
        const response = try fetchPostWithStatusRetry(self.client, a, site ++ "/search", payload, &headers);

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const array = switch (root) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        const wanted = try normalizeSearchTitle(a, trimmed);
        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var other: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (array.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const title = common.jsonString(obj, "title") orelse continue;
            const url = common.jsonString(obj, "url") orelse continue;
            if (url.len == 0 or std.mem.eql(u8, url, "#")) continue;
            const page_url = try common.resolveUrl(a, site, url);
            validateProviderUrl(page_url) catch continue;
            const item: SearchItem = .{
                .title = try a.dupe(u8, title),
                .page_url = page_url,
            };
            const base_title = titleWithoutYear(title);
            const normalized = try normalizeSearchTitle(a, base_title);
            if (std.mem.eql(u8, normalized, wanted))
                try exact.append(a, item)
            else
                try other.append(a, item);
        }

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        try items.appendSlice(a, exact.items);
        try items.appendSlice(a, other.items);
        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(item.page_url);

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });

        const rows_json = extractRowsJson(response.body) orelse return error.MissingField;
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, rows_json, .{});
        const array = switch (root) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        for (array.items) |entry| {
            const obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const title = common.jsonString(obj, "title") orelse continue;
            const language = common.jsonString(obj, "language") orelse continue;
            const row_url = common.jsonString(obj, "url") orelse continue;
            if (row_url.len == 0 or seen.contains(row_url)) continue;
            try seen.put(a, try a.dupe(u8, row_url), {});

            try subtitles.append(a, .{
                .title = try a.dupe(u8, title),
                .language = try a.dupe(u8, language),
                .row_url = try a.dupe(u8, row_url),
                .download_url = try makeDownloadToken(a, item.page_url, row_url, language, title),
            });
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateProviderUrl(parts.page_url);

        const page = try common.fetchBytes(self.client, allocator, parts.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });
        defer allocator.free(page.body);
        if (page.status != .ok) return error.UnexpectedHttpStatus;
        const ttl = parsePageTtl(page.body) orelse return error.MissingField;

        const id = rowId(parts.row_url) orelse return error.MissingField;
        const id_encoded = try common.encodeUriComponent(allocator, id);
        defer allocator.free(id_encoded);
        const language_encoded = try common.encodeUriComponent(allocator, parts.language);
        defer allocator.free(language_encoded);
        const row_url_encoded = try common.encodeUriComponent(allocator, parts.row_url);
        defer allocator.free(row_url_encoded);
        const payload = try std.fmt.allocPrint(
            allocator,
            "id={s}&lang={s}&url={s}",
            .{ id_encoded, language_encoded, row_url_encoded },
        );
        defer allocator.free(payload);

        const headers = [_]std.http.Header{
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
            .{ .name = "referer", .value = parts.page_url },
        };
        const info = try fetchPostWithStatusRetry(self.client, allocator, site ++ "/subtitlesInfo", payload, &headers);
        defer allocator.free(info.body);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, info.body, .{});
        defer parsed.deinit();
        const info_obj = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const access_token = common.jsonString(info_obj, "token") orelse return error.MissingField;

        const zip_name = try downloadZipName(allocator, parts.row_url);
        defer allocator.free(zip_name);
        const download_url = try std.fmt.allocPrint(
            allocator,
            "{s}/d/{s}/{d}/{s}/{s}.zip",
            .{ site, id, ttl, access_token, zip_name },
        );
        defer allocator.free(download_url);

        return common.fetchBytes(self.client, allocator, download_url, .{
            .accept = "application/zip,application/octet-stream,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = parts.page_url }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });
    }
};

fn validateProviderUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
}

fn fetchPostWithStatusRetry(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    payload: []const u8,
    headers: []const std.http.Header,
) !common.HttpResponse {
    const max_status_attempts: usize = 4;
    var attempt: usize = 0;
    while (attempt < max_status_attempts) : (attempt += 1) {
        const response = try common.fetchBytes(client, allocator, url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "application/json, text/javascript, */*; q=0.01",
            .extra_headers = headers,
            .cache = false,
            .allow_non_ok = true,
            .max_attempts = 2,
            .require_public_origin = true,
        });
        if (response.status == .ok) return response;

        const retry = isTransientStatus(response.status) and attempt + 1 < max_status_attempts;
        allocator.free(response.body);
        if (!retry) return error.UnexpectedHttpStatus;

        const code = @backingInt(response.status);
        const delay_ms: u64 = if (code == 429 or code == 403)
            5500
        else
            @as(u64, 1000) << @intCast(@min(attempt, 2));
        common.sleepMilliseconds(delay_ms);
    }
    return error.UnexpectedHttpStatus;
}

fn isTransientStatus(status: std.http.Status) bool {
    const code = @backingInt(status);
    return code == 403 or
        code == 408 or
        code == 425 or
        code == 429 or
        (code >= 500 and code <= 504);
}

fn extractRowsJson(body: []const u8) ?[]const u8 {
    const marker = "DataTable({ data: ";
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    const tail = body[start + marker.len ..];
    const end = std.mem.indexOf(u8, tail, ", columns:") orelse return null;
    return std.mem.trim(u8, tail[0..end], " \t\r\n");
}

fn parsePageTtl(body: []const u8) ?i64 {
    const marker = "ttl = ";
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    const tail = body[start + marker.len ..];
    var end: usize = 0;
    while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(i64, tail[0..end], 10) catch null;
}

fn rowId(row_url: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, row_url, '/') orelse return null;
    if (slash + 1 >= row_url.len) return null;
    const id = row_url[slash + 1 ..];
    for (id) |c| if (!std.ascii.isDigit(c)) return null;
    return id;
}

fn downloadZipName(allocator: Allocator, row_url: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var removed_first_non_word = false;
    for (row_url) |c| {
        const is_word = std.ascii.isAlphanumeric(c) or c == '_';
        if (!is_word and c != ' ' and !removed_first_non_word) {
            removed_first_non_word = true;
            continue;
        }
        try out.append(allocator, if (c == '/') '_' else c);
    }
    return out.toOwnedSlice(allocator);
}

pub fn makeDownloadToken(
    allocator: Allocator,
    page_url: []const u8,
    row_url: []const u8,
    language: []const u8,
    title: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}|{s}|{s}|{s}",
        .{ download_token_prefix, page_url, row_url, language, title },
    );
}

const DownloadToken = struct {
    page_url: []const u8,
    row_url: []const u8,
    language: []const u8,
    title: []const u8,
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
        .page_url = payload[0..a],
        .row_url = payload[a + 1 .. b],
        .language = payload[b + 1 .. c],
        .title = payload[c + 1 ..],
    };
}

fn titleWithoutYear(title: []const u8) []const u8 {
    if (title.len < 7 or title[title.len - 1] != ')') return title;
    const open = title.len - 6;
    if (title[open] != '(') return title;
    for (title[open + 1 .. title.len - 1]) |c| if (!std.ascii.isDigit(c)) return title;
    return std.mem.trimEnd(u8, title[0..open], " ");
}

fn normalizeSearchTitle(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            pending_space = out.items.len > 0;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "indexsubtitle extracts embedded rows and ttl" {
    const body =
        \\<script>$('#example').DataTable({ data: [{"title":"The.Matrix.1999.1080p","language":"english","author":{"name":"A","url":null},"comment":"ok","url":"the-matrix-1999/english/657711"}], columns: [{data:'title'}] }); let ttl = 1790576999;</script>
    ;
    const rows = extractRowsJson(body).?;
    try std.testing.expect(std.mem.startsWith(u8, rows, "[{"));
    try std.testing.expectEqual(@as(?i64, 1790576999), parsePageTtl(body));
    try std.testing.expectEqualStrings("657711", rowId("the-matrix-1999/english/657711").?);
}

test "indexsubtitle rejects non-provider page targets" {
    try validateProviderUrl("https://indexsubtitle.cc/movie/the-matrix");
    for ([_][]const u8{
        "http://127.0.0.1/movie/the-matrix",
        "https://indexsubtitle.cc.example/movie/the-matrix",
        "https://user@indexsubtitle.cc/movie/the-matrix",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url));
    }
}

test "indexsubtitle retries transient search statuses" {
    try std.testing.expect(isTransientStatus(.forbidden));
    try std.testing.expect(isTransientStatus(.too_many_requests));
    try std.testing.expect(isTransientStatus(.service_unavailable));
    try std.testing.expect(!isTransientStatus(.not_found));
}

test "live indexsubtitle movie and tv search/list/download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "indexsubtitle.cc")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    try std.testing.expect(movie_subtitles.subtitles.len > 0);

    const chosen = for (movie_subtitles.subtitles) |subtitle| {
        if (std.ascii.eqlIgnoreCase(subtitle.language, "english")) break subtitle;
    } else movie_subtitles.subtitles[0];

    const download = try scraper.fetchDownloadByToken(std.testing.allocator, chosen.download_url);
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.status == .ok);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));

    var tv = try scraper.search("Chernobyl");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    try std.testing.expect(tv_subtitles.subtitles.len > 0);
    var found_episode = false;
    for (tv_subtitles.subtitles) |subtitle| {
        if (std.ascii.findIgnoreCase(subtitle.title, "S01E01") != null) {
            found_episode = true;
            break;
        }
    }
    try std.testing.expect(found_episode);
}
