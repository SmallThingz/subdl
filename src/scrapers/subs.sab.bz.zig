const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "http://subs.sab.bz";
const search_url = site ++ "/index.php?";
pub const download_token_prefix = "subs-sab-referer:";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    language_code: []const u8,
    attach_id: []const u8,
    page_url: []const u8,
    download_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const SearchLanguage = struct {
    form_code: []const u8,
    language_code: []const u8,
};

const languages = [_]SearchLanguage{
    .{ .form_code = "1", .language_code = "en" },
    .{ .form_code = "2", .language_code = "bg" },
};

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
        const encoded = try common.encodeUriComponent(a, trimmed);

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        for (languages) |language| {
            const payload = try std.fmt.allocPrint(
                a,
                "act=search&movie={s}&select-language={s}&upldr=&yr=&release=",
                .{ encoded, language.form_code },
            );
            const response = try common.fetchBytes(self.client, a, search_url, .{
                .method = .POST,
                .payload = payload,
                .content_type = "application/x-www-form-urlencoded",
                .accept = "text/html,application/xhtml+xml,*/*",
                .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
                .cache = false,
                .max_attempts = 3,
                .require_public_origin = true,
            });
            try appendSearchRows(a, response.body, trimmed, language.language_code, &seen, &exact, &partial);
        }

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        try items.appendSlice(a, exact.items);
        try items.appendSlice(a, partial.items);
        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const slugged = try common.asciiSlug(a, item.title);
        const filename = try std.fmt.allocPrint(a, "subs-sab-{s}-{s}", .{ item.attach_id, slugged });
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = filename,
            .download_url = try makeDownloadToken(a, item.attach_id),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const attach_id = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        const url = try std.fmt.allocPrint(allocator, "{s}/index.php?act=download&attach_id={s}", .{ site, attach_id });
        defer allocator.free(url);
        const response = try common.fetchBytes(self.client, allocator, url, .{
            .accept = "application/octet-stream,application/download,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = search_url }},
            .cache = false,
            .max_attempts = 3,
            .require_public_origin = true,
        });
        if (response.status != .ok) {
            allocator.free(response.body);
            return error.UnexpectedHttpStatus;
        }
        validateArchiveDownloadBody(response.body) catch |err| {
            allocator.free(response.body);
            return err;
        };
        return response;
    }
};

pub fn makeDownloadToken(allocator: Allocator, attach_id: []const u8) ![]u8 {
    if (!isCanonicalAttachId(attach_id)) return error.InvalidDownloadUrl;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ download_token_prefix, attach_id });
}

pub fn parseDownloadToken(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const attach_id = value[download_token_prefix.len..];
    if (!isCanonicalAttachId(attach_id)) return null;
    return attach_id;
}

fn isCanonicalAttachId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

const AnchorTag = struct {
    href: ?[]const u8,
    tag_start: usize,
    content_start: usize,
};

const HtmlTag = struct {
    name: []const u8,
    closing: bool,
};

const HtmlElement = struct {
    tag_start: usize,
    content_start: usize,
    close_start: usize,
    close_end: usize,
};

fn nextAnchorTag(html: []const u8, cursor: *usize) ?AnchorTag {
    while (cursor.* < html.len) {
        const tag_start_rel = std.mem.indexOfScalar(u8, html[cursor.*..], '<') orelse {
            cursor.* = html.len;
            return null;
        };
        const tag_start = cursor.* + tag_start_rel;
        if (std.mem.startsWith(u8, html[tag_start..], "<!--")) {
            const comment_end_rel = std.mem.indexOf(u8, html[tag_start + "<!--".len ..], "-->") orelse {
                cursor.* = html.len;
                return null;
            };
            cursor.* = tag_start + "<!--".len + comment_end_rel + "-->".len;
            continue;
        }

        const tag_end = htmlTagEnd(html, tag_start + 1) orelse {
            cursor.* = html.len;
            return null;
        };
        cursor.* = tag_end + 1;
        const parsed = parseHtmlTag(html, tag_start, tag_end) orelse continue;
        if (!parsed.closing and
            (std.ascii.eqlIgnoreCase(parsed.name, "script") or std.ascii.eqlIgnoreCase(parsed.name, "style")))
        {
            skipRawTextElement(html, cursor, parsed.name);
            continue;
        }
        if (parsed.closing or !std.ascii.eqlIgnoreCase(parsed.name, "a")) continue;

        const tag = html[tag_start .. tag_end + 1];
        return .{
            .href = htmlAttributeValue(tag, "href"),
            .tag_start = tag_start,
            .content_start = tag_end + 1,
        };
    }
    return null;
}

