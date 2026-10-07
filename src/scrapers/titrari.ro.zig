const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.titrari.ro";
const search_page = "cautamainaltaparte";
pub const download_token_prefix = "titrari-referer:";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    language_code: []const u8,
    subtitle_id: []const u8,
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
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const url = try std.fmt.allocPrint(
            a,
            "{s}/index.php?page={s}&z7={s}&z2=&z5=&z3=-1&z4=-1&z8=-1&z9=All&z11=0&z6=0",
            .{ site, search_page, encoded },
        );
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = site ++ "/" }},
            .cache = false,
            .max_attempts = 3,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
            .deadline_ms = deadline_ms,
        });
        var parsed = try parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
        errdefer parsed.deinit();
        try self.preferZipMovieDuplicate(parsed.arena.allocator(), &parsed, deadline_ms);
        return parsed;
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderRoute(item.page_url, .page, item.subtitle_id);
        const filename = try std.fmt.allocPrint(a, "titrari-{s}-{s}", .{ item.subtitle_id, try common.asciiSlug(a, item.title) });
        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = filename,
            .download_url = try makeDownloadToken(a, item.subtitle_id, item.page_url),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parsed = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        try validateProviderRoute(parsed.page_url, .page, parsed.subtitle_id);
        const url = try std.fmt.allocPrint(allocator, "{s}/get.php?id={s}", .{ site, parsed.subtitle_id });
        defer allocator.free(url);
        try validateProviderRoute(url, .download, parsed.subtitle_id);
        const response = try common.fetchBytes(self.client, allocator, url, .{
            .accept = "application/octet-stream,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = parsed.page_url }},
            .cache = false,
            .max_attempts = 3,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        if (response.status != .ok) {
            allocator.free(response.body);
            return error.UnexpectedHttpStatus;
        }
        if (common.looksLikeHtml(response.body)) {
            allocator.free(response.body);
            return error.UnexpectedResponseType;
        }
        return response;
    }

    fn preferZipMovieDuplicate(self: *Scraper, allocator: Allocator, response: *SearchResponse, deadline_ms: i64) !void {
        return preferZipMovieDuplicateWith(probeArchiveKindForPreference, self, allocator, response, deadline_ms);
    }

    fn probeArchiveKind(
        self: *Scraper,
        allocator: Allocator,
        item: SearchItem,
        deadline_ms: i64,
    ) !ArchiveHint {
        const now_ms = common.compatMilliTimestamp();
        if (now_ms >= deadline_ms) return error.Timeout;

        const ProbeTask = struct {
            fn run(result: *?ArchiveHint, scraper: *Scraper, task_allocator: Allocator, task_item: SearchItem) !void {
                result.* = try scraper.probeArchiveKindUnbounded(task_allocator, task_item);
            }
        };
        const ProbeResult = @typeInfo(@TypeOf(ProbeTask.run)).@"fn".return_type.?;
        const TimeoutResult = @typeInfo(@TypeOf(std.Io.Timeout.sleep)).@"fn".return_type.?;
        const Selection = union(enum) {
            probe: ProbeResult,
            timeout: TimeoutResult,
        };
        var selection_buffer: [2]Selection = undefined;
        var selection = std.Io.Select(Selection).init(self.client.io, &selection_buffer);
        defer selection.cancelDiscard();

        var hint: ?ArchiveHint = null;
        const remaining_ms: i64 = deadline_ms -| now_ms;
        const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(self.client.io, .{
            .raw = std.Io.Duration.fromMilliseconds(remaining_ms),
            .clock = .awake,
        }) };
        try selection.concurrent(.probe, ProbeTask.run, .{ &hint, self, allocator, item });
        try selection.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, self.client.io });

        switch (try selection.await()) {
            .probe => |result| try result,
            .timeout => |result| {
                try result;
                return error.Timeout;
            },
        }
        return hint orelse error.MissingHttpResponse;
    }

    fn probeArchiveKindUnbounded(self: *Scraper, allocator: Allocator, item: SearchItem) !ArchiveHint {
        try validateProviderRoute(item.download_url, .download, item.subtitle_id);
        try validateProviderRoute(item.page_url, .page, item.subtitle_id);
        const normalized = try common.normalizeUrlForFetch(allocator, item.download_url);
        defer allocator.free(normalized);
        const uri = try std.Uri.parse(normalized);
        const headers = [_]std.http.Header{.{ .name = "referer", .value = item.page_url }};
        try common.validateHttpHeaders(&headers);
        var public_client: std.http.Client = undefined;
        try common.initPublicOriginClient(self.client, &public_client);
        defer public_client.deinit();
        const pinned_connection = try common.connectPinnedPublicHttpUrl(&public_client, allocator, normalized);
        pinned_connection.closing = true;

        var req = public_client.request(.HEAD, uri, .{
            .redirect_behavior = .unhandled,
            .handle_continue = false,
            .keep_alive = false,
            .connection = pinned_connection,
            .headers = .{
                .user_agent = .{ .override = common.default_user_agent },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = &headers,
        }) catch |err| {
            public_client.connection_pool.release(pinned_connection, public_client.io);
            return err;
        };
        defer req.deinit();
        errdefer req.connection.?.closing = true;
        req.sendBodiless() catch |err| return common.normalizeRequestWriteError(&req, err);

        var head_buffer: [16 * 1024]u8 = undefined;
        var response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
        var interim_count: usize = 0;
        while (response.head.status.class() == .informational) {
            if (response.head.status == .switching_protocols) return error.UnsupportedProtocolUpgrade;
            try validateRawArchiveProbeResponseHead(response.head);
            interim_count += 1;
            if (interim_count > 16) return error.TooManyInformationalResponses;
            response = req.receiveHead(&head_buffer) catch |err| return common.normalizeRequestReadError(&req, err);
        }
        try validateRawArchiveProbeResponseHead(response.head);
        if (!try archiveProbeStatusIsUsable(response.head.status)) return .unknown;
        return archiveHintFromHeaders(response.head.bytes);
    }
};

