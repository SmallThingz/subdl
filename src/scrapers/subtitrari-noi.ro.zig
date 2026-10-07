const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const HtmlParseOptions: html.ParseOptions = .{};
const site = "https://www.subtitrari-noi.ro";
const search_url = site ++ "/paginare_filme.php";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    page_url: []const u8,
    download_url: []const u8,
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
        const payload = try std.fmt.allocPrint(
            a,
            "search_q=1&tip=2&an=Toti%20anii&gen=Toate&cautare={s}&query_q={s}",
            .{ encoded, encoded },
        );
        const headers = [_]std.http.Header{
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
            .{ .name = "origin", .value = site },
            .{ .name = "referer", .value = site ++ "/" },
        };
        const response = try fetch(self.client, a, search_url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded; charset=UTF-8",
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &headers,
            .cache = false,
            .max_attempts = 3,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const detail_id = try detailId(item.page_url);
        try validateDownloadUrl(item.download_url, detail_id);

        const filename = try filenameFromDownloadUrl(a, item.download_url, item.title);
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = "ro",
            .filename = filename,
            .download_url = try a.dupe(u8, item.download_url),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

test "subtitrari-noi rejects normalized-empty searches before strict HTTPS I/O" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(search_url, url);
            try std.testing.expectEqual(std.http.Method.POST, options.method);
            try std.testing.expect(options.require_public_origin);
            try std.testing.expect(options.require_https);
            try std.testing.expect(options.require_same_origin);
            try std.testing.expectEqualStrings(
                "search_q=1&tip=2&an=Toti%20anii&gen=Toate&cautare=Matrix&query_q=Matrix",
                options.payload orelse return error.TestUnexpectedResult,
            );
            return .{ .status = .ok, .body = try allocator.dupe(u8, "<html></html>") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);

    var empty = try scraper.searchUsing(Fixture.fetch, "---");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    var normal = try scraper.searchUsing(Fixture.fetch, " Matrix ");
    defer normal.deinit();
    try std.testing.expectEqual(@as(usize, 0), normal.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    var parsed = try common.parseHtmlStable(a, body);

    const wanted = try common.normalizeTitle(a, query);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    var rounds = parsed.doc.queryAll("div#round");
    while (rounds.next()) |round| {
        candidate_scan: {
            var title_anchors = round.queryAll("div#content-main a[href]");
            while (title_anchors.next()) |title_anchor| {
                const page_href = common.getAttributeValueSafe(title_anchor, "href") orelse continue;
                const raw_title = try common.innerTextTrimmedOwned(a, title_anchor);
                if (raw_title.len == 0) continue;

                const split = common.splitTrailingYear(raw_title);
                const title = try a.dupe(u8, split.title);
                const normalized = try common.normalizeTitle(a, title);
                if (!normalizedTitlesRelated(normalized, wanted)) continue;
                const page_url = resolveDetailsUrl(a, page_href) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                const detail_id = detailId(page_url) catch continue;

                var download_anchors = round.queryAll("p.buton a[href]");
                while (download_anchors.next()) |download_anchor| {
                    const download_href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
                    const download_url = normalizeDownloadUrl(a, download_href, detail_id) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    const item: SearchItem = .{
                        .title = title,
                        .year = split.year,
                        .page_url = page_url,
                        .download_url = download_url,
                    };

                    if (std.mem.eql(u8, normalized, wanted))
                        try exact.append(a, item)
                    else
                        try partial.append(a, item);
                    break :candidate_scan;
                }
            }
        }
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
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

fn normalizeDownloadUrl(allocator: Allocator, href: []const u8, detail_id: []const u8) ![]const u8 {
    const resolved = if (std.mem.indexOf(u8, href, "https://")) |idx| blk: {
        if (idx != 0 and !hasDetailIdPrefix(href[0..idx], detail_id)) return error.UnsafeHttpTarget;
        break :blk try allocator.dupe(u8, href[idx..]);
    } else if (std.mem.indexOf(u8, href, "http://")) |idx| blk: {
        if (idx != 0 and !hasDetailIdPrefix(href[0..idx], detail_id)) return error.UnsafeHttpTarget;
        break :blk try allocator.dupe(u8, href[idx..]);
    } else try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateDownloadUrl(resolved, detail_id);
    return resolved;
}

fn hasDetailIdPrefix(prefix: []const u8, detail_id: []const u8) bool {
    return prefix.len == detail_id.len + 1 and
        std.mem.eql(u8, prefix[0..detail_id.len], detail_id) and
        prefix[detail_id.len] == '-';
}

fn resolveDetailsUrl(allocator: Allocator, href: []const u8) ![]const u8 {
    const decoded_href = try decodeHtmlAmpersands(allocator, href);
    defer allocator.free(decoded_href);
    const resolved = try common.resolveUrl(allocator, site, decoded_href);
    errdefer allocator.free(resolved);
    _ = try detailId(resolved);
    return resolved;
}

fn decodeHtmlAmpersands(allocator: Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        if (std.mem.startsWith(u8, input[index..], "&amp;")) {
            try output.append(allocator, '&');
            index += "&amp;".len;
        } else {
            try output.append(allocator, input[index]);
            index += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

fn validateProviderOrigin(url: []const u8) !std.Uri {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url)) and
        !(try common.sameOrigin("https://subtitrari-noi.ro", url)))
    {
        return error.UnsafeHttpTarget;
    }
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.UnsafeHttpTarget;
    return uri;
}

fn detailId(url: []const u8) ![]const u8 {
    const uri = try validateProviderOrigin(url);
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/index.php")) return error.UnsafeHttpTarget;
    const query_component = uri.query orelse return error.UnsafeHttpTarget;
    const query = switch (query_component) {
        .raw, .percent_encoded => |value| value,
    };
    var page_seen = false;
    var act_seen = false;
    var id: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.UnsafeHttpTarget;
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        if (std.mem.eql(u8, key, "page") and !page_seen and std.mem.eql(u8, value, "movie_details")) {
            page_seen = true;
        } else if (std.mem.eql(u8, key, "act") and !act_seen and std.mem.eql(u8, value, "1")) {
            act_seen = true;
        } else if (std.mem.eql(u8, key, "id") and id == null and isCanonicalPositiveId(value)) {
            id = value;
        } else {
            return error.UnsafeHttpTarget;
        }
    }
    if (!page_seen or !act_seen) return error.UnsafeHttpTarget;
    return id orelse error.UnsafeHttpTarget;
}

fn validateDownloadUrl(url: []const u8, detail_id: []const u8) !void {
    const uri = try validateProviderOrigin(url);
    if (uri.query != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const archive_prefix = "/Arhive/";
    if (std.mem.startsWith(u8, path, archive_prefix)) {
        if (!isSafeEncodedArchiveFilename(path[archive_prefix.len..])) return error.UnsafeHttpTarget;
        return;
    }

    if (path.len < 2 or path[0] != '/') return error.UnsafeHttpTarget;
    const filename = path[1..];
    if (!isSafeEncodedArchiveFilename(filename)) return error.UnsafeHttpTarget;
    if (!std.mem.startsWith(u8, filename, detail_id) or
        filename.len <= detail_id.len + "-subtitrari-noi.ro-".len or
        !std.mem.startsWith(u8, filename[detail_id.len..], "-subtitrari-noi.ro-"))
    {
        return error.UnsafeHttpTarget;
    }
}

fn isCanonicalPositiveId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isSafeEncodedArchiveFilename(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024 or !std.ascii.endsWithIgnoreCase(value, ".zip")) return false;
    var index: usize = 0;
    while (index < value.len) {
        var byte = value[index];
        if (byte == '%') {
            if (value.len - index < 3) return false;
            const high = std.fmt.charToDigit(value[index + 1], 16) catch return false;
            const low = std.fmt.charToDigit(value[index + 2], 16) catch return false;
            byte = @intCast(high * 16 + low);
            index += 3;
        } else {
            if (byte == '/' or byte == '\\' or byte == '?' or byte == '#') return false;
            index += 1;
        }
        if (byte < 0x20 or byte == 0x7f or byte == '%' or byte == '/' or byte == '\\' or byte == '?' or byte == '#') return false;
    }
    return true;
}

fn filenameFromDownloadUrl(allocator: Allocator, url: []const u8, title: []const u8) ![]u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..end];
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const filename = path[slash + 1 ..];
        if (filename.len > 0 and std.ascii.endsWithIgnoreCase(filename, ".zip"))
            return allocator.dupe(u8, filename);
    }
    const slug = try common.asciiSlug(allocator, title);
    defer allocator.free(slug);
    return std.fmt.allocPrint(allocator, "{s}.zip", .{if (slug.len > 0) slug else "subtitle"});
}

