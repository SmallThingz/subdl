const std = @import("std");
const common = @import("common.zig");
const unicode_letter_number = @import("unicode_letter_number.zig");

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
        return self.searchUsing(fetchPostWithStatusRetry, query);
    }

    fn searchUsing(self: *Scraper, comptime fetch_post: anytype, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        if (!hasMeaningfulSearchTerm(trimmed)) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;

        const encoded = try common.encodeUriComponent(a, trimmed);
        const payload = try std.fmt.allocPrint(a, "query={s}", .{encoded});
        const headers = [_]std.http.Header{
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
            .{ .name = "referer", .value = site ++ "/" },
        };
        const response = try fetch_post(self.client, a, site ++ "/search", payload, &headers, deadline_ms);

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const array = switch (root) {
            .array => |value| value,
            else => return error.InvalidFieldType,
        };

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
            const normalized = try common.normalizeTitle(a, base_title);
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
        return self.fetchSubtitlesBySearchItemUsing(common.fetchBytes, item);
    }

    fn fetchSubtitlesBySearchItemUsing(self: *Scraper, comptime fetch: anytype, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(item.page_url);

        const response = try fetch(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
        });
        if (response.status == .too_many_requests) return error.RateLimited;
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        const rows_json = (try extractRowsJson(self.allocator, response.body)) orelse return error.MissingField;
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
            // A malformed row must not abort the listing or reserve an ID
            // before a later complete candidate can supply its download token.
            if (!hasMetadataText(title) or !hasMetadataText(language)) continue;
            const row_url = common.jsonString(obj, "url") orelse continue;
            const row_id = rowId(row_url) orelse continue;
            if (seen.contains(row_id)) continue;
            try seen.put(a, try a.dupe(u8, row_id), {});

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
        const deadline_ms = common.compatMilliTimestamp() +| common.default_fetch_timeout_ms;

        const page = try common.fetchBytes(self.client, allocator, parts.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
            .deadline_ms = deadline_ms,
        });
        defer allocator.free(page.body);
        if (page.status == .too_many_requests) return error.RateLimited;
        if (page.status != .ok) return error.UnexpectedHttpStatus;
        const ttl = parsePageTtl(page.body) orelse return error.MissingField;
        if (!(try pageContainsDownloadRow(allocator, page.body, parts))) return error.InvalidDownloadUrl;

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
        const info = try fetchPostWithStatusRetry(self.client, allocator, site ++ "/subtitlesInfo", payload, &headers, deadline_ms);
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
        const download_url = try buildDownloadUrl(allocator, id, ttl, access_token, zip_name);
        defer allocator.free(download_url);

        const download = try common.fetchBytes(self.client, allocator, download_url, .{
            .accept = "application/zip,application/octet-stream,*/*",
            .extra_headers = &[_]std.http.Header{.{ .name = "referer", .value = parts.page_url }},
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
            .deadline_ms = deadline_ms,
        });
        if (download.status == .too_many_requests) {
            allocator.free(download.body);
            return error.RateLimited;
        }
        if (download.status != .ok) {
            allocator.free(download.body);
            return error.UnexpectedHttpStatus;
        }
        return download;
    }
};

fn validateProviderUrl(url: []const u8) !void {
    common.validatePublicHttpUrl(url) catch return error.InvalidDownloadUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
    if (!(common.sameOrigin(site, url) catch false)) return error.InvalidDownloadUrl;
    if (uri.query != null or uri.fragment != null) return error.InvalidDownloadUrl;

    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len == 0 or path[0] != '/' or path[path.len - 1] == '/') return error.InvalidDownloadUrl;
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidDownloadUrl, "subtitles")) {
        return error.InvalidDownloadUrl;
    }
    if (!isSafeEncodedSegment(segments.next() orelse return error.InvalidDownloadUrl)) {
        return error.InvalidDownloadUrl;
    }
    if (segments.next()) |season_segment| {
        const prefix = "season-";
        if (!std.mem.startsWith(u8, season_segment, prefix) or
            !isCanonicalPositiveId(season_segment[prefix.len..])) return error.InvalidDownloadUrl;
    }
    if (segments.next() != null) return error.InvalidDownloadUrl;
}

fn isCanonicalPositiveId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isSafeEncodedSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 512 or
        std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    var decoded_len: usize = 0;
    var decoded_all_dots = true;
    var index: usize = 0;
    while (index < segment.len) {
        const c = segment[index];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            decoded_len += 1;
            if (c != '.') decoded_all_dots = false;
            index += 1;
            continue;
        }
        if (c != '%' or segment.len - index < 3 or
            !std.ascii.isHex(segment[index + 1]) or !std.ascii.isHex(segment[index + 2])) return false;
        const decoded = std.fmt.parseInt(u8, segment[index + 1 .. index + 3], 16) catch return false;
        if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
            decoded == '?' or decoded == '#' or decoded == '%') return false;
        decoded_len += 1;
        if (decoded != '.') decoded_all_dots = false;
        index += 3;
    }
    return !(decoded_all_dots and decoded_len <= 2);
}

fn fetchPostWithStatusRetry(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    payload: []const u8,
    headers: []const std.http.Header,
    deadline_ms: i64,
) !common.HttpResponse {
    return fetchPostWithStatusRetryUsing(common.fetchBytes, common.sleepMillisecondsCancelable, client, allocator, url, payload, headers, deadline_ms);
}