fn validateRawArchiveProbeResponseHead(head: std.http.Client.Response.Head) !void {
    try common.validateResponseFraming(head);
}

fn probeArchiveKindForPreference(scraper: *Scraper, allocator: Allocator, item: SearchItem, deadline_ms: i64) !ArchiveHint {
    return scraper.probeArchiveKind(allocator, item, deadline_ms);
}

fn preferZipMovieDuplicateWith(comptime probe: anytype, context: anytype, allocator: Allocator, response: *SearchResponse, deadline_ms: i64) !void {
    if (response.items.len < 2) return;
    const first = response.items[0];
    if (first.media_kind != .movie) return;
    if (try optionalArchiveProbe(probe(context, allocator, first, deadline_ms)) != .rar) return;

    const max_probe = @min(response.items.len, @as(usize, 6));
    var idx: usize = 1;
    while (idx < max_probe) : (idx += 1) {
        const candidate = response.items[idx];
        if (candidate.media_kind != .movie) continue;
        if (!std.ascii.eqlIgnoreCase(candidate.title, first.title)) continue;
        if (candidate.year != first.year) continue;
        if (try optionalArchiveProbe(probe(context, allocator, candidate, deadline_ms)) != .zip) continue;

        const reordered = try allocator.alloc(SearchItem, response.items.len);
        @memcpy(reordered, response.items);
        std.mem.swap(SearchItem, &reordered[0], &reordered[idx]);
        response.items = reordered;
        return;
    }
}

const ProviderRoute = enum { page, download };

fn validateProviderRoute(url: []const u8, route: ProviderRoute, expected_id: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
    if (!isPositiveDecimalId(expected_id)) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return error.UnsafeHttpTarget;
    const query = url[query_start + 1 ..];
    const value = switch (route) {
        .page => blk: {
            if (!std.mem.eql(u8, path, "/index.php")) break :blk null;
            const prefix = "page=" ++ search_page ++ "&z10=";
            if (!std.mem.startsWith(u8, query, prefix)) break :blk null;
            break :blk query[prefix.len..];
        },
        .download => blk: {
            if (!std.mem.eql(u8, path, "/get.php")) break :blk null;
            const prefix = "id=";
            if (!std.mem.startsWith(u8, query, prefix)) break :blk null;
            break :blk query[prefix.len..];
        },
    } orelse return error.UnsafeHttpTarget;
    if (!isPositiveDecimalId(value) or !std.mem.eql(u8, value, expected_id)) {
        return error.UnsafeHttpTarget;
    }
}

