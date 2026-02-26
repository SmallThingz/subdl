const std = @import("std");
const html = @import("htmlparser");

pub const Allocator = std.mem.Allocator;

pub const default_user_agent = "subdl-zig-scrapers/0.2 (+https://subdl.com)";

pub const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
};

pub const FetchOptions = struct {
    method: std.http.Method = .GET,
    payload: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    allow_non_ok: bool = false,
    max_attempts: usize = 1,
    retry_initial_backoff_ms: u64 = 200,
    retry_on_429: bool = true,
};

pub const ParsedHtml = struct {
    allocator: Allocator,
    source: []u8,
    doc: html.Document,

    pub fn deinit(self: *ParsedHtml) void {
        self.doc.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }
};

fn debugTimingEnabled() bool {
    const value = std.posix.getenv("SCRAPERS_DEBUG_TIMING") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

pub fn fetchBytes(client: *std.http.Client, allocator: Allocator, url: []const u8, opts: FetchOptions) !HttpResponse {
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        var writer = std.Io.Writer.Allocating.init(allocator);
        errdefer writer.deinit();

        var header_buf: [16]std.http.Header = undefined;
        var header_len: usize = 0;
        if (opts.accept) |accept| {
            header_buf[header_len] = .{ .name = "accept", .value = accept };
            header_len += 1;
        }
        if (opts.content_type) |content_type| {
            header_buf[header_len] = .{ .name = "content-type", .value = content_type };
            header_len += 1;
        }
        if (!hasHeader(opts.extra_headers, "user-agent")) {
            header_buf[header_len] = .{ .name = "user-agent", .value = default_user_agent };
            header_len += 1;
        }
        for (opts.extra_headers) |h| {
            if (header_len >= header_buf.len) return error.OutOfMemory;
            header_buf[header_len] = h;
            header_len += 1;
        }

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = opts.method,
            .payload = opts.payload,
            .extra_headers = header_buf[0..header_len],
            .response_writer = &writer.writer,
        }) catch |err| {
            if (attempts + 1 < opts.max_attempts) {
                sleepBackoff(opts.retry_initial_backoff_ms, attempts);
                continue;
            }
            return err;
        };

        const body = try writer.toOwnedSlice();
        if (result.status == .too_many_requests and opts.retry_on_429 and attempts + 1 < opts.max_attempts) {
            allocator.free(body);
            sleepBackoff(opts.retry_initial_backoff_ms, attempts);
            continue;
        }

        if (!opts.allow_non_ok and result.status != .ok) {
            allocator.free(body);
            return error.UnexpectedHttpStatus;
        }

        return .{ .status = result.status, .body = body };
    }
}

fn hasHeader(headers: []const std.http.Header, wanted_name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, wanted_name)) return true;
    }
    return false;
}

pub fn parseHtmlTurbo(allocator: Allocator, source: []const u8) !ParsedHtml {
    const debug_timing = debugTimingEnabled();
    const started_ns = if (debug_timing) std.time.nanoTimestamp() else 0;
    if (debug_timing) std.debug.print("[parseHtmlTurbo] start len={d}\n", .{source.len});

    const html_bytes = try allocator.dupe(u8, source);
    errdefer allocator.free(html_bytes);

    var doc = html.Document.init(allocator);
    errdefer doc.deinit();

    try doc.parse(html_bytes, .{ .eager_child_views = false });

    if (debug_timing) {
        const elapsed_ns = std.time.nanoTimestamp() - started_ns;
        std.debug.print("[parseHtmlTurbo] done in {d} ms\n", .{@divTrunc(elapsed_ns, std.time.ns_per_ms)});
    }

    return .{ .allocator = allocator, .source = html_bytes, .doc = doc };
}

pub fn parseHtmlStable(allocator: Allocator, source: []const u8) !ParsedHtml {
    const debug_timing = debugTimingEnabled();
    const started_ns = if (debug_timing) std.time.nanoTimestamp() else 0;
    if (debug_timing) std.debug.print("[parseHtmlStable] start len={d}\n", .{source.len});

    const html_bytes = try allocator.dupe(u8, source);
    errdefer allocator.free(html_bytes);

    var doc = html.Document.init(allocator);
    errdefer doc.deinit();
    try doc.parse(html_bytes, .{});

    if (debug_timing) {
        const elapsed_ns = std.time.nanoTimestamp() - started_ns;
        std.debug.print("[parseHtmlStable] done in {d} ms\n", .{@divTrunc(elapsed_ns, std.time.ns_per_ms)});
    }
    return .{ .allocator = allocator, .source = html_bytes, .doc = doc };
}