fn parseHtmlTag(html: []const u8, tag_start: usize, tag_end: usize) ?HtmlTag {
    var name_start = tag_start + 1;
    if (name_start >= tag_end) return null;
    const closing = html[name_start] == '/';
    if (closing) name_start += 1;
    if (name_start >= tag_end or std.ascii.isWhitespace(html[name_start])) return null;

    var name_end = name_start;
    while (name_end < tag_end and !std.ascii.isWhitespace(html[name_end]) and
        html[name_end] != '/' and html[name_end] != '>') : (name_end += 1)
    {}
    if (name_end == name_start) return null;
    return .{ .name = html[name_start..name_end], .closing = closing };
}

fn skipRawTextElement(html: []const u8, cursor: *usize, element_name: []const u8) void {
    var search = cursor.*;
    while (search < html.len) {
        const close_start_rel = std.mem.indexOf(u8, html[search..], "</") orelse {
            cursor.* = html.len;
            return;
        };
        const close_start = search + close_start_rel;
        const close_end = htmlTagEnd(html, close_start + 2) orelse {
            cursor.* = html.len;
            return;
        };
        if (parseHtmlTag(html, close_start, close_end)) |parsed| {
            if (parsed.closing and std.ascii.eqlIgnoreCase(parsed.name, element_name)) {
                cursor.* = close_end + 1;
                return;
            }
        }
        search = close_start + 2;
    }
    cursor.* = html.len;
}

fn htmlTagEnd(html: []const u8, start: usize) ?usize {
    var quote: ?u8 = null;
    var index = start;
    while (index < html.len) : (index += 1) {
        if (quote) |active| {
            if (html[index] == active) quote = null;
        } else if (html[index] == '"' or html[index] == '\'') {
            quote = html[index];
        } else if (html[index] == '>') {
            return index;
        }
    }
    return null;
}

fn htmlAttributeValue(tag: []const u8, wanted_name: []const u8) ?[]const u8 {
    var cursor: usize = 1;
    if (cursor < tag.len and tag[cursor] == '/') cursor += 1;
    while (cursor < tag.len and !std.ascii.isWhitespace(tag[cursor]) and
        tag[cursor] != '/' and tag[cursor] != '>') : (cursor += 1)
    {}
    while (cursor < tag.len) {
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] == '>') return null;
        if (tag[cursor] == '/') {
            cursor += 1;
            continue;
        }

        const name_start = cursor;
        while (cursor < tag.len and !std.ascii.isWhitespace(tag[cursor]) and
            tag[cursor] != '=' and tag[cursor] != '/' and tag[cursor] != '>') : (cursor += 1)
        {}
        if (cursor == name_start) {
            cursor += 1;
            continue;
        }
        const name = tag[name_start..cursor];
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] != '=') continue;
        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] == '>') return null;

        const value = if (tag[cursor] == '"' or tag[cursor] == '\'') blk: {
            const quote = tag[cursor];
            const value_start = cursor + 1;
            const value_end_rel = std.mem.indexOfScalar(u8, tag[value_start..], quote) orelse return null;
            const value_end = value_start + value_end_rel;
            cursor = value_end + 1;
            break :blk tag[value_start..value_end];
        } else blk: {
            const value_start = cursor;
            while (cursor < tag.len and !std.ascii.isWhitespace(tag[cursor]) and
                tag[cursor] != '>') : (cursor += 1)
            {}
            break :blk tag[value_start..cursor];
        };
        if (std.ascii.eqlIgnoreCase(name, wanted_name)) return value;
    }
    return null;
}

