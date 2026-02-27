const std = @import("std");
const html = @import("htmlparser");
const build_options = @import("build_options");

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

fn livePhaseLoggingEnabled() bool {
    return build_options.live_tests_enabled;
}

pub const LivePhase = struct {
    scope: []const u8,
    phase: []const u8,
    tick_ms: u64 = 1000,
    start_ms: i64 = 0,
    enabled: bool = false,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn init(scope: []const u8, phase: []const u8) LivePhase {
        return .{
            .scope = scope,
            .phase = phase,
            .enabled = livePhaseLoggingEnabled(),
        };
    }

    pub fn start(self: *LivePhase) void {
        if (!self.enabled) return;
        self.start_ms = std.time.milliTimestamp();
        std.debug.print("[live][phase][{s}] start {s}\n", .{ self.scope, self.phase });
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    pub fn finish(self: *LivePhase) void {
        if (!self.enabled) return;
        self.stopped.store(true, .release);
        if (self.thread) |thread| thread.join();
        const elapsed_ms = std.time.milliTimestamp() - self.start_ms;
        std.debug.print("[live][phase][{s}] done {s} elapsed_ms={d}\n", .{
            self.scope,
            self.phase,
            elapsed_ms,
        });
    }

    fn run(self: *LivePhase) void {
        while (!self.stopped.load(.acquire)) {
            std.Thread.sleep(self.tick_ms * std.time.ns_per_ms);
            if (self.stopped.load(.acquire)) break;
            const elapsed_ms = std.time.milliTimestamp() - self.start_ms;
            std.debug.print("[live][phase][{s}] running {s} elapsed_ms={d}\n", .{
                self.scope,
                self.phase,
                elapsed_ms,
            });
        }
    }
};

fn selectorDebugEnabled() bool {
    const value = std.posix.getenv("SCRAPERS_SELECTOR_DEBUG") orelse return false;
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

        if (livePhaseLoggingEnabled()) {
            std.debug.print(
                "[live][phase][http.fetch] method={s} attempt={d}/{d} url={s}\n",
                .{ @tagName(opts.method), attempts + 1, opts.max_attempts, url },
            );
        }

        const result = blk: {
            var phase = LivePhase.init("http.fetch", url);
            phase.start();
            defer phase.finish();

            break :blk client.fetch(.{
                .location = .{ .url = url },
                .method = opts.method,
                .payload = opts.payload,
                .extra_headers = header_buf[0..header_len],
                .response_writer = &writer.writer,
            });
        } catch |err| {
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

    {
        var phase = LivePhase.init("html.parse", "turbo");
        phase.start();
        defer phase.finish();
        try doc.parse(html_bytes, .{
            .eager_child_views = false,
            .drop_whitespace_text_nodes = true,
        });
    }

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
    {
        var phase = LivePhase.init("html.parse", "stable");
        phase.start();
        defer phase.finish();
        try doc.parse(html_bytes, .{
            .eager_child_views = true,
            .drop_whitespace_text_nodes = false,
        });
    }

    if (debug_timing) {
        const elapsed_ns = std.time.nanoTimestamp() - started_ns;
        std.debug.print("[parseHtmlStable] done in {d} ms\n", .{@divTrunc(elapsed_ns, std.time.ns_per_ms)});
    }
    return .{ .allocator = allocator, .source = html_bytes, .doc = doc };
}

pub fn trimAscii(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

// Pass the request-local arena allocator (`const a = arena.allocator()`).
pub fn innerTextOwnedWithOptions(arena_alloc: Allocator, node: anytype, opts: html.TextOptions) ![]const u8 {
    return node.innerTextOwnedWithOptions(arena_alloc, opts);
}

// Returns an arena-backed slice; callers should not free it individually.
pub fn innerTextTrimmedOwned(arena_alloc: Allocator, node: anytype) ![]const u8 {
    return innerTextOwnedWithOptions(arena_alloc, node, .{ .normalize_whitespace = true });
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
    _ = allocator;
    return build_options.live_tests_enabled;
}

pub fn shouldRunNamedLiveTest(allocator: Allocator, name: []const u8) bool {
    _ = allocator;
    if (!build_options.live_named_tests_enabled) return false;

    const provider_name = namedLiveProvider(name) orelse return false;
    if (isCaptchaProviderName(provider_name) and !liveIncludeCaptchaEnabled()) return false;
    return providerMatchesLiveFilter(liveProviderFilter(), provider_name);
}

pub fn liveExtensiveSuiteEnabled() bool {
    return build_options.live_extensive_suite;
}

pub fn liveTuiSuiteEnabled() bool {
    return build_options.live_tui_suite;
}

pub fn liveIncludeCaptchaEnabled() bool {
    if (envBool("SCRAPERS_LIVE_INCLUDE_CAPTCHA")) |value| return value;
    return build_options.live_include_captcha;
}

pub fn liveProviderFilter() ?[]const u8 {
    if (std.posix.getenv("SCRAPERS_LIVE_PROVIDER_FILTER")) |value| {
        const trimmed_env = trimAscii(value);
        if (trimmed_env.len == 0) return null;
        return trimmed_env;
    }
    if (std.posix.getenv("SCRAPERS_LIVE_PROVIDERS")) |value| {
        const trimmed_env = trimAscii(value);
        if (trimmed_env.len == 0) return null;
        return trimmed_env;
    }
    const trimmed = trimAscii(build_options.live_provider_filter);
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn envBool(name: []const u8) ?bool {
    const raw = std.posix.getenv(name) orelse return null;
    const value = trimAscii(raw);
    if (value.len == 0) return null;
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    if (std.ascii.eqlIgnoreCase(value, "on")) return true;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    return null;
}

pub fn providerMatchesLiveFilter(filter: ?[]const u8, provider_name: []const u8) bool {
    const f = filter orelse return true;
    var it = std.mem.splitScalar(u8, f, ',');
    while (it.next()) |entry_raw| {
        const entry = trimAscii(entry_raw);
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return true;
        if (std.ascii.eqlIgnoreCase(entry, "all")) return true;
        if (providerNameEq(entry, provider_name)) return true;
        if (providerNameContains(provider_name, entry)) return true;
    }
    return false;
}

pub fn sanitizeUtf8ForLog(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const first = input[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(first) catch {
            try appendHexEscape(allocator, &out, first);
            i += 1;
            continue;
        };

        if (i + seq_len > input.len) {
            try appendHexEscape(allocator, &out, first);
            i += 1;
            continue;
        }

        const segment = input[i .. i + seq_len];
        _ = std.unicode.utf8Decode(segment) catch {
            try appendHexEscape(allocator, &out, first);
            i += 1;
            continue;
        };

        if (seq_len == 1 and (first < 0x20 or first == 0x7F)) {
            switch (first) {
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => try appendHexEscape(allocator, &out, first),
            }
            i += 1;
            continue;
        }

        try out.appendSlice(allocator, segment);
        i += seq_len;
    }

    return try out.toOwnedSlice(allocator);
}

pub fn livePrintField(allocator: Allocator, label: []const u8, value: []const u8) !void {
    try validateLiveUtf8(value);
    const safe = try sanitizeUtf8ForLog(allocator, value);
    defer allocator.free(safe);
    std.debug.print("[live] {s}: {s}\n", .{ label, safe });
}

pub fn livePrintOptionalField(allocator: Allocator, label: []const u8, value: ?[]const u8) !void {
    if (value) |v| {
        try livePrintField(allocator, label, v);
        return;
    }
    std.debug.print("[live] {s}: <null>\n", .{label});
}

fn validateLiveUtf8(value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8Data;

    var i: usize = 0;
    while (i < value.len) {
        const first = value[i];
        const seq_len_raw = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidUtf8Data;
        const seq_len: usize = @intCast(seq_len_raw);
        if (i + seq_len > value.len) return error.InvalidUtf8Data;

        const cp = std.unicode.utf8Decode(value[i .. i + seq_len]) catch return error.InvalidUtf8Data;
        if (cp == 0xFFFD) return error.InvalidUtf8Data;

        i += seq_len;
    }
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
    if (queryOneWithOptionalDebug(table, "thead tr", "firstTableHeaderRow:thead")) |header_row| return header_row;
    if (queryOneWithOptionalDebug(table, "tr", "firstTableHeaderRow:any-tr")) |header_row| return header_row;
    return null;
}

pub fn queryOneWithOptionalDebug(
    scope: anytype,
    comptime selector: []const u8,
    context: []const u8,
) ?@TypeOf(scope.queryOne(selector).?) {
    if (!selectorDebugEnabled()) return scope.queryOne(selector);

    var report: html.QueryDebugReport = .{};
    const node = scope.queryOneDebug(selector, &report);
    if (node != null) return node;

    std.debug.print(
        "[selector-debug] context={s} selector={s} visited={d} groups={d} parse_error={any}\n",
        .{
            context,
            selector,
            report.visited_elements,
            report.group_count,
            report.runtime_parse_error,
        },
    );

    var i: usize = 0;
    while (i < report.near_miss_len) : (i += 1) {
        const miss = report.near_misses[i];
        std.debug.print(
            "[selector-debug] near_miss[{d}] node={d} kind={s} group={d} compound={d} predicate={d}\n",
            .{
                i,
                miss.node_index,
                @tagName(miss.reason.kind),
                miss.reason.group_index,
                miss.reason.compound_index,
                miss.reason.predicate_index,
            },
        );
    }

    return null;
}

pub fn findTableColumnIndexByAliases(allocator: Allocator, header_row: anytype, aliases: []const []const u8) !?usize {
    if (aliases.len == 0) return null;

    var col: usize = 0;
    for (header_row.children()) |child_idx| {
        const cell = header_row.doc.nodeAt(child_idx) orelse continue;
        if (!isTableCellTag(cell.tagName())) continue;

        const raw = try innerTextTrimmedOwned(allocator, cell);
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
            const text = try innerTextTrimmedOwned(allocator, cell);
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

fn appendHexEscape(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), value: u8) !void {
    const hex = "0123456789ABCDEF";
    try out.appendSlice(allocator, &.{ '\\', 'x', hex[value >> 4], hex[value & 0x0F] });
}

fn namedLiveProvider(name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "SUBDL_COM")) return "subdl.com";
    if (std.ascii.eqlIgnoreCase(name, "MOVIESUBTITLES_ORG")) return "moviesubtitles.org";
    if (std.ascii.eqlIgnoreCase(name, "MOVIESUBTITLESRT_COM")) return "moviesubtitlesrt.com";
    if (std.ascii.eqlIgnoreCase(name, "PODNAPISI")) return "podnapisi.net";
    if (std.ascii.eqlIgnoreCase(name, "SUBTITLECAT")) return "subtitlecat.com";
    if (std.ascii.eqlIgnoreCase(name, "YIFY")) return "yifysubtitles.ch";
    if (std.ascii.eqlIgnoreCase(name, "OPENSUBTITLES_ORG")) return "opensubtitles.org";
    if (std.ascii.eqlIgnoreCase(name, "OPENSUBTITLES_COM")) return "opensubtitles.com";
    return null;
}

fn isCaptchaProviderName(provider_name: []const u8) bool {
    return providerNameEq(provider_name, "opensubtitles.org") or
        providerNameEq(provider_name, "opensubtitles.com") or
        providerNameEq(provider_name, "yifysubtitles.ch");
}

fn providerNameEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (normalizeProviderChar(ac) != normalizeProviderChar(bc)) return false;
    }
    return true;
}

fn providerNameContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var ok = true;
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (normalizeProviderChar(haystack[start + i]) != normalizeProviderChar(needle[i])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn normalizeProviderChar(c: u8) u8 {
    return switch (c) {
        '.', '-' => '_',
        else => std.ascii.toLower(c),
    };
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

test "sanitize utf8 for log escapes invalid bytes" {
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 'A', 0xFF, 'B', 0xC3 };
    const safe = try sanitizeUtf8ForLog(allocator, &raw);
    defer allocator.free(safe);

    try std.testing.expectEqualStrings("A\\xFFB\\xC3", safe);
    try std.testing.expect(std.unicode.utf8ValidateSlice(safe));
}

test "sanitize utf8 for log preserves valid unicode" {
    const allocator = std.testing.allocator;
    const safe = try sanitizeUtf8ForLog(allocator, "Cрпски");
    defer allocator.free(safe);

    try std.testing.expectEqualStrings("Cрпски", safe);
    try std.testing.expect(std.unicode.utf8ValidateSlice(safe));
}

test "validate live utf8 rejects invalid and replacement" {
    try std.testing.expectError(error.InvalidUtf8Data, validateLiveUtf8(&.{0xAA}));
    try std.testing.expectError(error.InvalidUtf8Data, validateLiveUtf8("\xEF\xBF\xBD"));
    try validateLiveUtf8("Matrix");
}

test "provider filter matching" {
    try std.testing.expect(providerMatchesLiveFilter(null, "tvsubtitles.net"));
    try std.testing.expect(providerMatchesLiveFilter("tvsubtitles.net", "tvsubtitles.net"));
    try std.testing.expect(providerMatchesLiveFilter("tvsubtitles_net", "tvsubtitles.net"));
    try std.testing.expect(providerMatchesLiveFilter("tvsubtitles", "tvsubtitles.net"));
    try std.testing.expect(providerMatchesLiveFilter("*", "tvsubtitles.net"));
    try std.testing.expect(providerMatchesLiveFilter("all", "tvsubtitles.net"));
    try std.testing.expect(!providerMatchesLiveFilter("podnapisi.net", "tvsubtitles.net"));
}