fn fetchPostWithStatusRetryUsing(
    comptime fetch: anytype,
    comptime sleep: anytype,
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    payload: []const u8,
    headers: []const std.http.Header,
    deadline_ms: i64,
) !common.HttpResponse {
    const max_attempts: usize = 4;
    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (common.compatMilliTimestamp() >= deadline_ms) return error.Timeout;
        const response = fetch(client, allocator, url, .{
            .method = .POST,
            .payload = payload,
            .content_type = "application/x-www-form-urlencoded",
            .accept = "application/json, text/javascript, */*; q=0.01",
            .extra_headers = headers,
            .cache = false,
            .allow_non_ok = true,
            // This helper owns status retries. Keeping the transport helper to
            // one attempt prevents the two retry loops from multiplying POSTs.
            .max_attempts = 1,
            .retry_on_429 = false,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
            .deadline_ms = deadline_ms,
        }) catch |err| switch (err) {
            else => {
                if (common.mustNotRetryFetchError(err)) return err;
                if (attempt + 1 >= max_attempts) return err;
                try sleepBeforeDeadlineUsing(sleep, deadline_ms, @as(u64, 1000) << @intCast(@min(attempt, 2)));
                continue;
            },
        };
        if (response.status == .ok) return response;
        if (response.status == .too_many_requests) {
            allocator.free(response.body);
            return error.RateLimited;
        }

        const retry = isTransientStatus(response.status) and attempt + 1 < max_attempts;
        allocator.free(response.body);
        if (!retry) return error.UnexpectedHttpStatus;

        const code = @backingInt(response.status);
        const delay_ms: u64 = if (code == 403)
            5500
        else
            @as(u64, 1000) << @intCast(@min(attempt, 2));
        try sleepBeforeDeadlineUsing(sleep, deadline_ms, delay_ms);
    }
    return error.UnexpectedHttpStatus;
}

fn sleepBeforeDeadlineUsing(comptime sleep: anytype, deadline_ms: i64, requested_ms: u64) !void {
    const now_ms = common.compatMilliTimestamp();
    if (now_ms >= deadline_ms) return error.Timeout;
    const remaining_ms: u64 = @intCast(deadline_ms -| now_ms);
    try sleep(@min(requested_ms, remaining_ms));
    if (common.compatMilliTimestamp() >= deadline_ms) return error.Timeout;
}

fn isTransientStatus(status: std.http.Status) bool {
    const code = @backingInt(status);
    return code == 403 or
        code == 408 or
        code == 425 or
        (code >= 500 and code <= 504);
}

fn extractRowsJson(allocator: Allocator, body: []const u8) !?[]const u8 {
    const marker = "DataTable({ data: ";
    var scanner = JavascriptMarkerScanner.init(body, marker);
    var empty_candidate: ?[]const u8 = null;
    var saw_invalid_nonempty_candidate = false;
    while (scanner.next()) |match| {
        if (match.index > 0 and isJavascriptIdentifierByte(body[match.index - 1])) continue;
        const value_start = match.index + marker.len;
        const candidate = rowsJsonInAssignment(body[value_start..]) orelse continue;
        switch (try classifyRowsCandidate(allocator, candidate)) {
            .complete => return candidate,
            .empty => if (empty_candidate == null) {
                empty_candidate = candidate;
            },
            .malformed => saw_invalid_nonempty_candidate = true,
        }
    }
    // A later complete provider table wins above. Otherwise, an unrelated
    // empty table must not turn a changed or malformed provider schema into a
    // successful empty listing.
    if (saw_invalid_nonempty_candidate) return null;
    return empty_candidate;
}

fn rowsJsonInAssignment(assignment: []const u8) ?[]const u8 {
    const value = std.mem.trimStart(u8, assignment, " \t\r\n");
    if (value.len == 0 or value[0] != '[') return null;

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (value, 0..) |byte, index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }

        // An unquoted assignment marker cannot belong to this JSON value.
        // Stop here so malformed input does not consume the following table.
        if (std.mem.startsWith(u8, value[index..], "DataTable({ data: ")) return null;

        switch (byte) {
            '"' => in_string = true,
            '[', '{' => depth = std.math.add(usize, depth, 1) catch return null,
            ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth != 0) continue;
                if (byte != ']') return null;

                const suffix = std.mem.trimStart(u8, value[index + 1 ..], " \t\r\n");
                if (!hasCompleteDataTableSuffix(suffix)) return null;
                return value[0 .. index + 1];
            },
            else => {},
        }
    }
    return null;
}

const RowsCandidateKind = enum {
    empty,
    complete,
    malformed,
};

fn classifyRowsCandidate(allocator: Allocator, candidate: []const u8) !RowsCandidateKind {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, candidate, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .malformed,
    };
    defer parsed.deinit();
    const rows = switch (parsed.value) {
        .array => |value| value,
        else => return .malformed,
    };
    if (rows.items.len == 0) return .empty;

    for (rows.items) |entry| {
        const obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const title = common.jsonString(obj, "title") orelse continue;
        const language = common.jsonString(obj, "language") orelse continue;
        const row_url = common.jsonString(obj, "url") orelse continue;
        if (hasMetadataText(title) and hasMetadataText(language) and rowId(row_url) != null) {
            return .complete;
        }
    }
    return .malformed;
}

fn hasCompleteDataTableSuffix(suffix_untrimmed: []const u8) bool {
    const prefix = ", columns:";
    var suffix = std.mem.trimStart(u8, suffix_untrimmed, " \t\r\n");
    if (!std.mem.startsWith(u8, suffix, prefix)) return false;
    suffix = std.mem.trimStart(u8, suffix[prefix.len..], " \t\r\n");

    const columns_end = javascriptArrayExpressionEnd(suffix) orelse return false;
    var rest = std.mem.trimStart(u8, suffix[columns_end..], " \t\r\n");
    if (rest.len > 0 and rest[0] == ',') {
        rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    }
    if (rest.len == 0 or rest[0] != '}') return false;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    if (rest.len == 0 or rest[0] != ')') return false;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    return rest.len == 0 or rest[0] == ';' or std.ascii.startsWithIgnoreCase(rest, "</script");
}

