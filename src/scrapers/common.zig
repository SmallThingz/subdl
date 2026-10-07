const std = @import("std");
const html = @import("htmlparser");
const builtin = @import("builtin");
const runtime_io = @import("runtime_io");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();
const build_options = @import("build_options");

/// Transfer an arena to a response parser without leaving a second cleanup owner.
pub fn takeArena(source: *std.heap.ArenaAllocator) std.heap.ArenaAllocator {
    const owned = source.*;
    source.* = std.heap.ArenaAllocator.init(owned.child_allocator);
    return owned;
}

/// Field expressions may grow the arena after its first struct-field copy.
/// Capture its final buffer chain only after every response field is ready.
pub fn finishResponse(comptime T: type, arena: *std.heap.ArenaAllocator, response: T) T {
    var result = response;
    result.arena = arena.*;
    return result;
}

pub const Allocator = std.mem.Allocator;

pub const default_user_agent = "subdl-zig-scrapers/0.2.0 (+https://subdl.com)";

pub const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
};

/// A single HTTP fetch, including retries, redirects, cache access, and
/// backoff, receives a finite cancellation deadline in production even when a
/// caller supplies no override. Two minutes accommodates slower providers.
/// Cancellation is cooperative: returning can take longer when the active
/// `Io` backend or platform operation cannot abort promptly.
pub const default_fetch_timeout_ms: i64 = 2 * 60 * 1000;

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
    cache: bool = true,
    max_response_bytes: usize = 128 * 1024 * 1024,
    /// Maximum encoded entity bytes consumed before decompression. This is
    /// independent of max_response_bytes so empty/skippable compressed frames
    /// cannot consume unbounded input while producing little or no output.
    max_encoded_response_bytes: usize = 128 * 1024 * 1024,
    /// Reject credentials, local/private hosts, and unsafe redirect targets.
    /// Enable this for URLs originating in provider-controlled response data.
    require_public_origin: bool = false,
    /// Require HTTPS for the initial request and every redirect hop.
    require_https: bool = false,
    /// Reject redirects whose scheme, host, or effective port differs from the
    /// initial request. Same-origin relative redirects remain allowed.
    require_same_origin: bool = false,
    /// Send caller-supplied private headers only while the request path remains
    /// at or below this canonical path prefix. This applies independently at
    /// every redirect hop; ordinary content-negotiation headers remain safe.
    private_headers_path_prefix: ?[]const u8 = null,
    /// Optional absolute override on the `.awake` clock, in milliseconds as
    /// returned by `compatMilliTimestamp`. Null uses
    /// `default_fetch_timeout_ms`. The deadline requests cancellation across
    /// cache access, retries, redirects, request/response I/O, and retry
    /// backoff; return latency still depends on the active operation honoring
    /// cancellation promptly.
    deadline_ms: ?i64 = null,
    /// Deliberate opt-out for embedding environments that provide a stricter
    /// cancellation scope. This takes precedence over `deadline_ms`.
    disable_deadline: bool = false,
};

pub const FetchCacheConfig = struct {
    enabled: bool = false,
    root_dir: ?[]const u8 = null,
    ttl_seconds: i64 = 12 * 60 * 60,
};

var fetch_cache_config: FetchCacheConfig = .{};
var fetch_cache_lock = std.atomic.Value(u8).init(0);
var client_init_lock = std.atomic.Value(u8).init(0);

const FetchCacheSnapshot = struct {
    enabled: bool,
    root_dir: ?[]u8,
    ttl_seconds: i64,

    fn deinit(self: *FetchCacheSnapshot, allocator: Allocator) void {
        if (self.root_dir) |root| allocator.free(root);
        self.* = undefined;
    }
};

const FetchCacheGuard = struct {
    fn lock() FetchCacheGuard {
        while (fetch_cache_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) sleepMilliseconds(5);
        return .{};
    }

    fn lockCancelable() !FetchCacheGuard {
        while (fetch_cache_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            try sleepMillisecondsCancelable(5);
        }
        return .{};
    }

    fn unlock(_: FetchCacheGuard) void {
        fetch_cache_lock.store(0, .release);
    }
};

pub fn configureFetchCache(config: FetchCacheConfig) void {
    // The public configuration may point into caller-owned storage. Keep an
    // independent process-lifetime copy so callers can release or mutate their
    // input as soon as this function returns.
    const owned_root = if (config.root_dir) |root|
        std.heap.page_allocator.dupe(u8, root) catch {
            replaceFetchCacheConfig(.{});
            return;
        }
    else
        null;
    replaceFetchCacheConfig(.{
        .enabled = config.enabled,
        .root_dir = owned_root,
        .ttl_seconds = config.ttl_seconds,
    });
}

fn replaceFetchCacheConfig(config: FetchCacheConfig) void {
    const guard = FetchCacheGuard.lock();
    const previous_root = fetch_cache_config.root_dir;
    fetch_cache_config = config;
    guard.unlock();

    if (previous_root) |root| std.heap.page_allocator.free(@constCast(root));
}

/// Optional child/enrichment requests may fail without invalidating an entire
/// provider result, but cancellation, resource exhaustion, and provider-wide
/// policy errors must never be hidden by that fallback behavior.
pub fn mustPropagateOptionalFailure(err: anyerror) bool {
    return err == error.Canceled or
        err == error.OutOfMemory or
        err == error.ConcurrencyUnavailable or
        err == error.RateLimited or
        err == error.ProviderAccessBlocked or
        err == error.CloudflareChallenge or
        err == error.UnsafeHttpTarget or
        err == error.InvalidDownloadUrl or
        err == error.Timeout or
        err == error.PublicOriginProxyUnsupported;
}

/// Errors caused by cancellation, local policy, or a deterministic response
/// shape cannot become successful by repeating the same request.
pub fn mustNotRetryFetchError(err: anyerror) bool {
    return err == error.Canceled or
        err == error.OutOfMemory or
        err == error.UnsafeHttpTarget or
        err == error.InvalidDownloadUrl or
        err == error.Timeout or
        err == error.PublicOriginProxyUnsupported or
        err == error.UnsupportedProtocolUpgrade or
        err == error.TooManyInformationalResponses or
        err == error.TooManyHttpRedirects or
        err == error.HttpRedirectLocationMissing or
        err == error.InvalidHttpHeader or
        err == error.InvalidHttpMethodPayload or
        err == error.TransportOwnedHttpHeader or
        err == error.HttpConnectionHeaderUnsupported or
        err == error.HttpContentEncodingUnsupported or
        err == error.HttpHeaderContinuationsUnsupported or
        err == error.HttpHeadersOversize or
        err == error.UnsupportedCompressionMethod or
        err == error.TooManyCompressedMembers or
        err == error.InvalidResponseLimit or
        err == error.ResponseTooLarge or
        err == error.AmbiguousHttpFraming or
        err == error.HttpChunkInvalid or
        err == error.InvalidContentLength or
        err == error.HttpHeadersInvalid or
        err == error.HttpTransferEncodingUnsupported or
        err == error.UnexpectedEncodedPayload or
        err == error.WrongGzipChecksum or
        err == error.WrongGzipSize or
        err == error.WrongZlibChecksum;
}

pub const ParsedHtml = struct {
    allocator: Allocator,
    source: []u8,
    doc: HtmlDocument,

    /// Release only when no extracted attribute or source-backed slice escapes.
    /// Response parsers intentionally let their owning arena reclaim this data.
    pub fn deinit(self: *ParsedHtml) void {
        self.doc.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }
};

pub fn SearchResponse(comptime Item: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        items: []const Item,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn PagedSearchResponse(comptime Item: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        items: []const Item,
        page: usize = 1,
        has_prev_page: bool = false,
        has_next_page: bool = false,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn NextSearchResponse(comptime Item: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        items: []const Item,
        has_next_page: bool = false,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn TitledSubtitlesResponse(comptime Item: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        title: []const u8,
        subtitles: []const Item,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn SubtitlesResponse(comptime Item: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        subtitles: []const Item,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn PagedTitledSubtitlesResponse(comptime Item: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        title: []const u8,
        subtitles: []const Item,
        page: usize = 1,
        has_prev_page: bool = false,
        has_next_page: bool = false,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn PagedSubtitlesResponse(comptime Item: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        subtitles: []const Item,
        page: usize = 1,
        has_prev_page: bool = false,
        has_next_page: bool = false,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn debugTimingEnabled() bool {
    const value = getenv("SCRAPERS_DEBUG_TIMING") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

// Live tests can look stuck when a provider throttles or changes markup.
// This switch keeps periodic phase logging out of normal CLI/library runs.
fn livePhaseLoggingEnabled() bool {
    return build_options.live_tests_enabled;
}

pub fn compatMilliTimestamp() i64 {
    const ns = std.Io.Timestamp.now(runtime_io.get(), .awake).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

pub fn compatNanoTimestamp() i64 {
    return @intCast(std.Io.Timestamp.now(runtime_io.get(), .awake).nanoseconds);
}

pub fn compatUnixTimestamp() i64 {
    const ns = std.Io.Timestamp.now(runtime_io.get(), .real).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_s));
}

pub fn sleepMillisecondsCancelable(ms: u64) std.Io.Cancelable!void {
    const bounded_ms = @min(ms, std.math.maxInt(i64));
    try runtime_io.get().sleep(.fromMilliseconds(@intCast(bounded_ms)), .awake);
}

/// Use only where cancellation cannot be returned to the caller, such as
/// lock polling and best-effort progress reporting. Request workflows should
/// use sleepMillisecondsCancelable instead.
pub fn sleepMilliseconds(ms: u64) void {
    sleepMillisecondsCancelable(ms) catch {};
}

pub fn isAustralianWebsiteBlockPage(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "Access to Website Disabled") != null and
        std.mem.indexOf(u8, body, "Federal Court of Australia") != null;
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
        self.start_ms = compatMilliTimestamp();
        std.debug.print("[live][phase][{s}] start {s}\n", .{ self.scope, self.phase });
        // `std.Thread.spawn` is a compile error in a single-threaded build.
        // Keep phase boundary logging available there, but omit the periodic
        // progress worker that necessarily requires another thread.
        if (comptime !builtin.single_threaded) {
            self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
        }
    }

    pub fn finish(self: *LivePhase) void {
        if (!self.enabled) return;
        self.stopped.store(true, .release);
        if (self.thread) |thread| thread.join();
        const elapsed_ms = compatMilliTimestamp() - self.start_ms;
        std.debug.print("[live][phase][{s}] done {s} elapsed_ms={d}\n", .{
            self.scope,
            self.phase,
            elapsed_ms,
        });
    }

    fn run(self: *LivePhase) void {
        const stop_poll_ms: u64 = 50;
        var until_tick_ms = self.tick_ms;
        while (!self.stopped.load(.acquire)) {
            const sleep_ms = @min(until_tick_ms, stop_poll_ms);
            sleepMilliseconds(sleep_ms);
            if (self.stopped.load(.acquire)) break;
            until_tick_ms -= sleep_ms;
            if (until_tick_ms > 0) continue;

            const elapsed_ms = compatMilliTimestamp() - self.start_ms;
            std.debug.print("[live][phase][{s}] running {s} elapsed_ms={d}\n", .{
                self.scope,
                self.phase,
                elapsed_ms,
            });
            until_tick_ms = self.tick_ms;
        }
    }
};

fn selectorDebugEnabled() bool {
    const value = getenv("SCRAPERS_SELECTOR_DEBUG") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

pub fn fetchBytes(client: *std.http.Client, allocator: Allocator, url: []const u8, opts: FetchOptions) !HttpResponse {
    const now_ms = compatMilliTimestamp();
    const deadline_ms = effectiveFetchDeadline(opts, now_ms) orelse
        return fetchBytesNoDeadline(client, allocator, url, opts);
    if (now_ms >= deadline_ms) return error.Timeout;

    const FetchTask = struct {
        fn run(result: *?HttpResponse, task_client: *std.http.Client, task_allocator: Allocator, task_url: []const u8, task_opts: FetchOptions) !void {
            result.* = try fetchBytesNoDeadline(task_client, task_allocator, task_url, task_opts);
        }
    };
    const FetchResult = @typeInfo(@TypeOf(FetchTask.run)).@"fn".return_type.?;
    const TimeoutResult = @typeInfo(@TypeOf(std.Io.Timeout.sleep)).@"fn".return_type.?;
    const Selection = union(enum) {
        fetch: FetchResult,
        timeout: TimeoutResult,
    };
    var selection_buffer: [2]Selection = undefined;
    var selection = std.Io.Select(Selection).init(client.io, &selection_buffer);
    var owned_response: ?HttpResponse = null;
    defer {
        selection.cancelDiscard();
        // A fetch can finish while its timeout result wins the race. The task
        // records ownership out-of-band so discarding its union result cannot
        // leak an allocator-owned response body.
        if (owned_response) |response| allocator.free(response.body);
    }

    // A caller can provide maxInt while a synthetic clock is negative. Use a
    // saturating difference so even adversarial option values cannot overflow.
    const remaining_ms: i64 = deadline_ms -| now_ms;
    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(client.io, .{
        .raw = std.Io.Duration.fromMilliseconds(remaining_ms),
        .clock = .awake,
    }) };
    try selection.concurrent(.fetch, FetchTask.run, .{ &owned_response, client, allocator, url, opts });
    try selection.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, client.io });

    switch (try selection.await()) {
        .fetch => |result| {
            try result;
            const response = owned_response orelse return error.MissingHttpResponse;
            owned_response = null;
            return response;
        },
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}

fn effectiveFetchDeadline(opts: FetchOptions, now_ms: i64) ?i64 {
    if (opts.disable_deadline) return null;
    return opts.deadline_ms orelse now_ms +| default_fetch_timeout_ms;
}

fn fetchBytesNoDeadline(client: *std.http.Client, allocator: Allocator, url: []const u8, opts: FetchOptions) !HttpResponse {
    return fetchBytesWith(fetchBytesViaHttp, sleepBackoff, client, allocator, url, opts);
}

fn fetchBytesWith(comptime fetch: anytype, comptime backoff: anytype, client: *std.http.Client, allocator: Allocator, url: []const u8, opts: FetchOptions) !HttpResponse {
    try validateFetchHeaders(opts);
    try validateFetchTarget(url, opts);
    if (try loadFetchCache(allocator, url, opts)) |cached| return cached;

    const logging_enabled = livePhaseLoggingEnabled();
    const owned_log_url = if (logging_enabled) redactUrlForLog(allocator, url) catch null else null;
    defer if (owned_log_url) |value| allocator.free(value);
    const log_url = owned_log_url orelse "<redacted-url>";

    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        if (logging_enabled) {
            std.debug.print(
                "[live][phase][http.fetch] method={s} attempt={d}/{d} url={s}\n",
                .{ @tagName(opts.method), attempts + 1, opts.max_attempts, log_url },
            );
        }

        const response = fetch(client, allocator, url, opts) catch |err| {
            if (mustNotRetryFetchError(err)) return err;
            if (attempts + 1 < opts.max_attempts) {
                try backoff(opts.retry_initial_backoff_ms, attempts);
                continue;
            }
            return err;
        };
        if (response.status == .too_many_requests) {
            if (opts.retry_on_429 and attempts + 1 < opts.max_attempts) {
                allocator.free(response.body);
                try backoff(opts.retry_initial_backoff_ms, attempts);
                continue;
            }
            if (!opts.allow_non_ok) {
                if (logging_enabled) std.debug.print("[live][http.status] code={d} url={s}\n", .{ @backingInt(response.status), log_url });
                allocator.free(response.body);
                return error.RateLimited;
            }
        }
        if (!opts.allow_non_ok and response.status != .ok) {
            if (logging_enabled) std.debug.print("[live][http.status] code={d} url={s}\n", .{ @backingInt(response.status), log_url });
            allocator.free(response.body);
            return error.UnexpectedHttpStatus;
        }
        errdefer allocator.free(response.body);
        try storeFetchCache(allocator, url, opts, response);
        return response;
    }
}

/// Keep diagnostics useful without persisting bearer-like query or path
/// capabilities. This is public so browser-session handoff messages can use
/// exactly the same policy as the HTTP transport.
pub fn redactUrlForLog(allocator: Allocator, url: []const u8) ![]u8 {
    const uri = std.Uri.parse(url) catch return allocator.dupe(u8, "<invalid-url>");
    const host_component = uri.host orelse return allocator.dupe(u8, "<invalid-url>");
    const host = switch (host_component) {
        .raw, .percent_encoded => |value| value,
    };
    const safe_scheme = try sanitizeUtf8ForLog(allocator, uri.scheme);
    defer allocator.free(safe_scheme);
    const safe_host = try sanitizeUtf8ForLog(allocator, host);
    defer allocator.free(safe_host);
    if (uri.port) |port| {
        return std.fmt.allocPrint(allocator, "{s}://{s}:{d}/<redacted>", .{ safe_scheme, safe_host, port });
    }
    return std.fmt.allocPrint(allocator, "{s}://{s}/<redacted>", .{ safe_scheme, safe_host });
}

const fetch_cache_magic = "subdl-http-cache-v3\n";
const fetch_cache_key_version = "subdl-http-cache-key-v1";
// Four short decimal/header lines precede the body. This generous fixed
// allowance keeps the file read cap tied to the caller's response limit.
const fetch_cache_metadata_max_bytes: usize = 256;

fn fetchCacheFileLimit(max_response_bytes: usize) ?usize {
    // allocRemaining adds one sentinel byte internally, while maxInt is the
    // Io.Limit `.unlimited` sentinel. Keep both values representable and finite.
    if (max_response_bytes > std.math.maxInt(usize) - fetch_cache_metadata_max_bytes - 2) return null;
    return max_response_bytes + fetch_cache_metadata_max_bytes;
}

fn encodedResponseReadLimit(max_encoded_response_bytes: usize) !usize {
    // Io.Limit reserves maxInt for `.unlimited`; leave one representable byte
    // beyond the configured cap so exhausting the reader proves an overflow.
    if (max_encoded_response_bytes > std.math.maxInt(usize) - 2) return error.InvalidResponseLimit;
    return max_encoded_response_bytes + 1;
}

fn openFetchCacheFile(io: std.Io, path: []const u8) anyerror!std.Io.File {
    if (comptime builtin.os.tag != .windows) {
        if (comptime @hasField(std.posix.O, "NONBLOCK") and
            @hasField(std.posix.O, "NOFOLLOW") and
            @hasField(std.posix.O, "ACCMODE") and
            @hasDecl(std.posix, "openat"))
        {
            // O_NONBLOCK prevents a locally replaced FIFO or device node from
            // stalling cache lookup before the regular-file check below.
            var flags: std.posix.O = .{
                .ACCMODE = .RDONLY,
                .NONBLOCK = true,
                .NOFOLLOW = true,
            };
            if (comptime @hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
            const handle = try std.posix.openat(std.Io.Dir.cwd().handle, path, flags, 0);
            return .{
                .handle = handle,
                .flags = .{ .nonblocking = true },
            };
        }
    }
    return std.Io.Dir.cwd().openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
}

fn fetchCacheFileOwnedByCurrentUser(file: std.Io.File) bool {
    // Windows has no POSIX uid to compare. The generic response cache does not
    // contain reusable browser credentials; rely on the no-follow open there.
    if (comptime builtin.os.tag == .windows) return true;
    if (comptime builtin.os.tag == .linux) {
        var statx_buf: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(
            @intCast(file.handle),
            "",
            std.os.linux.AT.EMPTY_PATH,
            .{ .UID = true },
            &statx_buf,
        );
        if (std.os.linux.errno(rc) == .SUCCESS and statx_buf.mask.UID)
            return statx_buf.uid == std.os.linux.geteuid();
        // Older kernels and some seccomp profiles omit or deny statx while
        // still permitting fstat. Fall through to the libc handle check.
    }
    if (comptime builtin.link_libc and @hasDecl(std.c, "fstat") and @hasDecl(std.c, "geteuid")) {
        if (comptime switch (@typeInfo(std.c.Stat)) {
            .@"struct" => @hasField(std.c.Stat, "uid"),
            else => false,
        }) {
            var stat_buf: std.c.Stat = undefined;
            return std.c.fstat(file.handle, &stat_buf) == 0 and stat_buf.uid == std.c.geteuid();
        }
    }
    // A cache entry is optional. On POSIX targets where ownership cannot be
    // established from the already-open handle, ignore it rather than trusting
    // a path-based check that can race replacement.
    return false;
}

fn loadFetchCache(allocator: Allocator, url: []const u8, opts: FetchOptions) !?HttpResponse {
    if (!opts.cache) return null;
    var config = try currentFetchCacheConfig(allocator);
    defer config.deinit(allocator);
    if (!config.enabled or config.ttl_seconds < 0) return null;
    const root = config.root_dir orelse return null;

    const path = try fetchCachePath(allocator, root, url, opts);
    defer allocator.free(path);

    const guard = try FetchCacheGuard.lockCancelable();
    defer guard.unlock();

    const file_limit = fetchCacheFileLimit(opts.max_response_bytes) orelse return null;
    const io = runtime_io.get();
    const file = openFetchCacheFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.Canceled => return err,
        else => return null,
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    if (stat.kind != .file or !fetchCacheFileOwnedByCurrentUser(file)) return null;
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        if (stat.permissions.toMode() & 0o077 != 0) return null;
    }
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.readerStreaming(io, &read_buffer);
    const data = file_reader.interface.allocRemaining(allocator, .limited(file_limit)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ReadFailed => {
            if (file_reader.err) |read_err| if (read_err == error.Canceled) return read_err;
            return null;
        },
        error.StreamTooLong => return null,
    };
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    const magic = it.next() orelse return null;
    if (!std.mem.eql(u8, magic, fetch_cache_magic[0 .. fetch_cache_magic.len - 1])) return null;
    const fetched_line = it.next() orelse return null;
    const status_line = it.next() orelse return null;
    const body_len_line = it.next() orelse return null;
    const body = it.rest();

    const fetched_at = std.fmt.parseInt(i64, fetched_line, 10) catch return null;
    const now = compatUnixTimestamp();
    if (fetched_at < 0 or fetched_at > now) return null;
    if (config.ttl_seconds > 0 and @as(i128, now) - fetched_at > config.ttl_seconds) return null;
    const status_int = std.fmt.parseInt(u10, status_line, 10) catch return null;
    if (status_int != @backingInt(std.http.Status.ok)) return null;
    const body_len = std.fmt.parseInt(usize, body_len_line, 10) catch return null;
    if (body.len != body_len or body.len > opts.max_response_bytes) return null;

    return .{
        .status = @fromBackingInt(@intCast(status_int)),
        .body = try allocator.dupe(u8, body),
    };
}

fn storeFetchCache(allocator: Allocator, url: []const u8, opts: FetchOptions, response: HttpResponse) !void {
    storeFetchCacheFallible(allocator, url, opts, response) catch |err| {
        return handleFetchCachePublicationError(err);
    };
}

fn handleFetchCachePublicationError(err: anyerror) !void {
    // Cancellation belongs to the surrounding request and must remain
    // observable. Every other cache failure, including allocator exhaustion,
    // is best-effort and cannot invalidate a fetched body.
    if (err == error.Canceled) return err;
}

fn storeFetchCacheFallible(allocator: Allocator, url: []const u8, opts: FetchOptions, response: HttpResponse) !void {
    if (!opts.cache) return;
    if (opts.method != .GET and opts.method != .POST) return;
    var config = try currentFetchCacheConfig(allocator);
    defer config.deinit(allocator);
    if (!config.enabled or config.ttl_seconds < 0) return;
    const root = config.root_dir orelse return;
    if (response.status != .ok) return;

    const path = try fetchCachePath(allocator, root, url, opts);
    defer allocator.free(path);

    var header_buffer: [fetch_cache_metadata_max_bytes]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "{s}{d}\n{d}\n{d}\n", .{
        fetch_cache_magic,
        compatUnixTimestamp(),
        @backingInt(response.status),
        response.body.len,
    });

    const guard = try FetchCacheGuard.lockCancelable();
    defer guard.unlock();
    try writeFetchCacheAtomically(path, header, response.body);
}

fn writeFetchCacheAtomically(path: []const u8, header: []const u8, body: []const u8) !void {
    try ensureParentDir(path);
    const io = runtime_io.get();
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .replace = true,
        .permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, header);
    try atomic.file.writeStreamingAll(io, body);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn currentFetchCacheConfig(allocator: Allocator) !FetchCacheSnapshot {
    const guard = try FetchCacheGuard.lockCancelable();
    defer guard.unlock();
    return .{
        .enabled = fetch_cache_config.enabled,
        .root_dir = if (fetch_cache_config.root_dir) |root| try allocator.dupe(u8, root) else null,
        .ttl_seconds = fetch_cache_config.ttl_seconds,
    };
}

fn fetchCachePath(allocator: Allocator, root: []const u8, url: []const u8, opts: FetchOptions) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashFetchCacheField(&hasher, "version", fetch_cache_key_version);
    hashFetchCacheField(&hasher, "method", @tagName(opts.method));
    hashFetchCacheField(&hasher, "public-origin", if (opts.require_public_origin) "1" else "0");
    hashFetchCacheField(&hasher, "https-only", if (opts.require_https) "1" else "0");
    hashFetchCacheField(&hasher, "same-origin", if (opts.require_same_origin) "1" else "0");
    hashFetchCacheOptionalField(&hasher, "private-header-path", opts.private_headers_path_prefix);
    hashFetchCacheField(&hasher, "url", url);
    hashFetchCacheOptionalField(&hasher, "accept", opts.accept);
    hashFetchCacheOptionalField(&hasher, "content-type", opts.content_type);
    hashFetchCacheUsize(&hasher, "header-count", opts.extra_headers.len);
    for (opts.extra_headers) |header| {
        hashFetchCacheField(&hasher, "header-name", header.name);
        hashFetchCacheField(&hasher, "header-value", header.value);
    }
    hashFetchCacheOptionalField(&hasher, "payload", opts.payload);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var hex: [64]u8 = undefined;
    const table = "0123456789abcdef";
    for (digest, 0..) |byte, idx| {
        hex[idx * 2] = table[byte >> 4];
        hex[idx * 2 + 1] = table[byte & 0x0f];
    }
    return std.fmt.allocPrint(allocator, "{s}/http/{s}.cache", .{ root, &hex });
}

fn hashFetchCacheField(hasher: *std.crypto.hash.sha2.Sha256, name: []const u8, value: []const u8) void {
    hashFetchCacheBytes(hasher, name);
    hashFetchCacheBytes(hasher, value);
}

fn hashFetchCacheOptionalField(hasher: *std.crypto.hash.sha2.Sha256, name: []const u8, value: ?[]const u8) void {
    hashFetchCacheBytes(hasher, name);
    if (value) |bytes| {
        hasher.update(&.{1});
        hashFetchCacheBytes(hasher, bytes);
    } else {
        hasher.update(&.{0});
    }
}

fn hashFetchCacheUsize(hasher: *std.crypto.hash.sha2.Sha256, name: []const u8, value: usize) void {
    hashFetchCacheBytes(hasher, name);
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .big);
    hasher.update(&encoded);
}

