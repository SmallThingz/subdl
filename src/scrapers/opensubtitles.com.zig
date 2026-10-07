const std = @import("std");
const common = @import("common.zig");
const cf = @import("opensubtitles_com_cf.zig");

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
        return self.searchUsing(common.fetchBytes, query);
    }

    fn searchUsing(self: *Scraper, comptime fetch: anytype, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const language = try encodeLanguagePathSegment(a, self.options.language_code);
        const url = try std.fmt.allocPrint(a, "{s}/{s}/{s}/search/autocomplete/{s}.json", .{ site, language, language, encoded });

        const body = try fetchPublicUsing(fetch, self.client, a, url, .{ .accept = "application/json" });
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
                .float => |f| common.jsonInt(.{ .float = f }),
                else => null,
            } else null;

            const locale_path = try localizeFeaturePath(a, path, language);
            const subtitles_list_url = makeSubtitlesListUrl(a, locale_path) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };

            try out.append(a, .{
                .title = title,
                .year = year,
                .item_type = item_type,
                .path = path,
                .subtitles_count = subtitles_count,
                .subtitles_list_url = subtitles_list_url,
            });
        }

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try out.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemWithOptions(item, .{});
    }

    pub fn fetchSubtitlesBySearchItemWithOptions(self: *Scraper, item: SearchItem, options: FetchSubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderRoute(item.subtitles_list_url, .feature_listing);
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

            const language = try parseLanguageFromCell(a, cols.items, 1);
            const filename = try parseFilenameFromCell(a, cols.items, 2);
            const row_summary = try summarizeRow(a, cols.items);
            const remote = (try parseOptionalRemoteEndpoint(a, cols.items)) orelse continue;

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

        return common.finishResponse(SubtitlesResponse, &arena, .{ .arena = arena, .subtitles = try subtitles.toOwnedSlice(a) });
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
        const remote_url = if (std.mem.startsWith(u8, remote_endpoint, "http://") or
            std.mem.startsWith(u8, remote_endpoint, "https://"))
            remote_endpoint
        else
            try common.resolveUrl(allocator, site, remote_endpoint);
        try validateProviderRoute(remote_url, .remote_download);

        const headers = [_]std.http.Header{
            .{ .name = "referer", .value = site ++ "/" },
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
            .{ .name = "accept", .value = "*/*" },
        };

        const body = try fetchPublic(self.client, allocator, remote_url, .{
            .accept = "*/*",
            .extra_headers = &headers,
        });

        const parsed = (try findPublicFileDownload(allocator, body)) orelse
            return .{ .filename = null, .verified_url = null };
        return .{ .filename = parsed.filename, .verified_url = parsed.url };
    }
};

const SessionFetchOptions = struct {
    accept: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
};

fn fetchPublic(client: *std.http.Client, allocator: Allocator, url: []const u8, options: SessionFetchOptions) ![]u8 {
    return fetchPublicUsing(common.fetchBytes, client, allocator, url, options);
}

fn fetchPublicUsing(comptime fetch: anytype, client: *std.http.Client, allocator: Allocator, url: []const u8, options: SessionFetchOptions) ![]u8 {
    const response = try fetch(client, allocator, url, .{
        .accept = options.accept,
        .extra_headers = options.extra_headers,
        .allow_non_ok = true,
        .max_attempts = 2,
        .retry_on_429 = false,
        .cache = false,
        .require_public_origin = true,
    });

    if (response.status == .too_many_requests) {
        allocator.free(response.body);
        return error.RateLimited;
    }
    if (cf.isChallengeBody(response.body)) {
        allocator.free(response.body);
        return error.CloudflareChallenge;
    }
    if (response.status == .forbidden) {
        allocator.free(response.body);
        return error.ProviderAccessBlocked;
    }
    if (response.status != .ok) {
        allocator.free(response.body);
        return error.UnexpectedHttpStatus;
    }

    return response.body;
}

fn validateProviderEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

const ProviderRoute = enum { feature_listing, remote_download };