fn javascriptArrayExpressionEnd(input: []const u8) ?usize {
    if (input.len == 0 or input[0] != '[') return null;

    const State = enum {
        code,
        single_quote,
        double_quote,
        template,
        regex,
        line_comment,
        block_comment,
    };
    var closing_stack: [128]u8 = undefined;
    var depth: usize = 0;
    var state: State = .code;
    var escaped = false;
    var regex_in_class = false;
    var regex_allowed = true;
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        switch (state) {
            .line_comment => {
                index += 1;
                if (byte == '\n' or byte == '\r') state = .code;
            },
            .block_comment => {
                if (byte == '*' and index + 1 < input.len and input[index + 1] == '/') {
                    state = .code;
                    index += 2;
                } else {
                    index += 1;
                }
            },
            .single_quote, .double_quote, .template => {
                const quote: u8 = switch (state) {
                    .single_quote => '\'',
                    .double_quote => '"',
                    .template => '`',
                    else => unreachable,
                };
                index += 1;
                if (escaped) {
                    escaped = false;
                } else if (byte == '\\') {
                    escaped = true;
                } else if (byte == quote) {
                    state = .code;
                } else if (quote != '`' and (byte == '\n' or byte == '\r')) {
                    return null;
                }
            },
            .regex => {
                index += 1;
                if (escaped) {
                    escaped = false;
                } else if (byte == '\\') {
                    escaped = true;
                } else if (byte == '[' and !regex_in_class) {
                    regex_in_class = true;
                } else if (byte == ']' and regex_in_class) {
                    regex_in_class = false;
                } else if (byte == '/' and !regex_in_class) {
                    state = .code;
                    regex_allowed = false;
                } else if (byte == '\n' or byte == '\r') {
                    return null;
                }
            },
            .code => {
                if (std.ascii.isWhitespace(byte)) {
                    index += 1;
                    continue;
                }
                if (byte == '/' and index + 1 < input.len) {
                    if (input[index + 1] == '/') {
                        state = .line_comment;
                        index += 2;
                        continue;
                    }
                    if (input[index + 1] == '*') {
                        state = .block_comment;
                        index += 2;
                        continue;
                    }
                }
                if (byte == '/') {
                    index += 1;
                    if (regex_allowed) {
                        state = .regex;
                        escaped = false;
                        regex_in_class = false;
                    } else {
                        // A division operator expects a right-hand expression.
                        regex_allowed = true;
                    }
                    continue;
                }
                if (byte == '\'' or byte == '"' or byte == '`') {
                    state = switch (byte) {
                        '\'' => .single_quote,
                        '"' => .double_quote,
                        '`' => .template,
                        else => unreachable,
                    };
                    escaped = false;
                    regex_allowed = false;
                    index += 1;
                    continue;
                }
                if (isJavascriptIdentifierByte(byte)) {
                    const start = index;
                    index += 1;
                    while (index < input.len and isJavascriptIdentifierByte(input[index])) index += 1;
                    regex_allowed = javascriptIdentifierAllowsRegexAfter(input[start..index]);
                    continue;
                }
                switch (byte) {
                    '[', '{', '(' => {
                        if (depth == closing_stack.len) return null;
                        closing_stack[depth] = switch (byte) {
                            '[' => ']',
                            '{' => '}',
                            '(' => ')',
                            else => unreachable,
                        };
                        depth += 1;
                        regex_allowed = true;
                    },
                    ']', '}', ')' => {
                        if (depth == 0 or closing_stack[depth - 1] != byte) return null;
                        depth -= 1;
                        if (depth == 0) return index + 1;
                        regex_allowed = false;
                    },
                    else => regex_allowed = javascriptPunctuationAllowsRegexAfter(byte),
                }
                index += 1;
            },
        }
    }
    return null;
}

fn javascriptIdentifierAllowsRegexAfter(identifier: []const u8) bool {
    inline for (.{
        "await",
        "case",
        "delete",
        "do",
        "else",
        "in",
        "instanceof",
        "new",
        "of",
        "return",
        "throw",
        "typeof",
        "void",
        "yield",
    }) |keyword| {
        if (std.mem.eql(u8, identifier, keyword)) return true;
    }
    return false;
}

fn javascriptPunctuationAllowsRegexAfter(byte: u8) bool {
    return switch (byte) {
        '(',
        '[',
        '{',
        '=',
        ':',
        ',',
        ';',
        '!',
        '?',
        '&',
        '|',
        '+',
        '-',
        '*',
        '%',
        '^',
        '~',
        '<',
        '>',
        => true,
        else => false,
    };
}