fn htmlClassHasToken(value: []const u8, wanted: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < value.len) {
        while (cursor < value.len and std.ascii.isWhitespace(value[cursor])) : (cursor += 1) {}
        const start = cursor;
        while (cursor < value.len and !std.ascii.isWhitespace(value[cursor])) : (cursor += 1) {}
        if (start != cursor and std.mem.eql(u8, value[start..cursor], wanted)) return true;
    }
    return false;
}

fn findClosingTagStart(html: []const u8, cursor: *usize, wanted_name: []const u8) ?usize {
    while (cursor.* < html.len) {
        const tag_start_rel = std.mem.indexOfScalar(u8, html[cursor.*..], '<') orelse {
            cursor.* = html.len;
            return null;
        };
        const tag_start = cursor.* + tag_start_rel;
        if (std.mem.startsWith(u8, html[tag_start..], "<!--")) {
            const comment_end_rel = std.mem.indexOf(u8, html[tag_start + "<!--".len ..], "-->") orelse {
                cursor.* = html.len;
                return null;
            };
            cursor.* = tag_start + "<!--".len + comment_end_rel + "-->".len;
            continue;
        }
        const tag_end = htmlTagEnd(html, tag_start + 1) orelse {
            cursor.* = html.len;
            return null;
        };
        cursor.* = tag_end + 1;
        const parsed = parseHtmlTag(html, tag_start, tag_end) orelse continue;
        if (!parsed.closing and
            (std.ascii.eqlIgnoreCase(parsed.name, "script") or std.ascii.eqlIgnoreCase(parsed.name, "style")))
        {
            skipRawTextElement(html, cursor, parsed.name);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(parsed.name, wanted_name)) {
            if (parsed.closing) return tag_start;
            cursor.* = tag_start;
            return null;
        }
    }
    return null;
}

fn findTableCellByClass(html: []const u8, wanted_class: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < html.len) {
        const tag_start_rel = std.mem.indexOfScalar(u8, html[cursor..], '<') orelse return null;
        const tag_start = cursor + tag_start_rel;
        if (std.mem.startsWith(u8, html[tag_start..], "<!--")) {
            const comment_end_rel = std.mem.indexOf(u8, html[tag_start + "<!--".len ..], "-->") orelse return null;
            cursor = tag_start + "<!--".len + comment_end_rel + "-->".len;
            continue;
        }
        const tag_end = htmlTagEnd(html, tag_start + 1) orelse return null;
        cursor = tag_end + 1;
        const parsed = parseHtmlTag(html, tag_start, tag_end) orelse continue;
        if (!parsed.closing and
            (std.ascii.eqlIgnoreCase(parsed.name, "script") or std.ascii.eqlIgnoreCase(parsed.name, "style")))
        {
            skipRawTextElement(html, &cursor, parsed.name);
            continue;
        }
        if (parsed.closing or !std.ascii.eqlIgnoreCase(parsed.name, "td")) continue;

        const class_value = htmlAttributeValue(html[tag_start .. tag_end + 1], "class") orelse continue;
        if (!htmlClassHasToken(class_value, wanted_class)) continue;
        var close_cursor = cursor;
        const close_start = findClosingTagStart(html, &close_cursor, "td") orelse return null;
        return html[cursor..close_start];
    }
    return null;
}