fn validateProviderRoute(url: []const u8, route: ProviderRoute) !void {
    try validateProviderEndpoint(url);
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };

    switch (route) {
        .feature_listing => {
            if (uri.query != null) return error.UnsafeHttpTarget;
            const parts = parseFeatureListingPath(path) orelse return error.UnsafeHttpTarget;
            _ = parts;
        },
        .remote_download => {
            const subtitle_id = remoteDownloadId(path) orelse return error.UnsafeHttpTarget;
            _ = subtitle_id;
            const query_component = uri.query orelse return error.UnsafeHttpTarget;
            const query = switch (query_component) {
                .raw, .percent_encoded => |value| value,
            };
            if (!validateRemoteDownloadQuery(query)) return error.UnsafeHttpTarget;
        },
    }
}

fn validateRemoteDownloadQuery(query: []const u8) bool {
    var direct_download_seen = false;
    var filename_seen = false;
    var locale_seen = false;
    var no_prompt_seen = false;
    var format_seen = false;
    var subtitle_id_seen = false;
    var field_count: usize = 0;

    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        if (field.len == 0) return false;
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return false;
        if (std.mem.indexOfScalar(u8, field[equals + 1 ..], '=') != null) return false;
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        field_count += 1;

        if (std.mem.eql(u8, key, "direct_dl") and !direct_download_seen and std.mem.eql(u8, value, "true")) {
            direct_download_seen = true;
        } else if (std.mem.eql(u8, key, "file_name") and !filename_seen and isSafeRemoteFilenameQueryValue(value)) {
            filename_seen = true;
        } else if (std.mem.eql(u8, key, "locale") and !locale_seen and isSafeLocaleSegment(value)) {
            locale_seen = true;
        } else if (std.mem.eql(u8, key, "np") and !no_prompt_seen and std.mem.eql(u8, value, "true")) {
            no_prompt_seen = true;
        } else if (std.mem.eql(u8, key, "sub_frmt") and !format_seen and std.mem.eql(u8, value, "srt")) {
            format_seen = true;
        } else if (std.mem.eql(u8, key, "subtitle_id") and !subtitle_id_seen and isPositiveDecimal(value)) {
            subtitle_id_seen = true;
        } else {
            return false;
        }
    }

    return field_count == 6 and direct_download_seen and filename_seen and locale_seen and
        no_prompt_seen and format_seen and subtitle_id_seen;
}

fn isSafeRemoteFilenameQueryValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 4096) return false;
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~' or byte == '+') {
            index += 1;
            continue;
        }
        if (byte != '%' or value.len - index < 3 or
            !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return false;
        index += 3;
    }
    return true;
}

const FeatureListingPath = struct {
    locale: []const u8,
    feature: []const u8,
};

fn parseFeatureListingPath(path: []const u8) ?FeatureListingPath {
    if (path.len == 0 or path[0] != '/') return null;
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    const locale = segments.next() orelse return null;
    if (!isSafeLocaleSegment(locale)) return null;
    if (!std.mem.eql(u8, segments.next() orelse return null, "features")) return null;
    const feature = segments.next() orelse return null;
    if (!isSafeFeatureSegment(feature)) return null;
    if (!std.mem.eql(u8, segments.next() orelse return null, "subtitles_list.json")) return null;
    if (segments.next() != null) return null;
    return .{ .locale = locale, .feature = feature };
}

fn remoteDownloadId(path: []const u8) ?[]const u8 {
    const prefix = "/nocache/download/";
    const suffix = "/subreq.js";
    if (!std.mem.startsWith(u8, path, prefix) or
        !std.mem.endsWith(u8, path, suffix) or
        path.len <= prefix.len + suffix.len) return null;
    const subtitle_id = path[prefix.len .. path.len - suffix.len];
    if (!isPositiveDecimal(subtitle_id)) return null;
    return subtitle_id;
}

fn isPositiveDecimal(value: []const u8) bool {
    if (value.len == 0 or value[0] == '0') return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isSafeLocaleSegment(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }
    return true;
}

fn isSafeFeatureSegment(value: []const u8) bool {
    if (value.len == 0) return false;
    var decoded_len: usize = 0;
    var decoded_all_dots = true;
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
            if (byte < 0x80 and !(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~')) return false;
            index += 1;
        }
        if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\' or byte == '?' or byte == '#') return false;
        decoded_len += 1;
        if (byte != '.') decoded_all_dots = false;
    }
    return !(decoded_all_dots and (decoded_len == 1 or decoded_len == 2));
}