const JavascriptMarkerScanner = struct {
    const State = enum {
        html,
        code,
        single_quote,
        double_quote,
        template,
        regex,
        line_comment,
        block_comment,
    };

    const Match = struct {
        index: usize,
        previous_code_byte: ?u8,
    };

    body: []const u8,
    marker: []const u8,
    cursor: usize = 0,
    state: State = .html,
    escaped: bool = false,
    regex_in_class: bool = false,
    regex_allowed: bool = true,
    previous_code_byte: ?u8 = null,

    fn init(body: []const u8, marker: []const u8) @This() {
        return .{ .body = body, .marker = marker };
    }

    fn next(self: *@This()) ?Match {
        while (self.cursor < self.body.len) {
            if (self.state == .html) {
                if (std.mem.startsWith(u8, self.body[self.cursor..], "<!--")) {
                    const comment_end = std.mem.indexOfPos(u8, self.body, self.cursor + "<!--".len, "-->") orelse return null;
                    self.cursor = comment_end + "-->".len;
                    continue;
                }
                if (self.body[self.cursor] == '<' and
                    std.ascii.startsWithIgnoreCase(self.body[self.cursor..], "<script"))
                {
                    const name_end = self.cursor + "<script".len;
                    if (name_end < self.body.len and !isHtmlTagBoundary(self.body[name_end])) {
                        self.cursor = name_end;
                        continue;
                    }
                    const tag_end = findHtmlTagEnd(self.body, name_end) orelse return null;
                    self.cursor = tag_end + 1;
                    self.state = .code;
                    self.escaped = false;
                    self.regex_in_class = false;
                    self.regex_allowed = true;
                    self.previous_code_byte = null;
                    continue;
                }
                if (self.body[self.cursor] == '<') {
                    const tag_end = findHtmlTagEnd(self.body, self.cursor + 1) orelse return null;
                    self.cursor = tag_end + 1;
                } else {
                    self.cursor += 1;
                }
                continue;
            }

            if (startsWithHtmlCloseScript(self.body[self.cursor..])) {
                const name_end = self.cursor + "</script".len;
                const tag_end = findHtmlTagEnd(self.body, name_end) orelse return null;
                self.cursor = tag_end + 1;
                self.state = .html;
                self.escaped = false;
                self.regex_in_class = false;
                self.regex_allowed = true;
                self.previous_code_byte = null;
                continue;
            }

            const byte = self.body[self.cursor];
            switch (self.state) {
                .html => unreachable,
                .code => {
                    if (std.mem.startsWith(u8, self.body[self.cursor..], self.marker)) {
                        const result: Match = .{
                            .index = self.cursor,
                            .previous_code_byte = self.previous_code_byte,
                        };
                        for (self.marker) |marker_byte| {
                            if (std.ascii.isWhitespace(marker_byte)) continue;
                            self.previous_code_byte = marker_byte;
                            self.regex_allowed = if (isJavascriptIdentifierByte(marker_byte))
                                false
                            else
                                javascriptPunctuationAllowsRegexAfter(marker_byte);
                        }
                        self.cursor += self.marker.len;
                        return result;
                    }
                    if (byte == '/' and self.cursor + 1 < self.body.len) {
                        if (self.body[self.cursor + 1] == '/') {
                            self.cursor += 2;
                            self.state = .line_comment;
                            continue;
                        }
                        if (self.body[self.cursor + 1] == '*') {
                            self.cursor += 2;
                            self.state = .block_comment;
                            continue;
                        }
                    }
                    if (byte == '/') {
                        self.cursor += 1;
                        if (self.regex_allowed) {
                            self.state = .regex;
                            self.escaped = false;
                            self.regex_in_class = false;
                        } else {
                            self.previous_code_byte = '/';
                            self.regex_allowed = true;
                        }
                        continue;
                    }
                    if (isJavascriptIdentifierByte(byte)) {
                        const start = self.cursor;
                        self.cursor += 1;
                        while (self.cursor < self.body.len and isJavascriptIdentifierByte(self.body[self.cursor])) {
                            self.cursor += 1;
                        }
                        const identifier = self.body[start..self.cursor];
                        self.previous_code_byte = identifier[identifier.len - 1];
                        self.regex_allowed = javascriptIdentifierAllowsRegexAfter(identifier);
                        continue;
                    }
                    switch (byte) {
                        '\'' => self.state = .single_quote,
                        '"' => self.state = .double_quote,
                        '`' => self.state = .template,
                        else => {
                            if (!std.ascii.isWhitespace(byte)) {
                                self.previous_code_byte = byte;
                                self.regex_allowed = javascriptPunctuationAllowsRegexAfter(byte);
                            }
                        },
                    }
                    if (self.state != .code) {
                        self.previous_code_byte = byte;
                        self.escaped = false;
                        self.regex_allowed = false;
                    }
                    self.cursor += 1;
                },
                .single_quote, .double_quote, .template => {
                    const quote: u8 = switch (self.state) {
                        .single_quote => '\'',
                        .double_quote => '"',
                        .template => '`',
                        else => unreachable,
                    };
                    self.cursor += 1;
                    if (self.escaped) {
                        self.escaped = false;
                    } else if (byte == '\\') {
                        self.escaped = true;
                    } else if (byte == quote) {
                        self.state = .code;
                    } else if (quote != '`' and (byte == '\n' or byte == '\r')) {
                        self.state = .code;
                    }
                },
                .regex => {
                    self.cursor += 1;
                    if (self.escaped) {
                        self.escaped = false;
                    } else if (byte == '\\') {
                        self.escaped = true;
                    } else if (byte == '[' and !self.regex_in_class) {
                        self.regex_in_class = true;
                    } else if (byte == ']' and self.regex_in_class) {
                        self.regex_in_class = false;
                    } else if (byte == '/' and !self.regex_in_class) {
                        self.state = .code;
                        self.previous_code_byte = '/';
                        self.regex_allowed = false;
                    } else if (byte == '\n' or byte == '\r') {
                        // Recover at an invalid unterminated literal so a later
                        // script statement can still be inspected.
                        self.state = .code;
                        self.previous_code_byte = null;
                        self.regex_allowed = true;
                        self.regex_in_class = false;
                    }
                },
                .line_comment => {
                    self.cursor += 1;
                    if (byte == '\n' or byte == '\r') self.state = .code;
                },
                .block_comment => {
                    if (byte == '*' and self.cursor + 1 < self.body.len and self.body[self.cursor + 1] == '/') {
                        self.cursor += 2;
                        self.state = .code;
                    } else {
                        self.cursor += 1;
                    }
                },
            }
        }
        return null;
    }
};

fn isHtmlTagBoundary(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '>' or byte == '/';
}

fn startsWithHtmlCloseScript(input: []const u8) bool {
    const tag = "</script";
    return std.ascii.startsWithIgnoreCase(input, tag) and
        (input.len == tag.len or isHtmlTagBoundary(input[tag.len]));
}

fn findHtmlTagEnd(input: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var index = start;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (quote != 0) {
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') {
            return index;
        }
    }
    return null;
}

fn parsePageTtl(body: []const u8) ?i64 {
    const marker = "ttl";
    const max_i64_digits = 19;
    var scanner = JavascriptMarkerScanner.init(body, marker);
    while (scanner.next()) |match| {
        const value_start = match.index + marker.len;
        if (match.index > 0 and isJavascriptIdentifierByte(body[match.index - 1])) continue;
        if (value_start < body.len and isJavascriptIdentifierByte(body[value_start])) continue;
        if (!hasJavascriptVariableDeclarationPrefix(body, match.index)) continue;

        var tail_start = value_start;
        if (!skipJavascriptTriviaForward(body, &tail_start)) continue;
        if (tail_start >= body.len or body[tail_start] != '=') continue;
        tail_start += 1;
        if (tail_start < body.len and (body[tail_start] == '=' or body[tail_start] == '>')) continue;
        if (!skipJavascriptTriviaForward(body, &tail_start)) continue;
        const tail = body[tail_start..];
        var end: usize = 0;
        while (end < tail.len and end < max_i64_digits and std.ascii.isDigit(tail[end])) : (end += 1) {}
        if (end == 0 or tail[0] == '0' or (end < tail.len and std.ascii.isDigit(tail[end]))) continue;

        var terminator = tail_start + end;
        if (!skipJavascriptTriviaForward(body, &terminator)) continue;
        if (terminator >= body.len or body[terminator] != ';') continue;

        return std.fmt.parseInt(i64, tail[0..end], 10) catch continue;
    }
    return null;
}

