const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://zoom.lk";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    season: ?i64,
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
        const parsed_query = try parseSearchQuery(trimmed);
        const wanted = try common.normalizeTitle(a, parsed_query.title);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, parsed_query.title);
        const url = try std.fmt.allocPrint(a, "{s}/?s={s}", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        try validateZoomUrl(item.page_url, .page);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        const download_url = try parseDownloadUrl(a, response.body);
        const download_id = trailingNumericSegment(download_url) orelse "subtitle";

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = "si",
            .filename = try std.fmt.allocPrint(a, "zoom-{s}-{s}", .{ download_id, try common.asciiSlug(a, item.title) }),
            .download_url = download_url,
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

    const parsed_query = try parseSearchQuery(query);
    const wanted = try common.normalizeTitle(a, parsed_query.title);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var cursor: usize = 0;
    const marker = "<h3 class=\"entry-title td-module-title\">";
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |h3_pos| {
        const content_start = h3_pos + marker.len;
        const next_h3 = std.mem.indexOfPos(u8, body, content_start, marker);
        const h3_end_opt = std.mem.indexOfPos(u8, body, content_start, "</h3>");
        if (next_h3) |next| {
            if (h3_end_opt == null or next < h3_end_opt.?) {
                cursor = next;
                continue;
            }
        }
        const h3_end = h3_end_opt orelse break;
        const block = body[h3_pos..h3_end];
        cursor = h3_end + "</h3>".len;

        const anchor_tag = firstOpeningTag(block, "a") orelse continue;
        const raw_href = attributeValue(anchor_tag, "href") orelse continue;
        const raw_title = attributeValue(anchor_tag, "title") orelse continue;
        const href = try decodeHtmlEntities(a, raw_href);
        const decoded_title = try decodeHtmlEntities(a, raw_title);
        validateZoomUrl(href, .page) catch continue;
        if (seen.contains(href)) continue;

        const parsed_title = parsePostTitle(decoded_title);
        if (parsed_title.title.len == 0) continue;
        if (parsed_query.season) |season| {
            if (parsed_title.media_kind != .tv or parsed_title.season != season) continue;
        }
        const normalized = try common.normalizeTitle(a, parsed_title.title);
        if (normalized.len == 0) continue;
        if (!common.normalizedTitlesRelated(normalized, wanted)) continue;

        try seen.put(a, try a.dupe(u8, href), {});
        const item: SearchItem = .{
            .title = try a.dupe(u8, parsed_title.title),
            .year = parsed_title.year,
            .media_kind = parsed_title.media_kind,
            .season = parsed_title.season,
            .page_url = try a.dupe(u8, href),
        };

        if (std.mem.eql(u8, normalized, wanted))
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

const ParsedTitle = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    season: ?i64,
};

const ZoomRoute = enum { page, download };

fn validateZoomUrl(url: []const u8, route: ZoomRoute) !void {
    try common.validatePublicHttpUrl(url);
    for (url) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\') return error.UnsafeHttpTarget;
    }
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null) return error.UnsafeHttpTarget;
    if (uri.port) |port| if (port != 443) return error.UnsafeHttpTarget;
    const host = uri.host orelse return error.UnsafeHttpTarget;
    const host_bytes = switch (host) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    if (!std.ascii.eqlIgnoreCase(host_bytes, "zoom.lk")) return error.UnsafeHttpTarget;
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
    if (uri.query != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    const valid = switch (route) {
        .page => isCanonicalPostPath(path),
        .download => isCanonicalDownloadPath(path),
    };
    if (!valid) return error.UnsafeHttpTarget;
}

fn isCanonicalDownloadPath(path: []const u8) bool {
    const prefix = "/sub-download/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const id = path[prefix.len..];
    if (id.len == 0 or id.len > 19 or id[0] == '0') return false;
    for (id) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isCanonicalPostPath(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/') return false;
    const without_trailing = if (path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    if (without_trailing.len < 2 or std.mem.indexOfScalar(u8, without_trailing[1..], '/') != null)
        return false;
    return isSafePathSegment(without_trailing[1..]);
}

fn isSafePathSegment(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            index += 1;
            continue;
        }
        if (byte != '%' or value.len - index < 3 or
            !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return false;
        const high = std.fmt.charToDigit(value[index + 1], 16) catch return false;
        const low = std.fmt.charToDigit(value[index + 2], 16) catch return false;
        const decoded: u8 = @intCast(high * 16 + low);
        if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
            decoded == '?' or decoded == '#' or decoded == '.') return false;
        index += 3;
    }
    return true;
}