fn hashFetchCacheBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var encoded_len: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded_len, @intCast(bytes.len), .big);
    hasher.update(&encoded_len);
    hasher.update(bytes);
}

pub fn ensureParentDir(path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), path[0..slash]);
}

fn fetchBytesViaHttp(client: *std.http.Client, allocator: Allocator, url: []const u8, opts: FetchOptions) !HttpResponse {
    if (opts.require_public_origin) {
        // Public-origin requests use a short-lived client with an empty pool
        // and no proxy. Each hop is connected to one validated DNS answer, so
        // a connection opened by an unrestricted request cannot redirect this
        // request into a private network.
        var public_client: std.http.Client = undefined;
        try initPublicOriginClient(client, &public_client);
        defer public_client.deinit();
        return fetchBytesViaReadyClient(&public_client, allocator, url, opts);
    }

    try ensureClientTlsReady(client);
    return fetchBytesViaReadyClient(client, allocator, url, opts);
}

/// Initialize an isolated client suitable for a request whose resolved socket
/// must remain bound to a validated public address. Proxies are rejected
/// because they move DNS resolution and the actual connection out of process.
pub fn initPublicOriginClient(source: *std.http.Client, destination: *std.http.Client) !void {
    if (source.http_proxy != null or source.https_proxy != null) {
        return error.PublicOriginProxyUnsupported;
    }

    try ensureClientTlsReady(source);
    destination.* = .{
        .allocator = source.allocator,
        .io = source.io,
        .tls_buffer_size = source.tls_buffer_size,
        .ssl_key_log = source.ssl_key_log,
        .read_buffer_size = source.read_buffer_size,
        .write_buffer_size = source.write_buffer_size,
    };
    errdefer destination.deinit();
    // Preserve caller-supplied roots and validation time. Rescanning the
    // system store here could silently discard a custom trust policy.
    try copyClientTrust(source, destination);
}

fn copyClientTrust(source: *std.http.Client, destination: *std.http.Client) !void {
    if (!std.http.Client.disable_tls) {
        try source.ca_bundle_lock.lockShared(source.io);
        defer source.ca_bundle_lock.unlockShared(source.io);

        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(destination.allocator);
        bundle.bytes = try source.ca_bundle.bytes.clone(destination.allocator);
        const Map = @TypeOf(source.ca_bundle.map);
        const MapContext = @typeInfo(@TypeOf(Map.promoteContext)).@"fn".param_types[2].?;
        bundle.map = try source.ca_bundle.map.cloneContext(
            destination.allocator,
            MapContext{ .cb = &bundle },
        );

        destination.ca_bundle = bundle;
        destination.now = source.now;
    }
}

fn fetchBytesViaReadyClient(client: *std.http.Client, allocator: Allocator, url: []const u8, opts: FetchOptions) !HttpResponse {
    const owned_log_url = if (livePhaseLoggingEnabled()) redactUrlForLog(allocator, url) catch null else null;
    defer if (owned_log_url) |value| allocator.free(value);
    var phase = LivePhase.init("http.fetch", owned_log_url orelse "<redacted-url>");
    phase.start();
    defer phase.finish();

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    if (opts.accept) |accept| {
        if (!hasHeader(opts.extra_headers, "accept")) {
            try headers.append(allocator, .{ .name = "accept", .value = accept });
        }
    }

    for (opts.extra_headers) |header| {
        if (isTypedRequestHeader(header.name)) continue;
        try headers.append(allocator, header);
    }

    const request_headers: std.http.Client.Request.Headers = .{
        .host = .default,
        .authorization = typedHeaderOverride(opts.extra_headers, "authorization"),
        .user_agent = if (findHeaderValue(opts.extra_headers, "user-agent")) |value|
            .{ .override = value }
        else
            .{ .override = default_user_agent },
        // Connection is hop-by-hop transport state. A caller override can
        // disagree with keep_alive and leave a closed socket in the pool.
        .connection = .default,
        .accept_encoding = typedHeaderOverride(opts.extra_headers, "accept-encoding"),
        .content_type = if (findHeaderValue(opts.extra_headers, "content-type")) |value|
            .{ .override = value }
        else if (opts.content_type) |value|
            .{ .override = value }
        else
            .default,
    };

    const normalized_url = try normalizeUrlForFetch(allocator, url);
    defer allocator.free(normalized_url);

    // std.http writes directly into an allocator-owned buffer. Transfer that
    // allocation to the caller rather than duplicating the full response body.
    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const fetched = try fetchWithRedirects(client, allocator, normalized_url, opts, request_headers, headers.items, &body_writer.writer);

    var body = body_writer.toArrayList();
    errdefer body.deinit(allocator);
    return .{
        .status = fetched.status,
        .body = try body.toOwnedSlice(allocator),
    };
}

// Own redirect policy and validate framing independently of std.http helpers.
// Private headers survive only while the origin stays unchanged.
fn decompressionReadError(decompress: *const std.http.Decompress) ?anyerror {
    return switch (decompress.*) {
        .flate => |value| value.err,
        .zstd => |value| value.err,
        .none => null,
    };
}

fn responseReadError(response: *std.http.Client.Response, request: *std.http.Client.Request, decompress: ?*const std.http.Decompress) anyerror {
    // Decoder format failures are also surfaced as ReadFailed, but they do not
    // set a socket error. Preserve the decoder's concrete error before looking
    // at transfer framing or transport state.
    if (decompress) |value| {
        if (decompressionReadError(value)) |err| {
            if (err != error.ReadFailed) return err;
        }
    }
    if (response.bodyErr()) |err| return err;
    return normalizeRequestReadError(request, error.ReadFailed);
}

/// Reject response framing that `std.http` deliberately tolerates but which is
/// ambiguous across intermediaries. In particular, a response carrying both
/// Transfer-Encoding and Content-Length, or more than one Content-Length
/// field, is a request-smuggling boundary and must never reach the body reader.
pub fn validateResponseFraming(head: std.http.Client.Response.Head) !void {
    var content_length_count: usize = 0;
    var transfer_encoding_count: usize = 0;
    var content_encoding_count: usize = 0;
    var location_count: usize = 0;
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (!validHttpHeaderName(header.name) or !validHttpHeaderValue(header.value))
            return error.HttpHeadersInvalid;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
            content_length_count += 1;
            try validateContentLengthField(header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) {
            transfer_encoding_count += 1;
            try validateTransferEncodingField(header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "content-encoding")) {
            content_encoding_count += 1;
            try validateContentEncodingField(header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "location")) {
            location_count += 1;
        }
    }
    if (content_length_count > 1 or transfer_encoding_count > 1 or content_encoding_count > 1 or
        (content_length_count != 0 and transfer_encoding_count != 0))
    {
        return error.AmbiguousHttpFraming;
    }
    // Location is a singleton field. Selecting one of multiple values before
    // applying redirect policy can disagree with an intermediary and route the
    // request, its payload, or its private headers to a different target.
    if (isRedirectStatus(head.status) and location_count > 1)
        return error.AmbiguousHttpFraming;
    // RFC 9110 forbids both fields on informational and 204 responses. Their
    // message ends at the header terminator, so accepting either field can
    // leave alleged body bytes queued as the next keep-alive response.
    if ((head.status.class() == .informational or head.status == .no_content) and
        (content_length_count != 0 or transfer_encoding_count != 0))
    {
        return error.AmbiguousHttpFraming;
    }
}

fn validateContentLengthField(value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return error.InvalidContentLength;
    for (trimmed) |byte| {
        // A comma represents a coalesced list of Content-Length values. Even
        // identical list members are rejected, just like repeated field lines,
        // so every hop observes one unambiguous framing value.
        if (byte == ',') return error.AmbiguousHttpFraming;
        if (!std.ascii.isDigit(byte)) return error.InvalidContentLength;
    }
    _ = std.fmt.parseInt(u64, trimmed, 10) catch return error.InvalidContentLength;
}

fn validateTransferEncodingField(value: []const u8) !void {
    // std.http maps one gzip/deflate transfer coding into its decompressor and
    // represents a final chunked coding separately. Mirror exactly that subset
    // here so no syntactically different chain reaches the strict body reader.
    var codings: [2][]const u8 = undefined;
    var coding_count: usize = 0;
    var fields = std.mem.splitScalar(u8, value, ',');
    while (fields.next()) |raw| {
        if (coding_count == codings.len) return error.HttpTransferEncodingUnsupported;
        const coding = std.mem.trim(u8, raw, " \t");
        if (coding.len == 0) return error.HttpTransferEncodingUnsupported;
        codings[coding_count] = coding;
        coding_count += 1;
    }
    if (coding_count == 1 and
        (std.ascii.eqlIgnoreCase(codings[0], "chunked") or
            std.ascii.eqlIgnoreCase(codings[0], "gzip") or
            std.ascii.eqlIgnoreCase(codings[0], "deflate"))) return;
    if (coding_count == 2 and
        (std.ascii.eqlIgnoreCase(codings[0], "gzip") or
            std.ascii.eqlIgnoreCase(codings[0], "deflate")) and
        std.ascii.eqlIgnoreCase(codings[1], "chunked")) return;
    return error.HttpTransferEncodingUnsupported;
}

fn validateContentEncodingField(value: []const u8) !void {
    // std.http exposes a single content-encoding enum, so require the wire
    // representation to be a single coding as well. Multiple codings cannot
    // be decoded or checksum-verified in the declared order by this transport.
    const trimmed = std.mem.trim(u8, value, " \t");
    if (!std.ascii.eqlIgnoreCase(trimmed, "identity") and
        !std.ascii.eqlIgnoreCase(trimmed, "gzip") and
        !std.ascii.eqlIgnoreCase(trimmed, "deflate"))
    {
        return error.HttpContentEncodingUnsupported;
    }
}

fn responseHeaderHasToken(head: std.http.Client.Response.Head, wanted_name: []const u8, wanted_token: []const u8) bool {
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, wanted_name)) continue;
        var tokens = std.mem.splitScalar(u8, header.value, ',');
        while (tokens.next()) |raw_token| {
            const token = std.mem.trim(u8, raw_token, " \t");
            if (std.ascii.eqlIgnoreCase(token, wanted_token)) return true;
        }
    }
    return false;
}

fn responseIsHeaderTerminated(method: std.http.Method, status: std.http.Status) bool {
    return method == .HEAD or status.class() == .informational or status == .no_content or
        status == .reset_content or status == .not_modified;
}

fn parseChunkSizeLine(line: []const u8) !u64 {
    // Bound both parser work and extension metadata retained by the socket
    // reader. Eight KiB is ample for legitimate chunk extensions.
    if (line.len < 3 or line.len > 8 * 1024 or
        line[line.len - 2] != '\r' or line[line.len - 1] != '\n')
    {
        return error.HttpChunkInvalid;
    }
    const fields = line[0 .. line.len - 2];
    const size_end = std.mem.indexOfScalar(u8, fields, ';') orelse fields.len;
    if (size_end == 0) return error.HttpChunkInvalid;

    var size: u64 = 0;
    for (fields[0..size_end]) |byte| {
        const digit: u64 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return error.HttpChunkInvalid,
        };
        if (size > (std.math.maxInt(u64) - digit) / 16) return error.HttpChunkInvalid;
        size = size * 16 + digit;
    }

    // Chunk extensions are hop-by-hop metadata. Accept their registered and
    // private syntax without interpreting it, but reject controls/DEL so an
    // extension can never smuggle another framing line.
    for (fields[size_end..]) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.HttpChunkInvalid;
    }
    return size;
}

fn validateChunkTrailerLine(line: []const u8) !bool {
    if (line.len < 2 or line.len > 8 * 1024 or
        line[line.len - 2] != '\r' or line[line.len - 1] != '\n')
    {
        return error.HttpChunkInvalid;
    }
    if (line.len == 2) return true;
    const field = line[0 .. line.len - 2];
    if (field[0] == ' ' or field[0] == '\t') return error.HttpChunkInvalid;
    const colon = std.mem.indexOfScalar(u8, field, ':') orelse return error.HttpChunkInvalid;
    if (colon == 0) return error.HttpChunkInvalid;
    const name = field[0..colon];
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
            return error.HttpChunkInvalid;
    }
    if (std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "content-encoding"))
    {
        return error.HttpChunkInvalid;
    }
    for (field[colon + 1 ..]) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.HttpChunkInvalid;
    }
    return false;
}

/// Decode transfer-encoding: chunked with strict RFC 9112 framing. Zig 0.17's
/// generic parser intentionally accepts bare LF and non-hex alphabetic digits;
/// provider downloads need a stricter trust boundary before decompression.
/// Decode one raw `transfer-encoding: chunked` payload without relying on
/// `std.http`'s deliberately permissive chunk parser. The input must begin at
/// the first chunk-size line. This pure-reader entry point also keeps malformed
/// framing tests deterministic and reusable by provider-specific transports.
pub fn readStrictChunkedPayload(input: *std.Io.Reader, allocator: Allocator, max_encoded_bytes: usize) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    var chunk_count: usize = 0;
    var framing_bytes: usize = 0;

    while (true) {
        const line = input.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.ReadFailed => return err,
            error.EndOfStream => return error.HttpChunkTruncated,
            error.StreamTooLong => return error.HttpChunkInvalid,
        };
        chunk_count += 1;
        if (chunk_count > 64 * 1024) return error.HttpChunkInvalid;
        framing_bytes = std.math.add(usize, framing_bytes, line.len) catch return error.HttpChunkInvalid;
        if (framing_bytes > 1024 * 1024) return error.HttpChunkInvalid;
        const size_u64 = try parseChunkSizeLine(line);
        const size = std.math.cast(usize, size_u64) orelse return error.ResponseTooLarge;
        if (size > max_encoded_bytes -| output.written().len) return error.ResponseTooLarge;

        if (size == 0) {
            var trailer_bytes: usize = 0;
            while (true) {
                const trailer = input.takeDelimiterInclusive('\n') catch |err| switch (err) {
                    error.ReadFailed => return err,
                    error.EndOfStream => return error.HttpChunkTruncated,
                    error.StreamTooLong => return error.HttpChunkInvalid,
                };
                trailer_bytes = std.math.add(usize, trailer_bytes, trailer.len) catch return error.HttpChunkInvalid;
                if (trailer_bytes > 32 * 1024) return error.HttpChunkInvalid;
                if (try validateChunkTrailerLine(trailer)) break;
            }
            return output.toOwnedSlice();
        }

        var remaining = size;
        while (remaining != 0) {
            try runtime_io.get().checkCancel();
            const count = @min(remaining, 64 * 1024);
            input.streamExact(&output.writer, count) catch |err| switch (err) {
                error.ReadFailed => return err,
                error.EndOfStream => return error.HttpChunkTruncated,
                error.WriteFailed => return error.OutOfMemory,
            };
            remaining -= count;
        }
        const suffix = input.take(2) catch |err| switch (err) {
            error.ReadFailed => return err,
            error.EndOfStream => return error.HttpChunkTruncated,
        };
        if (!std.mem.eql(u8, suffix, "\r\n")) return error.HttpChunkInvalid;
        framing_bytes += 2;
        if (framing_bytes > 1024 * 1024) return error.HttpChunkInvalid;
    }
}

fn readStrictChunkedBody(request: *std.http.Client.Request, allocator: Allocator, max_encoded_bytes: usize) ![]u8 {
    const body = readStrictChunkedPayload(request.reader.in, allocator, max_encoded_bytes) catch |err| switch (err) {
        error.ReadFailed => return normalizeRequestReadError(request, err),
        else => return err,
    };
    request.reader.state = .ready;
    return body;
}

/// Read an identity-encoded response with strict RFC 9112 transfer framing.
/// Callers must retain any header slices they need before invoking this helper,
/// because initializing a body reader invalidates response-head string fields.
pub fn readStrictResponseBody(
    request: *std.http.Client.Request,
    response: *std.http.Client.Response,
    allocator: Allocator,
    max_response_bytes: usize,
) ![]u8 {
    try validateResponseFraming(response.head);
    if (responseIsHeaderTerminated(request.method, response.head.status)) {
        if (request.connection) |connection| connection.closing = true;
        _ = request.reader.bodyReader(&.{}, .none, 0);
        return allocator.alloc(u8, 0);
    }
    if (response.head.content_encoding != .identity) return error.UnsupportedCompressionMethod;
    const expected_length: ?usize = if (response.head.content_length) |length|
        std.math.cast(usize, length) orelse return error.ResponseTooLarge
    else
        null;
    if (expected_length) |length| {
        if (length > max_response_bytes) return error.ResponseTooLarge;
    }
    if (response.head.transfer_encoding == .chunked) {
        return readStrictChunkedBody(request, allocator, max_response_bytes);
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var received: usize = 0;
    while (true) {
        try runtime_io.get().checkCancel();
        if (received == max_response_bytes) {
            _ = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return responseReadError(response, request, null),
            };
            return error.ResponseTooLarge;
        }
        const count = reader.stream(&writer.writer, .limited(max_response_bytes - received)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return responseReadError(response, request, null),
            error.WriteFailed => return normalizeAllocatingWriterError(err),
        };
        received += count;
    }
    switch (request.reader.state) {
        .body_remaining_content_length => |left| if (left != 0) return error.HttpBodyTruncated,
        .body_remaining_chunk_len => return error.HttpChunkTruncated,
        else => {},
    }
    if (expected_length) |length| {
        if (received != length) return error.HttpBodyTruncated;
    }
    var body = writer.toArrayList();
    errdefer body.deinit(allocator);
    return body.toOwnedSlice(allocator);
}

