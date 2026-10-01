const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://rest.opensubtitles.com";

pub const SearchItem = struct {
    title: []const u8,
    year: ?[]const u8,
    item_type: ?[]const u8,
    path: []const u8,
    subtitles_count: ?i64,
    subtitles_list_url: []const u8,
};

pub const SubtitleItem = struct {
    language: ?[]const u8,
    filename: ?[]const u8,
    row_summary: ?[]const u8,
    remote_endpoint: []const u8,
    resolved_filename: ?[]const u8,
    verified_download_url: ?[]const u8,
};

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.SubtitlesResponse(SubtitleItem);

pub const Scraper = struct {
    pub const Options = struct {
        language_code: []const u8 = "en",
    };

    pub const FetchSubtitlesOptions = struct {
        resolve_downloads: bool = false,
        resolve_limit: usize = 8,
    };

    allocator: Allocator,
    client: *std.http.Client,
    options: Options,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client, .options = .{} };
    }

    pub fn initWithOptions(allocator: Allocator, client: *std.http.Client, options: Options) Scraper {
        return .{ .allocator = allocator, .client = client, .options = options };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const encoded = try common.encodeUriComponent(a, query);
        const language = self.options.language_code;
        const url = try std.fmt.allocPrint(a, "{s}/{s}/{s}/search/autocomplete/{s}.json", .{ site, language, language, encoded });

        const body = try fetchPublic(self.client, a, url, .{ .accept = "application/json" });
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const arr = switch (root) {
            .array => |arr| arr,
            else => return error.InvalidFieldType,
        };

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (arr.items) |entry| {
            const obj = switch (entry) {
                .object => |o| o,
                else => continue,
            };

            const title = if (obj.get("title")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;
            const path = if (obj.get("path")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;
            const year = if (obj.get("year")) |v| switch (v) {
                .string => |s| s,
                .number_string => |s| s,
                .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
                else => null,
            } else null;
            const item_type = if (obj.get("type")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null;
            const subtitles_count = if (obj.get("subtitles_count")) |v| switch (v) {
                .integer => |i| i,
                .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => null,
            } else null;

            var replaced = std.ArrayList(u8).empty;
            defer replaced.deinit(a);
            const current_locale = "current_locale";
            var cursor: usize = 0;
            while (std.mem.indexOfPos(u8, path, cursor, current_locale)) |idx| {
                try replaced.appendSlice(a, path[cursor..idx]);
                try replaced.appendSlice(a, language);
                cursor = idx + current_locale.len;
            }
            try replaced.appendSlice(a, path[cursor..]);
            const locale_path = replaced.items;
            const subtitles_list_url = try makeSubtitlesListUrl(a, locale_path);

            try out.append(a, .{
                .title = title,
                .year = year,
                .item_type = item_type,
                .path = path,
                .subtitles_count = subtitles_count,
                .subtitles_list_url = subtitles_list_url,
            });
        }

        return .{ .arena = arena, .items = try out.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemWithOptions(item, .{});
    }

    pub fn fetchSubtitlesBySearchItemWithOptions(self: *Scraper, item: SearchItem, options: FetchSubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const list_body = try fetchPublic(self.client, a, item.subtitles_list_url, .{ .accept = "application/json" });
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, list_body, .{});
        const obj = switch (root) {
            .object => |o| o,
            else => return error.InvalidFieldType,
        };
        const data = obj.get("data") orelse return error.MissingField;
        const rows = switch (data) {
            .array => |arr| arr,
            else => return error.InvalidFieldType,
        };

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var resolved_count: usize = 0;
        for (rows.items) |row| {
            const cols = switch (row) {
                .array => |arr| arr,
                else => continue,
            };
            if (cols.items.len == 0) continue;

            const language = parseLanguageFromCell(a, cols.items, 1) catch null;
            const filename = parseFilenameFromCell(a, cols.items, 2) catch null;
            const row_summary = summarizeRow(a, cols.items) catch null;
            const remote = parseRemoteEndpoint(a, cols.items) catch continue;

            const should_resolve = options.resolve_downloads and
                (options.resolve_limit == 0 or resolved_count < options.resolve_limit);
            const resolved: ResolvedDownload = if (should_resolve)
                self.resolveAndVerifyDownloadPublic(a, remote) catch |err| switch (err) {
                    error.UnexpectedHttpStatus => .{ .filename = null, .verified_url = null },
                    else => return err,
                }
            else
                .{ .filename = null, .verified_url = null };
            if (should_resolve) resolved_count += 1;

            try subtitles.append(a, .{
                .language = language,
                .filename = filename,
                .row_summary = row_summary,
                .remote_endpoint = remote,
                .resolved_filename = resolved.filename,
                .verified_download_url = resolved.verified_url,
            });
        }

        return .{ .arena = arena, .subtitles = try subtitles.toOwnedSlice(a) };
    }

    const ResolvedDownload = struct {
        filename: ?[]const u8,
        verified_url: ?[]const u8,
    };

    pub fn resolveVerifiedDownloadUrl(self: *Scraper, allocator: Allocator, remote_endpoint: []const u8) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const resolved = try self.resolveAndVerifyDownloadPublic(a, remote_endpoint);
        if (resolved.verified_url) |url| {
            return try allocator.dupe(u8, url);
        }
        return null;
    }

    fn resolveAndVerifyDownloadPublic(self: *Scraper, allocator: Allocator, remote_endpoint: []const u8) !ResolvedDownload {
        const remote_url = if (std.mem.startsWith(u8, remote_endpoint, "http"))
            remote_endpoint
        else
            try common.resolveUrl(allocator, site, remote_endpoint);

        const headers = [_]std.http.Header{
            .{ .name = "referer", .value = site ++ "/" },
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
            .{ .name = "accept", .value = "*/*" },
        };

        const body = try fetchPublic(self.client, allocator, remote_url, .{
            .accept = "*/*",
            .extra_headers = &headers,
        });

        const parsed = parseFileDownload(body);
        if (parsed.url == null) return .{ .filename = null, .verified_url = null };

        const url = parsed.url orelse return .{ .filename = parsed.filename, .verified_url = null };
        return .{ .filename = parsed.filename, .verified_url = url };
    }
};

const SessionFetchOptions = struct {
    accept: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    allow_non_ok: bool = false,
};

fn fetchPublic(client: *std.http.Client, allocator: Allocator, url: []const u8, options: SessionFetchOptions) ![]u8 {
    const response = try common.fetchBytes(client, allocator, url, .{
        .accept = options.accept,
        .extra_headers = options.extra_headers,
        .allow_non_ok = true,
        .max_attempts = 2,
    });

    if (!options.allow_non_ok and response.status != .ok) {
        allocator.free(response.body);
        return error.UnexpectedHttpStatus;
    }

    return response.body;
}

fn parseLanguageFromCell(allocator: Allocator, cols: []const std.json.Value, idx: usize) !?[]const u8 {
    if (idx >= cols.len) return null;
    const fragment = switch (cols[idx]) {
        .string => |s| s,
        else => return null,
    };
    if (try firstHtmlAttribute(allocator, fragment, "title")) |title| return title;
    return @as(?[]const u8, try htmlFragmentText(allocator, fragment));
}

fn parseFilenameFromCell(allocator: Allocator, cols: []const std.json.Value, idx: usize) !?[]const u8 {
    if (idx >= cols.len) return null;
    const fragment = switch (cols[idx]) {
        .string => |s| s,
        else => return null,
    };
    const txt = try htmlFragmentText(allocator, fragment);
    if (txt.len == 0) return null;
    return txt;
}

fn summarizeRow(allocator: Allocator, cols: []const std.json.Value) !?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (cols, 0..) |col, i| {
        const fragment = switch (col) {
            .string => |s| s,
            else => continue,
        };
        const txt = try htmlFragmentText(allocator, fragment);
        if (txt.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(allocator, " | ");
        try out.appendSlice(allocator, txt);
        if (i >= 6 and out.items.len > 240) break;
    }

    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn parseRemoteEndpoint(allocator: Allocator, cols: []const std.json.Value) ![]const u8 {
    const idx = cols.len - 1;
    const fragment = switch (cols[idx]) {
        .string => |s| s,
        else => return error.MissingField,
    };
    const remote_marker = "data-remote=\"true\"";
    const marker = std.mem.indexOf(u8, fragment, remote_marker) orelse return error.MissingField;
    const tag_start = std.mem.lastIndexOfScalar(u8, fragment[0..marker], '<') orelse return error.MissingField;
    const tag_end_rel = std.mem.indexOfScalar(u8, fragment[marker..], '>') orelse return error.MissingField;
    const tag_end = marker + tag_end_rel + 1;
    const href = (try htmlAttribute(allocator, fragment[tag_start..tag_end], "href")) orelse return error.MissingField;
    defer allocator.free(href);
    return try common.resolveUrl(allocator, site, href);
}

fn firstHtmlAttribute(allocator: Allocator, fragment: []const u8, name: []const u8) !?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, fragment, pos, '<')) |start| {
        const end = std.mem.indexOfScalarPos(u8, fragment, start, '>') orelse return null;
        if (try htmlAttribute(allocator, fragment[start .. end + 1], name)) |value| return value;
        pos = end + 1;
    }
    return null;
}