fn hasJavascriptVariableDeclarationPrefix(body: []const u8, identifier_start: usize) bool {
    var cursor = identifier_start;
    const original = cursor;
    if (!skipJavascriptTriviaBackward(body, &cursor)) return false;
    if (cursor == original) return false;

    for ([_][]const u8{ "let", "const", "var" }) |keyword| {
        if (cursor < keyword.len) continue;
        const start = cursor - keyword.len;
        if (!std.mem.eql(u8, body[start..cursor], keyword)) continue;
        if (start > 0 and isJavascriptIdentifierByte(body[start - 1])) continue;
        return true;
    }
    return false;
}

fn skipJavascriptTriviaForward(body: []const u8, cursor: *usize) bool {
    while (cursor.* < body.len) {
        if (std.ascii.isWhitespace(body[cursor.*])) {
            cursor.* += 1;
            continue;
        }
        if (cursor.* + 1 >= body.len or body[cursor.*] != '/') return true;
        if (body[cursor.* + 1] == '/') {
            cursor.* += 2;
            while (cursor.* < body.len and body[cursor.*] != '\n' and body[cursor.*] != '\r') cursor.* += 1;
            continue;
        }
        if (body[cursor.* + 1] != '*') return true;
        const end = std.mem.indexOfPos(u8, body, cursor.* + 2, "*/") orelse return false;
        cursor.* = end + 2;
    }
    return true;
}

fn skipJavascriptTriviaBackward(body: []const u8, cursor: *usize) bool {
    while (cursor.* > 0) {
        if (std.ascii.isWhitespace(body[cursor.* - 1])) {
            cursor.* -= 1;
            continue;
        }
        if (cursor.* < 2 or !std.mem.eql(u8, body[cursor.* - 2 .. cursor.*], "*/")) return true;
        const start = std.mem.lastIndexOf(u8, body[0 .. cursor.* - 2], "/*") orelse return false;
        cursor.* = start;
    }
    return true;
}

fn isJavascriptIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte >= 0x80;
}

fn pageContainsDownloadRow(allocator: Allocator, body: []const u8, parts: DownloadToken) !bool {
    const rows_json = (try extractRowsJson(allocator, body)) orelse return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rows_json, .{});
    defer parsed.deinit();
    const rows = switch (parsed.value) {
        .array => |value| value,
        else => return false,
    };

    for (rows.items) |entry| {
        const obj = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const title = common.jsonString(obj, "title") orelse continue;
        const language = common.jsonString(obj, "language") orelse continue;
        const row_url = common.jsonString(obj, "url") orelse continue;
        if (std.mem.eql(u8, row_url, parts.row_url) and
            std.mem.eql(u8, language, parts.language) and
            std.mem.eql(u8, title, parts.title))
        {
            return true;
        }
    }
    return false;
}