fn nextElementByClass(
    html: []const u8,
    cursor: *usize,
    wanted_name: []const u8,
    wanted_class: []const u8,
) ?HtmlElement {
    while (cursor.* < html.len) {
        const tag_start_rel = std.mem.indexOfScalar(u8, html[cursor.*..], '<') orelse {
            cursor.* = html.len;
            return null;
        };
        const tag_start = cursor.* + tag_start_rel;
        if (std.mem.startsWith(u8, html[tag_start..], "<!--")) {
            const comment_end_rel = std.mem.indexOf(u8, html[tag_start + "<!--".len ..], "-->") orelse {
                cursor.* = html.len;
                return null;
            };
            cursor.* = tag_start + "<!--".len + comment_end_rel + "-->".len;
            continue;
        }

        const tag_end = htmlTagEnd(html, tag_start + 1) orelse {
            cursor.* = html.len;
            return null;
        };
        cursor.* = tag_end + 1;
        const parsed = parseHtmlTag(html, tag_start, tag_end) orelse continue;
        if (!parsed.closing and
            (std.ascii.eqlIgnoreCase(parsed.name, "script") or std.ascii.eqlIgnoreCase(parsed.name, "style")))
        {
            skipRawTextElement(html, cursor, parsed.name);
            continue;
        }
        if (parsed.closing or !std.ascii.eqlIgnoreCase(parsed.name, wanted_name)) continue;

        const class_value = htmlAttributeValue(html[tag_start .. tag_end + 1], "class") orelse continue;
        if (!htmlClassHasToken(class_value, wanted_class)) continue;
        const close_start = findClosingTagStart(html, cursor, wanted_name) orelse continue;
        const close_end = htmlTagEnd(html, close_start + 2) orelse continue;
        cursor.* = close_end + 1;
        return .{
            .tag_start = tag_start,
            .content_start = tag_end + 1,
            .close_start = close_start,
            .close_end = close_end,
        };
    }
    return null;
}

fn attachIdFromDownloadHref(href: []const u8) ?[]const u8 {
    const query = if (std.mem.startsWith(u8, href, site ++ "/index.php?"))
        href[(site ++ "/index.php?").len..]
    else if (std.mem.startsWith(u8, href, "/index.php?"))
        href["/index.php?".len..]
    else if (std.mem.startsWith(u8, href, "index.php?"))
        href["index.php?".len..]
    else if (std.mem.startsWith(u8, href, "?"))
        href[1..]
    else
        return null;

    var attach_id: ?[]const u8 = null;
    var saw_download_action = false;
    var field_start: usize = 0;
    while (field_start <= query.len) {
        const amp_rel = std.mem.indexOfScalar(u8, query[field_start..], '&');
        const field_end = if (amp_rel) |relative| field_start + relative else query.len;
        var field = query[field_start..field_end];
        if (field_start != 0 and std.mem.startsWith(u8, field, "amp;")) field = field["amp;".len..];
        if (std.mem.eql(u8, field, "act=download")) {
            if (saw_download_action) return null;
            saw_download_action = true;
        } else if (std.mem.startsWith(u8, field, "attach_id=")) {
            if (attach_id != null) return null;
            const candidate = field["attach_id=".len..];
            if (!isCanonicalAttachId(candidate)) return null;
            attach_id = candidate;
        } else {
            return null;
        }
        if (field_end == query.len) break;
        field_start = field_end + 1;
    }
    if (!saw_download_action) return null;
    return attach_id;
}

fn validateArchiveDownloadBody(body: []const u8) !void {
    if (body.len >= 4 and (std.mem.eql(u8, body[0..4], "PK\x03\x04") or
        std.mem.eql(u8, body[0..4], "PK\x05\x06") or
        std.mem.eql(u8, body[0..4], "PK\x07\x08"))) return;
    if (body.len >= 7 and std.mem.eql(u8, body[0..7], "Rar!\x1a\x07\x00")) return;
    if (body.len >= 8 and std.mem.eql(u8, body[0..8], "Rar!\x1a\x07\x01\x00")) return;
    return error.UnexpectedResponseType;
}

test "subs sab download tokens reject URL injection" {
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "http://127.0.0.1/private") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "https://user:pass@subs.sab.bz/private") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "https://subs.sab.bz.evil.com/private") == null);
}

test "subs sab token constructor accepts only bounded canonical decimal ids" {
    const valid = try makeDownloadToken(std.testing.allocator, "123");
    defer std.testing.allocator.free(valid);
    try std.testing.expectEqualStrings("123", parseDownloadToken(valid).?);

    for ([_][]const u8{ "", "0", "01", "12x", "1/2", "1\r\n2", "12345678901234567890" }) |invalid| {
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            makeDownloadToken(std.testing.allocator, invalid),
        );
    }
}