fn verifyFlateChecksum(decompress: *const std.http.Decompress, hasher: std.compress.flate.Container.Hasher, encoding: std.http.ContentEncoding) !void {
    switch (encoding) {
        .gzip => {
            const expected = decompress.flate.container_metadata.gzip;
            const actual = hasher.gzip;
            if (actual.crc.final() != expected.crc) return error.WrongGzipChecksum;
            if (actual.count != expected.count) return error.WrongGzipSize;
        },
        .deflate => {
            const expected = decompress.flate.container_metadata.zlib;
            const actual = hasher.zlib;
            if (actual.adler != expected.adler) return error.WrongZlibChecksum;
        },
        else => {},
    }
}

fn normalizeWrappedTransportError(wrapper: anyerror, underlying: ?anyerror) anyerror {
    return underlying orelse wrapper;
}

/// Recover the concrete connection error hidden by std.http's WriteFailed.
/// In particular, cancellation must remain terminal instead of becoming a
/// retryable generic transport failure.
pub fn normalizeRequestWriteError(request: *std.http.Client.Request, err: anyerror) anyerror {
    if (err != error.WriteFailed) return err;
    const connection = request.connection orelse return err;
    return normalizeWrappedTransportError(err, connection.stream_writer.err);
}

/// `std.Io.Writer.Allocating` reports allocation failure through its generic
/// writer interface. Its only WriteFailed cause is allocator exhaustion.
pub fn normalizeAllocatingWriterError(err: anyerror) anyerror {
    return if (err == error.WriteFailed) error.OutOfMemory else err;
}

/// Recover the concrete connection error hidden by std.http's ReadFailed.
/// This is suitable for receiveHead and for response readers after bodyErr has
/// already been checked.
pub fn normalizeRequestReadError(request: *std.http.Client.Request, err: anyerror) anyerror {
    if (err != error.ReadFailed) return err;
    const connection = request.connection orelse return err;
    const underlying: ?anyerror = switch (connection.protocol) {
        .plain => connection.stream_reader.err,
        .tls => tls: {
            if (std.http.Client.disable_tls) break :tls null;
            // Request.reader.in is initialized from Connection.reader(). Avoid
            // Connection.getReadError(), whose implementation force-unwraps
            // when ReadFailed came from a decoder rather than the transport.
            if (request.reader.in != connection.reader()) break :tls null;
            const tls_client: *const std.crypto.tls.Client = @alignCast(@fieldParentPtr("reader", request.reader.in));
            if (tls_client.read_err) |read_err| break :tls @as(anyerror, read_err);
            if (connection.stream_reader.err) |stream_err| break :tls @as(anyerror, stream_err);
            break :tls null;
        },
    };
    return normalizeWrappedTransportError(err, underlying);
}

const RedirectDisposition = struct {
    method: std.http.Method,
    preserve_payload: bool,
};

fn redirectDisposition(status: std.http.Status, method: std.http.Method, has_payload: bool, cross_origin: bool) !RedirectDisposition {
    std.debug.assert(isRedirectStatus(status));
    var result: RedirectDisposition = .{
        .method = method,
        .preserve_payload = has_payload,
    };
    if (status == .see_other or ((status == .moved_permanently or status == .found) and method == .POST)) {
        if (method != .HEAD) result.method = .GET;
        result.preserve_payload = false;
    }

    // A provider-controlled redirect must not forward an opaque request body
    // or a state-changing method to another origin. GET/HEAD without a body
    // remain useful for ordinary CDN redirects.
    if (cross_origin and (result.preserve_payload or (result.method != .GET and result.method != .HEAD))) {
        return error.UnsafeHttpTarget;
    }
    return result;
}

fn isCrossOriginSafeRequestHeader(name: []const u8) bool {
    // Treat caller-supplied headers as origin-bound unless they are ordinary
    // response-content negotiation. Unknown extensions frequently carry API
    // keys, CSRF tokens, signed request metadata, or other bearer material.
    return std.ascii.eqlIgnoreCase(name, "accept") or
        std.ascii.eqlIgnoreCase(name, "accept-language") or
        std.ascii.eqlIgnoreCase(name, "accept-charset");
}

fn resolveFetchRedirect(allocator: Allocator, current: []const u8, location: []const u8) ![]u8 {
    const resolved = resolveUrl(allocator, current, location) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidDownloadUrl,
    };
    defer allocator.free(resolved);
    // std.Uri deliberately accepts raw spaces and tabs in parsed paths and
    // would serialize them into the HTTP request line. Initial caller URLs are
    // normalized before this loop; apply the same boundary to every hop.
    return normalizeUrlForFetch(allocator, resolved);
}

fn fetchWithRedirects(client: *std.http.Client, allocator: Allocator, start_url: []const u8, opts: FetchOptions, initial_headers: std.http.Client.Request.Headers, extra_headers: []const std.http.Header, output: *std.Io.Writer) !std.http.Client.FetchResult {
    const accepted_content_encodings = try acceptedContentEncodings(opts.extra_headers);
    var current: []const u8 = try allocator.dupe(u8, start_url);
    defer allocator.free(current);
    var method = opts.method;
    var payload = opts.payload;
    var private_allowed = true;
    var redirects: usize = 0;
    while (true) {
        try validateFetchTarget(current, opts);
        const path_private_allowed = if (opts.private_headers_path_prefix) |prefix|
            privateHeadersPathMatches(current, prefix)
        else
            true;
        const private_headers_allowed = private_allowed and path_private_allowed;
        var headers = initial_headers;
        var selected: std.ArrayList(std.http.Header) = .empty;
        defer selected.deinit(allocator);
        if (opts.require_public_origin) headers.host = .default;
        if (!private_headers_allowed) {
            headers.authorization = .omit;
            headers.host = .default;
            // These typed fields may also have originated in caller-supplied
            // extra_headers. Reset them rather than letting an arbitrary value
            // bypass the cross-origin safe-header allowlist below.
            headers.user_agent = .{ .override = default_user_agent };
            headers.connection = .default;
            headers.content_type = .omit;
        }
        if (payload == null and opts.payload != null) headers.content_type = .omit;
        for (extra_headers) |header| {
            if (!private_headers_allowed and !isCrossOriginSafeRequestHeader(header.name)) continue;
            try selected.append(allocator, header);
        }
        const pinned_connection = if (opts.require_public_origin)
            try connectPinnedPublicHttpUrl(client, allocator, current)
        else
            null;
        if (pinned_connection) |connection| connection.closing = true;
        const request_options: std.http.Client.RequestOptions = .{
            .redirect_behavior = .unhandled,
            .handle_continue = false,
            .keep_alive = !opts.require_public_origin,
            .connection = pinned_connection,
            .headers = headers,
            .extra_headers = selected.items,
        };
        var request = client.request(method, try std.Uri.parse(current), request_options) catch |err| {
            if (pinned_connection) |connection| client.connection_pool.release(connection, client.io);
            return err;
        };
        defer request.deinit();
        errdefer request.connection.?.closing = true;
        // Keep the response decoder mask identical to the serialized
        // Accept-Encoding value. Zstd remains disabled: Zig 0.17's decoder has
        // a fixed window ceiling and cannot safely verify content checksums.
        request.accept_encoding = accepted_content_encodings;
        if (method.requestHasBody()) {
            const body = payload orelse "";
            request.transfer_encoding = .{ .content_length = body.len };
            var writer = request.sendBodyUnflushed(&.{}) catch |err| return normalizeRequestWriteError(&request, err);
            writer.writer.writeAll(body) catch |err| return normalizeRequestWriteError(&request, err);
            writer.end() catch |err| return normalizeRequestWriteError(&request, err);
            request.connection.?.flush() catch |err| return normalizeRequestWriteError(&request, err);
        } else request.sendBodiless() catch |err| return normalizeRequestWriteError(&request, err);
        var head_buffer: [32 * 1024]u8 = undefined;
        var response = request.receiveHead(&head_buffer) catch |err| return normalizeRequestReadError(&request, err);
        var interim_count: usize = 0;
        var peer_requested_close = false;
        while (response.head.status.class() == .informational) {
            if (response.head.status == .switching_protocols) return error.UnsupportedProtocolUpgrade;
            try validateResponseFraming(response.head);
            peer_requested_close = peer_requested_close or responseHeaderHasToken(response.head, "connection", "close");
            interim_count += 1;
            if (interim_count > 16) return error.TooManyInformationalResponses;
            response = request.receiveHead(&head_buffer) catch |err| return normalizeRequestReadError(&request, err);
        }
        try validateResponseFraming(response.head);
        peer_requested_close = peer_requested_close or responseHeaderHasToken(response.head, "connection", "close");
        // Zig 0.17 compares the whole Connection value to "close". Honor the
        // RFC token-list form too so a closing socket never enters the pool.
        if (peer_requested_close) request.connection.?.closing = true;
        if (isRedirectStatus(response.head.status)) {
            // Do not drain an untrusted redirect body during request cleanup.
            request.connection.?.closing = true;
            if (redirects == 5) return error.TooManyHttpRedirects;
            const next = try resolveFetchRedirect(
                allocator,
                current,
                response.head.location orelse return error.HttpRedirectLocationMissing,
            );
            errdefer allocator.free(next);
            try validateFetchTarget(next, opts);
            const cross_origin = !try sameOrigin(current, next);
            if (cross_origin and opts.require_same_origin) return error.UnsafeHttpTarget;
            const disposition = try redirectDisposition(response.head.status, method, payload != null, cross_origin);
            method = disposition.method;
            if (!disposition.preserve_payload) payload = null;
            if (cross_origin) private_allowed = false;
            allocator.free(current);
            current = next;
            redirects += 1;
            continue;
        }
        if (responseIsHeaderTerminated(method, response.head.status)) {
            // These responses end at the header terminator even when their
            // metadata describes a hypothetical representation. Do not pool
            // the socket: an invalid peer that appends body bytes could
            // otherwise make those bytes the next keep-alive response.
            request.connection.?.closing = true;
            _ = request.reader.bodyReader(&.{}, .none, 0);
            return .{ .status = response.head.status };
        }
        if (response.head.content_length) |content_length| {
            if (content_length > @as(u64, @intCast(opts.max_encoded_response_bytes))) {
                return error.ResponseTooLarge;
            }
        }
        const decompression_size: usize = switch (response.head.content_encoding) {
            .identity => 0,
            // Defense in depth: the request mask never advertises zstd, but
            // reject it here too if std.http's negotiation behavior changes.
            .zstd => return error.UnsupportedCompressionMethod,
            .deflate, .gzip => std.compress.flate.max_window_len,
            .compress => return error.UnsupportedCompressionMethod,
        };
        const decompression_buffer = try allocator.alloc(u8, decompression_size);
        defer allocator.free(decompression_buffer);
        var transfer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const encoding = response.head.content_encoding;
        var owned_chunked_body: ?[]u8 = null;
        defer if (owned_chunked_body) |body| allocator.free(body);
        var fixed_chunked_reader: std.Io.Reader = undefined;
        const transfer_reader = if (response.head.transfer_encoding == .chunked) blk: {
            const body = try readStrictChunkedBody(&request, allocator, opts.max_encoded_response_bytes);
            owned_chunked_body = body;
            fixed_chunked_reader = .fixed(body);
            break :blk &fixed_chunked_reader;
        } else response.reader(&transfer);
        // Keep one sentinel byte beyond the configured limit. Exhausting it
        // proves that the encoded body is too large without confusing an
        // artificial boundary with a legitimate end of stream.
        var encoded_buffer: [2048]u8 = undefined;
        var bounded_transfer = transfer_reader.limited(
            .limited(try encodedResponseReadLimit(opts.max_encoded_response_bytes)),
            &encoded_buffer,
        );
        const encoded_reader = &bounded_transfer.interface;
        var received: usize = 0;
        var members: usize = 0;
        while (true) {
            members += 1;
            if (members > 1024) return error.TooManyCompressedMembers;
            const reader = decompress.init(encoded_reader, decompression_buffer, encoding);
            const container: std.compress.flate.Container = switch (encoding) {
                .gzip => .gzip,
                .deflate => .zlib,
                else => .raw,
            };
            var hashed_output = output.hashed(std.compress.flate.Container.Hasher.init(container), &.{});
            const member_output = if (encoding == .gzip or encoding == .deflate) &hashed_output.writer else output;
            while (true) {
                try runtime_io.get().checkCancel();
                if (received == opts.max_response_bytes) {
                    _ = reader.takeByte() catch |err| switch (err) {
                        error.EndOfStream => break,
                        error.ReadFailed => {
                            if (bounded_transfer.remaining == .nothing) return error.ResponseTooLarge;
                            return responseReadError(&response, &request, &decompress);
                        },
                    };
                    if (bounded_transfer.remaining == .nothing) return error.ResponseTooLarge;
                    return error.ResponseTooLarge;
                }
                const read_limit = @min(opts.max_response_bytes - received, 64 * 1024);
                const count = reader.stream(member_output, .limited(read_limit)) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => {
                        if (bounded_transfer.remaining == .nothing) return error.ResponseTooLarge;
                        return responseReadError(&response, &request, &decompress);
                    },
                    error.WriteFailed => return normalizeAllocatingWriterError(err),
                };
                if (bounded_transfer.remaining == .nothing) return error.ResponseTooLarge;
                received += count;
            }
            try verifyFlateChecksum(&decompress, hashed_output.hasher, encoding);
            if (bounded_transfer.remaining == .nothing) return error.ResponseTooLarge;
            if (encoding == .identity) break;
            // Decoder EOF can precede the chunk terminator/trailers. Preserve
            // any next member's first byte while validating transfer framing.
            _ = encoded_reader.peekByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (bounded_transfer.remaining == .nothing) return error.ResponseTooLarge;
                    break;
                },
                error.ReadFailed => {
                    if (bounded_transfer.remaining == .nothing) return error.ResponseTooLarge;
                    return responseReadError(&response, &request, null);
                },
            };
            if (bounded_transfer.remaining == .nothing) return error.ResponseTooLarge;
            if (encoding != .gzip) return error.UnexpectedEncodedPayload;
            // RFC 1952 permits concatenated gzip members; the same aggregate
            // decoded-byte limit applies to every member.
        }
        switch (request.reader.state) {
            .body_remaining_content_length => |left| if (left != 0) {
                return error.HttpBodyTruncated;
            },
            .body_remaining_chunk_len => return error.HttpChunkTruncated,
            else => {},
        }
        return .{ .status = response.head.status };
    }
}

pub fn ensureClientTlsReady(client: *std.http.Client) !void {
    try acquireClientInitLockUsing(sleepMillisecondsCancelable);
    defer client_init_lock.store(0, .release);

    // `std.http.Client.request` reads these fields under ca_bundle_lock. Use
    // the same lock here so a concurrent direct client request cannot observe
    // `now` updated while the old (possibly empty) bundle is still installed.
    try client.ca_bundle_lock.lockShared(client.io);
    const already_ready = client.now != null;
    client.ca_bundle_lock.unlockShared(client.io);
    if (already_ready) return;

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(client.io);
    try bundle.rescan(client.allocator, client.io, now);

    try client.ca_bundle_lock.lock(client.io);
    defer client.ca_bundle_lock.unlock(client.io);
    // Another user of std.http may have initialized this client while the
    // filesystem scan above was in progress.
    if (client.now != null) return;
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

fn acquireClientInitLockUsing(comptime pause: anytype) !void {
    while (client_init_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        try pause(1);
    }
}

fn findHeaderValue(headers: []const std.http.Header, wanted_name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, wanted_name)) return header.value;
    }
    return null;
}

fn typedHeaderOverride(headers: []const std.http.Header, wanted_name: []const u8) std.http.Client.Request.Headers.Value {
    const value = findHeaderValue(headers, wanted_name) orelse return .default;
    return .{ .override = value };
}

const AcceptedContentEncodings = @TypeOf(std.http.Client.Request.default_accept_encoding);

fn httpQualityAccepted(text: []const u8) !bool {
    if (text.len == 0) return error.InvalidHttpHeader;
    if (text[0] != '0' and text[0] != '1') return error.InvalidHttpHeader;
    if (text.len == 1) return text[0] == '1';
    if (text[1] != '.' or text.len > 5) return error.InvalidHttpHeader;
    var nonzero = text[0] == '1';
    for (text[2..]) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidHttpHeader;
        if (text[0] == '1' and digit != '0') return error.InvalidHttpHeader;
        nonzero = nonzero or digit != '0';
    }
    return nonzero;
}

fn acceptedContentEncodings(headers: []const std.http.Header) !AcceptedContentEncodings {
    const value = findHeaderValue(headers, "accept-encoding") orelse {
        var defaults = std.http.Client.Request.default_accept_encoding;
        // Zig 0.17's zstd decoder uses a fixed window ceiling and deliberately
        // disables content-checksum verification. Do not advertise it until
        // both properties can be enforced by this transport.
        defaults[@backingInt(std.http.ContentEncoding.zstd)] = false;
        return defaults;
    };

    var result: AcceptedContentEncodings = @splat(false);
    // RFC 9110 permits identity unless it is explicitly assigned q=0. Since
    // wildcards advertise methods this transport cannot decode, they are
    // rejected below rather than used to alter this default.
    result[@backingInt(std.http.ContentEncoding.identity)] = true;
    var seen: AcceptedContentEncodings = @splat(false);
    var values = std.mem.splitScalar(u8, value, ',');
    var value_count: usize = 0;
    while (values.next()) |raw_value| {
        value_count += 1;
        var pieces = std.mem.splitScalar(u8, raw_value, ';');
        const coding = std.mem.trim(u8, pieces.next().?, " \t");
        if (coding.len == 0) return error.InvalidHttpHeader;

        const encoding: std.http.ContentEncoding = if (std.ascii.eqlIgnoreCase(coding, "identity"))
            .identity
        else if (std.ascii.eqlIgnoreCase(coding, "gzip"))
            .gzip
        else if (std.ascii.eqlIgnoreCase(coding, "deflate"))
            .deflate
        else
            return error.UnsupportedCompressionMethod;

        const index = @backingInt(encoding);
        if (seen[index]) return error.InvalidHttpHeader;
        seen[index] = true;

        var accepted = true;
        if (pieces.next()) |raw_parameter| {
            const parameter = std.mem.trim(u8, raw_parameter, " \t");
            if (parameter.len < 3 or (parameter[0] != 'q' and parameter[0] != 'Q')) return error.InvalidHttpHeader;
            var equals_index: usize = 1;
            while (equals_index < parameter.len and (parameter[equals_index] == ' ' or parameter[equals_index] == '\t')) : (equals_index += 1) {}
            if (equals_index == parameter.len or parameter[equals_index] != '=') return error.InvalidHttpHeader;
            const quality_text = std.mem.trim(u8, parameter[equals_index + 1 ..], " \t");
            accepted = try httpQualityAccepted(quality_text);
            if (pieces.next() != null) return error.InvalidHttpHeader;
        }
        result[index] = accepted;
    }
    if (value_count == 0) return error.InvalidHttpHeader;
    return result;
}

fn isTypedRequestHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "user-agent") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "accept-encoding") or
        std.ascii.eqlIgnoreCase(name, "content-type");
}

pub fn normalizeUrlForFetch(allocator: Allocator, url: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var scheme_end: usize = 0;
    var has_scheme_delimiter = false;
    var authority_start = url.len;
    var authority_end = url.len;
    if (std.mem.indexOf(u8, url, "://")) |end| {
        scheme_end = end;
        has_scheme_delimiter = true;
        authority_start = end + 3;
        const relative_end = std.mem.indexOfAny(u8, url[authority_start..], "/?#") orelse
            url.len - authority_start;
        authority_end = authority_start + relative_end;
    }

    var i: usize = 0;
    while (i < url.len) {
        const c = url[i];

        // Preserve existing escapes. Double-escaping provider URLs breaks
        // already-encoded search terms and path components.
        if (c == '%' and i + 2 < url.len and isHex(url[i + 1]) and isHex(url[i + 2])) {
            try out.appendSlice(allocator, url[i .. i + 3]);
            i += 3;
            continue;
        }

        const is_ipv6_authority_delimiter =
            i >= authority_start and i < authority_end and (c == '[' or c == ']');
        if (isSafeUrlByte(c) or is_ipv6_authority_delimiter) {
            // URI schemes are case-insensitive, while std.http's protocol
            // lookup is deliberately case-sensitive.
            try out.append(allocator, if (has_scheme_delimiter and i < scheme_end) std.ascii.toLower(c) else c);
        } else {
            const hi = "0123456789ABCDEF"[c >> 4];
            const lo = "0123456789ABCDEF"[c & 0xF];
            try out.appendSlice(allocator, &.{ '%', hi, lo });
        }
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

pub fn validateFetchTarget(url: []const u8, opts: FetchOptions) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidDownloadUrl;
    const host_component = uri.host orelse return error.InvalidDownloadUrl;
    const host = switch (host_component) {
        .raw, .percent_encoded => |value| value,
    };
    if (host.len == 0) return error.InvalidDownloadUrl;

    if (opts.require_public_origin) try validatePublicHttpUrl(url);
    if (opts.require_https and !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        return error.UnsafeHttpTarget;
}

fn privateHeadersPathMatches(url: []const u8, prefix: []const u8) bool {
    if (!isCanonicalPrivateHeaderPath(prefix)) return false;
    const uri = std.Uri.parse(url) catch return false;
    if (uri.fragment != null) return false;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| if (value.len == 0) "/" else value,
    };
    if (!isCanonicalPrivateHeaderPath(path)) return false;
    if (std.mem.eql(u8, prefix, "/") or std.mem.eql(u8, path, prefix)) return true;
    return std.mem.startsWith(u8, path, prefix) and
        path.len > prefix.len and path[prefix.len] == '/';
}

fn isCanonicalPrivateHeaderPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or
        std.mem.indexOfScalar(u8, path, '%') != null or
        std.mem.indexOfScalar(u8, path, '\\') != null or
        std.mem.indexOf(u8, path, "//") != null)
    {
        return false;
    }
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