test "subtitrari-noi parses exact result and prefixed absolute archive url" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<div id="round"><div id="content">
        \\<div id="content-main"><p><a href="https://www.subtitrari-noi.ro/index.php?page=movie_details&amp;act=1&amp;id=87170">Reacher (2022)</a></p></div>
        \\<div id="content-right"><p class="buton"><a href="87170-https://subtitrari-noi.ro/Arhive/Reacher.zip">Descarca</a></p></div>
        \\</div></div>
        \\<div id="round"><div id="content">
        \\<div id="content-main"><p><a href="https://www.subtitrari-noi.ro/index.php?page=movie_details&amp;act=1&amp;id=99999">Unrelated Film (2024)</a></p></div>
        \\<div id="content-right"><p class="buton"><a href="https://subtitrari-noi.ro/Arhive/Unrelated.zip">Descarca</a></p></div>
        \\</div></div>
        \\<div id="round"><div id="content">
        \\<div id="content-main"><p><a href="https://www.subtitrari-noi.ro/index.php?page=movie_details&amp;act=1&amp;id=77777">Preacher (2016)</a></p></div>
        \\<div id="content-right"><p class="buton"><a href="77777-https://subtitrari-noi.ro/Arhive/Preacher.zip">Descarca</a></p></div>
        \\</div></div>
        \\<div id="round"><div id="content">
        \\<div id="content-main"><p><a href="https://www.subtitrari-noi.ro/index.php?page=movie_details&amp;act=1&amp;id=88888">Jack Reacher (2012)</a></p></div>
        \\<div id="content-right"><p class="buton"><a href="88888-https://subtitrari-noi.ro/Arhive/Jack_Reacher.zip">Descarca</a></p></div>
        \\</div></div>
    ,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings("Reacher", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 2022), response.items[0].year);
    try std.testing.expectEqualStrings("https://subtitrari-noi.ro/Arhive/Reacher.zip", response.items[0].download_url);
    try std.testing.expectEqualStrings("Jack Reacher", response.items[1].title);
}