fn encodeLanguagePathSegment(allocator: Allocator, language_code: []const u8) ![]u8 {
    if (language_code.len == 0 or
        std.mem.eql(u8, language_code, ".") or
        std.mem.eql(u8, language_code, "..")) return error.InvalidLanguageCode;
    for (language_code) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidLanguageCode;
    }
    return common.encodeUriComponent(allocator, language_code);
}

fn normalizePublicDownloadUrl(allocator: Allocator, raw_url: []const u8) ![]const u8 {
    const url = if (std.mem.startsWith(u8, raw_url, "http://") or
        std.mem.startsWith(u8, raw_url, "https://"))
        try allocator.dupe(u8, raw_url)
    else
        try common.resolveUrl(allocator, site, raw_url);
    errdefer allocator.free(url);
    try common.validatePublicHttpUrl(url);
    return url;
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
    if (txt.len == 0) {
        allocator.free(txt);
        return null;
    }
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
        defer allocator.free(txt);
        if (txt.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(allocator, " | ");
        try out.appendSlice(allocator, txt);
        if (i >= 6 and out.items.len > 240) break;
    }

    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn parseRemoteEndpoint(allocator: Allocator, cols: []const std.json.Value) ![]const u8 {
    if (cols.len == 0) return error.MissingField;
    const idx = cols.len - 1;
    const fragment = switch (cols[idx]) {
        .string => |s| s,
        else => return error.MissingField,
    };
    const remote_marker = "data-remote=\"true\"";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, fragment, cursor, remote_marker)) |marker| {
        cursor = marker + remote_marker.len;
        const tag_start = std.mem.lastIndexOfScalar(u8, fragment[0..marker], '<') orelse continue;
        const next_tag = std.mem.indexOfScalarPos(u8, fragment, tag_start + 1, '<');
        if (next_tag) |next| if (next < marker) continue;
        const tag_end_rel = std.mem.indexOfScalar(u8, fragment[marker..], '>') orelse continue;
        const tag_end = marker + tag_end_rel + 1;
        if (next_tag) |next| if (next < tag_end) continue;
        const href = (try htmlAttribute(allocator, fragment[tag_start..tag_end], "href")) orelse continue;
        defer allocator.free(href);
        const resolved = common.resolveUrl(allocator, site, href) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        errdefer allocator.free(resolved);
        validateProviderRoute(resolved, .remote_download) catch {
            allocator.free(resolved);
            continue;
        };
        return resolved;
    }
    return error.MissingField;
}

fn parseOptionalRemoteEndpoint(allocator: Allocator, cols: []const std.json.Value) !?[]const u8 {
    return parseRemoteEndpoint(allocator, cols) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
}

fn firstHtmlAttribute(allocator: Allocator, fragment: []const u8, name: []const u8) !?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, fragment, pos, '<')) |start| {
        const next_start = std.mem.indexOfScalarPos(u8, fragment, start + 1, '<');
        const end = std.mem.indexOfScalarPos(u8, fragment, start, '>') orelse {
            pos = next_start orelse return null;
            continue;
        };
        if (next_start) |next| {
            if (next < end) {
                pos = next;
                continue;
            }
        }
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
    var cursor: usize = 0;
    return nextFileDownload(body, &cursor) orelse .{ .filename = null, .url = null };
}

fn nextFileDownload(body: []const u8, cursor: *usize) ?FileDownload {
    const marker = "file_download('";
    const comma_marker = "','";
    while (std.mem.indexOfPos(u8, body, cursor.*, marker)) |start| {
        const candidate_start = start + marker.len;
        const candidate_end = std.mem.indexOfPos(u8, body, candidate_start, marker) orelse body.len;
        const after = body[candidate_start..candidate_end];
        cursor.* = candidate_end;

        const quote1 = std.mem.indexOfScalar(u8, after, '\'') orelse continue;
        const filename = after[0..quote1];
        const comma_idx = std.mem.indexOfPos(u8, after, quote1, comma_marker) orelse continue;
        const url_start = comma_idx + comma_marker.len;
        const tail = after[url_start..];
        const url_end = std.mem.indexOfScalar(u8, tail, '\'') orelse continue;

        return .{ .filename = filename, .url = tail[0..url_end] };
    }
    return null;
}