fn isPositiveDecimalId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

const ArchiveHint = enum {
    unknown,
    zip,
    rar,
    seven_z,
};

fn optionalArchiveProbe(result: anyerror!ArchiveHint) !ArchiveHint {
    return result catch |err| {
        if (common.mustPropagateOptionalFailure(err)) return err;
        return .unknown;
    };
}

fn archiveProbeStatusIsUsable(status: std.http.Status) !bool {
    if (status == .too_many_requests) return error.RateLimited;
    if (status == .unauthorized or status == .forbidden) return error.ProviderAccessBlocked;
    return status == .ok;
}

test "titrari archive preference preserves search on probe failure" {
    try std.testing.expectEqual(ArchiveHint.unknown, try optionalArchiveProbe(error.ConnectionTimedOut));
    try std.testing.expectEqual(ArchiveHint.zip, try optionalArchiveProbe(.zip));
    try std.testing.expectError(error.Canceled, optionalArchiveProbe(error.Canceled));
    try std.testing.expectError(error.OutOfMemory, optionalArchiveProbe(error.OutOfMemory));
    try std.testing.expectError(error.RateLimited, optionalArchiveProbe(error.RateLimited));
    try std.testing.expectError(error.UnsafeHttpTarget, optionalArchiveProbe(error.UnsafeHttpTarget));

    try std.testing.expect(try archiveProbeStatusIsUsable(.ok));
    try std.testing.expect(!(try archiveProbeStatusIsUsable(.service_unavailable)));
    try std.testing.expectError(error.RateLimited, archiveProbeStatusIsUsable(.too_many_requests));
    try std.testing.expectError(error.ProviderAccessBlocked, archiveProbeStatusIsUsable(.unauthorized));
    try std.testing.expectError(error.ProviderAccessBlocked, archiveProbeStatusIsUsable(.forbidden));
}

test "titrari archive preference stops probing on a rate limit" {
    const Mock = struct {
        fn probe(calls: *usize, _: Allocator, _: SearchItem, _: i64) !ArchiveHint {
            calls.* += 1;
            return error.RateLimited;
        }
    };
    const items = [_]SearchItem{
        .{ .title = "Movie", .year = 2024, .media_kind = .movie, .language_code = "ro", .subtitle_id = "1", .page_url = site ++ "/one", .download_url = site ++ "/get.php?id=1" },
        .{ .title = "Movie", .year = 2024, .media_kind = .movie, .language_code = "ro", .subtitle_id = "2", .page_url = site ++ "/two", .download_url = site ++ "/get.php?id=2" },
    };
    var response: SearchResponse = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .items = &items,
    };
    defer response.deinit();
    var calls: usize = 0;
    try std.testing.expectError(error.RateLimited, preferZipMovieDuplicateWith(Mock.probe, &calls, response.arena.allocator(), &response, std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(usize, 1), calls);
}

fn archiveHintFromHeaders(headers: []const u8) ArchiveHint {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-disposition")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.findIgnoreCase(value, ".zip") != null) return .zip;
        if (std.ascii.findIgnoreCase(value, ".rar") != null) return .rar;
        if (std.ascii.findIgnoreCase(value, ".7z") != null) return .seven_z;
    }
    return .unknown;
}

pub fn makeDownloadToken(allocator: Allocator, subtitle_id: []const u8, page_url: []const u8) ![]u8 {
    if (!isPositiveDecimalId(subtitle_id)) return error.InvalidDownloadUrl;
    try validateProviderRoute(page_url, .page, subtitle_id);
    return std.fmt.allocPrint(
        allocator,
        "{s}v1:{d}:{s}{d}:{s}",
        .{ download_token_prefix, subtitle_id.len, subtitle_id, page_url.len, page_url },
    );
}