test "subtitrari-noi scans for a bound detail and archive pair" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<div id="round"><div id="content">
        \\<div id="content-main">
        \\  <a href="/index.php?page=movie_details&amp;act=1&amp;id=99999">Reacher (2022)</a>
        \\  <a href="/index.php?page=movie_details&amp;act=1&amp;id=87170">Reacher (2022)</a>
        \\</div>
        \\<p class="buton"><a href="88888-subtitrari-noi.ro-Reacher-1.zip">decoy</a></p>
        \\<p class="buton"><a href="87170-subtitrari-noi.ro-Reacher-2.zip">Descarca</a></p>
        \\</div></div>
    ,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings(
        site ++ "/index.php?page=movie_details&act=1&id=87170",
        response.items[0].page_url,
    );
    try std.testing.expectEqualStrings(
        site ++ "/87170-subtitrari-noi.ro-Reacher-2.zip",
        response.items[0].download_url,
    );
}

test "subtitrari-noi accepts the evidenced rewritten archive route" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<div id="round"><div id="content">
        \\<div id="content-main"><p><a href="https://www.subtitrari-noi.ro/index.php?page=movie_details&amp;act=1&amp;id=81697">The Matrix Resurrections (2021)</a></p></div>
        \\<div id="content-right"><p class="buton"><a href="81697-subtitrari-noi.ro-The_Matrix_Resurrections-616.zip">Descarca</a></p></div>
        \\</div></div>
    ,
        "The Matrix Resurrections",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings(
        site ++ "/81697-subtitrari-noi.ro-The_Matrix_Resurrections-616.zip",
        response.items[0].download_url,
    );
}

test "subtitrari-noi rejects unsafe provider urls before fetch" {
    for ([_][]const u8{
        "http://127.0.0.1/archive.zip",
        "https://user@subtitrari-noi.ro/archive.zip",
        "https://subtitrari-noi.ro.attacker.example/archive.zip",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateDownloadUrl(url, "87170"));
    }
    const detail_url = site ++ "/index.php?page=movie_details&act=1&id=87170";
    try std.testing.expectEqualStrings("87170", try detailId(detail_url));
    try validateDownloadUrl("https://subtitrari-noi.ro/Arhive/Reacher.zip", "87170");
    try validateDownloadUrl(site ++ "/87170-subtitrari-noi.ro-Reacher-134.zip", "87170");
    try std.testing.expectError(error.UnsafeHttpTarget, detailId(site ++ "/index.php?page=admin&id=87170"));
    try std.testing.expectError(error.UnsafeHttpTarget, detailId(site ++ "/index.php?page=movie_details&id=87170"));
    try std.testing.expectError(error.UnsafeHttpTarget, detailId(site ++ "/index.php?page=movie_details&act=2&id=87170"));
    try std.testing.expectError(error.UnsafeHttpTarget, detailId(site ++ "/index.php?page=movie_details&act=1&act=1&id=87170"));
    try std.testing.expectError(error.UnsafeHttpTarget, detailId(site ++ "/index.php?page=movie_details&act=1&id=87170&next=/admin"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateDownloadUrl(site ++ "/admin/export.zip", "87170"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateDownloadUrl(site ++ "/Arhive/a%2fb.zip", "87170"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateDownloadUrl(site ++ "/99999-subtitrari-noi.ro-Reacher-134.zip", "87170"));
    try std.testing.expectError(error.UnsafeHttpTarget, normalizeDownloadUrl(std.testing.allocator, "99999-https://subtitrari-noi.ro/Arhive/Reacher.zip", "87170"));
}

test "live subtitrari-noi movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitrari-noi.ro")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix Resurrections");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Reacher");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}