/// Validate an untrusted network target before a request is sent. Provider
/// download URLs never need embedded credentials, local names, or literal
/// private/reserved addresses. Redirects are checked through the same path.
pub fn validatePublicHttpUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null) return error.UnsafeHttpTarget;

    const component = uri.host orelse return error.InvalidDownloadUrl;
    const raw_host = switch (component) {
        .raw, .percent_encoded => |host| host,
    };
    // Escaped host bytes can obscure separators and address syntax. Parsed
    // ordinary hosts may still use the percent_encoded component tag, so
    // inspect the actual bytes rather than the union tag.
    if (std.mem.indexOfScalar(u8, raw_host, '%') != null) return error.UnsafeHttpTarget;
    if (isUnsafePublicHost(raw_host)) return error.UnsafeHttpTarget;
}

fn isUnsafePublicHost(raw_host: []const u8) bool {
    var host = std.mem.trim(u8, raw_host, " \t\r\n");
    while (host.len > 0 and host[host.len - 1] == '.') host = host[0 .. host.len - 1];
    if (host.len == 0) return true;

    if (std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.endsWithIgnoreCase(host, ".localhost") or
        std.ascii.eqlIgnoreCase(host, "local") or
        std.ascii.endsWithIgnoreCase(host, ".local") or
        std.ascii.eqlIgnoreCase(host, "internal") or
        std.ascii.endsWithIgnoreCase(host, ".internal") or
        std.ascii.eqlIgnoreCase(host, "invalid") or
        std.ascii.endsWithIgnoreCase(host, ".invalid") or
        std.ascii.eqlIgnoreCase(host, "test") or
        std.ascii.endsWithIgnoreCase(host, ".test") or
        std.ascii.eqlIgnoreCase(host, "example") or
        std.ascii.endsWithIgnoreCase(host, ".example") or
        std.ascii.eqlIgnoreCase(host, "home.arpa") or
        std.ascii.endsWithIgnoreCase(host, ".home.arpa")) return true;

    // Literal IPv6 targets are unnecessary for provider downloads. Rejecting
    // them also covers IPv4-mapped and alternate loopback spellings.
    if (std.mem.indexOfScalar(u8, host, ':') != null or
        host[0] == '[' or host[host.len - 1] == ']') return true;

    // Dotless names are subject to local resolver search paths and can target
    // an intranet host even when the literal spelling appears harmless.
    if (std.mem.indexOfScalar(u8, host, '.') == null) return true;

    if (parseIpv4Address(host)) |ip| return isUnsafeIpv4(ip);

    // Reject non-canonical integer/hex/octal address spellings that URL
    // stacks may normalize to an IP address after this check. Parse numeric
    // components rather than using a character class: public DNS names such as
    // `1a.cafe` start with a digit and contain only hexadecimal letters, but
    // neither label is an IPv4 number.
    if (looksLikeLegacyIpv4Address(host)) return true;
    return false;
}

fn looksLikeLegacyIpv4Address(host: []const u8) bool {
    var parts = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > 4 or part.len == 0) return false;

        if (part.len > 2 and part[0] == '0' and (part[1] == 'x' or part[1] == 'X')) {
            for (part[2..]) |c| if (!isHex(c)) return false;
            continue;
        }
        for (part) |c| if (c < '0' or c > '9') return false;
    }
    return count != 0;
}

fn isUnsafeIpv4(ip: [4]u8) bool {
    const a = ip[0];
    const b = ip[1];
    if (a == 0 or a == 10 or a == 127 or a >= 224) return true;
    if (a == 100 and b >= 64 and b <= 127) return true;
    if (a == 169 and b == 254) return true;
    if (a == 172 and b >= 16 and b <= 31) return true;
    // IANA's protocol-assignment block is 192.0.0.0/24, not /16. PCP and
    // TURN anycast are the two globally reachable assignments in that block.
    if (a == 192 and b == 0 and ip[2] == 0 and ip[3] != 9 and ip[3] != 10) return true;
    if (a == 192 and b == 0 and ip[2] == 2) return true;
    // The deprecated 6to4 relay block and its 6a44 assignment are non-global.
    if (a == 192 and b == 88 and ip[2] == 99) return true;
    if (a == 192 and b == 168) return true;
    if (a == 198 and (b == 18 or b == 19)) return true;
    if (a == 198 and b == 51 and ip[2] == 100) return true;
    if (a == 203 and b == 0 and ip[2] == 113) return true;
    return false;
}

const non_global_ipv6_prefixes = [_]struct {
    bytes: []const u8,
    bits: usize,
}{
    // IETF protocol assignments. This covers Teredo, benchmarking,
    // ORCHID/ORCHIDv2, and other special-purpose sub-allocations that a
    // provider hostname must never need.
    .{ .bytes = &.{ 0x20, 0x01, 0x00 }, .bits = 23 },
    // Documentation prefixes.
    .{ .bytes = &.{ 0x20, 0x01, 0x0d, 0xb8 }, .bits = 32 },
    .{ .bytes = &.{ 0x3f, 0xff, 0x00 }, .bits = 20 },
    // 6to4 can tunnel to an IPv4 address encoded in the next 32 bits, so an
    // apparently global IPv6 DNS answer could otherwise evade IPv4 policy.
    .{ .bytes = &.{ 0x20, 0x02 }, .bits = 16 },
    // The retired 6bone allocation is not globally routable.
    .{ .bytes = &.{ 0x3f, 0xfe }, .bits = 16 },
};

fn bytesHavePrefix(bytes: []const u8, prefix: []const u8, prefix_bits: usize) bool {
    const whole_bytes = prefix_bits / 8;
    const partial_bits = prefix_bits % 8;
    const required = whole_bytes + @intFromBool(partial_bits != 0);
    if (prefix.len < required or bytes.len < required) return false;
    if (!std.mem.eql(u8, bytes[0..whole_bytes], prefix[0..whole_bytes])) return false;
    if (partial_bits == 0) return true;
    const masks = [_]u8{ 0x00, 0x80, 0xc0, 0xe0, 0xf0, 0xf8, 0xfc, 0xfe };
    const mask = masks[partial_bits];
    return (bytes[whole_bytes] & mask) == (prefix[whole_bytes] & mask);
}

fn isUnsafeResolvedAddress(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| isUnsafeIpv4(ip4.bytes),
        .ip6 => |ip6| blk: {
            const bytes = ip6.bytes;
            const mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            if (std.mem.eql(u8, bytes[0..12], &mapped_prefix)) {
                break :blk isUnsafeIpv4(.{ bytes[12], bytes[13], bytes[14], bytes[15] });
            }
            // Only globally routed unicast space (2000::/3) is suitable for
            // provider downloads, and special-purpose sub-ranges within that
            // broad allocation remain ineligible.
            if ((bytes[0] & 0xe0) != 0x20) break :blk true;
            for (non_global_ipv6_prefixes) |prefix| {
                if (bytesHavePrefix(bytes[0..], prefix.bytes, prefix.bits)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// Resolve once, reject the complete answer set if any address is unsafe, and
/// return the exact addresses that the caller is allowed to connect to.
fn resolvePublicHttpAddresses(allocator: Allocator, io: std.Io, url: []const u8) ![]std.Io.net.IpAddress {
    const uri = try std.Uri.parse(url);
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try std.Io.net.HostName.fromUri(uri, &host_buffer);
    const port: u16 = uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;

    var addresses: std.ArrayListUnmanaged(std.Io.net.IpAddress) = .empty;
    errdefer addresses.deinit(allocator);

    var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    var lookup = io.async(std.Io.net.HostName.lookup, .{ host, io, &lookup_queue, .{ .port = port } });
    defer lookup.cancel(io) catch {};

    while (lookup_queue.getOne(io)) |result| switch (result) {
        .address => |address| {
            if (isUnsafeResolvedAddress(address)) return error.UnsafeHttpTarget;
            try addresses.append(allocator, address);
        },
        .canonical_name => |canonical| if (isUnsafePublicHost(canonical.bytes)) return error.UnsafeHttpTarget,
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => {
            try lookup.await(io);
            if (addresses.items.len == 0) return error.NoAddressReturned;
            return addresses.toOwnedSlice(allocator);
        },
    }
}

/// Resolve a public HTTP(S) origin once, reject the complete answer set when
/// any address is non-public, and select an IPv4 address suitable for an
/// external client's resolver-pinning configuration.
fn resolvePublicHttpIpv4Unbounded(allocator: Allocator, io: std.Io, url: []const u8) ![4]u8 {
    try validatePublicHttpUrl(url);
    const addresses = try resolvePublicHttpAddresses(allocator, io, url);
    defer allocator.free(addresses);
    for (addresses) |address| switch (address) {
        .ip4 => |ip4| return ip4.bytes,
        .ip6 => {},
    };
    return error.NoAddressReturned;
}

/// Deadline-supervised form used when an external process will rely on the
/// returned address as an egress policy. When the timeout wins, the resolver
/// task is canceled and joined before return. The deadline is therefore
/// cooperative: a platform resolver without prompt cancellation can finish
/// after the requested wall-clock budget.
pub fn resolvePublicHttpIpv4(allocator: Allocator, io: std.Io, url: []const u8, deadline_ms: i64) ![4]u8 {
    const now = compatMilliTimestamp();
    if (now >= deadline_ms) return error.Timeout;
    const duration: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(deadline_ms -| now),
        .clock = .awake,
    };
    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, duration) };

    const LookupResult = @typeInfo(@TypeOf(resolvePublicHttpIpv4Unbounded)).@"fn".return_type.?;
    const TimeoutResult = @typeInfo(@TypeOf(std.Io.Timeout.sleep)).@"fn".return_type.?;
    const Selection = union(enum) {
        lookup: LookupResult,
        timeout: TimeoutResult,
    };
    var selection_buffer: [2]Selection = undefined;
    var selection = std.Io.Select(Selection).init(io, &selection_buffer);
    defer selection.cancelDiscard();
    try selection.concurrent(.lookup, resolvePublicHttpIpv4Unbounded, .{ allocator, io, url });
    try selection.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, io });

    return switch (try selection.await()) {
        .lookup => |result| result,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    };
}

/// Format a resolver result as a numeric host without its port. Zig's resolver
/// recognizes these strings as literals before consulting hosts files or DNS.
fn formatNumericHost(address: std.Io.net.IpAddress, buffer: []u8) ![]u8 {
    return switch (address) {
        .ip4 => |ip4| std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
            ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3],
        }),
        .ip6 => |ip6| std.fmt.bufPrint(buffer, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
            std.mem.readInt(u16, ip6.bytes[0..2], .big),
            std.mem.readInt(u16, ip6.bytes[2..4], .big),
            std.mem.readInt(u16, ip6.bytes[4..6], .big),
            std.mem.readInt(u16, ip6.bytes[6..8], .big),
            std.mem.readInt(u16, ip6.bytes[8..10], .big),
            std.mem.readInt(u16, ip6.bytes[10..12], .big),
            std.mem.readInt(u16, ip6.bytes[12..14], .big),
            std.mem.readInt(u16, ip6.bytes[14..16], .big),
        }),
    };
}

/// Connect to one of the validated resolver results while retaining the
/// original hostname for the HTTP Host field and TLS certificate/SNI checks.
pub fn connectPinnedPublicHttpUrl(client: *std.http.Client, allocator: Allocator, url: []const u8) !*std.http.Client.Connection {
    try validatePublicHttpUrl(url);
    const uri = try std.Uri.parse(url);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.InvalidDownloadUrl;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const origin_host = try std.Io.net.HostName.fromUri(uri, &host_buffer);
    const port: u16 = uri.port orelse if (protocol == .tls) 443 else 80;

    const addresses = try resolvePublicHttpAddresses(allocator, client.io, url);
    defer allocator.free(addresses);

    var last_error: anyerror = error.NoAddressReturned;
    for (addresses) |address| {
        var numeric_buffer: [64]u8 = undefined;
        const numeric_bytes = try formatNumericHost(address, &numeric_buffer);
        // Deliberately bypass HostName.init: IPv6 literals contain colons, but
        // the resolver accepts and parses them before any name lookup.
        const numeric_host: std.Io.net.HostName = .{ .bytes = numeric_bytes };
        const connection = client.connectTcpOptions(.{
            .host = numeric_host,
            .port = port,
            .protocol = protocol,
            .proxied_host = origin_host,
            .proxied_port = port,
        }) catch |err| {
            try rememberRetryableConnectError(&last_error, err);
            continue;
        };
        return connection;
    }
    return last_error;
}

fn rememberRetryableConnectError(last_error: *anyerror, err: anyerror) !void {
    if (err == error.Canceled or err == error.OutOfMemory) return err;
    last_error.* = err;
}

fn parseIpv4Address(host: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, host, '.');
    var index: usize = 0;
    while (parts.next()) |part| {
        if (index == result.len or part.len == 0) return null;
        if (part.len > 1 and part[0] == '0') return null;
        for (part) |c| if (c < '0' or c > '9') return null;
        result[index] = std.fmt.parseInt(u8, part, 10) catch return null;
        index += 1;
    }
    if (index != result.len) return null;
    return result;
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}

fn isSafeUrlByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~' or
        c == ':' or c == '/' or c == '?' or c == '#' or
        c == '@' or
        c == '!' or c == '$' or c == '&' or c == '\'' or
        c == '(' or c == ')' or c == '*' or c == '+' or
        c == ',' or c == ';' or c == '=';
}

fn hasHeader(headers: []const std.http.Header, wanted_name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, wanted_name)) return true;
    }
    return false;
}

fn validHttpHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null) continue;
        return false;
    }
    return true;
}

pub fn validHttpHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        // RFC 9110 field values may contain horizontal tabs, visible ASCII,
        // and obs-text. Every other control byte is unsafe to serialize.
        if (byte == '\t') continue;
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

pub fn validateHttpHeaders(headers: []const std.http.Header) !void {
    for (headers) |header| {
        if (!validHttpHeaderName(header.name) or !validHttpHeaderValue(header.value)) {
            return error.InvalidHttpHeader;
        }
    }
}

fn validateFetchHeaders(opts: FetchOptions) !void {
    if (opts.method == .CONNECT) return error.UnsupportedProtocolUpgrade;
    // Zig 0.17 exposes body writers only for these methods; passing a body to
    // another method would otherwise assert inside std.http in safe builds.
    if (opts.payload != null and !opts.method.requestHasBody())
        return error.InvalidHttpMethodPayload;
    _ = try encodedResponseReadLimit(opts.max_encoded_response_bytes);
    if (opts.accept) |value| if (!validHttpHeaderValue(value)) return error.InvalidHttpHeader;
    if (opts.content_type) |value| if (!validHttpHeaderValue(value)) return error.InvalidHttpHeader;
    try validateHttpHeaders(opts.extra_headers);
    var accept_encoding_count: usize = 0;
    for (opts.extra_headers) |header| {
        if (isTransportOwnedFetchHeader(header.name)) return error.TransportOwnedHttpHeader;
        if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) accept_encoding_count += 1;
    }
    if (accept_encoding_count > 1) return error.InvalidHttpHeader;
    _ = try acceptedContentEncodings(opts.extra_headers);
}

fn isTransportOwnedFetchHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "te") or
        std.ascii.eqlIgnoreCase(name, "trailer") or
        std.ascii.eqlIgnoreCase(name, "upgrade") or
        std.ascii.eqlIgnoreCase(name, "keep-alive") or
        std.ascii.eqlIgnoreCase(name, "expect") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "proxy-connection");
}

pub fn parseHtmlTurbo(allocator: Allocator, source: []const u8) !ParsedHtml {
    const debug_timing = debugTimingEnabled();
    const started_ns = if (debug_timing) compatNanoTimestamp() else 0;
    if (debug_timing) std.debug.print("[parseHtmlTurbo] start len={d}\n", .{source.len});

    const html_bytes = try allocator.dupe(u8, source);
    errdefer allocator.free(html_bytes);

    var doc = HtmlDocument.init(allocator);
    errdefer doc.deinit();

    try doc.parse(html_bytes, .{
        .drop_whitespace_text_nodes = true,
    });

    if (debug_timing) {
        const elapsed_ns = compatNanoTimestamp() - started_ns;
        std.debug.print("[parseHtmlTurbo] done in {d} ms\n", .{@divTrunc(elapsed_ns, std.time.ns_per_ms)});
    }

    return .{ .allocator = allocator, .source = html_bytes, .doc = doc };
}

pub fn parseHtmlStable(allocator: Allocator, source: []const u8) !ParsedHtml {
    const debug_timing = debugTimingEnabled();
    const started_ns = if (debug_timing) compatNanoTimestamp() else 0;
    if (debug_timing) std.debug.print("[parseHtmlStable] start len={d}\n", .{source.len});

    const html_bytes = try allocator.dupe(u8, source);
    errdefer allocator.free(html_bytes);

    var doc = HtmlDocument.init(allocator);
    errdefer doc.deinit();
    try doc.parse(html_bytes, .{
        .drop_whitespace_text_nodes = false,
    });

    if (debug_timing) {
        const elapsed_ns = compatNanoTimestamp() - started_ns;
        std.debug.print("[parseHtmlStable] done in {d} ms\n", .{@divTrunc(elapsed_ns, std.time.ns_per_ms)});
    }
    return .{ .allocator = allocator, .source = html_bytes, .doc = doc };
}

// Pass the request-local arena allocator (`const a = arena.allocator()`).
pub fn innerTextOwnedWithOptions(arena_alloc: Allocator, node: anytype, opts: html.TextOptions) ![]const u8 {
    return node.innerTextOwnedWithOptions(arena_alloc, opts);
}

// Returns an arena-backed slice; callers should not free it individually.
pub fn innerTextTrimmedOwned(arena_alloc: Allocator, node: anytype) ![]const u8 {
    return innerTextOwnedWithOptions(arena_alloc, node, .{ .normalize_whitespace = true });
}

/// Provider result markup is shallow in practice. zhtml parses nesting with an
/// iterative, growable open-element stack; this iterator likewise uses no
/// recursion and keeps at most 256 direct-child iterators on the native stack.
/// Nodes through depth 256 are visited, while deeper nodes are treated as
/// absent.
pub const max_html_descendant_depth: usize = 256;

const HtmlChildrenIterator = @TypeOf(@as(HtmlNode, undefined).children());

pub const BoundedHtmlDescendantIterator = struct {
    stack: [max_html_descendant_depth]HtmlChildrenIterator = undefined,
    stack_len: usize = 1,

    pub fn init(node: HtmlNode) BoundedHtmlDescendantIterator {
        var result: BoundedHtmlDescendantIterator = .{};
        result.stack[0] = node.children();
        return result;
    }

    pub fn next(self: *BoundedHtmlDescendantIterator) ?HtmlNode {
        while (self.stack_len > 0) {
            const child = self.stack[self.stack_len - 1].next() orelse {
                self.stack_len -= 1;
                continue;
            };
            if (self.stack_len < self.stack.len) {
                self.stack[self.stack_len] = child.children();
                self.stack_len += 1;
            }
            return child;
        }
        return null;
    }
};

pub fn boundedHtmlDescendants(node: HtmlNode) BoundedHtmlDescendantIterator {
    return .init(node);
}

pub fn findDescendantByTag(node: HtmlNode, tag_name: []const u8) ?HtmlNode {
    var descendants = boundedHtmlDescendants(node);
    while (descendants.next()) |child| {
        if (std.mem.eql(u8, child.tagName(), tag_name)) return child;
    }
    return null;
}

test "bounded HTML descendant traversal preserves ordinary depth and fails closed beyond its cap" {
    const allocator = std.testing.allocator;
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(allocator);

    try source.appendSlice(allocator, "<div id=\"depth-root\">");
    for (0..max_html_descendant_depth) |depth| {
        try source.appendSlice(allocator, "<div>");
        if (depth == max_html_descendant_depth - 2)
            try source.appendSlice(allocator, "<span></span>");
    }
    try source.appendSlice(allocator, "<abbr></abbr>");
    for (0..max_html_descendant_depth) |_| try source.appendSlice(allocator, "</div>");
    try source.appendSlice(allocator, "</div>");

    var parsed = try parseHtmlTurbo(allocator, source.items);
    defer parsed.deinit();
    const root = parsed.doc.queryOne("div#depth-root") orelse return error.MissingFixtureNode;

    // The span is exactly 256 edges below root; the abbr is one edge deeper.
    try std.testing.expect(findDescendantByTag(root, "span") != null);
    try std.testing.expect(findDescendantByTag(root, "abbr") == null);
}

/// Lowercase ASCII words, preserve valid non-ASCII codepoints, and collapse
/// punctuation, whitespace, and each malformed UTF-8 byte into separators.
/// The returned title is always valid UTF-8, even for untrusted provider text.
pub fn normalizeTitle(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        var width: usize = 1;
        var whitespace = false;
        if (c >= 0x80) {
            const count = std.unicode.utf8ByteSequenceLength(c) catch {
                pending_space = out.items.len > 0;
                i += 1;
                continue;
            };
            if (count > input.len - i) {
                pending_space = out.items.len > 0;
                i += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(input[i..][0..count]) catch {
                pending_space = out.items.len > 0;
                i += 1;
                continue;
            };
            width = count;
            whitespace = switch (cp) {
                0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
                else => false,
            };
        }
        if (!whitespace and (std.ascii.isAlphanumeric(c) or c >= 0x80)) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            if (width == 1) try out.append(allocator, std.ascii.toLower(c)) else try out.appendSlice(allocator, input[i..][0..width]);
        } else {
            pending_space = out.items.len > 0;
        }
        i += width;
    }
    return out.toOwnedSlice(allocator);
}