const DownloadToken = common.SubtitleDownloadToken;

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    if (!std.mem.startsWith(u8, payload, "v1:")) return null;
    var cursor: usize = "v1:".len;
    const subtitle_id = takeTokenField(payload, &cursor) orelse return null;
    const page_url = takeTokenField(payload, &cursor) orelse return null;
    if (cursor != payload.len or !isPositiveDecimalId(subtitle_id)) return null;
    validateProviderRoute(page_url, .page, subtitle_id) catch return null;
    return .{ .subtitle_id = subtitle_id, .page_url = page_url };
}

fn takeTokenField(payload: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= payload.len) return null;
    const length_end_rel = std.mem.indexOfScalar(u8, payload[cursor.*..], ':') orelse return null;
    const length_end = cursor.* + length_end_rel;
    if (length_end == cursor.*) return null;
    const length_text = payload[cursor.*..length_end];
    if (length_text.len > 1 and length_text[0] == '0') return null;
    for (length_text) |c| if (!std.ascii.isDigit(c)) return null;
    const field_len = std.fmt.parseInt(usize, length_text, 10) catch return null;
    const field_start = length_end + 1;
    const field_end = std.math.add(usize, field_start, field_len) catch return null;
    if (field_end > payload.len) return null;
    cursor.* = field_end;
    return payload[field_start..field_end];
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
        return .{
            .href = htmlAttributeValue(html[tag_start .. tag_end + 1], "href"),
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
    var cursor: usize = 2;
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

fn nextElementByName(html: []const u8, cursor: *usize, wanted_name: []const u8) ?HtmlElement {
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

        const close_start = findClosingTagStart(html, cursor, wanted_name) orelse continue;
        const close_end = htmlTagEnd(html, close_start + 2) orelse continue;
        cursor.* = close_end + 1;
        return .{
            .tag_start = tag_start,
            .content_start = tag_end + 1,
            .close_start = close_start,
        };
    }
    return null;
}

const TitleRecord = struct {
    tag_start: usize,
    raw_title: []const u8,
};

fn nextTitleRecord(html: []const u8, cursor: *usize) ?TitleRecord {
    if (nextElementByName(html, cursor, "h1")) |heading| {
        const content = html[heading.content_start..heading.close_start];
        var anchor_cursor: usize = 0;
        while (nextAnchorTag(content, &anchor_cursor)) |anchor| {
            var close_cursor = anchor.content_start;
            const close_start = findClosingTagStart(content, &close_cursor, "a") orelse continue;
            const raw_title = std.mem.trim(u8, content[anchor.content_start..close_start], " \t\r\n");
            if (raw_title.len == 0) continue;
            return .{ .tag_start = heading.tag_start, .raw_title = raw_title };
        }
        // An unusable title still separates its downloads from the prior record.
        return .{ .tag_start = heading.tag_start, .raw_title = "" };
    }
    return null;
}

