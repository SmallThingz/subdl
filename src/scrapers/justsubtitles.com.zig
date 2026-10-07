const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.justsubtitles.com";
const search_site = "https://search.justsubtitles.com";
const download_site = "https://dl.subdl.com";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    movie_id: i64,
    page_url: []const u8,
};

pub const SubtitleItem = common.ReleaseSubtitleFile;

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
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/api/search?q={s}", .{ search_site, encoded });
        const response = try fetch(self.client, a, url, .{
            .accept = "application/json",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const obj = switch (root) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const results = switch (obj.get("results") orelse return error.MissingField) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var other: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen_ids = std.AutoHashMapUnmanaged(i64, void).empty;

        for (results.items) |entry| {
            const item_obj = switch (entry) {
                .object => |value| value,
                else => continue,
            };
            const title = common.jsonString(item_obj, "title") orelse continue;
            const movie_id = common.jsonIntField(item_obj, "id") orelse continue;
            if (movie_id <= 0) continue;
            if (seen_ids.contains(movie_id)) continue;
            const release_date = common.jsonString(item_obj, "release_date");
            const year = release_dateToYear(release_date);
            const slugged = try movieSlug(a, title, year);
            if (!isCanonicalSlug(slugged)) continue;
            const page_url = try std.fmt.allocPrint(a, "{s}/movie/{d}/{s}", .{ site, movie_id, slugged });
            validateProviderUrl(page_url, movie_id, slugged) catch continue;
            try seen_ids.put(a, movie_id, {});
            const normalized = try common.normalizeTitle(a, title);

            const item: SearchItem = .{
                .title = try a.dupe(u8, title),
                .year = year,
                .movie_id = movie_id,
                .page_url = page_url,
            };
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

        const expected_slug = try movieSlug(a, item.title, item.year);
        try validateProviderUrl(item.page_url, item.movie_id, expected_slug);

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });

        const flight = try extractNextFlightText(a, response.body);
        const subtitles = try parseInitialSubtitles(a, flight);
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn validateProviderUrl(url: []const u8, expected_movie_id: i64, expected_slug: []const u8) !void {
    if (expected_movie_id <= 0 or !isCanonicalSlug(expected_slug)) return error.InvalidDownloadUrl;
    common.validatePublicHttpUrl(url) catch return error.InvalidDownloadUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, '%') != null) {
        return error.InvalidDownloadUrl;
    }

    const prefix = "/movie/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidDownloadUrl;
    const route = path[prefix.len..];
    const separator = std.mem.indexOfScalar(u8, route, '/') orelse return error.InvalidDownloadUrl;
    const id_text = route[0..separator];
    const slug = route[separator + 1 ..];
    if (id_text.len == 0 or slug.len == 0 or std.mem.indexOfScalar(u8, slug, '/') != null) {
        return error.InvalidDownloadUrl;
    }
    if (id_text.len > 1 and id_text[0] == '0') return error.InvalidDownloadUrl;
    for (id_text) |c| if (!std.ascii.isDigit(c)) return error.InvalidDownloadUrl;
    const movie_id = std.fmt.parseInt(i64, id_text, 10) catch return error.InvalidDownloadUrl;
    if (movie_id != expected_movie_id or !std.mem.eql(u8, slug, expected_slug)) return error.InvalidDownloadUrl;
}

fn isCanonicalSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or value[0] == '-' or value[value.len - 1] == '-') return false;
    var previous_dash = false;
    for (value) |c| {
        if (c == '-') {
            if (previous_dash) return false;
            previous_dash = true;
        } else {
            if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
            previous_dash = false;
        }
    }
    return true;
}

fn isCanonicalSubtitlePath(value: []const u8) bool {
    const prefix = "/subtitle/";
    if (!std.mem.startsWith(u8, value, prefix)) return false;
    const filename = value[prefix.len..];
    if (filename.len == 0 or filename.len > 512 or
        std.mem.eql(u8, filename, ".") or std.mem.eql(u8, filename, "..") or
        !std.ascii.endsWithIgnoreCase(filename, ".zip"))
    {
        return false;
    }
    for (filename) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~')) return false;
    }
    return true;
}