/// Returns true when either already-normalized title contains the other as a
/// complete space-delimited phrase. Empty strings and partial-word matches do
/// not count (for example, "reacher" does not match "preacher").
pub fn normalizedTitlesRelated(lhs: []const u8, rhs: []const u8) bool {
    return containsNormalizedTitlePhrase(lhs, rhs) or containsNormalizedTitlePhrase(rhs, lhs);
}

fn containsNormalizedTitlePhrase(haystack: []const u8, needle: []const u8) bool {
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

pub fn asciiSlug(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var dash = false;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and out.items.len > 0) try out.append(allocator, '-');
            dash = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            dash = out.items.len > 0;
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

pub fn jsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        .float => |number| if (std.math.isFinite(number) and number >= -0x1p63 and number < 0x1p63 and @trunc(number) == number) @intFromFloat(number) else null,
        else => null,
    };
}

pub fn jsonIntField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    return jsonInt(obj.get(key) orelse return null);
}

pub fn countTrue(flags: []const bool) usize {
    var count: usize = 0;
    for (flags) |enabled| {
        if (enabled) count += 1;
    }
    return count;
}

pub fn seasonEpisodeLessThan(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn lessThan(_: void, lhs: T, rhs: T) bool {
            if (lhs.season != rhs.season) return lhs.season < rhs.season;
            return lhs.episode < rhs.episode;
        }
    }.lessThan;
}

pub fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

pub fn jsonArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

pub fn looksLikeHtml(body: []const u8) bool {
    const head = std.mem.trimStart(u8, body[0..@min(body.len, 1024)], " \t\r\n");
    return std.ascii.startsWithIgnoreCase(head, "<!doctype html") or
        std.ascii.startsWithIgnoreCase(head, "<html") or
        std.ascii.findIgnoreCase(head, "<body") != null;
}

pub fn isSubtitleFilename(filename: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(filename, ".srt") or
        std.ascii.endsWithIgnoreCase(filename, ".ass") or
        std.ascii.endsWithIgnoreCase(filename, ".ssa") or
        std.ascii.endsWithIgnoreCase(filename, ".vtt") or
        std.ascii.endsWithIgnoreCase(filename, ".sub");
}

pub fn dupOptional(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

pub fn pathBaseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[slash + 1 ..];
}

pub fn isRedirectStatus(status: std.http.Status) bool {
    return status == .moved_permanently or
        status == .found or
        status == .see_other or
        status == .temporary_redirect or
        status == .permanent_redirect;
}

pub fn extractPhpSessionCookie(allocator: Allocator, headers: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const pair_end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        const pair = std.mem.trim(u8, value[0..pair_end], " \t");
        const prefix = "PHPSESSID=";
        if (!std.mem.startsWith(u8, pair, prefix) or pair.len == prefix.len) continue;
        return try allocator.dupe(u8, pair);
    }
    return null;
}

test "PHP session cookie extraction only accepts the leading cookie pair" {
    const allocator = std.testing.allocator;
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Set-Cookie: decoy=PHPSESSID=inside-a-value; Path=/\r\n" ++
        "Set-Cookie: another=value; PHPSESSID=attribute-value\r\n" ++
        "sEt-CoOkIe:\t PHPSESSID=good=session; Path=/; HttpOnly\r\n" ++
        "\r\n";
    const cookie = (try extractPhpSessionCookie(allocator, headers)) orelse
        return error.ExpectedPhpSessionCookie;
    defer allocator.free(cookie);
    try std.testing.expectEqualStrings("PHPSESSID=good=session", cookie);

    try std.testing.expect((try extractPhpSessionCookie(
        allocator,
        "Set-Cookie: other=PHPSESSID=bad; PHPSESSID=also-an-attribute\r\n\r\n",
    )) == null);
    try std.testing.expect((try extractPhpSessionCookie(
        allocator,
        "Set-Cookie: PHPSESSID=; Path=/\r\n\r\n",
    )) == null);
}

pub const SeasonEpisode = struct {
    season: ?i64,
    episode: ?i64,
};

pub fn parseSeasonEpisode(value: []const u8) SeasonEpisode {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] != 's' and value[i] != 'S') continue;
        if (i > 0 and std.ascii.isAlphanumeric(value[i - 1])) continue;
        var p = i + 1;
        const season_start = p;
        while (p < value.len and std.ascii.isDigit(value[p])) : (p += 1) {}
        if (p == season_start or p >= value.len or (value[p] != 'e' and value[p] != 'E')) continue;
        const season = std.fmt.parseInt(i64, value[season_start..p], 10) catch continue;
        p += 1;
        const episode_start = p;
        while (p < value.len and std.ascii.isDigit(value[p])) : (p += 1) {}
        if (p == episode_start) continue;
        if (p < value.len and std.ascii.isAlphanumeric(value[p])) continue;
        const episode = std.fmt.parseInt(i64, value[episode_start..p], 10) catch continue;
        return .{ .season = season, .episode = episode };
    }
    return .{ .season = null, .episode = null };
}

const XzBudgetAllocator = struct {
    child: Allocator,
    limit: usize,
    used: usize = 0,
    limit_exceeded: bool = false,

    fn allocator(self: *XzBudgetAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *XzBudgetAllocator = @ptrCast(@alignCast(context));
        if (self.used > self.limit or len > self.limit - self.used) {
            self.limit_exceeded = true;
            return null;
        }
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.used += len;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *XzBudgetAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len and (self.used > self.limit or new_len - memory.len > self.limit - self.used)) {
            self.limit_exceeded = true;
            return false;
        }
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        if (new_len > memory.len) self.used += new_len - memory.len else self.used -= memory.len - new_len;
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *XzBudgetAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len and (self.used > self.limit or new_len - memory.len > self.limit - self.used)) {
            self.limit_exceeded = true;
            return null;
        }
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        if (new_len > memory.len) self.used += new_len - memory.len else self.used -= memory.len - new_len;
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *XzBudgetAllocator = @ptrCast(@alignCast(context));
        std.debug.assert(memory.len <= self.used);
        self.used -= memory.len;
        self.child.rawFree(memory, alignment, return_address);
    }
};

fn xzDecoderMemoryLimit(max_output_bytes: usize) usize {
    const overhead = 1024 * 1024;
    if (max_output_bytes > (std.math.maxInt(usize) - overhead) / 4) return std.math.maxInt(usize);
    return max_output_bytes * 4 + overhead;
}

fn takeXzVli(bytes: []const u8, cursor: *usize) !u64 {
    var result: u64 = 0;
    var index: usize = 0;
    while (index < 9) : (index += 1) {
        if (cursor.* == bytes.len) return error.CorruptInput;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        result |= @as(u64, byte & 0x7f) << @intCast(index * 7);
        if (byte & 0x80 == 0) {
            if (index > 0 and byte == 0) return error.CorruptInput;
            return result;
        }
    }
    return error.CorruptInput;
}

fn xzCrc32Cancelable(bytes: []const u8) !u32 {
    var crc = std.hash.Crc32.init();
    var offset: usize = 0;
    while (offset < bytes.len) {
        try runtime_io.get().checkCancel();
        const count = @min(bytes.len - offset, 64 * 1024);
        crc.update(bytes[offset..][0..count]);
        offset += count;
    }
    return crc.final();
}

fn verifyXzBlockChecksum(check_id: u8, decoded: []const u8, checksum: []const u8) !void {
    switch (check_id) {
        0 => {},
        1 => if (try xzCrc32Cancelable(decoded) != std.mem.readInt(u32, checksum[0..4], .little)) return error.WrongChecksum,
        4 => {
            var crc = std.hash.crc.@"CRC-64/XZ".init();
            var offset: usize = 0;
            while (offset < decoded.len) {
                try runtime_io.get().checkCancel();
                const count = @min(decoded.len - offset, 64 * 1024);
                crc.update(decoded[offset..][0..count]);
                offset += count;
            }
            if (crc.final() != std.mem.readInt(u64, checksum[0..8], .little))
                return error.WrongChecksum;
        },
        10 => {
            var sha = std.crypto.hash.sha2.Sha256.init(.{});
            var offset: usize = 0;
            while (offset < decoded.len) {
                try runtime_io.get().checkCancel();
                const count = @min(decoded.len - offset, 64 * 1024);
                sha.update(decoded[offset..][0..count]);
                offset += count;
            }
            var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            sha.final(&actual);
            if (!std.mem.eql(u8, &actual, checksum[0..actual.len])) return error.WrongChecksum;
        },
        else => return error.Unsupported,
    }
}

fn verifyXzMember(member: []const u8, decoded: []const u8) !void {
    const stream_header_len = 12;
    const stream_footer_len = 12;
    if (member.len < stream_header_len + stream_footer_len) return error.CorruptInput;
    if (!std.mem.eql(u8, member[0..6], "\xfd7zXZ\x00")) return error.NotXzStream;
    if (member[6] != 0 or member[7] & 0xf0 != 0) return error.Unsupported;
    const check_id = member[7] & 0x0f;
    // Zig 0.17's decoder does not validate XZ Index record sizes. A stream
    // without block checksums gives us no independent way to establish the
    // real block boundaries, so fail closed instead of trusting its Index.
    if (check_id == 0) return error.Unsupported;
    if (try xzCrc32Cancelable(member[6..8]) != std.mem.readInt(u32, member[8..12], .little)) return error.WrongChecksum;

    const footer = member[member.len - stream_footer_len ..];
    if (!std.mem.eql(u8, footer[10..12], "YZ")) return error.CorruptInput;
    if (try xzCrc32Cancelable(footer[4..10]) != std.mem.readInt(u32, footer[0..4], .little)) return error.WrongChecksum;
    if (!std.mem.eql(u8, member[6..8], footer[8..10])) return error.CorruptInput;

    const backward_size = @as(u64, std.mem.readInt(u32, footer[4..8], .little)) + 1;
    const index_size_u64 = backward_size * 4;
    const index_size = std.math.cast(usize, index_size_u64) orelse return error.CorruptInput;
    if (index_size > member.len - stream_header_len - stream_footer_len) return error.CorruptInput;
    const index_start = member.len - stream_footer_len - index_size;
    const index = member[index_start .. member.len - stream_footer_len];
    if (index.len < 8 or index[0] != 0) return error.CorruptInput;
    if (try xzCrc32Cancelable(index[0 .. index.len - 4]) != std.mem.readInt(u32, index[index.len - 4 ..][0..4], .little)) return error.WrongChecksum;

    var index_cursor: usize = 1;
    const record_count = try takeXzVli(index[0 .. index.len - 4], &index_cursor);
    if (record_count > 1024) return error.TooManyCompressedMembers;
    var block_start: usize = stream_header_len;
    var decoded_start: usize = 0;
    const check_size: usize = switch (check_id) {
        1 => 4,
        4 => 8,
        10 => std.crypto.hash.sha2.Sha256.digest_length,
        else => return error.Unsupported,
    };
    for (0..@intCast(record_count)) |_| {
        try runtime_io.get().checkCancel();
        const unpadded_u64 = try takeXzVli(index[0 .. index.len - 4], &index_cursor);
        const uncompressed_u64 = try takeXzVli(index[0 .. index.len - 4], &index_cursor);
        const unpadded = std.math.cast(usize, unpadded_u64) orelse return error.CorruptInput;
        const uncompressed = std.math.cast(usize, uncompressed_u64) orelse return error.CorruptInput;
        if (unpadded <= check_size or unpadded > std.math.maxInt(usize) - 3) return error.CorruptInput;
        const padded = (unpadded + 3) & ~@as(usize, 3);
        if (block_start > index_start or decoded_start > decoded.len) return error.CorruptInput;
        if (padded > index_start - block_start or uncompressed > decoded.len - decoded_start) return error.CorruptInput;
        const block_end = block_start + padded;
        const padding_len = padded - unpadded;
        if (check_size > padded or padding_len > padded - check_size) return error.CorruptInput;
        const checksum_start = block_end - check_size;
        const padding_start = checksum_start - padding_len;
        for (member[padding_start..checksum_start]) |byte| if (byte != 0) return error.CorruptInput;
        try verifyXzBlockChecksum(
            check_id,
            decoded[decoded_start .. decoded_start + uncompressed],
            member[checksum_start..block_end],
        );
        block_start = block_end;
        decoded_start += uncompressed;
    }
    if (block_start != index_start or decoded_start != decoded.len) return error.CorruptInput;
    for (index[index_cursor .. index.len - 4], 0..) |byte, offset| {
        if (offset % (64 * 1024) == 0) try runtime_io.get().checkCancel();
        if (byte != 0) return error.CorruptInput;
    }
}

pub fn decompressXz(allocator: Allocator, compressed: []const u8, max_output_bytes: usize) ![]u8 {
    var budget: XzBudgetAllocator = .{
        .child = allocator,
        .limit = xzDecoderMemoryLimit(max_output_bytes),
    };
    const decoder_allocator = budget.allocator();
    var input: std.Io.Reader = .fixed(compressed);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var transfer: [8192]u8 = undefined;
    var members: usize = 0;

    while (input.seek < compressed.len) {
        try runtime_io.get().checkCancel();
        members += 1;
        if (members > 1024) return error.TooManyCompressedMembers;
        const member_start = input.seek;
        const decoded_start = output.items.len;
        const scratch = decoder_allocator.alloc(u8, 8192) catch |err| {
            if (budget.limit_exceeded) return error.ResponseTooLarge;
            return err;
        };
        var xz = std.compress.xz.Decompress.init(&input, decoder_allocator, scratch) catch |err| {
            decoder_allocator.free(scratch);
            if (err == error.OutOfMemory and budget.limit_exceeded) return error.ResponseTooLarge;
            return err;
        };
        var xz_open = true;
        defer if (xz_open) xz.deinit();
        while (true) {
            try runtime_io.get().checkCancel();
            const n = xz.reader.readSliceShort(&transfer) catch |err| {
                const concrete = if (err == error.ReadFailed) xz.err orelse err else err;
                if (concrete == error.OutOfMemory and budget.limit_exceeded) return error.ResponseTooLarge;
                return concrete;
            };
            if (n == 0) break;
            if (n > max_output_bytes - output.items.len) return error.ResponseTooLarge;
            try output.appendSlice(allocator, transfer[0..n]);
        }
        xz.deinit();
        xz_open = false;
        const member_end = input.seek;
        try verifyXzMember(compressed[member_start..member_end], output.items[decoded_start..]);

        var padding: usize = 0;
        while (input.seek < compressed.len and compressed[input.seek] == 0) {
            if (padding % (64 * 1024) == 0) try runtime_io.get().checkCancel();
            input.toss(1);
            padding += 1;
        }
        if (padding % 4 != 0) return error.CorruptInput;
        if (input.seek == compressed.len) break;
        if (compressed.len - input.seek < 6 or !std.mem.eql(u8, compressed[input.seek..][0..6], "\xfd7zXZ\x00")) {
            return error.CorruptInput;
        }
    }
    if (members == 0) return error.NotXzStream;
    return output.toOwnedSlice(allocator);
}

pub const EpisodeQuery = struct {
    title: []const u8,
    season: ?u16,
    episode: ?u16,
};

pub const MediaKind = enum { movie, tv };

pub const SearchLink = struct {
    title: []const u8,
    page_url: []const u8,
};

pub const MediaSearchLink = struct {
    title: []const u8,
    media_kind: MediaKind,
    page_url: []const u8,
};

pub const SubtitleFile = struct {
    language_code: []const u8,
    filename: []const u8,
    download_url: []const u8,
};

pub const EpisodeSubtitleFile = struct {
    language_code: []const u8,
    filename: []const u8,
    download_url: []const u8,
    season: i64,
    episode: i64,
};

pub const DownloadSubtitleFile = struct {
    filename: []const u8,
    download_url: []const u8,
};

pub const ReleaseSubtitleFile = struct {
    language_code: []const u8,
    filename: []const u8,
    release_name: []const u8,
    download_url: []const u8,
};

pub const PageOptions = struct {
    page_start: usize = 1,
    max_pages: usize = 1,
};

pub const RawResponse = struct {
    status: std.http.Status,
    body: []u8,
    cookie: ?[]u8,

    pub fn deinit(self: *RawResponse, allocator: Allocator) void {
        allocator.free(self.body);
        if (self.cookie) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const TitleYear = struct {
    title: []const u8,
    year: ?i64,
};

pub const RequiredTitleYear = struct {
    title: []const u8,
    year: i64,
};

pub const SubtitleDownloadToken = struct {
    subtitle_id: []const u8,
    page_url: []const u8,
};

pub fn splitTrailingYear(input: []const u8) TitleYear {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len < 6 or trimmed[trimmed.len - 1] != ')') return .{ .title = trimmed, .year = null };
    const open = std.mem.lastIndexOfScalar(u8, trimmed, '(') orelse return .{ .title = trimmed, .year = null };
    const inside = trimmed[open + 1 .. trimmed.len - 1];
    if (inside.len != 4) return .{ .title = trimmed, .year = null };
    for (inside) |c| if (!std.ascii.isDigit(c)) return .{ .title = trimmed, .year = null };
    const year = std.fmt.parseInt(i64, inside, 10) catch return .{ .title = trimmed, .year = null };
    return .{ .title = std.mem.trimEnd(u8, trimmed[0..open], " \t"), .year = year };
}

pub fn parseEpisodeQuery(input: []const u8) EpisodeQuery {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (std.ascii.toLower(trimmed[i]) != 's') continue;
        if (i > 0 and std.ascii.isAlphanumeric(trimmed[i - 1])) continue;
        var cursor = i + 1;
        const season_start = cursor;
        while (cursor < trimmed.len and std.ascii.isDigit(trimmed[cursor])) : (cursor += 1) {}
        if (cursor == season_start or cursor >= trimmed.len or std.ascii.toLower(trimmed[cursor]) != 'e') continue;
        const season = std.fmt.parseInt(u16, trimmed[season_start..cursor], 10) catch continue;
        cursor += 1;
        const episode_start = cursor;
        while (cursor < trimmed.len and std.ascii.isDigit(trimmed[cursor])) : (cursor += 1) {}
        if (cursor == episode_start) continue;
        if (cursor < trimmed.len and std.ascii.isAlphanumeric(trimmed[cursor])) continue;
        const episode = std.fmt.parseInt(u16, trimmed[episode_start..cursor], 10) catch continue;
        const title = std.mem.trim(u8, trimmed[0..i], " \t\r\n-._");
        if (title.len == 0) continue;
        return .{ .title = title, .season = season, .episode = episode };
    }
    return .{ .title = trimmed, .season = null, .episode = null };
}

test "episode query trims real whitespace" {
    const query = parseEpisodeQuery("\tTitan S01E02\n");
    try std.testing.expectEqualStrings("Titan", query.title);
    try std.testing.expectEqual(@as(?u16, 1), query.season);
    try std.testing.expectEqual(@as(?u16, 2), query.episode);
}

pub fn normalizeLanguageCode(language_or_code: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, language_or_code, " \t\r\n");
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
    if (eqlCode(s, "hi") or std.ascii.eqlIgnoreCase(s, "hindi")) return "hi";
    if (eqlCode(s, "fa") or std.ascii.eqlIgnoreCase(s, "persian") or std.ascii.eqlIgnoreCase(s, "farsi")) return "fa";
    if (eqlCode(s, "uk") or std.ascii.eqlIgnoreCase(s, "ukrainian")) return "uk";
    if (eqlCode(s, "bg") or std.ascii.eqlIgnoreCase(s, "bulgarian")) return "bg";
    if (eqlCode(s, "hr") or std.ascii.eqlIgnoreCase(s, "croatian")) return "hr";
    if (eqlCode(s, "sr") or std.ascii.eqlIgnoreCase(s, "serbian")) return "sr";
    if (eqlCode(s, "sk") or std.ascii.eqlIgnoreCase(s, "slovak")) return "sk";
    if (eqlCode(s, "sl") or std.ascii.eqlIgnoreCase(s, "slovenian")) return "sl";
    if (eqlCode(s, "he") or eqlCode(s, "iw") or std.ascii.eqlIgnoreCase(s, "hebrew")) return "he";
    if (eqlCode(s, "th") or std.ascii.eqlIgnoreCase(s, "thai")) return "th";
    if (eqlCode(s, "ms") or std.ascii.eqlIgnoreCase(s, "malay")) return "ms";
    if (eqlCode(s, "bn") or std.ascii.eqlIgnoreCase(s, "bengali")) return "bn";
    if (eqlCode(s, "ta") or std.ascii.eqlIgnoreCase(s, "tamil")) return "ta";
    if (eqlCode(s, "te") or std.ascii.eqlIgnoreCase(s, "telugu")) return "te";
    if (eqlCode(s, "ml") or std.ascii.eqlIgnoreCase(s, "malayalam")) return "ml";
    if (eqlCode(s, "mr") or std.ascii.eqlIgnoreCase(s, "marathi")) return "mr";
    if (eqlCode(s, "ur") or std.ascii.eqlIgnoreCase(s, "urdu")) return "ur";
    if (eqlCode(s, "ca") or std.ascii.eqlIgnoreCase(s, "catalan")) return "ca";
    if (eqlCode(s, "eu") or std.ascii.eqlIgnoreCase(s, "basque")) return "eu";
    if (eqlCode(s, "gl") or std.ascii.eqlIgnoreCase(s, "galician")) return "gl";
    if (eqlCode(s, "lt") or std.ascii.eqlIgnoreCase(s, "lithuanian")) return "lt";
    if (eqlCode(s, "lv") or std.ascii.eqlIgnoreCase(s, "latvian")) return "lv";
    if (eqlCode(s, "et") or std.ascii.eqlIgnoreCase(s, "estonian")) return "et";
    if (eqlCode(s, "is") or std.ascii.eqlIgnoreCase(s, "icelandic")) return "is";
    if (eqlCode(s, "ga") or std.ascii.eqlIgnoreCase(s, "irish")) return "ga";
    if (eqlCode(s, "af") or std.ascii.eqlIgnoreCase(s, "afrikaans")) return "af";
    if (eqlCode(s, "sw") or std.ascii.eqlIgnoreCase(s, "swahili")) return "sw";
    if (eqlCode(s, "sq") or std.ascii.eqlIgnoreCase(s, "albanian")) return "sq";
    if (eqlCode(s, "mk") or std.ascii.eqlIgnoreCase(s, "macedonian")) return "mk";
    if (eqlCode(s, "bs") or std.ascii.eqlIgnoreCase(s, "bosnian")) return "bs";

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
    const base_uri = try std.Uri.parse(base);
    // `Uri.resolveInPlace` intentionally retries a failed absolute-URI parse as
    // a relative reference. That permissive fallback can turn a malformed
    // authority (for example, a non-numeric port) into an apparently safe path
    // on `base`. Absolute and network-path references are untrusted provider
    // input, so validate those forms strictly before resolving them.
    if (std.mem.startsWith(u8, href, "//")) {
        _ = try std.Uri.parseAfterScheme("", href);
    } else {
        var prefix_end: usize = 0;
        while (prefix_end < href.len and
            href[prefix_end] != '/' and
            href[prefix_end] != '?' and
            href[prefix_end] != '#') : (prefix_end += 1)
        {}
        if (std.mem.indexOfScalar(u8, href[0..prefix_end], ':') != null) {
            _ = try std.Uri.parse(href);
        }
    }
    // resolveInPlace retains the input reference before allocating merged paths.
    const size = try std.math.add(usize, try std.math.add(usize, base.len, try std.math.mul(usize, href.len, 2)), 32);
    const storage = try allocator.alloc(u8, size);
    defer allocator.free(storage);
    @memcpy(storage[0..href.len], href);
    var remaining = storage;
    const resolved = try base_uri.resolveInPlace(href.len, &remaining);
    return std.fmt.allocPrint(allocator, "{f}", .{resolved});
}