fn parsePostTitle(raw: []const u8) ParsedTitle {
    const suffixes = [_][]const u8{
        " Sinhala Subtitle",
        " Sinhala subtitle",
    };

    var core = std.mem.trim(u8, raw, " \t\r\n");
    for (suffixes) |suffix| {
        if (std.ascii.findIgnoreCase(core, suffix)) |pos| {
            core = std.mem.trimEnd(u8, core[0..pos], " \t");
            break;
        }
    }

    var year: ?i64 = null;
    var season: ?i64 = null;
    var media_kind: MediaKind = .movie;

    if (std.ascii.findIgnoreCase(core, "Complete season ")) |pos| {
        const tail = core[pos + "Complete season ".len ..];
        var end: usize = 0;
        while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
        if (end > 0) season = std.fmt.parseInt(i64, tail[0..end], 10) catch null;
        core = std.mem.trimEnd(u8, core[0..pos], " \t");
        media_kind = .tv;
    } else if (findSeasonToken(core)) |token| {
        season = token.season;
        media_kind = .tv;
        core = std.mem.trimEnd(u8, core[0..token.start], " \t-:");
    }

    if (parseTrailingYear(core)) |year_info| {
        year = year_info.year;
        core = year_info.title;
    }

    return .{
        .title = std.mem.trim(u8, core, " \t\r\n"),
        .year = year,
        .media_kind = media_kind,
        .season = season,
    };
}

const YearInfo = common.RequiredTitleYear;

fn parseTrailingYear(value: []const u8) ?YearInfo {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 6 or trimmed[trimmed.len - 1] != ')') return null;
    const open = std.mem.lastIndexOfScalar(u8, trimmed, '(') orelse return null;
    if (trimmed.len - open != 6) return null;
    const digits = trimmed[open + 1 .. trimmed.len - 1];
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const year = std.fmt.parseInt(i64, digits, 10) catch return null;
    return .{
        .title = std.mem.trimEnd(u8, trimmed[0..open], " \t"),
        .year = year,
    };
}

const SeasonToken = struct { start: usize, season: i64 };

fn findSeasonToken(value: []const u8) ?SeasonToken {
    var i: usize = 0;
    while (i + 1 < value.len) : (i += 1) {
        if (value[i] != 's' and value[i] != 'S') continue;
        if (i > 0 and std.ascii.isAlphanumeric(value[i - 1])) continue;
        var p = i + 1;
        const start = p;
        while (p < value.len and std.ascii.isDigit(value[p])) : (p += 1) {}
        if (p == start) continue;
        if (p < value.len and std.ascii.isAlphanumeric(value[p])) continue;
        const season = std.fmt.parseInt(i64, value[start..p], 10) catch continue;
        return .{ .start = i, .season = season };
    }
    return null;
}

fn parseSearchQuery(value: []const u8) !struct { title: []const u8, season: ?i64 } {
    if (common.parseEpisodeQuery(value).episode != null) return error.UnsupportedEpisodeSelection;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (findSeasonToken(trimmed)) |token| return .{
        .title = std.mem.trimEnd(u8, trimmed[0..token.start], " \t-:"),
        .season = token.season,
    };
    return .{ .title = trimmed, .season = null };
}

fn parseDownloadUrl(allocator: Allocator, body: []const u8) ![]const u8 {
    const marker = "https://zoom.lk/sub-download/";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, marker)) |pos| {
        var end = pos + marker.len;
        while (end < body.len and std.ascii.isDigit(body[end])) : (end += 1) {}
        cursor = @max(end, pos + marker.len);
        if (end == pos + marker.len) continue;
        if (body[pos + marker.len] == '0') continue;
        if (end < body.len and (std.ascii.isAlphanumeric(body[end]) or body[end] == '-' or body[end] == '_'))
            continue;
        const url = try allocator.dupe(u8, body[pos..end]);
        errdefer allocator.free(url);
        validateZoomUrl(url, .download) catch {
            allocator.free(url);
            continue;
        };
        return url;
    }
    return error.MissingField;
}