fn htmlAttribute(allocator: Allocator, tag: []const u8, name: []const u8) !?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, pos, name)) |idx| {
        if (idx > 0 and (std.ascii.isAlphanumeric(tag[idx - 1]) or tag[idx - 1] == '-' or tag[idx - 1] == '_')) {
            pos = idx + name.len;
            continue;
        }
        var cursor = idx + name.len;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] != '=') {
            pos = idx + name.len;
            continue;
        }
        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len) return null;
        const quote = tag[cursor];
        if (quote != '"' and quote != '\'') return null;
        cursor += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, cursor, quote) orelse return null;
        return @as(?[]const u8, try decodeBasicHtmlEntities(allocator, tag[cursor..end]));
    }
    return null;
}

fn htmlFragmentText(allocator: Allocator, fragment: []const u8) ![]const u8 {
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    errdefer raw.deinit(allocator);
    var in_tag = false;
    var pending_space = false;
    for (fragment) |c| {
        if (c == '<') {
            in_tag = true;
            pending_space = raw.items.len > 0;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;
        if (std.ascii.isWhitespace(c)) {
            pending_space = raw.items.len > 0;
            continue;
        }
        if (pending_space and raw.items.len > 0 and raw.items[raw.items.len - 1] != ' ') try raw.append(allocator, ' ');
        pending_space = false;
        try raw.append(allocator, c);
    }
    const decoded = try decodeBasicHtmlEntities(allocator, raw.items);
    raw.deinit(allocator);
    return decoded;
}

fn decodeBasicHtmlEntities(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            const replacements = [_]struct { encoded: []const u8, decoded: []const u8 }{
                .{ .encoded = "&amp;", .decoded = "&" },
                .{ .encoded = "&quot;", .decoded = "\"" },
                .{ .encoded = "&#39;", .decoded = "'" },
                .{ .encoded = "&apos;", .decoded = "'" },
                .{ .encoded = "&lt;", .decoded = "<" },
                .{ .encoded = "&gt;", .decoded = ">" },
                .{ .encoded = "&nbsp;", .decoded = " " },
            };
            var matched = false;
            for (replacements) |replacement| {
                if (!std.mem.startsWith(u8, input[i..], replacement.encoded)) continue;
                try out.appendSlice(allocator, replacement.decoded);
                i += replacement.encoded.len;
                matched = true;
                break;
            }
            if (matched) continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

const FileDownload = struct {
    filename: ?[]const u8,
    url: ?[]const u8,
};

fn parseFileDownload(body: []const u8) FileDownload {
    const marker = "file_download('";
    const start = std.mem.indexOf(u8, body, marker) orelse return .{ .filename = null, .url = null };
    const after = body[start + marker.len ..];

    const quote1 = std.mem.indexOfScalar(u8, after, '\'') orelse return .{ .filename = null, .url = null };
    const filename = after[0..quote1];

    const comma_marker = "','";
    const comma_idx = std.mem.indexOfPos(u8, after, quote1, comma_marker) orelse return .{ .filename = filename, .url = null };
    const url_start = comma_idx + comma_marker.len;
    const tail = after[url_start..];
    const url_end = std.mem.indexOfScalar(u8, tail, '\'') orelse return .{ .filename = filename, .url = null };
    const url = tail[0..url_end];

    return .{ .filename = filename, .url = url };
}

fn replaceMoviesWithFeatures(allocator: Allocator, input: []const u8) ![]const u8 {
    const needle = "/movies/";
    const idx = std.mem.indexOf(u8, input, needle) orelse return try allocator.dupe(u8, input);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, input[0..idx]);
    try out.appendSlice(allocator, "/features/");
    try out.appendSlice(allocator, input[idx + needle.len ..]);
    return try out.toOwnedSlice(allocator);
}

fn makeSubtitlesListUrl(allocator: Allocator, locale_path: []const u8) ![]const u8 {
    const feature_path = try replaceMoviesWithFeatures(allocator, locale_path);
    defer allocator.free(feature_path);
    return std.fmt.allocPrint(allocator, "{s}{s}/subtitles_list.json", .{ site, feature_path });
}

test "parse opensubtitles.com file_download" {
    const parsed = parseFileDownload("x file_download('name.zip','https://a/b.zip') y");
    try std.testing.expectEqualStrings("name.zip", parsed.filename.?);
    try std.testing.expectEqualStrings("https://a/b.zip", parsed.url.?);
}

test "opensubtitles.com public listing url has one host separator" {
    const allocator = std.testing.allocator;
    const url = try makeSubtitlesListUrl(allocator, "/en/movies/1999-the-matrix");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://rest.opensubtitles.com/en/features/1999-the-matrix/subtitles_list.json",
        url,
    );
}