fn subtitleIdFromDownloadHref(href: []const u8) ?[]const u8 {
    const subtitle_id = if (std.mem.startsWith(u8, href, site ++ "/get.php?id="))
        href[(site ++ "/get.php?id=").len..]
    else if (std.mem.startsWith(u8, href, "/get.php?id="))
        href["/get.php?id=".len..]
    else if (std.mem.startsWith(u8, href, "get.php?id="))
        href["get.php?id=".len..]
    else
        return null;
    if (!isPositiveDecimalId(subtitle_id)) return null;
    return subtitle_id;
}

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
    while (nextTitleRecord(body, &cursor)) |record| {
        var lookahead = cursor;
        const next_record = nextTitleRecord(body, &lookahead);
        const block_end = if (next_record) |next| next.tag_start else body.len;
        const block = body[record.tag_start..block_end];
        cursor = block_end;
        const raw_title = record.raw_title;
        if (raw_title.len == 0) continue;

        var subtitle_id: ?[]const u8 = null;
        var conflicting_ids = false;
        var anchor_cursor: usize = 0;
        while (nextAnchorTag(block, &anchor_cursor)) |anchor| {
            const href = anchor.href orelse continue;
            const candidate_id = subtitleIdFromDownloadHref(href) orelse continue;
            if (subtitle_id) |known_id| {
                if (!std.mem.eql(u8, known_id, candidate_id)) {
                    conflicting_ids = true;
                    break;
                }
            } else {
                subtitle_id = candidate_id;
            }
        }
        if (conflicting_ids) continue;
        const canonical_subtitle_id = subtitle_id orelse continue;

        const language_code: []const u8 = if (std.mem.indexOf(u8, block, "flags/1.gif") != null or std.mem.indexOf(u8, block, "[ Romana ]") != null)
            "ro"
        else if (std.mem.indexOf(u8, block, "flags/2.gif") != null or std.mem.indexOf(u8, block, "[ Engleza ]") != null)
            "en"
        else
            continue;

        const split = common.splitTrailingYear(raw_title);
        const clean_title = stripSeasonSuffix(split.title);
        const normalized = try common.normalizeTitle(a, clean_title);
        if (normalized.len == 0) continue;
        if (!common.normalizedTitlesRelated(normalized, wanted)) continue;
        const is_exact = std.mem.eql(u8, normalized, wanted);

        if (seen.contains(canonical_subtitle_id)) {
            if (is_exact) _ = try promotePartialBySubtitleId(a, canonical_subtitle_id, &exact, &partial);
            continue;
        }

        const media_kind: MediaKind = if (hasSeasonSuffix(split.title)) .tv else .movie;
        const page_url = try std.fmt.allocPrint(a, "{s}/index.php?page={s}&z10={s}", .{ site, search_page, canonical_subtitle_id });
        const download_url = try std.fmt.allocPrint(a, "{s}/get.php?id={s}", .{ site, canonical_subtitle_id });
        const item: SearchItem = .{
            .title = try a.dupe(u8, clean_title),
            .year = split.year,
            .media_kind = media_kind,
            .language_code = try a.dupe(u8, language_code),
            .subtitle_id = try a.dupe(u8, canonical_subtitle_id),
            .page_url = page_url,
            .download_url = download_url,
        };

        try seen.put(a, item.subtitle_id, {});
        if (is_exact)
            try exact.append(a, item)
        else
            try partial.append(a, item);
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn promotePartialBySubtitleId(
    allocator: Allocator,
    subtitle_id: []const u8,
    exact: *std.ArrayListUnmanaged(SearchItem),
    partial: *std.ArrayListUnmanaged(SearchItem),
) !bool {
    for (partial.items, 0..) |item, index| {
        if (!std.mem.eql(u8, item.subtitle_id, subtitle_id)) continue;
        try exact.ensureUnusedCapacity(allocator, 1);
        const promoted = partial.orderedRemove(index);
        exact.appendAssumeCapacity(promoted);
        return true;
    }
    return false;
}

fn hasSeasonSuffix(title: []const u8) bool {
    return std.ascii.findIgnoreCase(title, " - Sezonul ") != null or
        std.ascii.findIgnoreCase(title, " - Sezoanele ") != null;
}

fn stripSeasonSuffix(title: []const u8) []const u8 {
    if (std.ascii.findIgnoreCase(title, " - Sezonul ")) |idx| return std.mem.trimEnd(u8, title[0..idx], " \t");
    if (std.ascii.findIgnoreCase(title, " - Sezoanele ")) |idx| return std.mem.trimEnd(u8, title[0..idx], " \t");
    return std.mem.trim(u8, title, " \t\r\n");
}

test "titrari parses movie and season pack results" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<h1><a href=x>The Matrix Resurrections (2021)</a></h1>[ Romana ]<img src=flags/1.gif><a href=get.php?id=142169>Descarca</a>" ++
        "<h1><a href=x>Reacher - Sezonul 4 (2022)</a></h1>[ Romana ]<img src=flags/1.gif><a href=get.php?id=142095>Descarca</a>";
    var response = try parseSearchHtml(
        arena,
        fixture,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Reacher", response.items[0].title);
    try std.testing.expectEqual(MediaKind.tv, response.items[0].media_kind);
    try std.testing.expectEqual(@as(?i64, 2022), response.items[0].year);
    try std.testing.expectEqualStrings("https://www.titrari.ro/get.php?id=142095", response.items[0].download_url);
    const token = try makeDownloadToken(std.testing.allocator, "142095", response.items[0].page_url);
    defer std.testing.allocator.free(token);
    const parsed = parseDownloadToken(token).?;
    try std.testing.expectEqualStrings("142095", parsed.subtitle_id);
    try std.testing.expectEqualStrings(response.items[0].page_url, parsed.page_url);
    try std.testing.expectError(
        error.InvalidDownloadUrl,
        makeDownloadToken(std.testing.allocator, "0", response.items[0].page_url),
    );
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        makeDownloadToken(
            std.testing.allocator,
            "142095",
            "https://www.titrari.ro/index.php?page=cautamainaltaparte&z10=999",
        ),
    );
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "v1:01:x") == null);
}