fn appendSearchRows(
    allocator: Allocator,
    body: []const u8,
    query: []const u8,
    language_code: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    exact: *std.ArrayListUnmanaged(SearchItem),
    partial: *std.ArrayListUnmanaged(SearchItem),
) !void {
    const Candidate = struct {
        attach_id: []const u8,
        canonical_title: []const u8,
        year: ?i64,
        media_kind: MediaKind,
        is_exact: bool,
    };

    const wanted = try common.normalizeTitle(allocator, query);
    defer allocator.free(wanted);
    if (wanted.len == 0) return;

    var cursor: usize = 0;
    while (nextElementByClass(body, &cursor, "tr", "subs-row")) |row_element| {
        const row = body[row_element.content_start..row_element.close_start];

        const cell = findTableCellByClass(row, "c2field") orelse continue;
        var row_attach_id: ?[]const u8 = null;
        var candidate: ?Candidate = null;
        var conflicting_ids = false;
        var anchor_cursor: usize = 0;
        while (nextAnchorTag(cell, &anchor_cursor)) |anchor| {
            const href = anchor.href orelse continue;
            const attach_id = attachIdFromDownloadHref(href) orelse continue;
            if (row_attach_id) |known_id| {
                if (!std.mem.eql(u8, known_id, attach_id)) {
                    conflicting_ids = true;
                    break;
                }
            } else {
                row_attach_id = attach_id;
            }

            var close_cursor = anchor.content_start;
            const close = findClosingTagStart(cell, &close_cursor, "a") orelse continue;
            const close_end = htmlTagEnd(cell, close + 2) orelse continue;
            const raw_title = std.mem.trim(u8, cell[anchor.content_start..close], " \t\r\n");
            anchor_cursor = close_end + 1;
            if (raw_title.len == 0) continue;

            const year = parseYearAfterAnchor(cell[close_end + 1 ..]);
            const canonical = canonicalTitle(raw_title);
            const normalized = try common.normalizeTitle(allocator, canonical);
            defer allocator.free(normalized);
            if (normalized.len == 0) continue;
            if (!normalizedTitlesRelated(normalized, wanted)) continue;
            const is_exact = std.mem.eql(u8, normalized, wanted);
            if (candidate == null or (!candidate.?.is_exact and is_exact)) {
                candidate = .{
                    .attach_id = attach_id,
                    .canonical_title = canonical,
                    .year = year,
                    .media_kind = if (isTvTitle(raw_title)) .tv else .movie,
                    .is_exact = is_exact,
                };
            }
        }
        if (conflicting_ids) continue;
        const selected = candidate orelse continue;

        if (seen.contains(selected.attach_id)) {
            if (selected.is_exact) _ = try promotePartialByAttachId(allocator, selected.attach_id, exact, partial);
            continue;
        }

        const destination = if (selected.is_exact) exact else partial;
        try destination.ensureUnusedCapacity(allocator, 1);
        try seen.ensureUnusedCapacity(allocator, 1);

        const download_url = try std.fmt.allocPrint(allocator, "{s}/index.php?act=download&attach_id={s}", .{ site, selected.attach_id });
        errdefer allocator.free(download_url);
        const title = try allocator.dupe(u8, selected.canonical_title);
        errdefer allocator.free(title);
        const owned_language_code = try allocator.dupe(u8, language_code);
        errdefer allocator.free(owned_language_code);
        const owned_attach_id = try allocator.dupe(u8, selected.attach_id);
        errdefer allocator.free(owned_attach_id);
        const owned_download_url = try allocator.dupe(u8, download_url);
        errdefer allocator.free(owned_download_url);
        const item: SearchItem = .{
            .title = title,
            .year = selected.year,
            .media_kind = selected.media_kind,
            .language_code = owned_language_code,
            .attach_id = owned_attach_id,
            .page_url = download_url,
            .download_url = owned_download_url,
        };

        seen.putAssumeCapacityNoClobber(owned_attach_id, {});
        destination.appendAssumeCapacity(item);
    }
}