fn rowId(row_url: []const u8) ?[]const u8 {
    var segments = std.mem.splitScalar(u8, row_url, '/');
    const title = segments.next() orelse return null;
    const language = segments.next() orelse return null;
    const id = segments.next() orelse return null;
    if (segments.next() != null or
        !isSafeEncodedSegment(title) or
        !isSafeEncodedSegment(language) or
        !isCanonicalPositiveId(id)) return null;
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

fn buildDownloadUrl(
    allocator: Allocator,
    id: []const u8,
    ttl: i64,
    access_token: []const u8,
    zip_name: []const u8,
) ![]u8 {
    if (access_token.len == 0 or zip_name.len == 0) return error.MissingField;

    const token_segment = try common.encodeUriComponent(allocator, access_token);
    defer allocator.free(token_segment);
    const filename_segment = try common.encodeUriComponent(allocator, zip_name);
    defer allocator.free(filename_segment);
    return std.fmt.allocPrint(
        allocator,
        "{s}/d/{s}/{d}/{s}/{s}.zip",
        .{ site, id, ttl, token_segment, filename_segment },
    );
}

pub fn makeDownloadToken(
    allocator: Allocator,
    page_url: []const u8,
    row_url: []const u8,
    language: []const u8,
    title: []const u8,
) ![]u8 {
    if (page_url.len == 0 or rowId(row_url) == null or language.len == 0 or title.len == 0) {
        return error.InvalidDownloadUrl;
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}v1:{d}:{s}{d}:{s}{d}:{s}{d}:{s}",
        .{
            download_token_prefix,
            page_url.len,
            page_url,
            row_url.len,
            row_url,
            language.len,
            language,
            title.len,
            title,
        },
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
    if (!std.mem.startsWith(u8, payload, "v1:")) return null;
    var cursor: usize = "v1:".len;
    const page_url = takeTokenField(payload, &cursor) orelse return null;
    const row_url = takeTokenField(payload, &cursor) orelse return null;
    const language = takeTokenField(payload, &cursor) orelse return null;
    const title = takeTokenField(payload, &cursor) orelse return null;
    if (cursor != payload.len or page_url.len == 0 or rowId(row_url) == null or language.len == 0 or title.len == 0) return null;
    return .{
        .page_url = page_url,
        .row_url = row_url,
        .language = language,
        .title = title,
    };
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

fn titleWithoutYear(title: []const u8) []const u8 {
    if (title.len < 7 or title[title.len - 1] != ')') return title;
    const open = title.len - 6;
    if (title[open] != '(') return title;
    for (title[open + 1 .. title.len - 1]) |c| if (!std.ascii.isDigit(c)) return title;
    return std.mem.trimEnd(u8, title[0..open], " ");
}

fn hasMetadataText(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

fn hasMeaningfulSearchTerm(input: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(input)) return false;
    var index: usize = 0;
    while (index < input.len) {
        const first = input[index];
        if (first < 0x80) {
            if (std.ascii.isAlphanumeric(first)) return true;
            index += 1;
            continue;
        }

        const width = std.unicode.utf8ByteSequenceLength(first) catch return false;
        if (width > input.len - index) return false;
        const codepoint = std.unicode.utf8Decode(input[index..][0..width]) catch return false;
        if (unicode_letter_number.contains(codepoint)) return true;
        index += width;
    }
    return false;
}

test "indexsubtitle extracts embedded rows and ttl" {
    const body =
        \\<script>$('#example').DataTable({ data: [{"title":"The.Matrix.1999.1080p","language":"english","author":{"name":"A","url":null},"comment":"ok","url":"the-matrix-1999/english/657711"}], columns: [{data:'title'}] }); let ttl = 1790576999;</script>
    ;
    const rows = (try extractRowsJson(std.testing.allocator, body)).?;
    try std.testing.expect(std.mem.startsWith(u8, rows, "[{"));
    try std.testing.expectEqual(@as(?i64, 1790576999), parsePageTtl(body));
    try std.testing.expectEqualStrings("657711", rowId("the-matrix-1999/english/657711").?);
}

test "indexsubtitle skips malformed DataTable assignments before valid rows" {
    const expected =
        "[{\"title\":\"Valid\",\"language\":\"English\",\"url\":\"valid/english/1\"," ++
        "\"comment\":\"literal , columns: text\"}]";
    const body =
        "<!-- <script>DataTable({ data: " ++
        "[{\"title\":\"HTML comment\",\"language\":\"English\",\"url\":\"comment/english/9\"}]," ++
        " columns: [] });</script> -->" ++
        "<script>FakeDataTable({ data: " ++
        "[{\"title\":\"Identifier suffix\",\"language\":\"English\",\"url\":\"identifier/english/10\"}]," ++
        " columns: [] });</script>" ++
        "<script>const quoted = \"DataTable({ data: [], columns: [] });\";" ++
        "// DataTable({ data: [], columns: [] });\n" ++
        "/* DataTable({ data: [], columns: [] }); */" ++
        "DataTable({ data: [], columns:</script>" ++
        "<script>DataTable({ data: " ++
        "[{\"title\":\"Bad suffix\",\"language\":\"English\",\"url\":\"bad-suffix/english/8\"}]," ++
        " columns: [({)}] });</script>" ++
        "<script>DataTable({ data: [], columns: [] });</script>" ++
        "<script>DataTable({ data: " ++ expected ++ ", columns: [] });</script>";

    const rows = (try extractRowsJson(std.testing.allocator, body)).?;
    try std.testing.expectEqualStrings(expected, rows);
}

test "indexsubtitle preserves a sole complete empty DataTable" {
    const body = "<script>DataTable({ data: [], columns: [] });</script>";
    const rows = (try extractRowsJson(std.testing.allocator, body)).?;
    try std.testing.expectEqualStrings("[]", rows);
}

test "indexsubtitle does not let an empty table mask a malformed nonempty table" {
    const body =
        "<script>DataTable({ data: [], columns: [] });" ++
        "DataTable({ data: [" ++
        "{\"title\":\"\",\"language\":\"English\",\"url\":\"movie/english/1\"}," ++
        "{\"title\":\"Movie\",\"language\":\"\",\"url\":\"movie/english/2\"}" ++
        "], columns: [] });</script>";

    try std.testing.expect((try extractRowsJson(std.testing.allocator, body)) == null);
}

test "indexsubtitle malformed JSON invalidates only the empty fallback" {
    const empty_then_malformed =
        "<script>DataTable({ data: [], columns: [] });" ++
        "DataTable({ data: " ++
        "[{\"title\":undefined,\"language\":\"English\",\"url\":\"broken/english/1\"}]," ++
        " columns: [] });</script>";
    try std.testing.expect((try extractRowsJson(std.testing.allocator, empty_then_malformed)) == null);

    const expected =
        "[{\"title\":\"Valid\",\"language\":\"English\",\"url\":\"valid/english/2\"}]";
    const malformed_then_valid = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}<script>DataTable({{ data: {s}, columns: [] }});</script>",
        .{ empty_then_malformed, expected },
    );
    defer std.testing.allocator.free(malformed_then_valid);

    const rows = (try extractRowsJson(std.testing.allocator, malformed_then_valid)).?;
    try std.testing.expectEqualStrings(expected, rows);
}

test "indexsubtitle ignores regex decoys but accepts a DataTable division operand" {
    const expected =
        "[{\"title\":\"Valid\",\"language\":\"English\",\"url\":\"valid/english/1\"}]";
    const body =
        "<script>const decoy = /prefix\\/[a\\/]DataTable({ data: " ++
        "[{\"title\":\"Regex\",\"language\":\"English\",\"url\":\"regex\\/english\\/9\"}]," ++
        " columns: [] });/;" ++
        "const quotient = value / DataTable({ data: " ++ expected ++
        ", columns: [{ render: value => /[a\\/]+/.test(value) }] });</script>";

    const rows = (try extractRowsJson(std.testing.allocator, body)).?;
    try std.testing.expectEqualStrings(expected, rows);
}

test "indexsubtitle DataTable validation preserves allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        extractRowsJson(failing.allocator(), "<script>DataTable({ data: [], columns: [] });</script>"),
    );
}

test "indexsubtitle skips malformed ttl assignments before a valid ttl" {
    const body =
        "<script>const quoted = \"ttl = 1;\"; const single = 'ttl = 2;'; " ++
        "const template = `ttl = 3;`; // ttl = 4;\n/* ttl = 5; */ " ++
        "config.ttl = 6; config /* gap */ . /* gap */ ttl = 7; " ++
        "this.#ttl = 8; let attl = 9; function f(ttl = 10) {} " ++
        "const { ttl = 11 } = config; let ttl = 0; let ttl = 01; " ++
        "let ttl = 123oops; let ttl = 9223372036854775808; " ++
        "let ttl = 1790576999;</script>";

    try std.testing.expectEqual(@as(?i64, 1790576999), parsePageTtl(body));
    try std.testing.expectEqual(@as(?i64, null), parsePageTtl("<script>ttl = 123oops;</script>"));
    try std.testing.expectEqual(@as(?i64, null), parsePageTtl("<script>attl = 123;</script>"));
    try std.testing.expectEqual(@as(?i64, null), parsePageTtl("<script>ttl = 123</script>"));
    try std.testing.expectEqual(@as(?i64, 42), parsePageTtl("<script>const /* key */ ttl /* equals */ = /* value */ 42;</script>"));
    try std.testing.expectEqual(@as(?i64, 43), parsePageTtl("<script>var ttl = 43;</script>"));
}