pub fn sameOrigin(left: []const u8, right: []const u8) !bool {
    // Origin equality is commonly used immediately before a URL is promoted
    // into a Referer value. Do not let parsed path/query control bytes survive
    // that trust decision.
    if (!validHttpHeaderValue(left) or !validHttpHeaderValue(right)) return false;
    const l = try std.Uri.parse(left);
    const r = try std.Uri.parse(right);
    const lh = switch (l.host orelse return false) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    const rh = switch (r.host orelse return false) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    const lp = l.port orelse @as(u16, if (std.ascii.eqlIgnoreCase(l.scheme, "https")) 443 else 80);
    const rp = r.port orelse @as(u16, if (std.ascii.eqlIgnoreCase(r.scheme, "https")) 443 else 80);
    return std.ascii.eqlIgnoreCase(l.scheme, r.scheme) and std.ascii.eqlIgnoreCase(lh, rh) and lp == rp;
}

test "URL resolution follows document relative and origin semantics" {
    const cases = [_][3][]const u8{
        .{ "https://example.test/dir/page.html", "/download/x.zip", "https://example.test/download/x.zip" },
        .{ "https://example.test/dir/page.html", "x.zip", "https://example.test/dir/x.zip" },
        .{ "https://example.test/dir/page.html", "../x.zip", "https://example.test/x.zip" },
        .{ "https://example.test/dir/page.html?old=1", "?dl_id=1", "https://example.test/dir/page.html?dl_id=1" },
        .{ "https://example.test/dir/page.html?old=1", "#part", "https://example.test/dir/page.html?old=1#part" },
        .{ "http://example.test/dir/", "//cdn.test/x.zip", "http://cdn.test/x.zip" },
        .{ "https://example.test/films/", "x.zip", "https://example.test/films/x.zip" },
    };
    for (cases) |case| {
        const result = try resolveUrl(std.testing.allocator, case[0], case[1]);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case[2], result);
    }

    try std.testing.expect(try sameOrigin("https://EXAMPLE.test/a", "https://example.test:443/b"));
    try std.testing.expect(!try sameOrigin("https://example.test/a", "http://example.test/b"));
    try std.testing.expect(!try sameOrigin("http://localhost:8080/a", "http://localhost:8081/b"));
    try std.testing.expect(!try sameOrigin("https://example.test/a", "https://example.test/path\r\nx-injected: yes"));
}

test "URL resolution rejects malformed absolute authorities" {
    try std.testing.expectError(
        error.InvalidPort,
        resolveUrl(std.testing.allocator, "https://example.test/base/", "https://cdn.test:bad/file.zip"),
    );
    try std.testing.expectError(
        error.InvalidPort,
        resolveUrl(std.testing.allocator, "https://example.test/base/", "//cdn.test:bad/file.zip"),
    );
}

test "HTTP redirect targets normalize raw request-line whitespace" {
    const target = try resolveFetchRedirect(
        std.testing.allocator,
        "https://example.test/dir/page.html",
        "../subtitle file\tname.srt?token=one two",
    );
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings(
        "https://example.test/subtitle%20file%09name.srt?token=one%20two",
        target,
    );
}

test "cross-origin redirects cannot preserve payloads or unsafe methods" {
    const rewritten_post = try redirectDisposition(.found, .POST, true, true);
    try std.testing.expectEqual(std.http.Method.GET, rewritten_post.method);
    try std.testing.expect(!rewritten_post.preserve_payload);

    const rewritten_other = try redirectDisposition(.see_other, .PATCH, true, true);
    try std.testing.expectEqual(std.http.Method.GET, rewritten_other.method);
    try std.testing.expect(!rewritten_other.preserve_payload);

    const safe_get = try redirectDisposition(.temporary_redirect, .GET, false, true);
    try std.testing.expectEqual(std.http.Method.GET, safe_get.method);
    try std.testing.expect(!safe_get.preserve_payload);
    const safe_head = try redirectDisposition(.permanent_redirect, .HEAD, false, true);
    try std.testing.expectEqual(std.http.Method.HEAD, safe_head.method);

    try std.testing.expectError(error.UnsafeHttpTarget, redirectDisposition(.temporary_redirect, .POST, true, true));
    try std.testing.expectError(error.UnsafeHttpTarget, redirectDisposition(.permanent_redirect, .GET, true, true));
    try std.testing.expectError(error.UnsafeHttpTarget, redirectDisposition(.moved_permanently, .PUT, false, true));

    const same_origin = try redirectDisposition(.temporary_redirect, .POST, true, false);
    try std.testing.expectEqual(std.http.Method.POST, same_origin.method);
    try std.testing.expect(same_origin.preserve_payload);

    for ([_][]const u8{ "accept", "Accept-Language", "ACCEPT-CHARSET" }) |name| {
        try std.testing.expect(isCrossOriginSafeRequestHeader(name));
    }
    for ([_][]const u8{ "cookie", "Authorization", "Referer", "Origin", "X-API-Key", "X-CSRF-Token" }) |name| {
        try std.testing.expect(!isCrossOriginSafeRequestHeader(name));
    }
}

test "untrusted HTTP targets reject credentials and local address spellings" {
    for ([_][]const u8{
        "https://subdl.com/download/1",
        "http://93.184.216.34/subtitle.srt",
        "https://cdn.example.com/subtitle.zip",
        "https://1a.cafe/subtitle.srt",
    }) |url| try validatePublicHttpUrl(url);

    try std.testing.expectError(error.InvalidDownloadUrl, validatePublicHttpUrl("file:///etc/passwd"));

    for ([_][]const u8{
        "https://user@example.com/subtitle.srt",
        "https://localhost/subtitle.srt",
        "https://worker.local/subtitle.srt",
        "https://service.internal/subtitle.srt",
        "https://fixture.invalid/subtitle.srt",
        "https://fixture.test/subtitle.srt",
        "https://host.example/subtitle.srt",
        "https://127.0.0.1/subtitle.srt",
        "https://10.2.3.4/subtitle.srt",
        "https://100.64.0.1/subtitle.srt",
        "https://169.254.1.1/subtitle.srt",
        "https://172.16.2.3/subtitle.srt",
        "https://192.168.2.3/subtitle.srt",
        "https://198.18.0.1/subtitle.srt",
        "https://[::1]/subtitle.srt",
        "https://[::ffff:127.0.0.1]/subtitle.srt",
        "https://2130706433/subtitle.srt",
        "https://0x7f000001/subtitle.srt",
        "https://127.1/subtitle.srt",
        "https://0x7f.1/subtitle.srt",
        "https://0177.0.0.1/subtitle.srt",
        "https://%6cocalhost/subtitle.srt",
        "https://metadata/subtitle.srt",
    }) |url| try std.testing.expectError(error.UnsafeHttpTarget, validatePublicHttpUrl(url));
}

test "HTTPS fetch policy rejects an initial or redirected downgrade" {
    const opts: FetchOptions = .{
        .require_public_origin = true,
        .require_https = true,
    };
    try validateFetchTarget("https://cdn.example.com/archive.zip", opts);
    try std.testing.expectError(
        error.UnsafeHttpTarget,
        validateFetchTarget("http://cdn.example.com/archive.zip", opts),
    );

    const redirected = try resolveUrl(
        std.testing.allocator,
        "https://cdn.example.com/archive.zip",
        "http://downloads.example.com/archive.zip",
    );
    defer std.testing.allocator.free(redirected);
    try std.testing.expectError(error.UnsafeHttpTarget, validateFetchTarget(redirected, opts));

    try std.testing.expectError(error.InvalidDownloadUrl, validateFetchTarget("file:///etc/passwd", .{}));
    try std.testing.expectError(error.InvalidDownloadUrl, validateFetchTarget("https:///missing-host", .{}));
}

test "private request headers remain confined to a canonical path prefix" {
    const prefix = "/search";
    try std.testing.expect(privateHeadersPathMatches("https://provider.example/search?q=matrix", prefix));
    try std.testing.expect(privateHeadersPathMatches("https://provider.example/search/results?q=matrix", prefix));

    for ([_][]const u8{
        "https://provider.example/searching?q=matrix",
        "https://provider.example/load/archive.zip",
        "https://provider.example/search/../load/archive.zip",
        "https://provider.example/search/%2e%2e/load/archive.zip",
        "https://provider.example/search%2fload/archive.zip",
        "https://provider.example/search\\..\\load/archive.zip",
        "https://provider.example/search?q=matrix#fragment",
    }) |url| try std.testing.expect(!privateHeadersPathMatches(url, prefix));
}

test "resolved public address classification rejects private and special networks" {
    for ([_][]const u8{ "8.8.8.8", "93.184.216.34", "192.0.0.9", "192.0.0.10", "192.0.1.1", "2606:4700:4700::1111", "2003::1" }) |text| {
        const address = try std.Io.net.IpAddress.parse(text, 443);
        try std.testing.expect(!isUnsafeResolvedAddress(address));
    }
    for ([_][]const u8{
        "127.0.0.1",
        "10.0.0.1",
        "169.254.169.254",
        "192.0.0.8",
        "192.0.0.11",
        "192.0.2.1",
        "192.88.99.1",
        "192.88.99.2",
        "198.51.100.1",
        "203.0.113.1",
        "::1",
        "fc00::1",
        "fe80::1",
        "::ffff:127.0.0.1",
        "::ffff:192.0.2.1",
        "2001:10::1",
        "2001:20::1",
        "2001:db8::1",
        "2002:7f00:1::",
        "2002:0808:0808::",
        "3ffe::1",
        "3fff::1",
    }) |text| {
        const address = try std.Io.net.IpAddress.parse(text, 443);
        try std.testing.expect(isUnsafeResolvedAddress(address));
    }
}

test "resolver addresses become canonical numeric connection hosts" {
    var buffer: [64]u8 = undefined;
    const ip4 = try std.Io.net.IpAddress.parse("93.184.216.34", 443);
    try std.testing.expectEqualStrings("93.184.216.34", try formatNumericHost(ip4, &buffer));
    const ip6 = try std.Io.net.IpAddress.parse("2606:4700:4700::1111", 443);
    try std.testing.expectEqualStrings("2606:4700:4700:0:0:0:0:1111", try formatNumericHost(ip6, &buffer));
}

pub fn shouldRunLiveTests(allocator: Allocator) bool {
    _ = allocator;
    // Provider-local live tests are the named/direct suite. Keeping this gate
    // separate from the application smoke and extensive suites prevents a
    // single provider filter from repeating the same upstream flow in every
    // mode. `-Dlive=all` still composes all three suites deliberately.
    return providerLocalLiveSuiteEnabled(
        build_options.live_named_tests_enabled,
        build_options.live_extensive_suite,
    );
}

fn providerLocalLiveSuiteEnabled(named_enabled: bool, extensive_enabled: bool) bool {
    // Extensive being enabled at the same time means `all`, not that it
    // replaces the named suite.
    _ = extensive_enabled;
    return named_enabled;
}

test "provider-local live suite remains selected when all suites are composed" {
    try std.testing.expect(providerLocalLiveSuiteEnabled(true, false));
    try std.testing.expect(providerLocalLiveSuiteEnabled(true, true));
    try std.testing.expect(!providerLocalLiveSuiteEnabled(false, true));
    try std.testing.expect(!providerLocalLiveSuiteEnabled(false, false));
}

pub fn liveTestsEnabled() bool {
    return build_options.live_tests_enabled;
}

pub fn shouldRunNamedLiveTest(allocator: Allocator, name: []const u8) bool {
    _ = allocator;
    if (!build_options.live_named_tests_enabled) return false;

    const provider_name = namedLiveProvider(name) orelse return false;
    return providerMatchesLiveFilter(liveProviderFilter(), provider_name);
}

pub fn liveExtensiveSuiteEnabled() bool {
    return build_options.live_extensive_suite;
}

pub fn liveTuiSuiteEnabled() bool {
    return build_options.live_tui_suite;
}

pub fn liveProviderFilter() ?[]const u8 {
    if (getenv("SCRAPERS_LIVE_PROVIDER_FILTER")) |value| {
        const trimmed_env = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed_env.len == 0) return null;
        return trimmed_env;
    }
    if (getenv("SCRAPERS_LIVE_PROVIDERS")) |value| {
        const trimmed_env = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed_env.len == 0) return null;
        return trimmed_env;
    }
    const trimmed = std.mem.trim(u8, build_options.live_provider_filter, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

pub fn getenv(name: []const u8) ?[]const u8 {
    if (name.len > 256) return null;

    var name_z: [256:0]u8 = undefined;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;
    const value = CEnvironment.getenv(&name_z) orelse return null;
    return std.mem.span(value);
}

const CEnvironment = struct {
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
};

pub const GetenvOwnedError = Allocator.Error || error{InvalidWtf8};

/// Returns an owned copy of an environment value. Windows uses the process's
/// native UTF-16 environment block so paths and credentials are not lossy.
pub fn getenvOwned(allocator: Allocator, name: []const u8) GetenvOwnedError!?[]u8 {
    if (comptime builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        return std.process.Environ.getAlloc(environ, allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => null,
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidWtf8 => error.InvalidWtf8,
        };
    }

    const value = getenv(name) orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, value));
}

pub fn hasEnv(comptime name: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        return std.process.Environ.containsConstant(environ, name);
    }
    return getenv(name) != null;
}

pub fn providerMatchesLiveFilter(filter: ?[]const u8, provider_name: []const u8) bool {
    const f = filter orelse return true;
    var it = std.mem.splitScalar(u8, f, ',');
    while (it.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return liveProviderFilterMatch(f, provider_name);
        if (std.ascii.eqlIgnoreCase(entry, "all")) return liveProviderFilterMatch(f, provider_name);
        if (std.ascii.eqlIgnoreCase(entry, "active")) {
            if (isActiveLiveProvider(provider_name)) return liveProviderFilterMatch(f, provider_name);
            continue;
        }
        if (providerNameEq(entry, provider_name)) return liveProviderFilterMatch(f, provider_name);
        if (providerNameContains(provider_name, entry)) return liveProviderFilterMatch(f, provider_name);
    }
    return false;
}

fn liveProviderFilterMatch(filter: []const u8, provider_name: []const u8) bool {
    // The fanout runner validates this marker before accepting a zero exit
    // status. The runner always supplies its exact per-provider selection in
    // SCRAPERS_LIVE_PROVIDER_FILTER. Pointer identity with that C environment
    // value distinguishes an actual live-test gate from ordinary unit tests
    // that exercise providerMatchesLiveFilter with an equal string literal.
    if (build_options.live_tests_enabled) {
        if (getenv("SCRAPERS_LIVE_PROVIDER_FILTER")) |configured_raw| {
            const configured = std.mem.trim(u8, configured_raw, " \t\r\n");
            if (filter.ptr == configured.ptr and filter.len == configured.len) {
                std.debug.print("[live][probe] provider={s}\n", .{provider_name});
            }
        }
    }
    return true;
}