fn promotePartialByAttachId(
    allocator: Allocator,
    attach_id: []const u8,
    exact: *std.ArrayListUnmanaged(SearchItem),
    partial: *std.ArrayListUnmanaged(SearchItem),
) !bool {
    for (partial.items, 0..) |item, index| {
        if (!std.mem.eql(u8, item.attach_id, attach_id)) continue;
        try exact.ensureUnusedCapacity(allocator, 1);
        const promoted = partial.orderedRemove(index);
        exact.appendAssumeCapacity(promoted);
        return true;
    }
    return false;
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

fn parseYearAfterAnchor(value: []const u8) ?i64 {
    const open = std.mem.indexOfScalar(u8, value, '(') orelse return null;
    if (open + 5 > value.len) return null;
    const digits = value[open + 1 .. open + 5];
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    if (open + 5 >= value.len or value[open + 5] != ')') return null;
    return std.fmt.parseInt(i64, digits, 10) catch null;
}

fn canonicalTitle(raw: []const u8) []const u8 {
    const patterns = [_][]const u8{
        " - Season ",
        " - season ",
    };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, raw, pattern)) |idx| return std.mem.trimEnd(u8, raw[0..idx], " \t");
    }

    var i: usize = 0;
    while (i + 6 <= raw.len) : (i += 1) {
        if (raw[i] != ' ' or raw[i + 1] != '-') continue;
        var p = i + 2;
        while (p < raw.len and raw[p] == ' ') : (p += 1) {}
        if (p + 4 >= raw.len) continue;
        if (std.ascii.isDigit(raw[p]) and std.ascii.isDigit(raw[p + 1]) and raw[p + 2] == 'x' and
            std.ascii.isDigit(raw[p + 3]) and std.ascii.isDigit(raw[p + 4]))
        {
            return std.mem.trimEnd(u8, raw[0..i], " \t");
        }
    }
    return std.mem.trim(u8, raw, " \t\r\n");
}

fn isTvTitle(raw: []const u8) bool {
    if (std.ascii.findIgnoreCase(raw, " - Season ") != null) return true;
    var i: usize = 0;
    while (i + 5 <= raw.len) : (i += 1) {
        if (std.ascii.isDigit(raw[i]) and std.ascii.isDigit(raw[i + 1]) and raw[i + 2] == 'x' and
            std.ascii.isDigit(raw[i + 3]) and std.ascii.isDigit(raw[i + 4]))
        {
            return true;
        }
    }
    return false;
}

test "subs sab parses movie and tv rows" {
    const allocator = std.testing.allocator;
    const fixture =
        "<tr class=\"subs-row\"><td class=\"c2field\"><a href=\"http://subs.sab.bz/index.php?act=download&attach_id=52867\">The Matrix</a> (1999)</td><td>English</td></tr>" ++
        "<tr class=\"subs-row\"><td class=\"c2field\"><a href=\"http://subs.sab.bz/index.php?act=download&attach_id=101693\">Reacher - Season 1</a> (2022)</td><td>English</td></tr>";
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    defer {
        for (exact.items) |item| {
            allocator.free(item.title);
            allocator.free(item.language_code);
            allocator.free(item.attach_id);
            allocator.free(item.page_url);
            allocator.free(item.download_url);
        }
        exact.deinit(allocator);
    }
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    defer {
        for (partial.items) |item| {
            allocator.free(item.title);
            allocator.free(item.language_code);
            allocator.free(item.attach_id);
            allocator.free(item.page_url);
            allocator.free(item.download_url);
        }
        partial.deinit(allocator);
    }

    try appendSearchRows(allocator, fixture, "Reacher", "en", &seen, &exact, &partial);
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqualStrings("Reacher", exact.items[0].title);
    try std.testing.expectEqual(MediaKind.tv, exact.items[0].media_kind);
    try std.testing.expectEqual(@as(?i64, 2022), exact.items[0].year);
}