test "titrari valid duplicate is not shadowed by an unusable block" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<h1><a href=x>Reacher (2022)</a></h1>[ Unknown ]<a href=get.php?id=77>Descarca</a>" ++
        "<h1><a href=x>Reacher (2022)</a></h1>[ Romana ]<img src=flags/1.gif><a href=get.php?id=77>Descarca</a>";
    var response = try parseSearchHtml(arena, fixture, "Reacher");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("77", response.items[0].subtitle_id);
    try std.testing.expectEqualStrings("ro", response.items[0].language_code);
}

test "titrari download ids come only from canonical href attributes" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<h1><a href=x>Reacher (2022)</a></h1>[ Romana ]" ++
        "get.php?id=70" ++
        "<!-- <a href=\"get.php?id=71\">comment decoy</a> -->" ++
        "<a data-href=\"get.php?id=72\" href=\"get.php?id=73evil\">bad</a>" ++
        "<a title=\"get.php?id=74\" href=\"/get.php?id=77\">Descarca</a>";
    var response = try parseSearchHtml(arena, fixture, "Reacher");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("77", response.items[0].subtitle_id);
}

test "titrari empty heading cannot lend its download to the preceding record" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<h1><a href=x>Reacher (2022)</a></h1>[ Romana ]" ++
        "<h1><a href=x></a></h1>[ Romana ]" ++
        "<a href=\"/get.php?id=77\">Download</a>";
    var response = try parseSearchHtml(arena, fixture, "Reacher");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "titrari empty heading preserves neighboring valid candidates" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<h1><a href=x>Reacher (2022)</a></h1>[ Romana ]<a href=\"/get.php?id=76\">Download</a>" ++
        "<h1><a href=x> </a></h1>[ Romana ]<a href=\"/get.php?id=77\">Download</a>" ++
        "<h1><a href=x>Reacher (2023)</a></h1>[ Romana ]<a href=\"/get.php?id=78\">Download</a>";
    var response = try parseSearchHtml(arena, fixture, "Reacher");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings("76", response.items[0].subtitle_id);
    try std.testing.expectEqualStrings(site ++ "/get.php?id=76", response.items[0].download_url);
    try std.testing.expectEqualStrings("78", response.items[1].subtitle_id);
    try std.testing.expectEqualStrings(site ++ "/get.php?id=78", response.items[1].download_url);
}

test "titrari ignores anchor-shaped script and style text" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<SCRIPT>const record = '<H1><A href=x>Reacher (1900)</A></H1>[ Romana ]<A href=\"/get.php?id=70\">fake</A>';</SCRIPT>" ++
        "<!-- <H1><A href=x>Reacher (1901)</A></H1>[ Romana ]<A href=\"/get.php?id=73\">fake</A> -->" ++
        "<H1 data-note='><h1><a href=x>decoy</a></h1>'><A data-note='>' HREF=\"index.php?page=details\">Reacher (2022)</A></H1>[ Romana ]" ++
        "<script>const sample = '<h1><a href=x>Wrong title</a></h1><a href=\"/get.php?id=71\">sample</a>'; const close = '</A>';</script>" ++
        "<STYLE>.sample::after { content: '<H1><A href=x>Wrong style</A></H1><A href=\"/get.php?id=72\">sample</A>'; }</STYLE>" ++
        "<A data-note='>' HREF=\"/get.php?id=77\">Descarca</A>";
    var response = try parseSearchHtml(arena, fixture, "Reacher");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("77", response.items[0].subtitle_id);
}