fn trailingNumericSegment(url: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
    if (slash + 1 >= url.len) return null;
    const value = url[slash + 1 ..];
    if (value.len == 0) return null;
    for (value) |c| if (!std.ascii.isDigit(c)) return null;
    return value;
}

fn firstOpeningTag(input: []const u8, name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor + name.len + 1 <= input.len) : (cursor += 1) {
        if (input[cursor] != '<') continue;
        const name_start = cursor + 1;
        const name_end = name_start + name.len;
        if (name_end > input.len or !std.ascii.eqlIgnoreCase(input[name_start..name_end], name)) continue;
        if (name_end < input.len and !std.ascii.isWhitespace(input[name_end]) and
            input[name_end] != '>' and input[name_end] != '/') continue;

        var active_quote: ?u8 = null;
        var end = name_end;
        while (end < input.len) : (end += 1) {
            if (active_quote) |quote| {
                if (input[end] == quote) active_quote = null;
                continue;
            }
            if (input[end] == '"' or input[end] == '\'') {
                active_quote = input[end];
                continue;
            }
            if (input[end] == '>') return input[cursor .. end + 1];
        }
        return null;
    }
    return null;
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    var active_quote: ?u8 = null;
    while (cursor + name.len <= tag.len) {
        if (active_quote) |quote| {
            if (tag[cursor] == quote) active_quote = null;
            cursor += 1;
            continue;
        }
        if (tag[cursor] == '"' or tag[cursor] == '\'') {
            active_quote = tag[cursor];
            cursor += 1;
            continue;
        }
        const pos = cursor;
        if (!std.ascii.eqlIgnoreCase(tag[pos .. pos + name.len], name)) {
            cursor += 1;
            continue;
        }
        if (pos == 0 or !std.ascii.isWhitespace(tag[pos - 1])) {
            cursor = pos + name.len;
            continue;
        }
        var after = pos + name.len;
        while (after < tag.len and std.ascii.isWhitespace(tag[after])) : (after += 1) {}
        if (after >= tag.len or tag[after] != '=') {
            cursor = pos + name.len;
            continue;
        }
        after += 1;
        while (after < tag.len and std.ascii.isWhitespace(tag[after])) : (after += 1) {}
        if (after >= tag.len) return null;
        const quote = tag[after];
        if (quote != '"' and quote != '\'') return null;
        const start = after + 1;
        const end_rel = std.mem.indexOfScalar(u8, tag[start..], quote) orelse return null;
        return tag[start .. start + end_rel];
    }
    return null;
}