fn findPublicFileDownload(allocator: Allocator, body: []const u8) !?FileDownload {
    var cursor: usize = 0;
    var first_rejected_error: ?anyerror = null;
    while (nextFileDownload(body, &cursor)) |candidate| {
        const raw_url = candidate.url orelse continue;
        const url = normalizePublicDownloadUrl(allocator, raw_url) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                if (first_rejected_error == null) first_rejected_error = err;
                continue;
            },
        };
        return .{ .filename = candidate.filename, .url = url };
    }
    if (first_rejected_error) |err| return err;
    return null;
}

fn makeSubtitlesListUrl(allocator: Allocator, locale_path: []const u8) ![]const u8 {
    if (locale_path.len == 0 or locale_path[0] != '/' or std.mem.indexOfAny(u8, locale_path, "?#\\") != null)
        return error.InvalidDownloadUrl;
    var segments = std.mem.splitScalar(u8, locale_path[1..], '/');
    const locale = segments.next() orelse return error.InvalidDownloadUrl;
    if (!isSafeLocaleSegment(locale)) return error.InvalidDownloadUrl;
    const media = segments.next() orelse return error.InvalidDownloadUrl;
    if (!(std.mem.eql(u8, media, "movies") or std.mem.eql(u8, media, "tvshows")))
        return error.InvalidDownloadUrl;
    const feature = segments.next() orelse return error.InvalidDownloadUrl;
    if (!isSafeFeatureSegment(feature) or segments.next() != null) return error.InvalidDownloadUrl;

    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/features/{s}/subtitles_list.json",
        .{ site, locale, feature },
    );
    errdefer allocator.free(url);
    try validateProviderRoute(url, .feature_listing);
    return url;
}

fn localizeFeaturePath(allocator: Allocator, path: []const u8, language: []const u8) ![]u8 {
    const marker = "/current_locale/";
    if (!std.mem.startsWith(u8, path, marker)) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ language, path[marker.len..] });
}

