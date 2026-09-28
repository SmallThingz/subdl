const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://indexsubtitle.cc";
pub const download_token_prefix = "indexsubtitle:";

pub const SearchItem = struct {
    title: []const u8,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    title: []const u8,
    language: []const u8,
    row_url: []const u8,
    download_url: []const u8,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SearchItem,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    subtitles: []const SubtitleItem,

    pub fn deinit(self: *SubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn deinit(_: *Scraper) void {}

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
        const response = try common.fetchBytes(self.client, a, site ++ "/search", .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "application/json, text/javascript, */*; q=0.01",
            .extra_headers = &headers,
            .cache = false,
            .max_attempts = 2,
        });

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
            const title = jsonString(obj, "title") orelse continue;
            const url = jsonString(obj, "url") orelse continue;
            if (url.len == 0 or std.mem.eql(u8, url, "#")) continue;
            const item: SearchItem = .{
                .title = try a.dupe(u8, title),
                .page_url = try common.resolveUrl(a, site, url),
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
        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
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
            const title = jsonString(obj, "title") orelse continue;
            const language = jsonString(obj, "language") orelse continue;
            const row_url = jsonString(obj, "url") orelse continue;
            if (row_url.len == 0 or seen.contains(row_url)) continue;
            try seen.put(a, try a.dupe(u8, row_url), {});

            try subtitles.append(a, .{
                .title = try a.dupe(u8, title),
                .language = try a.dupe(u8, language),
                .row_url = try a.dupe(u8, row_url),
                .download_url = try makeDownloadToken(a, item.page_url, row_url, language, title),
            });
        }

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parts = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;

        const page = try common.fetchBytes(self.client, allocator, parts.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
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
        const info = try common.fetchBytes(self.client, allocator, site ++ "/subtitlesInfo", .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "application/json, text/javascript, */*; q=0.01",
            .extra_headers = &headers,
            .cache = false,
            .max_attempts = 2,
        });
        defer allocator.free(info.body);
        if (info.status != .ok) return error.UnexpectedHttpStatus;

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, info.body, .{});
        defer parsed.deinit();
        const info_obj = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const access_token = jsonString(info_obj, "token") orelse return error.MissingField;

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
        });
    }
};

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

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
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
        if (std.ascii.indexOfIgnoreCase(subtitle.title, "S01E01") != null) {
            found_episode = true;
            break;
        }
    }
    try std.testing.expect(found_episode);
}
