const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://feliratok.eu";

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    language_code: []const u8,
    filename: []const u8,
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const normalized_query = try common.normalizeTitle(a, trimmed);
        if (normalized_query.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(a, "{s}/index.php?search={s}&soriSorszam=&nyelv=&tab=film", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
        });

        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const page_id = try validateProviderUrl(item.page_url, .detail);
        const download_id = try validateProviderUrl(item.download_url, .download);
        if (!std.mem.eql(u8, page_id, download_id) or !isSafeOutputFilename(item.filename))
            return error.InvalidDownloadUrl;

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = try a.dupe(u8, item.filename),
            .download_url = try a.dupe(u8, item.download_url),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();

    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var cursor: usize = 0;
    const marker = "action=letolt";
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        const row_start = std.mem.lastIndexOf(u8, body[0..pos], "<tr") orelse {
            cursor = pos + marker.len;
            continue;
        };
        const next_row = std.mem.indexOfPos(u8, body, row_start + "<tr".len, "<tr");
        const row_end_opt = std.mem.indexOfPos(u8, body, pos, "</tr>");
        if (next_row) |next| {
            if (row_end_opt == null or next < row_end_opt.?) {
                cursor = next;
                continue;
            }
        }
        const row_end = row_end_opt orelse break;
        const row = body[row_start .. row_end + "</tr>".len];
        cursor = row_end + "</tr>".len;

        const language_label = between(row, "<small>", "</small>") orelse continue;
        const language_code: []const u8 = if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, language_label, " \t\r\n"), "Angol"))
            "en"
        else if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, language_label, " \t\r\n"), "Magyar"))
            "hu"
        else
            continue;

        const original = between(row, "<div class=\"eredeti\">", "</div>") orelse continue;
        const clean_original = std.mem.trim(u8, original, " \t\r\n");
        const split = splitTitleYear(clean_original);
        if (split.title.len == 0) continue;

        const normalized = try common.normalizeTitle(a, split.title);
        defer a.free(normalized);
        if (std.mem.indexOf(u8, normalized, wanted) == null and
            std.mem.indexOf(u8, wanted, normalized) == null) continue;

        var href_cursor: usize = 0;
        var selected_download_url: ?[]const u8 = null;
        var selected_subtitle_id: ?[]const u8 = null;
        var selected_filename: ?[]u8 = null;
        while (nextHrefContaining(row, marker, &href_cursor)) |href| {
            const candidate_url = try common.resolveUrl(a, site, href);
            const candidate_id = validateProviderUrl(candidate_url, .download) catch {
                a.free(candidate_url);
                continue;
            };
            const candidate_filename = queryParam(href, "fnev") orelse {
                a.free(candidate_url);
                continue;
            };
            // Validate the decoded filename before selecting this anchor so
            // an unsafe candidate cannot hide a later usable link in the row.
            const decoded_filename = try percentDecode(a, candidate_filename);
            if (!isSafeOutputFilename(decoded_filename)) {
                a.free(decoded_filename);
                a.free(candidate_url);
                continue;
            }
            selected_download_url = candidate_url;
            selected_subtitle_id = candidate_id;
            selected_filename = decoded_filename;
            break;
        }
        const download_url = selected_download_url orelse continue;
        errdefer a.free(download_url);
        const subtitle_id = selected_subtitle_id.?;
        const filename = selected_filename.?;
        errdefer a.free(filename);
        if (seen.contains(subtitle_id)) {
            a.free(filename);
            a.free(download_url);
            continue;
        }

        const destination = if (std.mem.eql(u8, normalized, wanted)) &exact else &partial;
        try destination.ensureUnusedCapacity(a, 1);
        try seen.ensureUnusedCapacity(a, 1);

        const detail_url = try std.fmt.allocPrint(a, "{s}/index.php?tipus=adatlap&azon=a_{s}", .{ site, subtitle_id });
        errdefer a.free(detail_url);
        const title = try a.dupe(u8, split.title);
        errdefer a.free(title);
        const owned_language_code = try a.dupe(u8, language_code);
        errdefer a.free(owned_language_code);
        const item: SearchItem = .{
            .title = title,
            .year = split.year,
            .language_code = owned_language_code,
            .filename = filename,
            .page_url = detail_url,
            .download_url = download_url,
        };

        seen.putAssumeCapacityNoClobber(subtitle_id, {});
        destination.appendAssumeCapacity(item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

const ProviderRoute = enum { detail, download };

fn validateProviderUrl(url: []const u8, route: ProviderRoute) ![]const u8 {
    common.validatePublicHttpUrl(url) catch return error.InvalidDownloadUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
    if (uri.fragment != null) return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, path, "/index.php")) return error.InvalidDownloadUrl;
    const query_component = uri.query orelse return error.InvalidDownloadUrl;
    const query = switch (query_component) {
        .raw, .percent_encoded => |value| value,
    };

    var action_ok = false;
    var detail_type_ok = false;
    var subtitle_id: ?[]const u8 = null;
    var filename_seen = false;
    var field_count: usize = 0;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        if (field.len == 0) return error.InvalidDownloadUrl;
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidDownloadUrl;
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        field_count += 1;
        switch (route) {
            .detail => {
                if (std.mem.eql(u8, key, "tipus") and !detail_type_ok and std.mem.eql(u8, value, "adatlap")) {
                    detail_type_ok = true;
                } else if (std.mem.eql(u8, key, "azon") and subtitle_id == null and std.mem.startsWith(u8, value, "a_") and isPositiveDecimal(value[2..])) {
                    subtitle_id = value[2..];
                } else return error.InvalidDownloadUrl;
            },
            .download => {
                if (std.mem.eql(u8, key, "action") and !action_ok and std.mem.eql(u8, value, "letolt")) {
                    action_ok = true;
                } else if (std.mem.eql(u8, key, "felirat") and subtitle_id == null and isPositiveDecimal(value)) {
                    subtitle_id = value;
                } else if (std.mem.eql(u8, key, "fnev") and !filename_seen and isSafeQueryValue(value)) {
                    filename_seen = true;
                } else return error.InvalidDownloadUrl;
            },
        }
    }

    switch (route) {
        .detail => {
            if (field_count != 2 or !detail_type_ok) return error.InvalidDownloadUrl;
        },
        .download => {
            if (field_count != 3 or !action_ok or !filename_seen) return error.InvalidDownloadUrl;
        },
    }
    return subtitle_id orelse error.InvalidDownloadUrl;
}