test "titrari leaves unterminated raw text closed" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<H1><A href=x>Reacher (2022)</A><SCRIPT>const sample = '" ++
        "<H1><A href=x>Reacher (1900)</A></H1>[ Romana ]<A href=\"/get.php?id=71\">fake</A>';" ++
        "</H1>[ Romana ]<A href=\"/get.php?id=77\">not a document anchor</A>";
    var response = try parseSearchHtml(arena, fixture, "Reacher");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "titrari rejects conflicting block ids but permits a repeated id" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<h1><a href=x>Reacher (2022)</a></h1>[ Romana ]" ++
        "<a href=\"get.php?id=70\">first</a><a href=\"/get.php?id=71\">second</a>" ++
        "<h1><a href=x>Reacher (2022)</a></h1>[ Romana ]" ++
        "<a href=\"get.php?id=77\">first</a><a href=\"/get.php?id=77\">second</a>";
    var response = try parseSearchHtml(arena, fixture, "Reacher");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("77", response.items[0].subtitle_id);
    try std.testing.expect(subtitleIdFromDownloadHref("get.php?id=77&id=78") == null);
    try std.testing.expect(subtitleIdFromDownloadHref("get.php?id=77#suffix") == null);
}

test "titrari promotes a later exact duplicate without disturbing order" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const fixture =
        "<h1><a href=x>Reacher Legacy (2022)</a></h1>[ Romana ]<a href=get.php?id=99>Descarca</a>" ++
        "<h1><a href=x>Jack Reacher (2022)</a></h1>[ Romana ]<a href=get.php?id=77>Descarca</a>" ++
        "<h1><a href=x>Reacher (2022)</a></h1>[ Romana ]<a href=get.php?id=88>Descarca</a>" ++
        "<h1><a href=x>Reacher (2022)</a></h1>[ Romana ]<a href=get.php?id=77>Descarca</a>";
    var response = try parseSearchHtml(arena, fixture, "Reacher");
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 3), response.items.len);
    try std.testing.expectEqualStrings("88", response.items[0].subtitle_id);
    try std.testing.expectEqualStrings("77", response.items[1].subtitle_id);
    try std.testing.expectEqualStrings("99", response.items[2].subtitle_id);
}

test "titrari rejects unsafe token and probe targets before fetch" {
    try validateProviderRoute(
        "https://www.titrari.ro/index.php?page=cautamainaltaparte&z10=77",
        .page,
        "77",
    );
    try validateProviderRoute("https://www.titrari.ro/get.php?id=77", .download, "77");
    for ([_][]const u8{
        "http://127.0.0.1/get.php?id=77",
        "https://user:pass@www.titrari.ro/get.php?id=77",
        "https://www.google.com/get.php?id=77",
        "https://www.titrari.ro/private?id=77",
        "https://www.titrari.ro/get.php?id=77&next=/private",
        "https://www.titrari.ro/get.php?id=77#fragment",
        "https://www.titrari.ro/get.php?id=%37%37",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderRoute(url, .download, "77"));
    }
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        validateProviderRoute("https://www.titrari.ro/get.php?id=78", .download, "77"),
    );
    for ([_][]const u8{
        "https://www.titrari.ro/index.php?page=cautamainaltaparte&z10=77&next=/private",
        "https://www.titrari.ro/index.php?page=other&z10=77",
        "https://www.titrari.ro/index.php?page=cautamainaltaparte&z10=%37%37",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderRoute(url, .page, "77"));
    }
}

test "titrari HEAD probe rejects an expired deadline before I/O" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    const item: SearchItem = .{
        .title = "fixture",
        .year = null,
        .media_kind = .movie,
        .language_code = "ro",
        .subtitle_id = "1",
        .page_url = site ++ "/",
        .download_url = site ++ "/get.php?id=1",
    };
    const now_ms = common.compatMilliTimestamp();
    try std.testing.expectError(
        error.Timeout,
        scraper.probeArchiveKind(std.testing.allocator, item, now_ms),
    );
}

test "titrari raw archive probe rejects ambiguous response framing" {
    for ([_][]const u8{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
    }) |raw_head| {
        const head = try std.http.Client.Response.Head.parse(raw_head);
        try std.testing.expectError(error.AmbiguousHttpFraming, validateRawArchiveProbeResponseHead(head));
    }
}

test "live titrari movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "titrari.ro")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix Resurrections");
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
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}