test "opensubtitles.com parses listing cells without reparsing html documents" {
    const allocator = std.testing.allocator;
    const cols = [_]std.json.Value{
        .{ .string = "en" },
        .{ .string = "<a title=\"English\" href=\"/x\"><i class=\"flag en\"></i></a>" },
        .{ .string = "<a href=\"/x\">The Matrix &amp; Extras</a><div><strong>HD</strong></div>" },
        .{ .string = "2026-01-01" },
        .{ .string = "user" },
        .{ .string = "23.976" },
        .{ .string = "100%" },
        .{ .string = "1" },
        .{ .string = "42" },
        .{ .string = "<a data-remote=\"true\" href=\"/nocache/download/1/subreq.js?direct_dl=true&amp;locale=en\">Direct</a>" },
    };
    const language = (try parseLanguageFromCell(allocator, &cols, 1)).?;
    defer allocator.free(language);
    try std.testing.expectEqualStrings("English", language);
    const filename = (try parseFilenameFromCell(allocator, &cols, 2)).?;
    defer allocator.free(filename);
    try std.testing.expectEqualStrings("The Matrix & Extras HD", filename);
    const remote = try parseRemoteEndpoint(allocator, &cols);
    defer allocator.free(remote);
    try std.testing.expectEqualStrings("https://rest.opensubtitles.com/nocache/download/1/subreq.js?direct_dl=true&locale=en", remote);
}