fn isPositiveDecimal(value: []const u8) bool {
    if (value.len == 0 or value[0] == '0') return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isSafeQueryValue(value: []const u8) bool {
    if (value.len == 0) return false;
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (byte <= 0x20 or byte == 0x7f or byte == '&' or byte == '#' or byte == '=') return false;
        if (byte != '%') {
            index += 1;
            continue;
        }
        if (value.len - index < 3 or !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2]))
            return false;
        index += 3;
    }
    return true;
}

fn isSafeOutputFilename(value: []const u8) bool {
    if (value.len == 0 or value.len > 4096 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, ".."))
        return false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\') return false;
    }
    return true;
}

const TitleYear = common.TitleYear;

fn splitTitleYear(value: []const u8) TitleYear {
    var i: usize = 0;
    while (i + 7 <= value.len) : (i += 1) {
        if (value[i] != ' ' or value[i + 1] != '(') continue;
        const digits = value[i + 2 .. i + 6];
        if (value[i + 6] != ')') continue;
        var all_digits = true;
        for (digits) |c| if (!std.ascii.isDigit(c)) {
            all_digits = false;
            break;
        };
        if (!all_digits) continue;
        const year = std.fmt.parseInt(i64, digits, 10) catch continue;
        return .{ .title = std.mem.trimEnd(u8, value[0..i], " \t"), .year = year };
    }
    return .{ .title = std.mem.trim(u8, value, " \t\r\n"), .year = null };
}