test "subs sab malformed duplicate does not suppress a valid row" {
    const allocator = std.testing.allocator;
    const fixture =
        "<tr class=\"subs-row\"><td><a href=\"/index.php?act=download&attach_id=7\">missing title cell</a></td></tr>" ++
        "<tr class=\"subs-row\"><td class=\"c2field\">attach_id=91" ++
        "<!-- <a href=\"/index.php?act=download&attach_id=92\">comment decoy</a> -->" ++
        "<a href=\"/index.php?act=download&fooattach_id=95\">bad field boundary</a>" ++
        "<a data-href=\"/index.php?act=download&attach_id=93\" href=\"/index.php?act=download&attach_id=12evil\">bad</a>" ++
        "<a title=\"attach_id=94\" href=\"/index.php?act=download&amp;attach_id=7\">The Matrix</a> (1999)</td></tr>" ++
        "<tr class=\"subs-row\"><td class=\"c2field\"><a href=\"/index.php?act=download&attach_id=7\">The Matrix</a> (1999)</td></tr>";
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    defer {
        for (exact.items) |item| {
            allocator.free(item.title);
            allocator.free(item.language_code);
            allocator.free(item.attach_id);
            allocator.free(item.page_url);
            allocator.free(item.download_url);
        }
        exact.deinit(allocator);
    }
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    defer {
        for (partial.items) |item| {
            allocator.free(item.title);
            allocator.free(item.language_code);
            allocator.free(item.attach_id);
            allocator.free(item.page_url);
            allocator.free(item.download_url);
        }
        partial.deinit(allocator);
    }

    try appendSearchRows(allocator, fixture, "The Matrix", "en", &seen, &exact, &partial);

    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqualStrings("7", exact.items[0].attach_id);
}

test "subs sab scans only real anchors inside the c2 cell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture =
        "<SCRIPT>const row = '<TR class=\"subs-row\"><TD class=\"c2field\"><A href=\"/index.php?act=download&amp;attach_id=6\">The Matrix</A></TD></TR>';</SCRIPT>" ++
        "<!-- <TR class=\"subs-row\"><TD class=\"c2field\"><A href=\"/index.php?act=download&amp;attach_id=5\">The Matrix</A></TD></TR> -->" ++
        "<TR data-note='</TR><TR class=\"subs-row\">' CLASS=\"subs-row\"><TD CLASS=\"lead c2field tail\" data-note='<a href=\"/index.php?act=download&amp;attach_id=7\">The Matrix</a>'>" ++
        "<script>const sample = '<a href=\"/index.php?act=download&amp;attach_id=71\">The Matrix</a>'; const close = '</A></TR>';</script>" ++
        "<STYLE>.sample::after { content: '<a href=\"/index.php?act=download&amp;attach_id=72\">The Matrix</a>'; }</STYLE>" ++
        "<A data-note='</A>' HREF=\"/index.php?act=download&amp;attach_id=8\">The Matrix</A> (1999)</TD>" ++
        "<TD><A href=\"/index.php?act=download&amp;attach_id=9\">The Matrix</A></TD></TR>" ++
        "<tr class=\"subs-row\"><td class=\"c2field\">No download here</td>" ++
        "<td><a href=\"/index.php?act=download&amp;attach_id=10\">The Matrix</a></td></tr>";
    var seen = std.StringHashMapUnmanaged(void).empty;
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    try appendSearchRows(allocator, fixture, "The Matrix", "bg", &seen, &exact, &partial);

    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqual(@as(usize, 0), partial.items.len);
    try std.testing.expectEqualStrings("8", exact.items[0].attach_id);
}

test "subs sab leaves unterminated raw text closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture =
        "<TR class=\"subs-row\"><TD class=\"c2field\"><SCRIPT>const row = '" ++
        "<TR class=\"subs-row\"><TD class=\"c2field\"><A href=\"/index.php?act=download&amp;attach_id=7\">" ++
        "The Matrix</A></TD></TR>';</TD></TR>";
    var seen = std.StringHashMapUnmanaged(void).empty;
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    try appendSearchRows(allocator, fixture, "The Matrix", "en", &seen, &exact, &partial);

    try std.testing.expectEqual(@as(usize, 0), exact.items.len);
    try std.testing.expectEqual(@as(usize, 0), partial.items.len);
}