test "opensubtitles.com trims queries and does not fetch empty searches" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqualStrings(site ++ "/en/en/search/autocomplete/Matrix.json", url);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "[]") };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);

    var empty = try scraper.searchUsing(Fixture.fetch, " \t\r\n ");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    var trimmed = try scraper.searchUsing(Fixture.fetch, "  Matrix\t");
    defer trimmed.deinit();
    try std.testing.expectEqual(@as(usize, 0), trimmed.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "opensubtitles.com language is one validated path segment" {
    const allocator = std.testing.allocator;
    const encoded = try encodeLanguagePathSegment(allocator, "pt-BR");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("pt-BR", encoded);

    for ([_][]const u8{ "", ".", "..", "../en", "en/us", "en\\us", "en?x=1", "en#x", "en%2fus", "en\nfoo" }) |invalid| {
        try std.testing.expectError(error.InvalidLanguageCode, encodeLanguagePathSegment(allocator, invalid));
    }

    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.UnexpectedFetch;
        }
    };
    var fixture: Fixture = .{ .client = .{ .allocator = allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.initWithOptions(allocator, &fixture.client, .{ .language_code = "../en" });
    try std.testing.expectError(error.InvalidLanguageCode, scraper.searchUsing(Fixture.fetch, "Matrix"));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "parse opensubtitles.com file_download" {
    const parsed = parseFileDownload("x file_download('name.zip','https://a/b.zip') y");
    try std.testing.expectEqualStrings("name.zip", parsed.filename.?);
    try std.testing.expectEqualStrings("https://a/b.zip", parsed.url.?);
}

test "opensubtitles.com scans past malformed file_download calls" {
    const parsed = parseFileDownload(
        "file_download('missing-url') " ++
            "file_download('unterminated.zip','https://bad.example/zip " ++
            "file_download('good.zip','https://dl.opensubtitles.com/good.zip')",
    );
    try std.testing.expectEqualStrings("good.zip", parsed.filename.?);
    try std.testing.expectEqualStrings("https://dl.opensubtitles.com/good.zip", parsed.url.?);
}

test "opensubtitles.com scans past an unsafe complete file_download call" {
    const parsed = (try findPublicFileDownload(
        std.testing.allocator,
        "file_download('unsafe.zip','http://127.0.0.1/private') " ++
            "file_download('good.zip','https://dl.opensubtitles.com/good.zip')",
    )) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(parsed.url.?);

    try std.testing.expectEqualStrings("good.zip", parsed.filename.?);
    try std.testing.expectEqualStrings("https://dl.opensubtitles.com/good.zip", parsed.url.?);
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

test "opensubtitles.com replaces only the locale path segment" {
    const path = try localizeFeaturePath(
        std.testing.allocator,
        "/current_locale/movies/current_locale-feature",
        "en",
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/en/movies/current_locale-feature", path);
}

test "opensubtitles.com accepts only canonical listing and remote download routes" {
    for ([_]struct { url: []const u8, route: ProviderRoute }{
        .{ .url = site ++ "/en/features/1999-the-matrix/subtitles_list.json", .route = .feature_listing },
        .{ .url = site ++ "/pt-BR/features/amelie%20poulain/subtitles_list.json", .route = .feature_listing },
        // The route request id and subtitle_id are distinct in captured provider output.
        .{ .url = site ++ "/nocache/download/12778078/subreq.js?direct_dl=true&file_name=The+Matrix+1999.+WEBRip.+23_976.+lat.+2-16-42&locale=en&np=true&sub_frmt=srt&subtitle_id=11891567", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/42/subreq.js?subtitle_id=99&sub_frmt=srt&np=true&locale=pt-BR&file_name=Movie%20Two&direct_dl=true", .route = .remote_download },
    }) |valid| try validateProviderRoute(valid.url, valid.route);

    for ([_]struct { url: []const u8, route: ProviderRoute }{
        .{ .url = site ++ "/admin", .route = .feature_listing },
        .{ .url = site ++ "/en/features/title/subtitles_list.json?next=/admin", .route = .feature_listing },
        .{ .url = site ++ "/en/features/title/subtitles_list.json#fragment", .route = .feature_listing },
        .{ .url = site ++ "/en/features/../subtitles_list.json", .route = .feature_listing },
        .{ .url = site ++ "/en/features/%2e%2e/subtitles_list.json", .route = .feature_listing },
        .{ .url = site ++ "/en/features/title%2Fadmin/subtitles_list.json", .route = .feature_listing },
        .{ .url = site ++ "/en/features/title/extra/subtitles_list.json", .route = .feature_listing },
        .{ .url = site ++ "/nocache/download/0/subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/01/subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/../subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1%2Fadmin/subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=srt&subtitle_id=1&next=/admin", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=false&file_name=x&locale=en&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x&locale=en&locale=fr&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x=y&locale=en&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x%GG&locale=en&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x&%6cocale=en&np=true&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x&locale=en&np=false&sub_frmt=srt&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=zip&subtitle_id=1", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=srt&subtitle_id=01", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=srt", .route = .remote_download },
        .{ .url = site ++ "/nocache/download/1/subreq.js?direct_dl=true&file_name=x&locale=en&np=true&sub_frmt=srt&subtitle_id=1#fragment", .route = .remote_download },
    }) |invalid| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderRoute(invalid.url, invalid.route));
    }
}

test "opensubtitles.com malformed metadata sibling does not suppress a valid feature" {
    const Fixture = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{
                .status = .ok,
                .body = try allocator.dupe(
                    u8,
                    "[{\"title\":\"bad dot\",\"path\":\"/en/movies/../admin\"}," ++
                        "{\"title\":\"bad separator\",\"path\":\"/en/movies/title%2Fadmin\"}," ++
                        "{\"title\":\"The Matrix\",\"year\":\"1999\",\"path\":\"/en/movies/1999-the-matrix\"}]",
                ),
            };
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.searchUsing(Fixture.fetch, "The Matrix");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqualStrings(
        site ++ "/en/features/1999-the-matrix/subtitles_list.json",
        response.items[0].subtitles_list_url,
    );
}

test "opensubtitles.com malformed remote sibling is ignored before a valid endpoint" {
    const bad = [_]std.json.Value{
        .{ .string = "en" },
        .{ .string = "<a data-remote=\"true\" href=\"/admin?direct_dl=true&amp;locale=en\">bad</a>" },
    };
    try std.testing.expect((try parseOptionalRemoteEndpoint(std.testing.allocator, &bad)) == null);

    const good = [_]std.json.Value{
        .{ .string = "en" },
        .{ .string = "<a data-remote=\"true\" href=\"/nocache/download/7/subreq.js?direct_dl=true&amp;file_name=Good+Subtitle&amp;locale=en&amp;np=true&amp;sub_frmt=srt&amp;subtitle_id=70\">good</a>" },
    };
    const remote = (try parseOptionalRemoteEndpoint(std.testing.allocator, &good)).?;
    defer std.testing.allocator.free(remote);
    try std.testing.expectEqualStrings(
        site ++ "/nocache/download/7/subreq.js?direct_dl=true&file_name=Good+Subtitle&locale=en&np=true&sub_frmt=srt&subtitle_id=70",
        remote,
    );
}

test "opensubtitles.com malformed remote in one cell does not shadow a valid sibling" {
    const row = [_]std.json.Value{
        .{ .string = "en" },
        .{ .string = "<a data-remote=\"true\" href=\"/admin\">bad</a>" ++
            "<a data-remote=\"true\" href=\"/nocache/download/8/subreq.js?subtitle_id=80&amp;sub_frmt=srt&amp;np=true&amp;locale=en&amp;file_name=Good+Subtitle&amp;direct_dl=true\">good</a>" },
    };
    const remote = try parseRemoteEndpoint(std.testing.allocator, &row);
    defer std.testing.allocator.free(remote);
    try std.testing.expectEqualStrings(
        site ++ "/nocache/download/8/subreq.js?subtitle_id=80&sub_frmt=srt&np=true&locale=en&file_name=Good+Subtitle&direct_dl=true",
        remote,
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
        .{ .string = "<a data-remote=\"true\" href=\"/nocache/download/1/subreq.js?direct_dl=true&amp;file_name=The+Matrix&amp;locale=en&amp;np=true&amp;sub_frmt=srt&amp;subtitle_id=10\">Direct</a>" },
    };
    const language = (try parseLanguageFromCell(allocator, &cols, 1)).?;
    defer allocator.free(language);
    try std.testing.expectEqualStrings("English", language);
    const filename = (try parseFilenameFromCell(allocator, &cols, 2)).?;
    defer allocator.free(filename);
    try std.testing.expectEqualStrings("The Matrix & Extras HD", filename);
    const summary = (try summarizeRow(allocator, &cols)).?;
    defer allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "The Matrix & Extras HD") != null);
    const remote = try parseRemoteEndpoint(allocator, &cols);
    defer allocator.free(remote);
    try std.testing.expectEqualStrings("https://rest.opensubtitles.com/nocache/download/1/subreq.js?direct_dl=true&file_name=The+Matrix&locale=en&np=true&sub_frmt=srt&subtitle_id=10", remote);
}

test "opensubtitles.com optional listing parsers preserve allocation errors" {
    const cols = [_]std.json.Value{
        .{ .string = "en" },
        .{ .string = "<a title=\"English\">English</a>" },
        .{ .string = "<a>The Matrix</a>" },
        .{ .string = "<a data-remote=\"true\" href=\"/download\">Direct</a>" },
    };

    var failing_language = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseLanguageFromCell(failing_language.allocator(), &cols, 1));

    var failing_filename = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseFilenameFromCell(failing_filename.allocator(), &cols, 2));

    var failing_summary = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, summarizeRow(failing_summary.allocator(), &cols));

    var failing_remote = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseOptionalRemoteEndpoint(failing_remote.allocator(), &cols));
}