fn nextHrefContaining(row: []const u8, needle: []const u8, cursor: *usize) ?[]const u8 {
    const href_marker = "href=\"";
    while (std.mem.indexOfPos(u8, row, cursor.*, href_marker)) |pos| {
        const href_start = pos + href_marker.len;
        const next_pos = std.mem.indexOfPos(u8, row, href_start, href_marker);
        const candidate_end = next_pos orelse row.len;
        const href_end_rel = std.mem.indexOfScalar(u8, row[href_start..candidate_end], '"') orelse {
            cursor.* = candidate_end;
            continue;
        };
        const href_end = href_start + href_end_rel;
        cursor.* = href_end + 1;
        const href = row[href_start..href_end];
        if (std.mem.indexOf(u8, href, needle) != null) return href;
    }
    return null;
}

fn between(value: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, value, open) orelse return null;
    const tail = value[start + open.len ..];
    const end = std.mem.indexOf(u8, tail, close) orelse return null;
    return tail[0..end];
}

fn queryParam(url: []const u8, key: []const u8) ?[]const u8 {
    const query = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var parts = std.mem.splitScalar(u8, url[query + 1 ..], '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], key)) return part[eq + 1 ..];
    }
    return null;
}

fn percentDecode(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                try out.append(allocator, @intCast(hi.? * 16 + lo.?));
                i += 3;
                continue;
            }
        }
        try out.append(allocator, if (input[i] == '+') ' ' else input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "supersubtitles parses exact movie rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        "<tr><td class=\"lang\"><small>Angol</small></td><td><div class=\"eredeti\">The Matrix (1999) (REMUX.2160p-SA89)</div></td><td><a href=\"/index.php?action=letolt&fnev=The.Matrix.1999.eng.srt&felirat=1742204065\">x</a></td></tr>",
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 1999), response.items[0].year);
    try std.testing.expectEqualStrings("en", response.items[0].language_code);
}

test "supersubtitles punctuation-only normalized query yields no search results" {
    var response = try parseSearchHtml(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<tr><td class=\"lang\"><small>Angol</small></td><td><div class=\"eredeti\">The Matrix (1999)</div></td><td><a href=\"/index.php?action=letolt&fnev=The.Matrix.srt&felirat=7\">x</a></td></tr>",
        "... !!! ---",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "supersubtitles malformed duplicate does not suppress a valid row" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        "<tr><td><small>Angol</small></td><td><div class=\"eredeti\">The Matrix (1999)</div></td><td><a href=\"/index.php?action=letolt&felirat=7\">bad</a></td></tr>" ++
            "<tr><td><small>Angol</small></td><td><div class=\"eredeti\">The Matrix (1999)</div></td><td><a href=\"/index.php?action=letolt&fnev=The.Matrix.srt&felirat=7\">good</a></td></tr>" ++
            "<tr><td><small>Angol</small></td><td><div class=\"eredeti\">The Matrix (1999)</div></td><td><a href=\"/index.php?action=letolt&fnev=Duplicate.srt&felirat=7\">duplicate</a></td></tr>",
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The.Matrix.srt", response.items[0].filename);
}

test "supersubtitles scans later canonical downloads in the same row" {
    var response = try parseSearchHtml(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        "<tr><td><small>Angol</small></td><td><div class=\"eredeti\">The Matrix (1999)</div></td><td>" ++
            "<a href=\"/index.php?action=letolt&fnev=Bad.srt&felirat=7&next=/admin\">bad</a>" ++
            "<a href=\"/index.php?action=letolt&fnev=The.Matrix.srt&felirat=8\">good</a>" ++
            "</td></tr>",
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The.Matrix.srt", response.items[0].filename);
    try std.testing.expectEqualStrings(
        "https://feliratok.eu/index.php?action=letolt&fnev=The.Matrix.srt&felirat=8",
        response.items[0].download_url,
    );
}

test "supersubtitles unterminated row does not consume a valid sibling" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        "<tr><td><a href=\"/index.php?action=letolt&felirat=7\">broken</a></td>" ++
            "<tr><td><small>Angol</small></td><td><div class=\"eredeti\">The Matrix (1999)</div></td>" ++
            "<td><a href=\"/index.php?action=letolt&fnev=The.Matrix.srt&felirat=8\">good</a></td></tr>",
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The.Matrix.srt", response.items[0].filename);
}

test "supersubtitles rejects non-provider download targets" {
    _ = try validateProviderUrl(
        "https://feliratok.eu/index.php?action=letolt&fnev=subtitle.srt&felirat=1",
        .download,
    );
    _ = try validateProviderUrl(
        "https://feliratok.eu/index.php?tipus=adatlap&azon=a_1",
        .detail,
    );
    for ([_][]const u8{
        "http://127.0.0.1/index.php?action=letolt",
        "https://feliratok.eu.example/index.php?action=letolt",
        "https://user@feliratok.eu/index.php?action=letolt",
        "https://feliratok.eu/admin?action=letolt&fnev=subtitle.srt&felirat=1",
        "https://feliratok.eu/index.php?action=letolt&fnev=subtitle.srt&felirat=1&next=/admin",
        "https://feliratok.eu/index.php?action=letolt&fnev=subtitle.srt&felirat=1#fragment",
        "https://feliratok.eu/index.php?action=letolt&fnev=subtitle.srt&felirat=01",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url, .download));
    }
}