fn isActiveLiveProvider(provider_name: []const u8) bool {
    var active = std.mem.splitScalar(u8, build_options.active_live_provider_filter, ',');
    while (active.next()) |name| {
        if (providerNameEq(provider_name, name)) return true;
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
    const printable = if (isSensitiveLiveFieldLabel(label)) "<redacted>" else value;
    const safe = try sanitizeUtf8ForLog(allocator, printable);
    defer allocator.free(safe);
    std.debug.print("[live] {s}: {s}\n", .{ label, safe });
}

fn isSensitiveLiveFieldLabel(label: []const u8) bool {
    return std.ascii.eqlIgnoreCase(label, "url") or
        std.ascii.endsWithIgnoreCase(label, "_url") or
        std.ascii.eqlIgnoreCase(label, "link") or
        std.ascii.endsWithIgnoreCase(label, "_link") or
        std.ascii.eqlIgnoreCase(label, "endpoint") or
        std.ascii.endsWithIgnoreCase(label, "_endpoint") or
        std.ascii.eqlIgnoreCase(label, "token") or
        std.ascii.endsWithIgnoreCase(label, "_token") or
        std.ascii.eqlIgnoreCase(label, "cookie") or
        std.ascii.endsWithIgnoreCase(label, "_cookie");
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
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(T, trimmed, 10) catch null;
}

pub fn parseAttrFloat(node: anytype, attr_name: []const u8) ?f64 {
    const raw = getAttributeValueSafe(node, attr_name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseFloat(f64, trimmed) catch null;
}

pub fn parseAttrBool(node: anytype, attr_name: []const u8) ?bool {
    const raw = getAttributeValueSafe(node, attr_name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
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

    const debug_result = scope.queryOneDebug(selector);
    if (debug_result.node) |node| return node;

    std.debug.print(
        "[selector-debug] context={s} selector={s} visited={d} groups={d} parse_error={any}\n",
        .{
            context,
            selector,
            debug_result.report.visited_elements,
            debug_result.report.group_count,
            debug_result.report.runtime_parse_error,
        },
    );

    var i: usize = 0;
    while (i < debug_result.report.near_miss_len) : (i += 1) {
        const miss = debug_result.report.near_misses[i];
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
    var children = header_row.children();
    while (children.next()) |cell| {
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
    var children = row.children();
    while (children.next()) |cell| {
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

fn sleepBackoff(initial_ms: u64, attempt: usize) std.Io.Cancelable!void {
    const shift: u6 = @intCast(@min(attempt, 6));
    const multiplier = (@as(u64, 1) << shift);
    const delay = std.math.mul(u64, initial_ms, multiplier) catch std.math.maxInt(u64);
    try sleepMillisecondsCancelable(delay);
}

pub fn appendHexEscape(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), value: u8) !void {
    const hex = "0123456789ABCDEF";
    try out.appendSlice(allocator, &.{ '\\', 'x', hex[value >> 4], hex[value & 0x0F] });
}

fn namedLiveProvider(name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "SUBDL_COM")) return "subdl.com";
    if (std.ascii.eqlIgnoreCase(name, "MOVIESUBTITLES_ORG")) return "moviesubtitles.org";
    if (std.ascii.eqlIgnoreCase(name, "MOVIESUBTITLESRT_COM")) return "moviesubtitlesrt.com";
    if (std.ascii.eqlIgnoreCase(name, "PODNAPISI")) return "podnapisi.net";
    if (std.ascii.eqlIgnoreCase(name, "SUBTITLECAT") or std.ascii.eqlIgnoreCase(name, "SUBTITLECAT_COM")) return "subtitlecat.com";
    if (std.ascii.eqlIgnoreCase(name, "YIFY")) return "yifysubtitles.ch";
    if (std.ascii.eqlIgnoreCase(name, "OPENSUBTITLES_ORG")) return "opensubtitles.org";
    if (std.ascii.eqlIgnoreCase(name, "OPENSUBTITLES_COM")) return "opensubtitles.com";
    return null;
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

pub fn normalizeProviderChar(c: u8) u8 {
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

test "normalize url for fetch preserves valid escapes and encodes unsafe bytes" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeUrlForFetch(
        allocator,
        "https://www.subtitlecat.com/subs/1366/[Chinese Traditional] A❤️ B.srt?x=1 2&y=%2F",
    );
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings(
        "https://www.subtitlecat.com/subs/1366/%5BChinese%20Traditional%5D%20A%E2%9D%A4%EF%B8%8F%20B.srt?x=1%202&y=%2F",
        normalized,
    );

    const ipv6 = try normalizeUrlForFetch(allocator, "http://[2001:db8::1]/[subtitle].srt");
    defer allocator.free(ipv6);
    try std.testing.expectEqualStrings(
        "http://[2001:db8::1]/%5Bsubtitle%5D.srt",
        ipv6,
    );

    const malformed_escapes = try normalizeUrlForFetch(
        allocator,
        "https://example.test/100%/bad%2G/short%2/good%2f",
    );
    defer allocator.free(malformed_escapes);
    try std.testing.expectEqualStrings(
        "https://example.test/100%25/bad%252G/short%252/good%2f",
        malformed_escapes,
    );

    const mixed_case_scheme = try normalizeUrlForFetch(allocator, "HtTpS://Example.COM/MixedCase.srt");
    defer allocator.free(mixed_case_scheme);
    try std.testing.expectEqualStrings("https://Example.COM/MixedCase.srt", mixed_case_scheme);

    const relative = try normalizeUrlForFetch(allocator, "Keep/RelativeCase.srt");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("Keep/RelativeCase.srt", relative);
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
    var doc = HtmlDocument.init(std.testing.allocator);
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
    var doc = HtmlDocument.init(std.testing.allocator);
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

test "transport URL logging redacts paths queries fragments and credentials" {
    const allocator = std.testing.allocator;
    const safe = try redactUrlForLog(
        allocator,
        "https://user:secret@downloads.example:8443/download/bearer-token/subfile/movie.srt?token=query-secret#fragment-secret",
    );
    defer allocator.free(safe);

    try std.testing.expectEqualStrings("https://downloads.example:8443/<redacted>", safe);
    for ([_][]const u8{ "user", "secret", "bearer-token", "movie.srt", "query-secret", "fragment-secret" }) |sensitive| {
        try std.testing.expect(std.mem.indexOf(u8, safe, sensitive) == null);
    }
}

test "live result logging classifies capability-bearing fields as sensitive" {
    for ([_][]const u8{
        "url",
        "download_url",
        "link",
        "bucket_link",
        "remote_endpoint",
        "download_token",
        "session_cookie",
    }) |label| try std.testing.expect(isSensitiveLiveFieldLabel(label));
    for ([_][]const u8{ "title", "filename", "language_code", "download_ok" }) |label| {
        try std.testing.expect(!isSensitiveLiveFieldLabel(label));
    }
}

test "HTTP header validation rejects injection controls" {
    try validateHttpHeaders(&.{
        .{ .name = "referer", .value = "https://fixture.invalid/path" },
        .{ .name = "x-fixture", .value = "value\twith-tab\x80" },
    });
    try std.testing.expectError(error.InvalidHttpHeader, validateHttpHeaders(&.{.{
        .name = "referer",
        .value = "https://fixture.invalid/\r\nx-injected: yes",
    }}));
    try std.testing.expectError(error.InvalidHttpHeader, validateHttpHeaders(&.{.{
        .name = "bad name",
        .value = "value",
    }}));
}

test "fetch header policy rejects transport-owned fields before I/O" {
    for ([_][]const u8{
        "Host",
        "Connection",
        "Content-Length",
        "Transfer-Encoding",
        "TE",
        "Trailer",
        "Upgrade",
        "Keep-Alive",
        "Expect",
        "Proxy-Authorization",
        "Proxy-Connection",
    }) |name| {
        try std.testing.expectError(error.TransportOwnedHttpHeader, validateFetchHeaders(.{
            .extra_headers = &.{.{ .name = name, .value = "fixture" }},
        }));
    }
    try validateFetchHeaders(.{ .extra_headers = &.{
        .{ .name = "Authorization", .value = "Bearer fixture" },
        .{ .name = "User-Agent", .value = "fixture" },
        .{ .name = "Accept-Encoding", .value = "identity" },
    } });
    // Empty POST/PUT requests still require the body-writing path in Zig 0.17.
    try validateFetchHeaders(.{ .method = .POST });
    try validateFetchHeaders(.{ .method = .PUT, .payload = "" });
    try std.testing.expectError(error.InvalidHttpMethodPayload, validateFetchHeaders(.{
        .method = .GET,
        .payload = "",
    }));
    try std.testing.expectError(error.UnsupportedProtocolUpgrade, validateFetchHeaders(.{
        .method = .CONNECT,
    }));
}

test "accept-encoding serialization and decoder mask stay equivalent" {
    const defaults = try acceptedContentEncodings(&.{});
    try std.testing.expect(defaults[@backingInt(std.http.ContentEncoding.identity)]);
    try std.testing.expect(defaults[@backingInt(std.http.ContentEncoding.gzip)]);
    try std.testing.expect(defaults[@backingInt(std.http.ContentEncoding.deflate)]);
    try std.testing.expect(!defaults[@backingInt(std.http.ContentEncoding.zstd)]);

    const identity_only = try acceptedContentEncodings(&.{.{ .name = "Accept-Encoding", .value = "identity" }});
    try std.testing.expect(identity_only[@backingInt(std.http.ContentEncoding.identity)]);
    try std.testing.expect(!identity_only[@backingInt(std.http.ContentEncoding.gzip)]);
    try std.testing.expect(!identity_only[@backingInt(std.http.ContentEncoding.deflate)]);

    const weighted = try acceptedContentEncodings(&.{.{ .name = "accept-encoding", .value = "gzip; q=0, deflate;q=0.5, identity;q=0" }});
    try std.testing.expect(!weighted[@backingInt(std.http.ContentEncoding.identity)]);
    try std.testing.expect(!weighted[@backingInt(std.http.ContentEncoding.gzip)]);
    try std.testing.expect(weighted[@backingInt(std.http.ContentEncoding.deflate)]);
    try std.testing.expectError(error.UnsupportedCompressionMethod, acceptedContentEncodings(&.{.{ .name = "Accept-Encoding", .value = "zstd;q=0" }}));
    try std.testing.expectError(error.UnsupportedCompressionMethod, acceptedContentEncodings(&.{.{ .name = "Accept-Encoding", .value = "*" }}));
    try std.testing.expectError(error.InvalidHttpHeader, acceptedContentEncodings(&.{.{ .name = "Accept-Encoding", .value = "gzip, gzip" }}));
    try std.testing.expectError(error.InvalidHttpHeader, acceptedContentEncodings(&.{.{ .name = "Accept-Encoding", .value = "gzip;q=1e-1" }}));
    try std.testing.expectError(error.InvalidHttpHeader, acceptedContentEncodings(&.{.{ .name = "Accept-Encoding", .value = "gzip;q=1.1" }}));
    try std.testing.expectError(error.InvalidHttpHeader, validateFetchHeaders(.{ .extra_headers = &.{
        .{ .name = "Accept-Encoding", .value = "gzip" },
        .{ .name = "accept-encoding", .value = "deflate" },
    } }));
}

test "response framing rejects TE plus CL and every repeated Content-Length" {
    const valid = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n",
    );
    try validateResponseFraming(valid);

    const te_and_cl = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n",
    );
    try std.testing.expectError(error.AmbiguousHttpFraming, validateResponseFraming(te_and_cl));

    const duplicate = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n",
    );
    try std.testing.expectError(error.AmbiguousHttpFraming, validateResponseFraming(duplicate));

    try std.testing.expectError(error.AmbiguousHttpFraming, validateContentLengthField("3, 3"));
    try std.testing.expectError(error.InvalidContentLength, validateContentLengthField("+3"));
    try validateTransferEncodingField("deflate, chunked");
    try std.testing.expectError(error.HttpTransferEncodingUnsupported, validateTransferEncodingField("gzip, identity"));
    try std.testing.expectError(error.HttpContentEncodingUnsupported, validateContentEncodingField("gzip, identity"));

    const duplicate_location = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 302 Found\r\nLocation: /safe\r\nLocation: https://attacker.invalid/\r\nContent-Length: 0\r\n\r\n",
    );
    try std.testing.expectError(error.AmbiguousHttpFraming, validateResponseFraming(duplicate_location));

    const tokenized_close = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nConnection: keep-alive, close\r\nContent-Length: 0\r\n\r\n",
    );
    try validateResponseFraming(tokenized_close);
    try std.testing.expect(responseHeaderHasToken(tokenized_close, "connection", "close"));

    const invalid_name = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nBad Name: value\r\nContent-Length: 0\r\n\r\n",
    );
    try std.testing.expectError(error.HttpHeadersInvalid, validateResponseFraming(invalid_name));

    inline for (.{
        "HTTP/1.1 103 Early Hints\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 103 Early Hints\r\nTransfer-Encoding: chunked\r\n\r\n",
        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 204 No Content\r\nTransfer-Encoding: chunked\r\n\r\n",
    }) |raw| {
        const forbidden_body_framing = try std.http.Client.Response.Head.parse(raw);
        try std.testing.expectError(error.AmbiguousHttpFraming, validateResponseFraming(forbidden_body_framing));
    }

    // A 304 may advertise the framing a corresponding 200 would have used.
    const not_modified = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 304 Not Modified\r\nContent-Length: 3\r\n\r\n",
    );
    try validateResponseFraming(not_modified);
}

test "header-terminated responses are never treated as reusable body streams" {
    try std.testing.expect(responseIsHeaderTerminated(.HEAD, .ok));
    try std.testing.expect(responseIsHeaderTerminated(.GET, .early_hints));
    try std.testing.expect(responseIsHeaderTerminated(.GET, .no_content));
    try std.testing.expect(responseIsHeaderTerminated(.GET, .reset_content));
    try std.testing.expect(responseIsHeaderTerminated(.GET, .not_modified));
    try std.testing.expect(!responseIsHeaderTerminated(.GET, .ok));
}

test "strict chunk-size parser accepts extensions and rejects syntax overflow and bare LF" {
    try std.testing.expectEqual(@as(u64, 0x1a), try parseChunkSizeLine("1a;fixture=yes\r\n"));
    try std.testing.expectEqual(@as(u64, 0), try parseChunkSizeLine("0\r\n"));
    for ([_][]const u8{
        "g\r\n",
        "10000000000000000\r\n",
        "1\n",
        ";fixture=yes\r\n",
        "1;fixture=bad\x7f\r\n",
    }) |line| try std.testing.expectError(error.HttpChunkInvalid, parseChunkSizeLine(line));
}

test "public strict chunked payload reader rejects malformed and truncated framing" {
    var valid_reader: std.Io.Reader = .fixed("3\r\nabc\r\n0\r\nX-Test: ok\r\n\r\n");
    const valid = try readStrictChunkedPayload(&valid_reader, std.testing.allocator, 3);
    defer std.testing.allocator.free(valid);
    try std.testing.expectEqualStrings("abc", valid);

    const malformed_cases = [_][]const u8{
        "1\nx\r\n0\r\n\r\n",
        "g\r\n",
        "1\r\nx\n0\r\n\r\n",
    };
    for (malformed_cases) |payload| {
        var reader: std.Io.Reader = .fixed(payload);
        try std.testing.expectError(
            error.HttpChunkInvalid,
            readStrictChunkedPayload(&reader, std.testing.allocator, 1024),
        );
    }

    const truncated_cases = [_][]const u8{
        "3\r\nab",
        "3\r\nabc\r\n",
        "0\r\nX-Test: missing-terminator\r\n",
    };
    for (truncated_cases) |payload| {
        var reader: std.Io.Reader = .fixed(payload);
        try std.testing.expectError(
            error.HttpChunkTruncated,
            readStrictChunkedPayload(&reader, std.testing.allocator, 1024),
        );
    }
}

test "validate live utf8 rejects invalid and replacement" {
    try std.testing.expectError(error.InvalidUtf8Data, validateLiveUtf8(&.{0xAA}));
    try std.testing.expectError(error.InvalidUtf8Data, validateLiveUtf8("\xEF\xBF\xBD"));
    try validateLiveUtf8("Matrix");
}

test "detect Australian website block page" {
    try std.testing.expect(isAustralianWebsiteBlockPage(
        "<h2>Access to Website Disabled</h2><p>the Federal Court of Australia has determined that the website infringes</p>",
    ));
    try std.testing.expect(!isAustralianWebsiteBlockPage("<title>Provider</title>"));
}

test "optional provider fallbacks preserve terminal failures" {
    inline for (.{
        error.Canceled,
        error.OutOfMemory,
        error.ConcurrencyUnavailable,
        error.RateLimited,
        error.ProviderAccessBlocked,
        error.CloudflareChallenge,
        error.UnsafeHttpTarget,
        error.InvalidDownloadUrl,
        error.Timeout,
        error.PublicOriginProxyUnsupported,
    }) |err| try std.testing.expect(mustPropagateOptionalFailure(err));
    try std.testing.expect(!mustPropagateOptionalFailure(error.ConnectionResetByPeer));
    try std.testing.expect(!mustPropagateOptionalFailure(error.UnexpectedHttpStatus));
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

test "active provider filter expands only registry active entries" {
    try std.testing.expect(providerMatchesLiveFilter("active", "subsource.net"));
    try std.testing.expect(providerMatchesLiveFilter("ACTIVE", "subsource_net"));
    try std.testing.expect(providerMatchesLiveFilter("active", "subhd.tv"));
    try std.testing.expect(!providerMatchesLiveFilter("active", "tvsubtitles.net"));
    try std.testing.expect(providerMatchesLiveFilter("active,tvsubtitles.net", "tvsubtitles.net"));
}

test "JSON integer conversion rejects fractional nonfinite and out of range provider numbers" {
    const t = std.testing;
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1e100, -1e100, 0x1p63 }) |number|
        try t.expectEqual(@as(?i64, null), jsonInt(.{ .float = number }));
    try t.expectEqual(@as(?i64, std.math.minInt(i64)), jsonInt(.{ .float = -0x1p63 }));
    try t.expectEqual(@as(?i64, 9223372036854774784), jsonInt(.{ .float = 0x1p63 - 1024 }));
    try t.expectEqual(@as(?i64, 42), jsonInt(.{ .float = 42.0 }));
    try t.expectEqual(@as(?i64, null), jsonInt(.{ .float = 42.75 }));
    try t.expectEqual(@as(?i64, null), jsonInt(.{ .float = -42.75 }));
    try t.expectEqual(@as(?i64, null), jsonInt(.{ .number_string = "9223372036854775808" }));
}

test "HTTP cancellation and allocation failure never retry" {
    const Mock = struct {
        var calls: usize = 0;
        fn canceled(_: *std.http.Client, _: Allocator, _: []const u8, _: FetchOptions) anyerror!HttpResponse {
            calls += 1;
            return error.Canceled;
        }
        fn oom(_: *std.http.Client, _: Allocator, _: []const u8, _: FetchOptions) anyerror!HttpResponse {
            calls += 1;
            return error.OutOfMemory;
        }
        fn noBackoff(_: u64, _: usize) anyerror!void {
            return error.UnexpectedBackoff;
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    Mock.calls = 0;
    try std.testing.expectError(error.Canceled, fetchBytesWith(Mock.canceled, Mock.noBackoff, &client, std.testing.allocator, "https://fixture.invalid", .{ .cache = false, .max_attempts = 3 }));
    try std.testing.expectEqual(@as(usize, 1), Mock.calls);
    Mock.calls = 0;
    try std.testing.expectError(error.OutOfMemory, fetchBytesWith(Mock.oom, Mock.noBackoff, &client, std.testing.allocator, "https://fixture.invalid", .{ .cache = false, .max_attempts = 3 }));
    try std.testing.expectEqual(@as(usize, 1), Mock.calls);
}

test "expired absolute HTTP deadline fails before target or network work" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(error.Timeout, fetchBytes(
        &client,
        std.testing.allocator,
        "this is deliberately not a URL",
        .{ .cache = false, .deadline_ms = compatMilliTimestamp() },
    ));
}

test "HTTP fetch deadline is finite by default with explicit override and opt out" {
    const now: i64 = 1_000;
    try std.testing.expectEqual(
        @as(?i64, now + default_fetch_timeout_ms),
        effectiveFetchDeadline(.{}, now),
    );
    try std.testing.expectEqual(
        @as(?i64, 42),
        effectiveFetchDeadline(.{ .deadline_ms = 42 }, now),
    );
    try std.testing.expectEqual(
        @as(?i64, null),
        effectiveFetchDeadline(.{ .deadline_ms = 42, .disable_deadline = true }, now),
    );
    try std.testing.expectEqual(
        @as(?i64, std.math.maxInt(i64)),
        effectiveFetchDeadline(.{}, std.math.maxInt(i64) - 1),
    );
}

test "HTTP wrapper errors preserve their underlying cancellation" {
    try std.testing.expectEqual(error.Canceled, normalizeWrappedTransportError(error.WriteFailed, error.Canceled));
    try std.testing.expectEqual(error.Canceled, normalizeWrappedTransportError(error.ReadFailed, error.Canceled));
    try std.testing.expectEqual(error.WriteFailed, normalizeWrappedTransportError(error.WriteFailed, null));
    try std.testing.expectEqual(error.ReadFailed, normalizeWrappedTransportError(error.ReadFailed, null));
    try std.testing.expectEqual(error.OutOfMemory, normalizeAllocatingWriterError(error.WriteFailed));
    try std.testing.expectEqual(error.Canceled, normalizeAllocatingWriterError(error.Canceled));
}

test "malformed gzip and zstd retain decoder errors" {
    {
        var input: std.Io.Reader = .fixed("not a gzip payload");
        var decoder: std.http.Decompress = undefined;
        const reader = decoder.init(&input, &.{}, .gzip);
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();

        try std.testing.expectError(error.ReadFailed, reader.streamRemaining(&output.writer));
        const decoder_error = decompressionReadError(&decoder) orelse return error.ExpectedDecoderError;
        try std.testing.expect(decoder_error != error.ReadFailed);
    }
    {
        var input: std.Io.Reader = .fixed("\x28\xb5\x2f");
        var decoder: std.http.Decompress = undefined;
        const reader = decoder.init(&input, &.{}, .zstd);
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();

        try std.testing.expectError(error.ReadFailed, reader.streamRemaining(&output.writer));
        const decoder_error = decompressionReadError(&decoder) orelse return error.ExpectedDecoderError;
        try std.testing.expect(decoder_error != error.ReadFailed);
    }
}

test "encoded response cap bounds zstd skippable input" {
    const encoded = "\x50\x2a\x4d\x18\x40\x00\x00\x00" ++ @as([64]u8, @splat('x'));
    var input: std.Io.Reader = .fixed(encoded);
    var bounded_buffer: [2048]u8 = undefined;
    var bounded = input.limited(.limited(17), &bounded_buffer);
    var decoder: std.http.Decompress = undefined;
    const reader = decoder.init(&bounded.interface, &.{}, .zstd);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = reader.streamRemaining(&output.writer) catch {};
    try std.testing.expectEqual(std.Io.Limit.nothing, bounded.remaining);
    try std.testing.expectEqual(@as(usize, 17), input.seek);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "encoded response sentinel limit cannot overflow" {
    try std.testing.expectEqual(@as(usize, 1), try encodedResponseReadLimit(0));
    try std.testing.expectEqual(std.math.maxInt(usize) - 1, try encodedResponseReadLimit(std.math.maxInt(usize) - 2));
    try std.testing.expectError(error.InvalidResponseLimit, encodedResponseReadLimit(std.math.maxInt(usize) - 1));
    try std.testing.expectError(error.InvalidResponseLimit, encodedResponseReadLimit(std.math.maxInt(usize)));
}

test "XZ decoding verifies checksums concatenation padding and output limits" {
    const no_check_alpha = "\xfd\x37\x7a\x58\x5a\x00\x00\x00\xff\x12\xd9\x41\x04\xc0\x09\x05\x21\x01\x16\x00\x00\x00\x00\x00\x00\x00\x00\x00\xbf\x79\x25\x67\x01\x00\x04\x61\x6c\x70\x68\x61\x00\x00\x00\x00\x00\x01\x1d\x05\xb8\x2d\x80\xaf\x06\x72\x9e\x7a\x01\x00\x00\x00\x00\x00\x59\x5a";
    const crc32_alpha = "\xfd\x37\x7a\x58\x5a\x00\x00\x01\x69\x22\xde\x36\x02\x00\x21\x01\x16\x00\x00\x00\x74\x2f\xe5\xa3\x01\x00\x04\x61\x6c\x70\x68\x61\x00\x00\x00\x00\x6a\x39\xe0\xd0\x00\x01\x19\x05\xbc\xe8\xec\xcb\x90\x42\x99\x0d\x01\x00\x00\x00\x00\x01\x59\x5a";
    const crc64_beta = "\xfd\x37\x7a\x58\x5a\x00\x00\x04\xe6\xd6\xb4\x46\x02\x00\x21\x01\x16\x00\x00\x00\x74\x2f\xe5\xa3\x01\x00\x03\x62\x65\x74\x61\x00\x9b\x1c\x04\x14\x7c\x27\x61\x73\x00\x01\x1c\x04\x6f\x2c\x9c\xc1\x1f\xb6\xf3\x7d\x01\x00\x00\x00\x00\x04\x59\x5a";
    const sha256_gamma = "\xfd\x37\x7a\x58\x5a\x00\x00\x0a\xe1\xfb\x0c\xa1\x02\x00\x21\x01\x16\x00\x00\x00\x74\x2f\xe5\xa3\x01\x00\x04\x67\x61\x6d\x6d\x61\x00\x00\x00\x00\xbe\x9d\x58\x7d\xef\xa1\xf0\xc0\x9e\xf4\x9e\xb1\x7e\x20\x69\x83\xa5\xf8\xf8\x28\x9e\x42\x81\x86\x0b\xd0\xee\x5a\x19\x59\x2c\x67\x00\x01\x35\x05\x12\x83\xdd\xf2\x18\x9b\x4b\x9a\x01\x00\x00\x00\x00\x0a\x59\x5a";

    const concatenated = crc32_alpha ++ "\x00\x00\x00\x00" ++ crc64_beta;
    const decoded = try decompressXz(std.testing.allocator, concatenated, 9);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("alphabeta", decoded);

    const sha_decoded = try decompressXz(std.testing.allocator, sha256_gamma, 5);
    defer std.testing.allocator.free(sha_decoded);
    try std.testing.expectEqualStrings("gamma", sha_decoded);

    var corrupt = try std.testing.allocator.dupe(u8, crc32_alpha);
    defer std.testing.allocator.free(corrupt);
    corrupt[36] ^= 1;
    try std.testing.expectError(error.WrongChecksum, decompressXz(std.testing.allocator, corrupt, 5));
    try std.testing.expectError(error.Unsupported, decompressXz(std.testing.allocator, no_check_alpha, 5));
    try std.testing.expectError(error.ResponseTooLarge, decompressXz(std.testing.allocator, crc32_alpha, 4));
    try std.testing.expectError(error.CorruptInput, decompressXz(std.testing.allocator, crc32_alpha ++ "x", 5));

    const unexpected = decompressXz(std.testing.allocator, crc32_alpha[0..30], 5) catch |err| {
        try std.testing.expect(err != error.ReadFailed);
        return;
    };
    defer std.testing.allocator.free(unexpected);
    return error.ExpectedTruncatedXzError;
}

test "XZ CRC-64 implementation matches the standard check vector" {
    try std.testing.expectEqual(
        @as(u64, 0x995d_c9bb_df19_39fa),
        std.hash.crc.@"CRC-64/XZ".hash("123456789"),
    );
}

test "XZ decoder memory cap derivation cannot overflow" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), xzDecoderMemoryLimit(0));
    try std.testing.expectEqual(std.math.maxInt(usize), xzDecoderMemoryLimit(std.math.maxInt(usize)));

    var budget: XzBudgetAllocator = .{ .child = std.testing.allocator, .limit = 4 };
    const allocator = budget.allocator();
    const allocation = try allocator.alloc(u8, 4);
    defer allocator.free(allocation);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expect(budget.limit_exceeded);
}