pub fn trimAscii(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

pub fn collapseWhitespace(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var had_space = false;
    for (input) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (is_space) {
            had_space = true;
            continue;
        }
        if (had_space and out.items.len > 0) {
            try out.append(allocator, ' ');
        }
        had_space = false;
        try out.append(allocator, c);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn normalizeLanguageCode(language_or_code: []const u8) ?[]const u8 {
    const s = trimAscii(language_or_code);
    if (s.len == 0) return null;

    if (eqlCode(s, "en") or std.ascii.eqlIgnoreCase(s, "english")) return "en";
    if (eqlCode(s, "es") or std.ascii.eqlIgnoreCase(s, "spanish")) return "es";
    if (eqlCode(s, "fr") or std.ascii.eqlIgnoreCase(s, "french")) return "fr";
    if (eqlCode(s, "de") or std.ascii.eqlIgnoreCase(s, "german")) return "de";
    if (eqlCode(s, "it") or std.ascii.eqlIgnoreCase(s, "italian")) return "it";
    if (eqlCode(s, "pt") or std.ascii.eqlIgnoreCase(s, "portuguese")) return "pt";
    if (eqlCode(s, "pt-br") or std.ascii.eqlIgnoreCase(s, "brazilian portuguese")) return "pt-br";
    if (eqlCode(s, "tr") or std.ascii.eqlIgnoreCase(s, "turkish")) return "tr";
    if (eqlCode(s, "ar") or std.ascii.eqlIgnoreCase(s, "arabic")) return "ar";
    if (eqlCode(s, "ru") or std.ascii.eqlIgnoreCase(s, "russian")) return "ru";
    if (eqlCode(s, "nl") or std.ascii.eqlIgnoreCase(s, "dutch")) return "nl";
    if (eqlCode(s, "sv") or std.ascii.eqlIgnoreCase(s, "swedish")) return "sv";
    if (eqlCode(s, "da") or std.ascii.eqlIgnoreCase(s, "danish")) return "da";
    if (eqlCode(s, "fi") or std.ascii.eqlIgnoreCase(s, "finnish")) return "fi";
    if (eqlCode(s, "no") or std.ascii.eqlIgnoreCase(s, "norwegian")) return "no";
    if (eqlCode(s, "pl") or std.ascii.eqlIgnoreCase(s, "polish")) return "pl";
    if (eqlCode(s, "cs") or std.ascii.eqlIgnoreCase(s, "czech")) return "cs";
    if (eqlCode(s, "hu") or std.ascii.eqlIgnoreCase(s, "hungarian")) return "hu";
    if (eqlCode(s, "ro") or std.ascii.eqlIgnoreCase(s, "romanian")) return "ro";
    if (eqlCode(s, "el") or std.ascii.eqlIgnoreCase(s, "greek")) return "el";
    if (eqlCode(s, "ja") or std.ascii.eqlIgnoreCase(s, "japanese")) return "ja";
    if (eqlCode(s, "ko") or std.ascii.eqlIgnoreCase(s, "korean")) return "ko";
    if (eqlCode(s, "zh") or std.ascii.eqlIgnoreCase(s, "chinese")) return "zh";
    if (eqlCode(s, "zh-tw") or std.ascii.eqlIgnoreCase(s, "traditional chinese")) return "zh-tw";
    if (eqlCode(s, "id") or std.ascii.eqlIgnoreCase(s, "indonesian")) return "id";
    if (eqlCode(s, "vi") or std.ascii.eqlIgnoreCase(s, "vietnamese")) return "vi";

    return null;
}

pub fn encodeUriComponent(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (value) |byte| {
        const is_unreserved = (byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (is_unreserved) {
            try out.append(allocator, byte);
            continue;
        }

        const hi = "0123456789ABCDEF"[byte >> 4];
        const lo = "0123456789ABCDEF"[byte & 0xF];
        try out.appendSlice(allocator, &.{ '%', hi, lo });
    }

    return try out.toOwnedSlice(allocator);
}

pub fn resolveUrl(allocator: Allocator, base: []const u8, href: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://")) {
        return try allocator.dupe(u8, href);
    }

    if (std.mem.startsWith(u8, href, "//")) {
        return std.fmt.allocPrint(allocator, "https:{s}", .{href});
    }

    if (href.len == 0) return try allocator.dupe(u8, base);

    if (href[0] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, href });
    }

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, href });
}