test "opensubtitles.com empty filename cells release temporary text" {
    const cols = [_]std.json.Value{
        .{ .string = "en" },
        .{ .string = "<span> </span>" },
    };
    try std.testing.expect((try parseFilenameFromCell(std.testing.allocator, &cols, 1)) == null);
}

test "opensubtitles.com rejects untrusted provider endpoints before fetch" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "http://127.0.0.1/private",
        "https://user:pass@rest.opensubtitles.com/private",
        "https://rest.opensubtitles.com.evil.test/private",
        "https://evil.test/private",
    };
    for (cases) |url| try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(url));

    const cols = [_]std.json.Value{
        .{ .string = "en" },
        .{ .string = "<a data-remote=\"true\" href=\"http://127.0.0.1/private\">Direct</a>" },
    };
    try std.testing.expectError(error.MissingField, parseRemoteEndpoint(allocator, &cols));

    const scheme_relative_cols = [_]std.json.Value{
        .{ .string = "en" },
        .{ .string = "<a data-remote=\"true\" href=\"//169.254.169.254/latest/meta-data\">Direct</a>" },
    };
    try std.testing.expectError(error.MissingField, parseRemoteEndpoint(allocator, &scheme_relative_cols));

    try std.testing.expectError(error.InvalidDownloadUrl, makeSubtitlesListUrl(allocator, ".attacker.example/movies/x"));
    try std.testing.expectError(error.InvalidDownloadUrl, makeSubtitlesListUrl(allocator, "@attacker.example/movies/x"));

    try std.testing.expectError(error.InvalidDownloadUrl, normalizePublicDownloadUrl(allocator, "file:///tmp/subtitle.zip"));
    try std.testing.expectError(error.UnsafeHttpTarget, normalizePublicDownloadUrl(allocator, "http://127.0.0.1/subtitle.zip"));
    try std.testing.expectError(error.UnsafeHttpTarget, normalizePublicDownloadUrl(allocator, "http://169.254.169.254/latest/meta-data"));
    try std.testing.expectError(error.UnsafeHttpTarget, normalizePublicDownloadUrl(allocator, "https://user:pass@cdn.opensubtitles.com/subtitle.zip"));
}