test "encoded response limit leaves room for the sentinel" {
    try validateFetchHeaders(.{ .max_encoded_response_bytes = std.math.maxInt(usize) - 2 });
    try std.testing.expectError(
        error.InvalidResponseLimit,
        validateFetchHeaders(.{ .max_encoded_response_bytes = std.math.maxInt(usize) - 1 }),
    );
    try std.testing.expectError(
        error.InvalidResponseLimit,
        validateFetchHeaders(.{ .max_encoded_response_bytes = std.math.maxInt(usize) }),
    );
}

test "HTTP deterministic response and policy failures never retry" {
    const Fixture = struct {
        client: std.http.Client,
        failure: anyerror,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: FetchOptions) anyerror!HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return self.failure;
        }

        fn noBackoff(_: u64, _: usize) anyerror!void {
            return error.UnexpectedBackoff;
        }
    };

    inline for (.{
        error.UnsafeHttpTarget,
        error.InvalidDownloadUrl,
        error.PublicOriginProxyUnsupported,
        error.UnsupportedProtocolUpgrade,
        error.TooManyInformationalResponses,
        error.TooManyHttpRedirects,
        error.HttpRedirectLocationMissing,
        error.InvalidHttpHeader,
        error.InvalidHttpMethodPayload,
        error.TransportOwnedHttpHeader,
        error.HttpConnectionHeaderUnsupported,
        error.HttpContentEncodingUnsupported,
        error.HttpHeaderContinuationsUnsupported,
        error.HttpHeadersOversize,
        error.UnsupportedCompressionMethod,
        error.TooManyCompressedMembers,
        error.InvalidResponseLimit,
        error.ResponseTooLarge,
        error.AmbiguousHttpFraming,
        error.HttpChunkInvalid,
        error.InvalidContentLength,
        error.HttpHeadersInvalid,
        error.HttpTransferEncodingUnsupported,
        error.UnexpectedEncodedPayload,
        error.WrongGzipChecksum,
        error.WrongGzipSize,
        error.WrongZlibChecksum,
    }) |failure| {
        var fixture: Fixture = .{
            .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .failure = failure,
        };
        defer fixture.client.deinit();
        try std.testing.expectError(failure, fetchBytesWith(
            Fixture.fetch,
            Fixture.noBackoff,
            &fixture.client,
            std.testing.allocator,
            "https://fixture.invalid",
            .{ .cache = false, .max_attempts = 3 },
        ));
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    }
}

test "TLS initialization lock wait preserves cancellation" {
    const Pause = struct {
        fn cancel(_: u64) !void {
            return error.Canceled;
        }
    };
    client_init_lock.store(1, .release);
    defer client_init_lock.store(0, .release);
    try std.testing.expectError(error.Canceled, acquireClientInitLockUsing(Pause.cancel));
}

test "HTTP backoff cancellation prevents the next network attempt" {
    const Mock = struct {
        var calls: usize = 0;
        fn fail(_: *std.http.Client, _: Allocator, _: []const u8, _: FetchOptions) anyerror!HttpResponse {
            calls += 1;
            return error.ConnectionResetByPeer;
        }
        fn cancel(_: u64, _: usize) anyerror!void {
            return error.Canceled;
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    Mock.calls = 0;
    try std.testing.expectError(error.Canceled, fetchBytesWith(Mock.fail, Mock.cancel, &client, std.testing.allocator, "https://fixture.invalid", .{ .cache = false, .max_attempts = 3 }));
    try std.testing.expectEqual(@as(usize, 1), Mock.calls);
}

test "HTTP 429 becomes rate limited after retry exhaustion" {
    const Mock = struct {
        var calls: usize = 0;
        var backoffs: usize = 0;

        fn rateLimited(_: *std.http.Client, allocator: Allocator, _: []const u8, _: FetchOptions) anyerror!HttpResponse {
            calls += 1;
            return .{
                .status = .too_many_requests,
                .body = try allocator.dupe(u8, "slow down"),
            };
        }

        fn backoff(_: u64, _: usize) anyerror!void {
            backoffs += 1;
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    Mock.calls = 0;
    Mock.backoffs = 0;
    try std.testing.expectError(error.RateLimited, fetchBytesWith(Mock.rateLimited, Mock.backoff, &client, std.testing.allocator, "https://fixture.invalid", .{
        .cache = false,
        .max_attempts = 3,
    }));
    try std.testing.expectEqual(@as(usize, 3), Mock.calls);
    try std.testing.expectEqual(@as(usize, 2), Mock.backoffs);

    Mock.calls = 0;
    Mock.backoffs = 0;
    try std.testing.expectError(error.RateLimited, fetchBytesWith(Mock.rateLimited, Mock.backoff, &client, std.testing.allocator, "https://fixture.invalid", .{
        .cache = false,
        .max_attempts = 3,
        .retry_on_429 = false,
    }));
    try std.testing.expectEqual(@as(usize, 1), Mock.calls);
    try std.testing.expectEqual(@as(usize, 0), Mock.backoffs);
}

test "pinned address fallback preserves terminal connect errors" {
    var last_error: anyerror = error.NoAddressReturned;

    try std.testing.expectError(error.Canceled, rememberRetryableConnectError(&last_error, error.Canceled));
    try std.testing.expect(last_error == error.NoAddressReturned);
    try std.testing.expectError(error.OutOfMemory, rememberRetryableConnectError(&last_error, error.OutOfMemory));
    try std.testing.expect(last_error == error.NoAddressReturned);

    try rememberRetryableConnectError(&last_error, error.FixtureConnectFailed);
    try std.testing.expect(last_error == error.FixtureConnectFailed);
}

fn failAfterArenaTransfer(allocator: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    _ = try arena.allocator().dupe(u8, "allocated response body");
    return consumeArenaFailure(takeArena(&arena));
}
fn consumeArenaFailure(arena: std.heap.ArenaAllocator) !void {
    var owned = arena;
    defer owned.deinit();
    return error.MalformedTestResponse;
}
fn checkArenaErrorOwnership(allocator: Allocator) !void {
    failAfterArenaTransfer(allocator) catch |err| switch (err) {
        error.MalformedTestResponse => return,
        else => return err,
    };
    return error.ExpectedMalformedTestResponse;
}
test "response parser transfer has one cleanup owner on all failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkArenaErrorOwnership, .{});
}
test "native script title normalization keeps non ASCII identity" {
    for ([_][]const u8{ "進撃の巨人", "字幕", "école" }) |title| {
        const result = try normalizeTitle(std.testing.allocator, title);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(title, result);
    }
}

test "normalized title relevance rejects empty and partial-word matches" {
    try std.testing.expect(normalizedTitlesRelated("the matrix revolutions", "the matrix"));
    try std.testing.expect(normalizedTitlesRelated("jack reacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("preacher", "reacher"));
    try std.testing.expect(!normalizedTitlesRelated("the matrix", ""));
}

test "title normalization treats malformed UTF-8 as separators" {
    const allocator = std.testing.allocator;
    for ([_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "Alpha\xffBeta", .expected = "alpha beta" },
        .{ .input = "Alpha\xc3(Beta", .expected = "alpha beta" },
        .{ .input = "\xff\xfeAlpha\xf0\x9f", .expected = "alpha" },
        .{ .input = "é\xff進撃", .expected = "é 進撃" },
    }) |fixture| {
        const normalized = try normalizeTitle(allocator, fixture.input);
        defer allocator.free(normalized);
        try std.testing.expectEqualStrings(fixture.expected, normalized);
        try std.testing.expect(std.unicode.utf8ValidateSlice(normalized));
    }
}
test "episode parsing preserves season zero and complete episode numbers" {
    try std.testing.expectEqual(@as(?i64, 0), parseSeasonEpisode("Show S00E01").season);
    try std.testing.expectEqual(@as(?i64, 0), parseSeasonEpisode("Show S01E00").episode);
    try std.testing.expectEqual(@as(?i64, 1), parseSeasonEpisode("S1E1").episode);
    try std.testing.expectEqual(@as(?u16, 1000), parseEpisodeQuery("Show S01E1000").episode);
    try std.testing.expectEqual(@as(?u16, 100), parseEpisodeQuery("Show S100E01").season);
    try std.testing.expectEqual(@as(?u16, null), parseEpisodeQuery("Show S01E99999999999").episode);
}

test "episode parsing requires token boundaries" {
    for ([_][]const u8{ "Cases01E02 Study", "Show S01E02x" }) |value| {
        try std.testing.expectEqual(@as(?i64, null), parseSeasonEpisode(value).season);
        try std.testing.expectEqual(@as(?u16, null), parseEpisodeQuery(value).season);
    }

    const separated = parseEpisodeQuery("Show.S01E02.1080p");
    try std.testing.expectEqualStrings("Show", separated.title);
    try std.testing.expectEqual(@as(?u16, 1), separated.season);
    try std.testing.expectEqual(@as(?u16, 2), separated.episode);
}

test "HTML detection treats tag names case insensitively" {
    try std.testing.expect(looksLikeHtml("<head>gateway</head><BODY>error</BODY>"));
    try std.testing.expect(!looksLikeHtml("1\n00:00:01,000 --> 00:00:02,000\nbody language"));
}

fn checkFinalArenaCapture(allocator: Allocator) !void {
    const Response = struct { arena: std.heap.ArenaAllocator, title: []const u8 };
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var response = finishResponse(Response, &arena, .{ .arena = arena, .title = try arena.allocator().dupe(u8, "first allocation occurs after the arena field") });
    defer response.arena.deinit();
    try std.testing.expectEqualStrings("first allocation occurs after the arena field", response.title);
}
test "response finalization captures allocations made by later field expressions" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkFinalArenaCapture, .{});
}

pub fn isWindowsReservedFilename(name: []const u8) bool {
    const stem_end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    var trimmed_end = stem_end;
    while (trimmed_end > 0) {
        const ch = name[trimmed_end - 1];
        if (ch != ' ' and ch != '.') break;
        trimmed_end -= 1;
    }
    const stem = name[0..trimmed_end];
    if (stem.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(stem, "CON") or
        std.ascii.eqlIgnoreCase(stem, "PRN") or
        std.ascii.eqlIgnoreCase(stem, "AUX") or
        std.ascii.eqlIgnoreCase(stem, "NUL") or
        std.ascii.eqlIgnoreCase(stem, "CONIN$") or
        std.ascii.eqlIgnoreCase(stem, "CONOUT$") or
        std.ascii.eqlIgnoreCase(stem, "CLOCK$"))
    {
        return true;
    }
    if (stem.len == 4 and
        (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or
            std.ascii.eqlIgnoreCase(stem[0..3], "LPT")) and
        stem[3] >= '1' and stem[3] <= '9')
    {
        return true;
    }
    // Win32 also recognizes superscript 1/2/3 in device-number aliases.
    if (stem.len == 5 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
        return std.mem.eql(u8, stem[3..], "¹") or std.mem.eql(u8, stem[3..], "²") or std.mem.eql(u8, stem[3..], "³");
    }
    return false;
}

test "HTTP cache keys isolate cookie identities" {
    const a = std.testing.allocator;
    const first = try fetchCachePath(a, "cache", "https://fixture.invalid/data", .{ .extra_headers = &.{.{ .name = "Cookie", .value = "fixture=first" }} });
    defer a.free(first);
    const second = try fetchCachePath(a, "cache", "https://fixture.invalid/data", .{ .extra_headers = &.{.{ .name = "Cookie", .value = "fixture=second" }} });
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));

    const downgrade_allowed = try fetchCachePath(a, "cache", "https://fixture.invalid/data", .{});
    defer a.free(downgrade_allowed);
    const https_only = try fetchCachePath(a, "cache", "https://fixture.invalid/data", .{ .require_https = true });
    defer a.free(https_only);
    try std.testing.expect(!std.mem.eql(u8, downgrade_allowed, https_only));

    const same_origin = try fetchCachePath(a, "cache", "https://fixture.invalid/data", .{ .require_same_origin = true });
    defer a.free(same_origin);
    try std.testing.expect(!std.mem.eql(u8, downgrade_allowed, same_origin));

    const absent_accept = try fetchCachePath(a, "cache", "https://fixture.invalid/data", .{});
    defer a.free(absent_accept);
    const empty_accept = try fetchCachePath(a, "cache", "https://fixture.invalid/data", .{ .accept = "" });
    defer a.free(empty_accept);
    try std.testing.expect(!std.mem.eql(u8, absent_accept, empty_accept));

    const segmented_a = try fetchCachePath(a, "cache", "https://fixture.invalid/data", .{ .extra_headers = &.{.{ .name = "ab", .value = "c" }} });
    defer a.free(segmented_a);
    const segmented_b = try fetchCachePath(a, "cache", "https://fixture.invalid/data", .{ .extra_headers = &.{.{ .name = "a", .value = "bc" }} });
    defer a.free(segmented_b);
    try std.testing.expect(!std.mem.eql(u8, segmented_a, segmented_b));
}

test "HTTP cache read cap is derived without overflow or unlimited sentinel" {
    try std.testing.expectEqual(@as(?usize, fetch_cache_metadata_max_bytes), fetchCacheFileLimit(0));
    try std.testing.expectEqual(
        @as(?usize, std.math.maxInt(usize) - 2),
        fetchCacheFileLimit(std.math.maxInt(usize) - fetch_cache_metadata_max_bytes - 2),
    );
    try std.testing.expectEqual(@as(?usize, null), fetchCacheFileLimit(std.math.maxInt(usize) - fetch_cache_metadata_max_bytes - 1));
    try std.testing.expectEqual(@as(?usize, null), fetchCacheFileLimit(std.math.maxInt(usize)));
}

test "URL resolution reserves both relative input and merged output" {
    const segment = "very-long-relative-subtitle-directory/";
    const href = segment ++ segment ++ segment ++ segment ++ segment ++ segment ++ segment ++ segment ++ "episode.srt";
    const resolved = try resolveUrl(std.testing.allocator, "https://fixture.invalid/base/", href);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("https://fixture.invalid/base/" ++ href, resolved);
}

test "named live subtitlecat aliases reach translation coverage" {
    try std.testing.expectEqualStrings("subtitlecat.com", namedLiveProvider("SUBTITLECAT_COM").?);
    try std.testing.expectEqualStrings("subtitlecat.com", namedLiveProvider("SUBTITLECAT").?);
}

test "HTTP cache configuration owns and snapshots its root path" {
    const allocator = std.testing.allocator;
    const expected = ".zig-cache/cache-owned-root";
    const caller_root = try allocator.dupe(u8, expected);
    defer allocator.free(caller_root);
    configureFetchCache(.{ .enabled = true, .root_dir = caller_root, .ttl_seconds = 17 });
    defer configureFetchCache(.{});

    @memset(caller_root, 'x');
    var snapshot = try currentFetchCacheConfig(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expect(snapshot.enabled);
    try std.testing.expectEqual(@as(i64, 17), snapshot.ttl_seconds);
    try std.testing.expectEqualStrings(expected, snapshot.root_dir.?);

    configureFetchCache(.{});
    try std.testing.expectEqualStrings(expected, snapshot.root_dir.?);
}

test "HTTP cache opens a FIFO without blocking before rejecting it" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = std.os.linux.mknodat(
        tmp.dir.handle,
        "cache.fifo",
        std.os.linux.S.IFIFO | std.os.linux.S.IRUSR | std.os.linux.S.IWUSR,
        0,
    );
    try std.testing.expect(std.os.linux.errno(result) == .SUCCESS);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/cache.fifo", .{tmp.sub_path});
    defer allocator.free(path);
    const file = try openFetchCacheFile(runtime_io.get(), path);
    defer file.close(runtime_io.get());
    try std.testing.expect((try file.stat(runtime_io.get())).kind != .file);
}

test "HTTP cache rejects legacy status and impossible timestamps" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    configureFetchCache(.{ .enabled = true, .root_dir = root, .ttl_seconds = 0 });
    defer configureFetchCache(.{});
    const url = "https://fixture.invalid/cache";
    const path = try fetchCachePath(allocator, root, url, .{});
    defer allocator.free(path);
    try ensureParentDir(path);
    try std.Io.Dir.cwd().writeFile(runtime_io.get(), .{ .sub_path = path, .data = "old cache bytes" });
    var body = [_]u8{'x'};
    try storeFetchCache(allocator, url, .{}, .{ .status = .ok, .body = &body });
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        const file = try std.Io.Dir.cwd().openFile(runtime_io.get(), path, .{});
        defer file.close(runtime_io.get());
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try file.stat(runtime_io.get())).permissions.toMode() & 0o777);
    }
    const valid = (try loadFetchCache(allocator, url, .{})).?;
    allocator.free(valid.body);
    const now = compatUnixTimestamp();
    for ([_]struct { magic: []const u8, status: u16 = 200, timestamp: i64 }{
        .{ .magic = "subdl-http-cache-v1\n", .timestamp = now },
        .{ .magic = "subdl-http-cache-v2\n", .timestamp = now },
        .{ .magic = fetch_cache_magic, .status = 500, .timestamp = now },
        .{ .magic = fetch_cache_magic, .timestamp = -1 },
        .{ .magic = fetch_cache_magic, .timestamp = std.math.maxInt(i64) },
    }) |case| {
        const content = try std.fmt.allocPrint(allocator, "{s}{d}\n{d}\n1\nx", .{ case.magic, case.timestamp, case.status });
        defer allocator.free(content);
        try std.Io.Dir.cwd().writeFile(runtime_io.get(), .{ .sub_path = path, .data = content });
        try std.testing.expect((try loadFetchCache(allocator, url, .{})) == null);
    }
}

test "unusable cache directory cannot discard a successful HTTP response" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(runtime_io.get(), .{ .sub_path = "http", .data = "ordinary file" });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    configureFetchCache(.{ .enabled = true, .root_dir = root });
    defer configureFetchCache(.{});
    const Mock = struct {
        fn fetch(_: *std.http.Client, a: Allocator, _: []const u8, _: FetchOptions) anyerror!HttpResponse {
            return .{ .status = .ok, .body = try a.dupe(u8, "success") };
        }
        fn backoff(_: u64, _: usize) anyerror!void {
            return error.UnexpectedRetry;
        }
    };
    var client: std.http.Client = .{ .allocator = allocator, .io = runtime_io.get() };
    defer client.deinit();
    const response = try fetchBytesWith(Mock.fetch, Mock.backoff, &client, allocator, "https://fixture.invalid/cache-failure", .{});
    defer allocator.free(response.body);
    try std.testing.expectEqualStrings("success", response.body);
}

test "cache publication is best effort except for cancellation" {
    try std.testing.expectError(error.Canceled, handleFetchCachePublicationError(error.Canceled));
    try handleFetchCachePublicationError(error.OutOfMemory);
    try handleFetchCachePublicationError(error.AccessDenied);

    configureFetchCache(.{ .enabled = true, .root_dir = ".zig-cache/cache-oom-fixture" });
    defer configureFetchCache(.{});

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var body = [_]u8{ 'v', 'a', 'l', 'i', 'd' };
    // The first cache-key/path allocation fails. Cache publication is
    // disposable, so the successful response remains usable by its caller.
    try storeFetchCache(failing.allocator(), "https://fixture.invalid/cache-oom", .{}, .{
        .status = .ok,
        .body = &body,
    });
    try std.testing.expectEqualStrings("valid", &body);
}

test "title normalization collapses Unicode whitespace without destroying scripts" {
    const allocator = std.testing.allocator;
    const title = try normalizeTitle(allocator, "\u{a0}Chernobyl\u{a0}");
    defer allocator.free(title);
    try std.testing.expectEqualStrings("chernobyl", title);
    const japanese = try normalizeTitle(allocator, "字幕\u{3000}作品");
    defer allocator.free(japanese);
    try std.testing.expectEqualStrings("字幕 作品", japanese);
}

test "Windows superscript device names are reserved before extensions" {
    for ([_][]const u8{ "COM¹.srt", "LPT².ass", "COM³", "lpt³ .srt" }) |name| try std.testing.expect(isWindowsReservedFilename(name));
    try std.testing.expect(!isWindowsReservedFilename("COM⁴.srt"));
}

test "LivePhase remains usable without thread support" {
    if (comptime builtin.single_threaded) {
        var phase: LivePhase = .{ .scope = "test", .phase = "single-threaded" };
        phase.start();
        phase.finish();
        try std.testing.expect(phase.thread == null);
    }
}