test "live opensubtitles.com search and resolve" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "OPENSUBTITLES_COM")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    const item = search.items[0];
    std.debug.print("[live][opensubtitles.com][search][0]\n", .{});
    try common.livePrintField(std.testing.allocator, "title", item.title);
    try common.livePrintOptionalField(std.testing.allocator, "year", item.year);
    try common.livePrintOptionalField(std.testing.allocator, "item_type", item.item_type);
    try common.livePrintField(std.testing.allocator, "path", item.path);
    if (item.subtitles_count) |count| {
        std.debug.print("[live] subtitles_count={d}\n", .{count});
    } else {
        std.debug.print("[live] subtitles_count=<null>\n", .{});
    }
    try common.livePrintField(std.testing.allocator, "subtitles_list_url", item.subtitles_list_url);

    var subtitles = try scraper.fetchSubtitlesBySearchItemWithOptions(item, .{
        .resolve_downloads = false,
    });
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    const sub = subtitles.subtitles[0];
    std.debug.print("[live][opensubtitles.com][subtitle][0]\n", .{});
    try common.livePrintOptionalField(std.testing.allocator, "language", sub.language);
    try common.livePrintOptionalField(std.testing.allocator, "filename", sub.filename);
    try common.livePrintOptionalField(std.testing.allocator, "row_summary", sub.row_summary);
    try common.livePrintField(std.testing.allocator, "remote_endpoint", sub.remote_endpoint);
    try common.livePrintOptionalField(std.testing.allocator, "resolved_filename", sub.resolved_filename);
    try common.livePrintOptionalField(std.testing.allocator, "verified_download_url", sub.verified_download_url);
}