test "opensubtitles.com REST metadata classifies terminal responses without retrying" {
    const challenge = "<!doctype html><html><title>Just a moment...</title><script>window._cf_chl_opt = {};</script></html>";
    const Case = struct {
        status: std.http.Status,
        body: []const u8,
        expected_error: anyerror,
    };
    const Fixture = struct {
        client: std.http.Client,
        status: std.http.Status,
        body: []const u8,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(options.allow_non_ok);
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expect(!options.cache);
            try std.testing.expectEqual(@as(usize, 2), options.max_attempts);
            return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
        }
    };

    for ([_]Case{
        .{ .status = .too_many_requests, .body = challenge, .expected_error = error.RateLimited },
        .{ .status = .ok, .body = challenge, .expected_error = error.CloudflareChallenge },
        .{ .status = .forbidden, .body = "forbidden", .expected_error = error.ProviderAccessBlocked },
        .{ .status = .service_unavailable, .body = "unavailable", .expected_error = error.UnexpectedHttpStatus },
        .{ .status = .bad_gateway, .body = "upstream failure", .expected_error = error.UnexpectedHttpStatus },
    }) |case| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .status = case.status,
            .body = case.body,
        };
        defer fixture.client.deinit();
        try std.testing.expectError(case.expected_error, fetchPublicUsing(
            Fixture.fetch,
            &fixture.client,
            std.testing.allocator,
            site ++ "/en/en/search/autocomplete/matrix.json",
            .{ .accept = "application/json" },
        ));
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    }

    var success: Fixture = .{
        .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
        .status = .ok,
        .body = "{\"title\":\"Just a moment\"}",
    };
    defer success.client.deinit();
    const body = try fetchPublicUsing(Fixture.fetch, &success.client, std.testing.allocator, site ++ "/metadata.json", .{});
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"title\":\"Just a moment\"}", body);
    try std.testing.expectEqual(@as(usize, 1), success.calls);
}

test "opensubtitles.com REST metadata preserves cancellation and allocation failure" {
    const Fixture = struct {
        client: std.http.Client,
        failure: anyerror,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(options.allow_non_ok);
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expect(!options.cache);
            return self.failure;
        }
    };

    inline for (.{ error.Canceled, error.OutOfMemory }) |failure| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .failure = failure,
        };
        defer fixture.client.deinit();
        try std.testing.expectError(failure, fetchPublicUsing(
            Fixture.fetch,
            &fixture.client,
            std.testing.allocator,
            site ++ "/metadata.json",
            .{},
        ));
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    }
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

test "opensubtitles TV listings use the public features endpoint" {
    const url = try makeSubtitlesListUrl(std.testing.allocator, "/en/tvshows/2019-chernobyl");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://rest.opensubtitles.com/en/features/2019-chernobyl/subtitles_list.json", url);
}