pub fn shouldRunLiveTests(allocator: Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SCRAPERS_LIVE_TEST") catch return false;
    defer allocator.free(value);
    if (value.len == 0) return false;
    return !std.mem.eql(u8, value, "0");
}

pub fn shouldRunNamedLiveTest(allocator: Allocator, name: []const u8) bool {
    const key = std.fmt.allocPrint(allocator, "SCRAPERS_LIVE_TEST_{s}", .{name}) catch return false;
    defer allocator.free(key);
    const value = std.process.getEnvVarOwned(allocator, key) catch return false;
    defer allocator.free(value);
    if (value.len == 0) return false;
    return !std.mem.eql(u8, value, "0");
}

pub fn getAttributeValueSafe(node: anytype, attr_name: []const u8) ?[]const u8 {
    return node.getAttributeValue(attr_name);
}

pub fn parseAttrInt(node: anytype, attr_name: []const u8, comptime T: type) ?T {
    const raw = getAttributeValueSafe(node, attr_name) orelse return null;
    const trimmed = trimAscii(raw);
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(T, trimmed, 10) catch null;
}

pub fn parseAttrFloat(node: anytype, attr_name: []const u8) ?f64 {
    const raw = getAttributeValueSafe(node, attr_name) orelse return null;
    const trimmed = trimAscii(raw);
    if (trimmed.len == 0) return null;
    return std.fmt.parseFloat(f64, trimmed) catch null;
}

pub fn parseAttrBool(node: anytype, attr_name: []const u8) ?bool {
    const raw = getAttributeValueSafe(node, attr_name) orelse return null;
    const trimmed = trimAscii(raw);
    if (trimmed.len == 0) return true;
    return parseBoolLike(attr_name, trimmed);
}

pub fn firstTableHeaderRow(table: anytype) ?@TypeOf(table) {
    if (table.queryOne("thead tr")) |header_row| return header_row;
    if (table.queryOne("tr")) |header_row| return header_row;
    return null;
}

pub fn findTableColumnIndexByAliases(allocator: Allocator, header_row: anytype, aliases: []const []const u8) !?usize {
    if (aliases.len == 0) return null;

    var col: usize = 0;
    for (header_row.children()) |child_idx| {
        const cell = header_row.doc.nodeAt(child_idx) orelse continue;
        if (!isTableCellTag(cell.tagName())) continue;

        const raw = trimAscii(try cell.innerTextWithOptions(allocator, .{ .normalize_whitespace = true }));
        if (raw.len == 0) {
            col += 1;
            continue;
        }

        for (aliases) |alias| {
            if (try headerTextsLikelyMatch(allocator, raw, alias)) return col;
        }

        col += 1;
    }

    return null;
}

pub fn tableCellTextByColumnIndex(allocator: Allocator, row: anytype, maybe_col: ?usize) !?[]const u8 {
    const col = maybe_col orelse return null;

    var cell_index: usize = 0;
    for (row.children()) |child_idx| {
        const cell = row.doc.nodeAt(child_idx) orelse continue;
        if (!isTableCellTag(cell.tagName())) continue;
        if (cell_index == col) {
            const text = trimAscii(try cell.innerTextWithOptions(allocator, .{ .normalize_whitespace = true }));
            if (text.len == 0) return null;
            return text;
        }
        cell_index += 1;
    }

    return null;
}

pub fn tableCellTextByHeaderAliases(
    allocator: Allocator,
    row: anytype,
    header_row: anytype,
    aliases: []const []const u8,
) !?[]const u8 {
    const col = try findTableColumnIndexByAliases(allocator, header_row, aliases);
    return tableCellTextByColumnIndex(allocator, row, col);
}

fn sleepBackoff(initial_ms: u64, attempt: usize) void {
    const shift: u6 = @intCast(@min(attempt, 6));
    const multiplier = (@as(u64, 1) << shift);
    std.Thread.sleep(initial_ms * multiplier * std.time.ns_per_ms);
}