fn decodeHtmlEntities(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '&') {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }

        const tail = input[i..];
        const replacements = [_]struct { encoded: []const u8, decoded: u8 }{
            .{ .encoded = "&amp;", .decoded = '&' },
            .{ .encoded = "&quot;", .decoded = '"' },
            .{ .encoded = "&apos;", .decoded = '\'' },
            .{ .encoded = "&lt;", .decoded = '<' },
            .{ .encoded = "&gt;", .decoded = '>' },
            .{ .encoded = "&nbsp;", .decoded = ' ' },
        };
        var matched = false;
        for (replacements) |replacement| {
            if (!std.mem.startsWith(u8, tail, replacement.encoded)) continue;
            try out.append(allocator, replacement.decoded);
            i += replacement.encoded.len;
            matched = true;
            break;
        }
        if (matched) continue;

        if (std.mem.startsWith(u8, tail, "&#")) {
            const semicolon = std.mem.indexOfScalar(u8, tail, ';') orelse {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            if (semicolon > 2 and semicolon <= 10) {
                const numeric = tail[2..semicolon];
                const hex = numeric.len > 1 and (numeric[0] == 'x' or numeric[0] == 'X');
                const digits = if (hex) numeric[1..] else numeric;
                const codepoint = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch {
                    try out.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch {
                    try out.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                try out.appendSlice(allocator, encoded[0..encoded_len]);
                i += semicolon + 1;
                continue;
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "zoom parses movie and tv titles" {
    const movie = parsePostTitle("Centigrade (2020) Sinhala Subtitle (සිංහල උපසිරැසි)");
    try std.testing.expectEqualStrings("Centigrade", movie.title);
    try std.testing.expectEqual(@as(?i64, 2020), movie.year);
    try std.testing.expect(movie.media_kind == .movie);

    const tv = parsePostTitle("Teen Wolf (2012) Complete season 02 Sinhala Subtitle (සිංහල උපසිරැසි)");
    try std.testing.expectEqualStrings("Teen Wolf", tv.title);
    try std.testing.expectEqual(@as(?i64, 2012), tv.year);
    try std.testing.expectEqual(@as(?i64, 2), tv.season);
    try std.testing.expect(tv.media_kind == .tv);
}

test "zoom verifies season packs and rejects unsupported episode selection" {
    const fixture =
        "<h3 class=\"entry-title td-module-title\"><a href=\"https://zoom.lk/season1\" title=\"Teen Wolf (2012) S01 Sinhala Subtitle\">x</a></h3>" ++
        "<h3 class=\"entry-title td-module-title\"><a href=\"https://zoom.lk/season10\" title=\"Teen Wolf (2012) S10 Sinhala Subtitle\">x</a></h3>";
    var response = try parseSearchHtml(std.heap.ArenaAllocator.init(std.testing.allocator), fixture, "Teen Wolf S10");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Teen Wolf", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 10), response.items[0].season);
    const special = parsePostTitle("Teen Wolf (2012) S00 Sinhala Subtitle");
    try std.testing.expectEqual(@as(?i64, 0), special.season);
    try std.testing.expectEqualStrings("Teen Wolf", special.title);
    try std.testing.expectError(error.UnsupportedEpisodeSelection, parseSearchQuery("Teen Wolf S01E01"));
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    try std.testing.expectError(error.UnsupportedEpisodeSelection, scraper.search("Teen Wolf S10E01"));
}

test "zoom matches exact attribute names and decodes title entities" {
    const fixture =
        "<h3 class=\"entry-title td-module-title\"><span href=\"https://zoom.lk/nested-wrong\" title=\"Nested Wrong\"></span><a data-href=\"https://zoom.lk/wrong\" href = \"https://zoom.lk/right\" aria-title=\"Wrong\" data-note=\" title='Injected'\" title=\"Tom &amp; Jerry (2021) Sinhala Subtitle\">x</a></h3>";
    var response = try parseSearchHtml(std.heap.ArenaAllocator.init(std.testing.allocator), fixture, "Tom & Jerry");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Tom & Jerry", response.items[0].title);
    try std.testing.expectEqualStrings("https://zoom.lk/right", response.items[0].page_url);
    try std.testing.expectEqual(@as(?i64, 2021), response.items[0].year);

    const decoded = try decodeHtmlEntities(std.testing.allocator, "Rock&#39;n&#x20AC;");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("Rock'n€", decoded);
}

test "zoom malformed heading does not consume the following valid sibling" {
    const fixture =
        "<h3 class=\"entry-title td-module-title\"><a href=\"https://zoom.lk/bad\" title=\"broken\">" ++
        "<h3 class=\"entry-title td-module-title\"><a href=\"https://zoom.lk/centigrade\" title=\"Centigrade (2020) Sinhala Subtitle\">good</a></h3>";
    var response = try parseSearchHtml(std.heap.ArenaAllocator.init(std.testing.allocator), fixture, "Centigrade");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Centigrade", response.items[0].title);
    try std.testing.expectEqualStrings("https://zoom.lk/centigrade", response.items[0].page_url);
}

test "zoom only accepts exact public HTTPS provider routes before acquisition" {
    try validateZoomUrl("https://zoom.lk/post", .page);
    try validateZoomUrl("HTTPS://ZOOM.LK:443/post", .page);
    try validateZoomUrl("https://zoom.lk/sub-download/42", .download);
    for ([_][]const u8{
        "https://zoom.lk.attacker.example/post",
        "https://zoom.lk@attacker.example/post",
        "https://user@zoom.lk/post",
        "https://zoom.lk:444/post",
        "http://zoom.lk/post",
        "https://%7aoom.lk/post",
        "https://zoom.lk./post",
        "https://zoom.lk\\@attacker.example/post",
        "https://zoom.lk/post\n",
        "https://zoom.lk/admin/users",
        "https://zoom.lk/post?next=/admin",
        "https://zoom.lk/post#fragment",
        "https://zoom.lk/%2e%2e",
    }) |url| try std.testing.expectError(error.UnsafeHttpTarget, validateZoomUrl(url, .page));
    try std.testing.expectError(error.InvalidDownloadUrl, validateZoomUrl("file:///post", .page));
    for ([_][]const u8{
        "https://zoom.lk/sub-download/0",
        "https://zoom.lk/sub-download/01",
        "https://zoom.lk/sub-download/42/extra",
        "https://zoom.lk/sub-download/42?next=/admin",
    }) |url| try std.testing.expectError(error.UnsafeHttpTarget, validateZoomUrl(url, .download));

    const fixture =
        "<h3 class=\"entry-title td-module-title\"><a href=\"https://zoom.lk.attacker.example/post\" title=\"Centigrade (2020) Sinhala Subtitle\">x</a></h3>" ++
        "<h3 class=\"entry-title td-module-title\"><a href=\"https://user@zoom.lk/post\" title=\"Centigrade (2020) Sinhala Subtitle\">x</a></h3>" ++
        "<h3 class=\"entry-title td-module-title\"><a href=\"https://zoom.lk/post\" title=\"Centigrade (2020) Sinhala Subtitle\">x</a></h3>";
    var response = try parseSearchHtml(std.heap.ArenaAllocator.init(std.testing.allocator), fixture, "Centigrade");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("https://zoom.lk/post", response.items[0].page_url);

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    try std.testing.expectError(error.UnsafeHttpTarget, scraper.fetchSubtitlesBySearchItem(.{
        .title = "Centigrade",
        .year = 2020,
        .media_kind = .movie,
        .season = null,
        .page_url = "https://zoom.lk.attacker.example/post",
    }));
}

test "zoom download scanner skips malformed first candidates" {
    const url = try parseDownloadUrl(
        std.testing.allocator,
        "https://zoom.lk/sub-download/not-an-id https://zoom.lk/sub-download/01 " ++
            "https://zoom.lk/sub-download/12evil https://zoom.lk/sub-download/42",
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://zoom.lk/sub-download/42", url);
}

test "live zoom movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "zoom.lk")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("Centigrade");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    try std.testing.expectEqualStrings("Centigrade", movie.items[0].title);
    var movie_subs = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subs.deinit();
    const movie_dl = try common.fetchBytes(&client, std.testing.allocator, movie_subs.subtitles[0].download_url, .{
        .accept = "application/octet-stream,application/x-rar-compressed,*/*",
        .cache = false,
        .require_public_origin = true,
        .require_https = true,
    });
    defer std.testing.allocator.free(movie_dl.body);
    try std.testing.expect(movie_dl.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, movie_dl.body, "Rar!"));

    var tv = try scraper.search("Teen Wolf");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    const tv_item = for (tv.items) |item| {
        if (item.media_kind == .tv and item.season != null) break item;
    } else return error.TestUnexpectedResult;
    var tv_subs = try scraper.fetchSubtitlesBySearchItem(tv_item);
    defer tv_subs.deinit();
    const tv_dl = try common.fetchBytes(&client, std.testing.allocator, tv_subs.subtitles[0].download_url, .{
        .accept = "application/octet-stream,application/x-rar-compressed,*/*",
        .cache = false,
        .require_public_origin = true,
        .require_https = true,
    });
    defer std.testing.allocator.free(tv_dl.body);
    try std.testing.expect(tv_dl.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, tv_dl.body, "Rar!"));
}