test "indexsubtitle rejects noncanonical row ids before token emission" {
    for ([_][]const u8{
        "/the-matrix-1999/english/1",
        "prefix/extra/english/1",
        "../english/1",
        "the-matrix-1999/english\r\n/1",
        "the-matrix-1999/english/1?next=/admin",
        "the-matrix-1999/english/0",
        "the-matrix-1999/english/01",
        "the-matrix-1999/english/not-an-id",
        "the-matrix-1999/english/12345678901234567890",
    }) |row_url| {
        try std.testing.expect(rowId(row_url) == null);
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            makeDownloadToken(std.testing.allocator, site ++ "/subtitles/the-matrix-1999", row_url, "english", "The Matrix"),
        );
    }
    try std.testing.expectEqualStrings("1", rowId("the-matrix-1999/english/1").?);
}

test "indexsubtitle deduplicates canonical rows by subtitle id" {
    const Fixture = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) !common.HttpResponse {
            try std.testing.expectEqualStrings(site ++ "/subtitles/the-matrix-1999", url);
            return .{
                .status = .ok,
                .body = try allocator.dupe(
                    u8,
                    "<script>DataTable({ data: " ++
                        "[{\"title\":\"Invalid prefix\",\"language\":\"English\",\"url\":\"bad\\r\\nprefix/english/9\"}," ++
                        "{\"title\":\"First\",\"language\":\"English\",\"url\":\"the-matrix-1999/english/1\"}," ++
                        "{\"title\":\"Duplicate id\",\"language\":\"French\",\"url\":\"other-title/french/1\"}," ++
                        "{\"title\":\"Second\",\"language\":\"Spanish\",\"url\":\"the-matrix-1999/spanish/2\"}]," ++
                        " columns: [] });</script>",
                ),
            };
        }
    };

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
        .title = "The Matrix",
        .page_url = site ++ "/subtitles/the-matrix-1999",
    });
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.subtitles.len);
    try std.testing.expectEqualStrings("First", response.subtitles[0].title);
    try std.testing.expectEqualStrings("the-matrix-1999/english/1", response.subtitles[0].row_url);
    try std.testing.expectEqualStrings("Second", response.subtitles[1].title);
}

test "indexsubtitle rejects punctuation-only searches but posts Unicode titles" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetchPost(
            client: *std.http.Client,
            allocator: Allocator,
            _: []const u8,
            _: []const u8,
            _: []const std.http.Header,
            _: i64,
        ) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return .{
                .status = .ok,
                .body = try allocator.dupe(
                    u8,
                    "[{\"title\":\"\\u5b57\\u5e55 (1950)\",\"url\":\"/subtitles/subtitles-1950\"}]",
                ),
            };
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchUsing(Fixture.fetchPost, "---");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), response.items.len);

    var unicode_punctuation = try scraper.searchUsing(Fixture.fetchPost, "\u{2014} \u{2026}");
    defer unicode_punctuation.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), unicode_punctuation.items.len);

    var unicode_format = try scraper.searchUsing(Fixture.fetchPost, "\u{feff} \u{061c} \u{180e}");
    defer unicode_format.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), unicode_format.items.len);
    try std.testing.expect(!hasMeaningfulSearchTerm(&.{ 0xff, 'A' }));

    var unicode_title = try scraper.searchUsing(Fixture.fetchPost, "\u{5b57}\u{5e55}");
    defer unicode_title.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), unicode_title.items.len);
    try std.testing.expectEqualStrings("\u{5b57}\u{5e55} (1950)", unicode_title.items[0].title);
}

test "indexsubtitle binds a download token to one fresh page row" {
    const body =
        "<script>let ttl = 1790576999; DataTable({ data: " ++
        "[{\"title\":\"Right title\",\"language\":\"English\",\"url\":\"movie/right/1\"}," ++
        "{\"title\":\"Other title\",\"language\":\"Spanish\",\"url\":\"movie/other/2\"}], columns: [] });</script>";

    try std.testing.expect(try pageContainsDownloadRow(std.testing.allocator, body, .{
        .page_url = site ++ "/movie/right",
        .row_url = "movie/right/1",
        .language = "English",
        .title = "Right title",
    }));
    try std.testing.expect(!(try pageContainsDownloadRow(std.testing.allocator, body, .{
        .page_url = site ++ "/movie/right",
        .row_url = "movie/right/1",
        .language = "Spanish",
        .title = "Other title",
    })));
}

test "indexsubtitle keeps token and filename in canonical path segments" {
    const url = try buildDownloadUrl(
        std.testing.allocator,
        "657711",
        1790576999,
        "token/?#%\\\r\n",
        "name/?#%\\\r\n",
    );
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://indexsubtitle.cc/d/657711/1790576999/token%2F%3F%23%25%5C%0D%0A/name%2F%3F%23%25%5C%0D%0A.zip",
        url,
    );
    try std.testing.expect(std.mem.indexOfAny(u8, url, "?#\\\r\n") == null);
}

test "indexsubtitle download token round trips delimiter and control bytes outside row route" {
    const page_url = "https://indexsubtitle.cc/movie|part?note=line%0D%0A";
    const row_url = "movie-part/english/657711";
    const language = "english|alternate\r\n";
    const title = "Movie|Title\r\nEdition";
    const token = try makeDownloadToken(std.testing.allocator, page_url, row_url, language, title);
    defer std.testing.allocator.free(token);

    const parsed = parseDownloadToken(token).?;
    try std.testing.expectEqualStrings(page_url, parsed.page_url);
    try std.testing.expectEqualStrings(row_url, parsed.row_url);
    try std.testing.expectEqualStrings(language, parsed.language);
    try std.testing.expectEqualStrings(title, parsed.title);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "page|row|language|title") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "v1:01:a1:b1:c1:d") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "v1:1:a1:b1:c2:d") == null);
}