test "subs sab rejects conflicting row ids but permits a repeated id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture =
        "<tr class=\"subs-row\"><td class=\"c2field\">" ++
        "<a href=\"/index.php?act=download&amp;attach_id=20\">broken" ++
        "<a href=\"/index.php?act=download&amp;attach_id=21\">The Matrix</a></td></tr>" ++
        "<tr class=\"subs-row\"><td class=\"c2field\">" ++
        "<a href=\"/index.php?act=download&amp;attach_id=22\">The Matrix</a>" ++
        "<a href=\"/index.php?attach_id=22&amp;act=download\">The Matrix</a> (1999)</td></tr>";
    var seen = std.StringHashMapUnmanaged(void).empty;
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    try appendSearchRows(allocator, fixture, "The Matrix", "en", &seen, &exact, &partial);

    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqualStrings("22", exact.items[0].attach_id);
    try std.testing.expect(attachIdFromDownloadHref("/index.php?act=download&attach_id=7&attach_id=8") == null);
    try std.testing.expect(attachIdFromDownloadHref("/index.php?act=download&act=download&attach_id=7") == null);
    try std.testing.expect(attachIdFromDownloadHref("/index.php?act=download&attach_id=7#suffix") == null);
}

test "subs sab promotes a later exact duplicate without disturbing order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture =
        "<tr class=\"subs-row\"><td class=\"c2field\"><a href=\"?act=download&amp;attach_id=9\">Reacher Legacy</a></td></tr>" ++
        "<tr class=\"subs-row\"><td class=\"c2field\"><a href=\"?act=download&amp;attach_id=7\">Jack Reacher</a></td></tr>" ++
        "<tr class=\"subs-row\"><td class=\"c2field\"><a href=\"?act=download&amp;attach_id=8\">Reacher</a></td></tr>" ++
        "<tr class=\"subs-row\"><td class=\"c2field\"><a href=\"?act=download&amp;attach_id=7\">Reacher</a></td></tr>";
    var seen = std.StringHashMapUnmanaged(void).empty;
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    try appendSearchRows(allocator, fixture, "Reacher", "en", &seen, &exact, &partial);

    try std.testing.expectEqual(@as(usize, 2), exact.items.len);
    try std.testing.expectEqualStrings("8", exact.items[0].attach_id);
    try std.testing.expectEqualStrings("7", exact.items[1].attach_id);
    try std.testing.expectEqual(@as(usize, 1), partial.items.len);
    try std.testing.expectEqualStrings("9", partial.items[0].attach_id);
}

test "subs sab relevance and archive validation reject ambiguous input" {
    try std.testing.expect(normalizedTitlesRelated("jack reacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("preacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("reacher", ""));
    try validateArchiveDownloadBody("PK\x03\x04payload");
    try validateArchiveDownloadBody("Rar!\x1a\x07\x01\x00payload");
    try std.testing.expectError(error.UnexpectedResponseType, validateArchiveDownloadBody("<html>blocked</html>"));
    try std.testing.expectError(error.UnexpectedResponseType, validateArchiveDownloadBody("Rar!"));
}

test "live subs sab movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subs.sab.bz")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie.items[0]);
    defer movie_subtitles.deinit();
    const movie_download = try scraper.fetchDownloadByToken(std.testing.allocator, movie_subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 8);
    try std.testing.expect(std.mem.startsWith(u8, movie_download.body, "Rar!") or std.mem.startsWith(u8, movie_download.body, "PK"));

    var tv = try scraper.search("Reacher");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    try std.testing.expect(tv.items[0].media_kind == .tv);
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv.items[0]);
    defer tv_subtitles.deinit();
    const tv_download = try scraper.fetchDownloadByToken(std.testing.allocator, tv_subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK") or std.mem.startsWith(u8, tv_download.body, "Rar!"));
}