fn extractNextFlightText(allocator: Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const marker = "self.__next_f.push(";
    var cursor: usize = 0;

    while (std.mem.indexOfPos(u8, body, cursor, marker)) |start| {
        const payload_start = start + marker.len;
        const next_marker = std.mem.indexOfPos(u8, body, payload_start, marker);
        const candidate_end = next_marker orelse body.len;
        const close_rel = std.mem.indexOf(u8, body[payload_start..candidate_end], ")</script>") orelse {
            cursor = candidate_end;
            continue;
        };
        const close = payload_start + close_rel;
        cursor = close + ")</script>".len;
        const payload = body[payload_start..close];

        var parsed = (try parseNextFlightPayload(allocator, payload)) orelse continue;
        defer parsed.deinit();
        const array = switch (parsed.value) {
            .array => |value| value,
            else => continue,
        };
        if (array.items.len < 2) continue;
        const text = switch (array.items[1]) {
            .string => |value| value,
            else => continue,
        };
        try out.appendSlice(allocator, text);
    }

    return out.toOwnedSlice(allocator);
}

fn parseNextFlightPayload(allocator: Allocator, payload: []const u8) Allocator.Error!?std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn parseInitialSubtitles(allocator: Allocator, flight: []const u8) ![]const SubtitleItem {
    const marker = "\"initialSubtitles\":";
    const marker_pos = std.mem.indexOf(u8, flight, marker) orelse return error.MissingField;
    const array_start = marker_pos + marker.len;
    if (array_start >= flight.len or flight[array_start] != '[') return error.InvalidFieldType;
    const array_end = findJsonArrayEnd(flight, array_start) orelse return error.InvalidFieldType;
    const json_slice = flight[array_start .. array_end + 1];

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_slice, .{});
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |value| value,
        else => return error.InvalidFieldType,
    };

    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);
    for (array.items) |entry| {
        const obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const relative_url = common.jsonString(obj, "url") orelse continue;
        if (!isCanonicalSubtitlePath(relative_url)) continue;
        if (seen.contains(relative_url)) continue;
        try seen.put(allocator, relative_url, {});

        const release_name = common.jsonString(obj, "release_name") orelse "subtitle";
        const raw_name = common.jsonString(obj, "name") orelse release_name;
        const language = common.jsonString(obj, "language") orelse common.jsonString(obj, "lang") orelse "und";
        const language_code = try lowerAscii(allocator, language);
        const filename = if (std.ascii.endsWithIgnoreCase(raw_name, ".zip"))
            try allocator.dupe(u8, raw_name)
        else
            try std.fmt.allocPrint(allocator, "{s}.zip", .{release_name});

        try subtitles.append(allocator, .{
            .language_code = language_code,
            .filename = filename,
            .release_name = try allocator.dupe(u8, release_name),
            .download_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ download_site, relative_url }),
        });
    }

    return subtitles.toOwnedSlice(allocator);
}

fn findJsonArrayEnd(value: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '[') {
            depth += 1;
        } else if (c == ']') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn movieSlug(allocator: Allocator, title: []const u8, year: ?i64) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var pending_dash = false;
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_dash and out.items.len > 0) try out.append(allocator, '-');
            pending_dash = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else if (std.ascii.isWhitespace(c) or c == '-') {
            pending_dash = out.items.len > 0;
        }
    }
    if (year) |value| {
        if (out.items.len > 0) try out.append(allocator, '-');
        const year_text = try std.fmt.allocPrint(allocator, "{d}", .{value});
        defer allocator.free(year_text);
        try out.appendSlice(allocator, year_text);
    }
    return out.toOwnedSlice(allocator);
}

fn release_dateToYear(value: ?[]const u8) ?i64 {
    const text = value orelse return null;
    if (text.len < 4) return null;
    return std.fmt.parseInt(i64, text[0..4], 10) catch null;
}