test "indexsubtitle rejects non-provider page targets" {
    try validateProviderUrl("https://indexsubtitle.cc/subtitles/the-matrix-1999");
    try validateProviderUrl("https://indexsubtitle.cc/subtitles/mobland-2025/season-2");
    try validateProviderUrl("https://indexsubtitle.cc/subtitles/caf%C3%A9");
    for ([_][]const u8{
        "http://127.0.0.1/subtitles/the-matrix-1999",
        "https://indexsubtitle.cc.example/subtitles/the-matrix-1999",
        "https://user@indexsubtitle.cc/subtitles/the-matrix-1999",
        "https://indexsubtitle.cc/subtitles/the-matrix-1999?next=/d/1",
        "https://indexsubtitle.cc/subtitles/a%252fb",
        "https://indexsubtitle.cc/subtitles/%2e%2E",
        "https://indexsubtitle.cc/subtitles/show/season-0",
        "https://indexsubtitle.cc/subtitles/show/season-2/extra",
        "https://indexsubtitle.cc/subtitlesInfo",
    }) |url| {
        try std.testing.expectError(error.InvalidDownloadUrl, validateProviderUrl(url));
    }
}

test "indexsubtitle retries transient search statuses" {
    try std.testing.expect(isTransientStatus(.forbidden));
    try std.testing.expect(!isTransientStatus(.too_many_requests));
    try std.testing.expect(isTransientStatus(.service_unavailable));
    try std.testing.expect(!isTransientStatus(.not_found));
}

test "indexsubtitle treats rate limits as a single terminal POST" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expectEqual(@as(usize, 1), options.max_attempts);
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expect(options.require_https);
            try std.testing.expect(options.require_same_origin);
            return .{ .status = .too_many_requests, .body = try allocator.dupe(u8, "limited") };
        }

        fn noSleep(_: u64) !void {}
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    try std.testing.expectError(error.RateLimited, fetchPostWithStatusRetryUsing(
        Fixture.fetch,
        Fixture.noSleep,
        &fixture.client,
        std.testing.allocator,
        site ++ "/search",
        "query=matrix",
        &.{},
        std.math.maxInt(i64),
    ));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "indexsubtitle preserves terminal transport errors without retrying" {
    const Fixture = struct {
        client: std.http.Client,
        failure: anyerror,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return self.failure;
        }

        fn noSleep(_: u64) !void {}
    };

    inline for (.{
        error.Canceled,
        error.OutOfMemory,
        error.UnsafeHttpTarget,
        error.InvalidDownloadUrl,
        error.UnsupportedCompressionMethod,
        error.TooManyCompressedMembers,
        error.ResponseTooLarge,
        error.UnexpectedEncodedPayload,
    }) |failure| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .failure = failure,
        };
        defer fixture.client.deinit();
        try std.testing.expectError(failure, fetchPostWithStatusRetryUsing(
            Fixture.fetch,
            Fixture.noSleep,
            &fixture.client,
            std.testing.allocator,
            site ++ "/search",
            "query=matrix",
            &.{},
            std.math.maxInt(i64),
        ));
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    }
}

test "indexsubtitle cancellation during POST backoff prevents another request" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.ConnectionResetByPeer;
        }

        fn cancel(_: u64) !void {
            return error.Canceled;
        }
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    try std.testing.expectError(error.Canceled, fetchPostWithStatusRetryUsing(
        Fixture.fetch,
        Fixture.cancel,
        &fixture.client,
        std.testing.allocator,
        site ++ "/search",
        "query=matrix",
        &.{},
        std.math.maxInt(i64),
    ));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "indexsubtitle POST retry rejects an expired deadline before I/O" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.UnexpectedHttpStatus;
        }

        fn noSleep(_: u64) !void {}
    };

    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    try std.testing.expectError(error.Timeout, fetchPostWithStatusRetryUsing(
        Fixture.fetch,
        Fixture.noSleep,
        &fixture.client,
        std.testing.allocator,
        site ++ "/search",
        "query=matrix",
        &.{},
        common.compatMilliTimestamp(),
    ));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
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

test "indexsubtitle empty metadata candidates do not abort or shadow valid rows" {
    const Fixture = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{
                .status = .ok,
                .body = try allocator.dupe(u8,
                    \\<script>DataTable({ data: [
                    \\{"title":"","language":"English","url":"the-matrix-1999/english/1"},
                    \\{"title":"The Matrix","language":"","url":"the-matrix-1999/english/2"},
                    \\{"title":" \t ","language":"English","url":"the-matrix-1999/english/3"},
                    \\{"title":"The Matrix","language":" \r\n ","url":"the-matrix-1999/english/4"},
                    \\{"title":"Valid English","language":"English","url":"the-matrix-1999/english/1"},
                    \\{"title":"Valid Spanish","language":"Spanish","url":"the-matrix-1999/spanish/2"},
                    \\{"title":"Valid French","language":"French","url":"the-matrix-1999/french/3"},
                    \\{"title":"Valid German","language":"German","url":"the-matrix-1999/german/4"}
                    \\], columns: [] });</script>
                ),
            };
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.fetchSubtitlesBySearchItemUsing(Fixture.fetch, .{
        .title = "The Matrix",
        .page_url = site ++ "/subtitles/the-matrix-1999",
    });
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 4), response.subtitles.len);
    try std.testing.expectEqualStrings("Valid English", response.subtitles[0].title);
    try std.testing.expectEqualStrings("Valid Spanish", response.subtitles[1].title);
    try std.testing.expectEqualStrings("Valid French", response.subtitles[2].title);
    try std.testing.expectEqualStrings("Valid German", response.subtitles[3].title);
    for (response.subtitles) |subtitle| {
        const token = parseDownloadToken(subtitle.download_url) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(subtitle.row_url, token.row_url);
        try std.testing.expectEqualStrings(subtitle.language, token.language);
        try std.testing.expectEqualStrings(subtitle.title, token.title);
    }
}

test "indexsubtitle preserves DataTable markers inside JSON strings during recovery" {
    const expected =
        \\[{"title":"The Matrix","language":"English","url":"the-matrix-1999/english/1","comment":"literal DataTable({ data: text"}]
    ;
    for ([_][]const u8{
        "",
        "<script>DataTable({ data: [{\"title\":\"broken\"}, columns: [] });</script>",
        "<script>DataTable({ data: [{\"title\":\"unterminated DataTable({ data: broken</script>",
    }) |prefix| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{s}<script>DataTable({{ data: {s}, columns: [] }});</script>", .{ prefix, expected });
        defer std.testing.allocator.free(body);
        const rows = (try extractRowsJson(std.testing.allocator, body)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected, rows);
    }
}