test "supersubtitles binds detail and download ids and rejects unsafe filenames" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    const base: SearchItem = .{
        .title = "The Matrix",
        .year = 1999,
        .language_code = "en",
        .filename = "matrix.srt",
        .page_url = site ++ "/index.php?tipus=adatlap&azon=a_1",
        .download_url = site ++ "/index.php?action=letolt&fnev=matrix.srt&felirat=2",
    };
    try std.testing.expectError(error.InvalidDownloadUrl, scraper.fetchSubtitlesBySearchItem(base));
    var unsafe = base;
    unsafe.download_url = site ++ "/index.php?action=letolt&fnev=matrix.srt&felirat=1";
    unsafe.filename = "../matrix.srt";
    try std.testing.expectError(error.InvalidDownloadUrl, scraper.fetchSubtitlesBySearchItem(unsafe));
}

test "live supersubtitles movie search and download" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "feliratok.eu")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);

    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();

    const download = try common.fetchBytes(&client, std.testing.allocator, subtitles.subtitles[0].download_url, .{
        .accept = "application/text,text/plain,*/*",
        .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = search.items[0].page_url }},
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(download.body);
    try std.testing.expect(download.body.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, download.body, "-->") != null);
}

test "supersubtitles unsafe decoded filenames do not shadow a valid same-row candidate" {
    inline for (.{ "%2Fbad.srt", "bad%5Cname.srt", "bad%00name.srt", "%2E%2E" }) |unsafe_filename| {
        var response = try parseSearchHtml(
            std.heap.ArenaAllocator.init(std.testing.allocator),
            "<tr><td><small>Angol</small></td><td><div class=\"eredeti\">The Matrix (1999)</div></td><td>" ++
                "<a href=\"/index.php?action=letolt&fnev=" ++ unsafe_filename ++ "&felirat=7\">bad</a>" ++
                "<a href=\"/index.php?action=letolt&fnev=The.Matrix.srt&felirat=7\">good</a>" ++
                "</td></tr>",
            "The Matrix",
        );
        defer response.deinit();
        try std.testing.expectEqual(@as(usize, 1), response.items.len);
        try std.testing.expectEqualStrings("The.Matrix.srt", response.items[0].filename);
        try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
        try std.testing.expectEqualStrings(site ++ "/index.php?action=letolt&fnev=The.Matrix.srt&felirat=7", response.items[0].download_url);
        try std.testing.expectEqualStrings(site ++ "/index.php?tipus=adatlap&azon=a_7", response.items[0].page_url);
    }
}