fn parseBoolLike(attr_name: []const u8, value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "on")) return true;
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, attr_name)) return true;

    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    if (std.mem.eql(u8, value, "0")) return false;

    return null;
}

fn isTableCellTag(tag_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag_name, "th") or std.ascii.eqlIgnoreCase(tag_name, "td");
}

fn normalizeHeaderText(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var pending_space = false;
    for (input) |c| {
        const lower = std.ascii.toLower(c);
        const is_alnum = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9');
        if (is_alnum) {
            if (pending_space and out.items.len > 0) {
                try out.append(allocator, ' ');
            }
            pending_space = false;
            try out.append(allocator, lower);
            continue;
        }

        pending_space = true;
    }

    return try out.toOwnedSlice(allocator);
}

fn headerTextsLikelyMatch(allocator: Allocator, header_text: []const u8, alias: []const u8) !bool {
    const left = try normalizeHeaderText(allocator, header_text);
    defer allocator.free(left);
    if (left.len == 0) return false;

    const right = try normalizeHeaderText(allocator, alias);
    defer allocator.free(right);
    if (right.len == 0) return false;

    return std.mem.indexOf(u8, left, right) != null or
        std.mem.indexOf(u8, right, left) != null;
}

fn eqlCode(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const x = if (ac == '_') '-' else std.ascii.toLower(ac);
        const y = if (bc == '_') '-' else std.ascii.toLower(bc);
        if (x != y) return false;
    }
    return true;
}

test "normalize language code" {
    try std.testing.expectEqualStrings("en", normalizeLanguageCode("English").?);
    try std.testing.expectEqualStrings("pt-br", normalizeLanguageCode("pt_br").?);
    try std.testing.expect(normalizeLanguageCode("unknown") == null);
}

test "encode uri component" {
    const allocator = std.testing.allocator;
    const encoded = try encodeUriComponent(allocator, "The Matrix (1999)");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("The%20Matrix%20%281999%29", encoded);
}

test "hasHeader detects custom user-agent case-insensitively" {
    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "custom-agent" },
    };
    try std.testing.expect(hasHeader(&headers, "user-agent"));
    try std.testing.expect(!hasHeader(&headers, "cookie"));
}

test "parse attr helpers" {
    var source =
        "<div id='root' data-i='42' data-f='3.25' data-b1='true' data-b2='0' disabled></div>".*;
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.parse(&source, .{});

    const node = doc.queryOne("div#root") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?i64, 42), parseAttrInt(node, "data-i", i64));
    try std.testing.expect(parseAttrFloat(node, "data-f") != null);
    try std.testing.expectApproxEqRel(@as(f64, 3.25), parseAttrFloat(node, "data-f").?, 1e-9);
    try std.testing.expectEqual(@as(?bool, true), parseAttrBool(node, "data-b1"));
    try std.testing.expectEqual(@as(?bool, false), parseAttrBool(node, "data-b2"));
    try std.testing.expectEqual(@as(?bool, true), parseAttrBool(node, "disabled"));
    try std.testing.expect(parseAttrInt(node, "missing", i64) == null);
}

test "table helpers find columns and extract cells" {
    const source =
        "<table>" ++
        "<thead><tr><th>Upload Date</th><th>FPS</th><th>CDs</th></tr></thead>" ++
        "<tbody><tr><td>2024-01-01</td><td>23.976</td><td>2</td></tr></tbody>" ++
        "</table>";
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();
    var buf = source.*;
    try doc.parse(&buf, .{});

    const table = doc.queryOne("table") orelse return error.TestUnexpectedResult;
    const header_row = firstTableHeaderRow(table) orelse return error.TestUnexpectedResult;
    const row = doc.queryOne("tbody tr") orelse return error.TestUnexpectedResult;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fps_col = try findTableColumnIndexByAliases(a, header_row, &.{ "fps", "frame rate" });
    try std.testing.expectEqual(@as(?usize, 1), fps_col);

    const fps = try tableCellTextByColumnIndex(a, row, fps_col);
    try std.testing.expect(fps != null);
    try std.testing.expectEqualStrings("23.976", fps.?);

    const uploaded = try tableCellTextByHeaderAliases(a, row, header_row, &.{ "uploaded at", "upload date" });
    try std.testing.expect(uploaded != null);
    try std.testing.expectEqualStrings("2024-01-01", uploaded.?);
}