fn lowerAscii(allocator: Allocator, value: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, value.len);
    for (value, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "justsubtitles rejects non-provider movie targets" {
    try validateProviderUrl("https://www.justsubtitles.com/movie/1/title", 1, "title");
    for ([_][]const u8{
        "http://127.0.0.1/movie/1/title",
        "https://www.justsubtitles.com.example/movie/1/title",
        "https://user@www.justsubtitles.com/movie/1/title",
        "https://www.justsubtitles.com/movie/2/title",
        "https://www.justsubtitles.com/movie/1/other",
        "https://www.justsubtitles.com/movie/1/title/extra",
        "https://www.justsubtitles.com/movie/1/title?next=/admin",
        "https://www.justsubtitles.com/movie/1/%2e%2e",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url, 1, "title"));
    }
}

test "justsubtitles rejects normalized-empty searches before I/O" {
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
    var response = try scraper.searchUsing(Fixture.fetch, "---");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "justsubtitles search deduplicates IDs and rejects fractional IDs" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(search_site ++ "/api/search?q=The%20Matrix", url);
            try std.testing.expectEqualStrings("application/json", options.accept orelse return error.TestUnexpectedResult);
            const body =
                \\{"results":[
                \\{"title":"The Matrix","id":1,"release_date":"1999-03-31"},
                \\{"title":"Duplicate Matrix","id":1,"release_date":"2000-01-01"},
                \\{"title":"Fractional","id":2.5,"release_date":"2001-01-01"},
                \\{"title":"The Matrix Reloaded","id":2,"release_date":"2003-05-15"}
                \\]}
            ;
            return .{ .status = .ok, .body = try allocator.dupe(u8, body) };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetch, "The Matrix");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqual(@as(i64, 1), response.items[0].movie_id);
    try std.testing.expectEqual(@as(i64, 2), response.items[1].movie_id);
}

test "justsubtitles parses next flight subtitle rows" {
    const allocator = std.testing.allocator;
    const flight =
        "x\"initialSubtitles\":[" ++
        "{\"release_name\":\"Traversal\",\"url\":\"/subtitle/../../admin.zip\"}," ++
        "{\"release_name\":\"Query\",\"url\":\"/subtitle/file.zip?next=/admin\"}," ++
        "{\"release_name\":\"Encoded\",\"url\":\"/subtitle/%2e%2e.zip\"}," ++
        "{\"release_name\":\"The.Matrix.1999\",\"name\":\"The.Matrix.1999.zip\",\"url\":\"/subtitle/1-2.zip\",\"language\":\"EN\"}]y";
    const subtitles = try parseInitialSubtitles(allocator, flight);
    defer {
        for (subtitles) |item| {
            allocator.free(item.language_code);
            allocator.free(item.filename);
            allocator.free(item.release_name);
            allocator.free(item.download_url);
        }
        allocator.free(subtitles);
    }
    try std.testing.expectEqual(@as(usize, 1), subtitles.len);
    try std.testing.expectEqualStrings("en", subtitles[0].language_code);
    try std.testing.expectEqualStrings("https://dl.subdl.com/subtitle/1-2.zip", subtitles[0].download_url);
}

test "justsubtitles extracts next flight strings" {
    const allocator = std.testing.allocator;
    const body = "<script>self.__next_f.push([1,\"hello\\nworld\"])</script>";
    const text = try extractNextFlightText(allocator, body);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
}

test "justsubtitles flight JSON skips malformed input and preserves allocation errors" {
    const body =
        "<script>self.__next_f.push([1,\"unterminated\"]</script>" ++
        "<script>self.__next_f.push(not-json)</script>" ++
        "<script>self.__next_f.push([1,\"valid\"])</script>";
    const text = try extractNextFlightText(std.testing.allocator, body);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("valid", text);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        parseNextFlightPayload(failing.allocator(), "[1,\"text\"]"),
    );
}

test "live justsubtitles movie search listing and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "justsubtitles.com")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    try std.testing.expectEqualStrings("The Matrix", search.items[0].title);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .max_attempts = 2,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, download.body[0..2], "PK"));
}
