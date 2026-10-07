const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const common = @import("common.zig");
const chromium_pipe = @import("chromium_pipe.zig");
const runtime_io = @import("runtime_io");

const Allocator = std.mem.Allocator;
const shared_cache_filename = "cloudflare_shared_sessions.json";
const session_ttl_seconds: i64 = 5 * 60 * 60;
const challenge_timeout_ms: i64 = 4 * 60 * 1000;
const challenge_poll_interval_ms: i64 = 1000;
const automatic_headed_probe_ms: i64 = 60 * 1000;
const automatic_headless_reserve_ms: i64 = 60 * 1000;
const cache_lock_timeout_ms: i64 = 5 * 1000;
const max_browser_user_agent_bytes: usize = 4096;
const max_session_cache_bytes: usize = 2 * 1024 * 1024;
const max_session_cache_records: usize = 256;
const max_session_cookies: usize = 4096;
var session_acquire_lock = std.atomic.Value(u8).init(0);
var last_session_generation = std.atomic.Value(u64).init(0);

const BrowserLaunchMode = enum {
    automatic,
    headed,
    headless,
};

const BrowserLaunchPlan = struct {
    mode: BrowserLaunchMode,
    auto_starts_headed: bool,

    fn primaryHeadless(self: BrowserLaunchPlan) bool {
        return switch (self.mode) {
            .automatic => !self.auto_starts_headed,
            .headed => false,
            .headless => true,
        };
    }

    fn passCount(self: BrowserLaunchPlan) usize {
        return if (self.mode == .automatic and self.auto_starts_headed) 2 else 1;
    }

    fn headlessForPass(self: BrowserLaunchPlan, pass_index: usize) bool {
        return switch (self.mode) {
            .automatic => !self.auto_starts_headed or pass_index == 1,
            .headed => false,
            .headless => true,
        };
    }
};

const BrowserLaunchAttempt = struct {
    executable_index: usize,
    headless: bool,
};

const BrowserLaunchIterator = struct {
    plan: BrowserLaunchPlan,
    pass_index: usize = 0,
    executable_index: usize = 0,

    fn next(self: *BrowserLaunchIterator, executable_count: usize) ?BrowserLaunchAttempt {
        while (self.pass_index < self.plan.passCount()) {
            if (self.executable_index < executable_count) {
                const index = self.executable_index;
                self.executable_index += 1;
                return .{
                    .executable_index = index,
                    .headless = self.plan.headlessForPass(self.pass_index),
                };
            }
            self.pass_index += 1;
            self.executable_index = 0;
        }
        return null;
    }
};

const SessionAcquireGuard = struct {
    fn lockUntil(deadline_ms: i64) !SessionAcquireGuard {
        return lockUntilWith(deadline_ms, common.compatMilliTimestamp, common.sleepMillisecondsCancelable);
    }

    fn lockUntilWith(deadline_ms: i64, comptime now: anytype, comptime pause: anytype) !SessionAcquireGuard {
        while (session_acquire_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            const current = now();
            const delay = remainingTimeoutMs(current, deadline_ms, 25) orelse
                return error.CloudflareSessionUnavailable;
            try pause(delay);
        }
        if (now() >= deadline_ms) {
            session_acquire_lock.store(0, .release);
            return error.CloudflareSessionUnavailable;
        }
        return .{};
    }

    fn unlock(_: SessionAcquireGuard) void {
        session_acquire_lock.store(0, .release);
    }
};

pub const Error = error{
    CloudflareSessionUnavailable,
    BrowserAutomationDisabled,
    BrowserAutomationUnavailable,
    InvalidBrowserExecutable,
    BrowserAutomationFailed,
    InvalidSessionPayload,
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    secure: bool,
    host_only: bool,
    expires_unix_seconds: ?i64,
};

pub const Session = struct {
    cookies: []const Cookie,
    cf_clearance: []const u8,
    user_agent: []const u8,
    acquired_at_unix: i64,
    generation: u64,

    pub fn isLikelyExpired(self: Session, now_unix: i64) bool {
        return self.acquired_at_unix > now_unix or @as(i128, now_unix) - self.acquired_at_unix > session_ttl_seconds;
    }

    pub fn cookieHeaderForUrl(self: Session, allocator: Allocator, url: []const u8) !?[]u8 {
        return buildCookieHeaderForUrl(allocator, self.cookies, url, common.compatUnixTimestamp());
    }

    pub fn deinit(self: *Session, allocator: Allocator) void {
        freeCookies(allocator, self.cookies);
        allocator.free(self.cf_clearance);
        allocator.free(self.user_agent);
        self.* = undefined;
    }
};

pub const EnsureDomainOptions = struct {
    domain: []const u8,
    challenge_url: ?[]const u8 = null,
    force_refresh: bool = false,
    /// Identifies the session that the caller has just seen rejected. A forced
    /// refresh may reuse a different generation produced by a concurrent
    /// acquisition, but it must never return this generation again.
    rejected_generation: ?u64 = null,
};

const CacheRecord = struct {
    domain: []const u8,
    cookies: []const Cookie,
    cf_clearance: []const u8,
    user_agent: []const u8,
    acquired_at_unix: i64,
    generation: u64,
};

pub fn ensureDomainSession(allocator: Allocator, options: EnsureDomainOptions) !Session {
    // Queueing, cache work and browser acquisition share one wall-clock budget.
    const deadline = common.compatMilliTimestamp() +| challenge_timeout_ms;
    const acquire_guard = try SessionAcquireGuard.lockUntil(deadline);
    defer acquire_guard.unlock();
    try browserDeadlineCheckpoint(deadline);

    const normalized_domain = try normalizeDomain(allocator, options.domain);
    defer allocator.free(normalized_domain);

    var owned_challenge_url: ?[]u8 = null;
    defer if (owned_challenge_url) |url| allocator.free(url);

    const challenge_url = if (options.challenge_url) |url|
        url
    else blk: {
        owned_challenge_url = try std.fmt.allocPrint(allocator, "https://{s}/", .{normalized_domain});
        break :blk owned_challenge_url orelse return error.OutOfMemory;
    };
    try validateChallengeTarget(challenge_url, normalized_domain);

    if (try loadSessionForDomain(allocator, normalized_domain, deadline)) |cached| {
        if (try reuseLoadedSessionUsing(
            allocator,
            normalized_domain,
            cached,
            options,
            challenge_url,
            common.compatUnixTimestamp(),
            deadline,
            browserDeadlineCheckpoint,
            removeCachedSessionForDomain,
        )) |reusable| return reusable;
    }

    try browserDeadlineCheckpoint(deadline);
    const acquired = try acquireSessionViaBrowser(allocator, normalized_domain, challenge_url, deadline);
    return finishAcquiredSessionUsing(
        allocator,
        normalized_domain,
        acquired,
        deadline,
        browserDeadlineCheckpoint,
        saveSessionForDomain,
    );
}

fn reuseLoadedSessionUsing(
    allocator: Allocator,
    normalized_domain: []const u8,
    loaded: Session,
    options: EnsureDomainOptions,
    challenge_url: []const u8,
    now: i64,
    deadline: i64,
    comptime checkpoint: anytype,
    comptime remove_cached: anytype,
) !?Session {
    var cached = loaded;
    var owns_cached = true;
    defer if (owns_cached) cached.deinit(allocator);

    try checkpoint(deadline);
    if (canReuseCachedSession(cached, options, challenge_url, now)) {
        // Validation can consume the final part of the shared deadline. Keep
        // ownership until a second checkpoint confirms the caller can use it.
        try checkpoint(deadline);
        owns_cached = false;
        return cached;
    }
    remove_cached(allocator, normalized_domain, cached, deadline) catch |err| {
        if (mustPropagateOperationError(err)) return err;
    };
    return null;
}

fn finishAcquiredSessionUsing(
    allocator: Allocator,
    normalized_domain: []const u8,
    acquired_value: Session,
    deadline: i64,
    comptime checkpoint: anytype,
    comptime save_session: anytype,
) !Session {
    var acquired = acquired_value;
    var owns_acquired = true;
    defer if (owns_acquired) acquired.deinit(allocator);

    try checkpoint(deadline);
    save_session(allocator, normalized_domain, acquired, deadline) catch |err| {
        if (mustPropagateOperationError(err)) return err;
        // Persistence is an optimization. A valid browser session remains
        // useful when HOME, permissions, or the cache lock are unavailable.
    };
    try checkpoint(deadline);
    owns_acquired = false;
    return acquired;
}

fn isUsableSession(session: Session, challenge_url: []const u8, now: i64) bool {
    if (session.cf_clearance.len == 0) return false;
    if (!validBrowserUserAgent(session.user_agent)) return false;
    const clearance = findCookieValueForUrl(session.cookies, challenge_url, "cf_clearance", now) orelse return false;
    return std.mem.eql(u8, clearance, session.cf_clearance);
}

fn canReuseCachedSession(session: Session, options: EnsureDomainOptions, challenge_url: []const u8, now: i64) bool {
    if (session.isLikelyExpired(now) or !isUsableSession(session, challenge_url, now)) return false;
    if (!options.force_refresh) return true;
    const rejected = options.rejected_generation orelse return false;
    return session.generation != 0 and session.generation != rejected;
}

fn loadSessionForDomain(allocator: Allocator, domain_input: []const u8, deadline: i64) !?Session {
    if (!build_options.enable_alldriver or !diskSessionCacheSupported(builtin.os.tag)) return null;
    try browserDeadlineCheckpoint(deadline);
    const io = runtime_io.get();
    const cache_lock = acquireSessionCacheLock(allocator, deadline) catch |err| {
        if (mustPropagateOperationError(err)) return err;
        return null;
    };
    defer cache_lock.close(io);
    try browserDeadlineCheckpoint(deadline);

    const domain = try normalizeDomain(allocator, domain_input);
    defer allocator.free(domain);

    var records = try readCacheRecords(allocator, deadline);
    defer freeCacheRecords(allocator, &records);
    if (pruneCacheRecords(allocator, &records, common.compatUnixTimestamp())) {
        // Cache maintenance is opportunistic. A read-only cache directory or
        // a full disk must not prevent a fresh browser acquisition.
        try ignoreOrdinaryOperationFailure(writeCacheRecords(allocator, records.items, deadline));
        try browserDeadlineCheckpoint(deadline);
    }

    for (records.items) |record| {
        if (!std.ascii.eqlIgnoreCase(record.domain, domain)) continue;

        return try cloneSession(allocator, .{
            .cookies = record.cookies,
            .cf_clearance = record.cf_clearance,
            .user_agent = record.user_agent,
            .acquired_at_unix = record.acquired_at_unix,
            .generation = record.generation,
        });
    }

    return null;
}

fn saveSessionForDomain(allocator: Allocator, domain_input: []const u8, session: Session, deadline: i64) !void {
    if (!build_options.enable_alldriver or !diskSessionCacheSupported(builtin.os.tag)) return;
    try browserDeadlineCheckpoint(deadline);

    const io = runtime_io.get();
    const cache_lock = acquireSessionCacheLock(allocator, deadline) catch |err| switch (err) {
        // Browsers are not available on the principal platform without file
        // locking (WASI). If another filesystem also cannot lock, keep the
        // freshly acquired in-memory session but do not risk a lost cache
        // update.
        error.FileLocksUnsupported => return,
        else => return err,
    };
    defer cache_lock.close(io);
    try browserDeadlineCheckpoint(deadline);

    const domain = try normalizeDomain(allocator, domain_input);
    defer allocator.free(domain);

    var records = try readCacheRecords(allocator, deadline);
    defer freeCacheRecords(allocator, &records);
    const pruned = pruneCacheRecords(allocator, &records, common.compatUnixTimestamp());
    const changed = try upsertCacheRecord(allocator, &records, domain, session);
    if (changed or pruned) try writeCacheRecords(allocator, records.items, deadline);
    try browserDeadlineCheckpoint(deadline);
}

fn removeCachedSessionForDomain(allocator: Allocator, domain_input: []const u8, rejected: Session, deadline: i64) !void {
    if (!build_options.enable_alldriver or !diskSessionCacheSupported(builtin.os.tag)) return;
    try browserDeadlineCheckpoint(deadline);

    const io = runtime_io.get();
    const cache_lock = acquireSessionCacheLock(allocator, deadline) catch |err| switch (err) {
        error.FileLocksUnsupported => return,
        else => return err,
    };
    defer cache_lock.close(io);
    try browserDeadlineCheckpoint(deadline);

    const domain = try normalizeDomain(allocator, domain_input);
    defer allocator.free(domain);
    var records = try readCacheRecords(allocator, deadline);
    defer freeCacheRecords(allocator, &records);
    const pruned = pruneCacheRecords(allocator, &records, common.compatUnixTimestamp());
    if (removeMatchingCacheRecords(allocator, &records, domain, rejected) or pruned) {
        try writeCacheRecords(allocator, records.items, deadline);
    }
    try browserDeadlineCheckpoint(deadline);
}

fn cacheRecordStale(record: CacheRecord, now: i64) bool {
    const session: Session = .{
        .cookies = record.cookies,
        .cf_clearance = record.cf_clearance,
        .user_agent = record.user_agent,
        .acquired_at_unix = record.acquired_at_unix,
        .generation = record.generation,
    };
    if (session.isLikelyExpired(now) or record.cf_clearance.len == 0 or !validBrowserUserAgent(record.user_agent)) return true;
    for (record.cookies) |cookie| {
        if (!std.mem.eql(u8, cookie.name, "cf_clearance") or
            !std.mem.eql(u8, cookie.value, record.cf_clearance)) continue;
        if (cookie.expires_unix_seconds) |expires| if (expires >= 0 and expires <= now) continue;
        if (cookie.host_only) {
            if (!std.ascii.eqlIgnoreCase(cookie.domain, record.domain)) continue;
        } else if (!isSameOrSubdomain(record.domain, cookie.domain)) continue;
        return false;
    }
    return true;
}

fn sessionIdentityDigest(session: anytype) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const separator = [_]u8{0};
    hasher.update(session.cf_clearance);
    hasher.update(&separator);
    hasher.update(session.user_agent);
    hasher.update(&separator);
    var acquired = session.acquired_at_unix;
    var generation = session.generation;
    hasher.update(std.mem.asBytes(&acquired));
    hasher.update(std.mem.asBytes(&generation));
    for (session.cookies) |cookie| {
        hasher.update(cookie.name);
        hasher.update(&separator);
        hasher.update(cookie.value);
        hasher.update(&separator);
        hasher.update(cookie.domain);
        hasher.update(&separator);
        hasher.update(cookie.path);
        const flags = [_]u8{ @intFromBool(cookie.secure), @intFromBool(cookie.host_only) };
        hasher.update(&flags);
        var expires = cookie.expires_unix_seconds orelse std.math.minInt(i64);
        hasher.update(std.mem.asBytes(&expires));
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn compareSessionFreshness(left: anytype, right: anytype) std.math.Order {
    // Generation is process-local and restarts at boot. Wall-clock acquisition
    // time therefore has to be the primary key for durable cache records.
    if (left.acquired_at_unix != right.acquired_at_unix) {
        return std.math.order(left.acquired_at_unix, right.acquired_at_unix);
    }
    if (left.generation != right.generation) return std.math.order(left.generation, right.generation);
    const left_digest = sessionIdentityDigest(left);
    const right_digest = sessionIdentityDigest(right);
    return std.mem.order(u8, &left_digest, &right_digest);
}

fn upsertCacheRecord(
    allocator: Allocator,
    records: *std.ArrayListUnmanaged(CacheRecord),
    domain: []const u8,
    session: Session,
) !bool {
    for (records.items) |*record| {
        if (!std.ascii.eqlIgnoreCase(record.domain, domain)) continue;
        if (compareSessionFreshness(record.*, session) != .lt) return false;

        const replacement = try dupRecord(allocator, domain, session);
        freeRecordFields(allocator, record.*);
        record.* = replacement;
        return true;
    }

    const additional = try dupRecord(allocator, domain, session);
    records.append(allocator, additional) catch |err| {
        freeRecordFields(allocator, additional);
        return err;
    };
    return true;
}

fn pruneCacheRecords(allocator: Allocator, records: *std.ArrayListUnmanaged(CacheRecord), now: i64) bool {
    var changed = false;
    var i: usize = 0;
    while (i < records.items.len) {
        if (cacheRecordStale(records.items[i], now)) {
            const removed = records.orderedRemove(i);
            freeRecordFields(allocator, removed);
            changed = true;
            continue;
        }

        var j = i + 1;
        while (j < records.items.len) {
            if (!std.ascii.eqlIgnoreCase(records.items[i].domain, records.items[j].domain)) {
                j += 1;
                continue;
            }
            if (compareSessionFreshness(records.items[j], records.items[i]) == .gt) {
                std.mem.swap(CacheRecord, &records.items[i], &records.items[j]);
            }
            const removed = records.orderedRemove(j);
            freeRecordFields(allocator, removed);
            changed = true;
        }
        i += 1;
    }
    return changed;
}

fn removeMatchingCacheRecords(allocator: Allocator, records: *std.ArrayListUnmanaged(CacheRecord), domain: []const u8, rejected: Session) bool {
    const rejected_digest = sessionIdentityDigest(rejected);
    var changed = false;
    var i: usize = 0;
    while (i < records.items.len) {
        const record = records.items[i];
        if (!std.ascii.eqlIgnoreCase(record.domain, domain) or
            record.generation != rejected.generation or
            record.acquired_at_unix != rejected.acquired_at_unix or
            !std.mem.eql(u8, record.cf_clearance, rejected.cf_clearance) or
            !std.mem.eql(u8, record.user_agent, rejected.user_agent))
        {
            i += 1;
            continue;
        }
        const record_digest = sessionIdentityDigest(record);
        if (!std.mem.eql(u8, &record_digest, &rejected_digest)) {
            i += 1;
            continue;
        }
        const removed = records.orderedRemove(i);
        freeRecordFields(allocator, removed);
        changed = true;
    }
    return changed;
}

fn acquireSessionCacheLock(allocator: Allocator, deadline: i64) !std.Io.File {
    try browserDeadlineCheckpoint(deadline);
    const path = try cachePath(allocator);
    defer allocator.free(path);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{path});
    defer allocator.free(lock_path);

    if (std.fs.path.dirname(lock_path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(runtime_io.get(), dir_path);
    }
    const lock_deadline = @min(deadline, common.compatMilliTimestamp() +| cache_lock_timeout_ms);
    const io = runtime_io.get();
    const file = try acquireSessionCacheLockAt(std.Io.Dir.cwd(), io, lock_path, lock_deadline);
    errdefer file.close(io);
    try browserDeadlineCheckpoint(deadline);
    return file;
}

fn acquireSessionCacheLockAt(dir: std.Io.Dir, io: std.Io, path: []const u8, deadline: i64) !std.Io.File {
    const permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
        std.Io.File.Permissions.fromMode(0o600)
    else
        std.Io.File.Permissions.default_file;

    while (true) {
        const file = dir.openFile(io, path, .{
            .mode = .read_write,
            .follow_symlinks = false,
        }) catch |open_err| switch (open_err) {
            error.FileNotFound => dir.createFile(io, path, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = permissions,
            }) catch |create_err| switch (create_err) {
                // Another process won the creation race. Open and lock the
                // now-existing file on the next iteration.
                error.PathAlreadyExists => continue,
                else => return create_err,
            },
            else => return open_err,
        };
        errdefer file.close(io);

        const stat = try file.stat(io);
        if (stat.kind != .file or !cacheFileOwnedByCurrentUser(file)) return error.InvalidSessionPayload;
        if (@hasDecl(std.Io.File.Permissions, "fromMode")) {
            try file.setPermissions(io, .fromMode(0o600));
        }

        while (!(try file.tryLock(io, .exclusive))) {
            const remaining = remainingTimeoutMs(common.compatMilliTimestamp(), deadline, 25) orelse
                return error.SessionCacheLockTimeout;
            try common.sleepMillisecondsCancelable(remaining);
        }
        common.sleepMillisecondsCancelable(0) catch |err| {
            file.unlock(io);
            return err;
        };
        if (common.compatMilliTimestamp() >= deadline) {
            file.unlock(io);
            return error.SessionCacheLockTimeout;
        }
        return file;
    }
}

fn cloneSession(allocator: Allocator, source: Session) !Session {
    const cookies = try cloneCookies(allocator, source.cookies);
    errdefer freeCookies(allocator, cookies);
    const clearance = try allocator.dupe(u8, source.cf_clearance);
    errdefer allocator.free(clearance);
    const agent = try allocator.dupe(u8, source.user_agent);
    errdefer allocator.free(agent);
    return .{
        .cookies = cookies,
        .cf_clearance = clearance,
        .user_agent = agent,
        .acquired_at_unix = source.acquired_at_unix,
        .generation = source.generation,
    };
}
fn dupRecord(allocator: Allocator, domain: []const u8, session: Session) !CacheRecord {
    const owned_domain = try allocator.dupe(u8, domain);
    errdefer allocator.free(owned_domain);
    const owned = try cloneSession(allocator, session);
    return .{
        .domain = owned_domain,
        .cookies = owned.cookies,
        .cf_clearance = owned.cf_clearance,
        .user_agent = owned.user_agent,
        .acquired_at_unix = owned.acquired_at_unix,
        .generation = owned.generation,
    };
}

fn freeRecordFields(allocator: Allocator, record: CacheRecord) void {
    allocator.free(record.domain);
    freeCookies(allocator, record.cookies);
    allocator.free(record.cf_clearance);
    allocator.free(record.user_agent);
}

fn cloneCookies(allocator: Allocator, source: []const Cookie) ![]Cookie {
    const out = try allocator.alloc(Cookie, source.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |cookie| freeCookieFields(allocator, cookie);
        allocator.free(out);
    }
    for (source, 0..) |cookie, i| {
        const name = try allocator.dupe(u8, cookie.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, cookie.value);
        errdefer allocator.free(value);
        const domain = try allocator.dupe(u8, cookie.domain);
        errdefer allocator.free(domain);
        const path = try allocator.dupe(u8, cookie.path);
        out[i] = .{
            .name = name,
            .value = value,
            .domain = domain,
            .path = path,
            .secure = cookie.secure,
            .host_only = cookie.host_only,
            .expires_unix_seconds = cookie.expires_unix_seconds,
        };
        initialized += 1;
    }
    return out;
}

fn freeCookieFields(allocator: Allocator, cookie: Cookie) void {
    allocator.free(cookie.name);
    allocator.free(cookie.value);
    allocator.free(cookie.domain);
    allocator.free(cookie.path);
}

fn freeCookies(allocator: Allocator, cookies: []const Cookie) void {
    for (cookies) |cookie| freeCookieFields(allocator, cookie);
    allocator.free(cookies);
}

fn deinitCookieList(allocator: Allocator, cookies: *std.ArrayListUnmanaged(Cookie)) void {
    for (cookies.items) |cookie| freeCookieFields(allocator, cookie);
    cookies.deinit(allocator);
    cookies.* = .empty;
}

fn dupeCookie(allocator: Allocator, source: Cookie) !Cookie {
    const name = try allocator.dupe(u8, source.name);
    errdefer allocator.free(name);
    const value = try allocator.dupe(u8, source.value);
    errdefer allocator.free(value);
    const domain = try allocator.dupe(u8, source.domain);
    errdefer allocator.free(domain);
    const path = try allocator.dupe(u8, source.path);
    return .{
        .name = name,
        .value = value,
        .domain = domain,
        .path = path,
        .secure = source.secure,
        .host_only = source.host_only,
        .expires_unix_seconds = source.expires_unix_seconds,
    };
}

fn validCookieName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (byte < 0x21 or byte >= 0x7f or std.mem.indexOfScalar(u8, "()<>@,;:\"/[]?={}\\", byte) != null) return false;
    }
    return true;
}

fn validCookieValue(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte == 0x7f or byte == ';') return false;
    return true;
}

fn validCookiePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f or byte == ';') return false;
    return true;
}

fn mustPropagateOperationError(err: anyerror) bool {
    return err == error.Canceled or
        err == error.OutOfMemory or
        err == error.CloudflareSessionUnavailable or
        err == error.BrowserAutomationDisabled or
        err == error.BrowserAutomationUnavailable or
        err == error.InvalidBrowserExecutable or
        err == error.UnsafeHttpTarget;
}

fn ignoreOrdinaryOperationFailure(operation: anytype) !void {
    _ = operation catch |err| {
        if (mustPropagateOperationError(err)) return err;
        return;
    };
}

fn readCacheRecords(allocator: Allocator, deadline: i64) !std.ArrayListUnmanaged(CacheRecord) {
    try browserDeadlineCheckpoint(deadline);
    return readCacheRecordsStrict(allocator, deadline) catch |err| {
        if (mustPropagateOperationError(err)) return err;
        // Session state is an optimization. Corrupt, stale-schema, or unsafe
        // cache files must not prevent ordinary browser acquisition.
        return .empty;
    };
}

fn readCacheRecordsStrict(allocator: Allocator, deadline: i64) !std.ArrayListUnmanaged(CacheRecord) {
    var records: std.ArrayListUnmanaged(CacheRecord) = .empty;
    errdefer freeCacheRecords(allocator, &records);
    if (!build_options.enable_alldriver or !diskSessionCacheSupported(builtin.os.tag)) return records;

    const path = try cachePath(allocator);
    defer allocator.free(path);

    const io = runtime_io.get();
    const file = openCacheFileNonblockingAt(std.Io.Dir.cwd(), path) catch |err| {
        if (mustPropagateOperationError(err)) return err;
        return records;
    };
    defer file.close(io);
    try browserDeadlineCheckpoint(deadline);

    const stat = file.stat(io) catch |err| {
        if (mustPropagateOperationError(err)) return err;
        return records;
    };
    try browserDeadlineCheckpoint(deadline);
    if (stat.kind != .file or !cacheFileOwnedByCurrentUser(file)) return records;
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) {
        file.setPermissions(io, .fromMode(0o600)) catch |err| {
            if (mustPropagateOperationError(err)) return err;
            return records;
        };
    }

    var read_buffer: [4096]u8 = undefined;
    // The file was already stat'ed above. Streaming mode avoids a second
    // implicit stat whose cancellation could be memoized as an ordinary size
    // failure before the reader falls back to streaming I/O.
    var file_reader = file.readerStreaming(io, &read_buffer);
    const data = file_reader.interface.allocRemaining(allocator, .limited(max_session_cache_bytes)) catch |err| switch (err) {
        error.OutOfMemory, error.StreamTooLong => return err,
        error.ReadFailed => return file_reader.err orelse err,
    };
    defer allocator.free(data);
    try browserDeadlineCheckpoint(deadline);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidSessionPayload,
    };
    const version = try getInt(root, "version");
    if (version != 1 and version != 2) return error.InvalidSessionPayload;

    const sessions_val = root.get("sessions") orelse return error.InvalidSessionPayload;
    const sessions = switch (sessions_val) {
        .array => |a| a,
        else => return error.InvalidSessionPayload,
    };
    if (sessions.items.len > max_session_cache_records) return error.InvalidSessionPayload;

    for (sessions.items) |entry| {
        const obj = switch (entry) {
            .object => |o| o,
            else => return error.InvalidSessionPayload,
        };

        const domain = try normalizeDomain(allocator, try getString(obj, "domain"));
        defer allocator.free(domain);
        const cookies = if (version == 1)
            try parseLegacyCookieHeader(allocator, domain, try getString(obj, "cookie_header"))
        else
            try parseCachedCookies(allocator, obj.get("cookies") orelse return error.InvalidSessionPayload);
        defer freeCookies(allocator, cookies);
        for (cookies) |cookie| {
            if (cookie.host_only) {
                if (!std.ascii.eqlIgnoreCase(cookie.domain, domain))
                    return error.InvalidSessionPayload;
            } else if (!isSameOrSubdomain(domain, cookie.domain)) {
                return error.InvalidSessionPayload;
            }
        }

        const cf_clearance = (try getOptionalString(obj, "cf_clearance")) orelse
            findCookieValueByName(cookies, "cf_clearance") orelse "";
        const user_agent = try getString(obj, "user_agent");
        if (!validBrowserUserAgent(user_agent)) return error.InvalidSessionPayload;
        const acquired_at_unix = try getInt(obj, "acquired_at_unix");
        const generation_i64 = if (version == 1) 0 else try getInt(obj, "generation");
        if (generation_i64 < 0) return error.InvalidSessionPayload;

        const record = try dupRecord(allocator, domain, .{
            .cookies = cookies,
            .cf_clearance = cf_clearance,
            .user_agent = user_agent,
            .acquired_at_unix = acquired_at_unix,
            .generation = @intCast(generation_i64),
        });
        records.append(allocator, record) catch |err| {
            freeRecordFields(allocator, record);
            return err;
        };
    }

    try browserDeadlineCheckpoint(deadline);
    return records;
}

fn openCacheFileNonblockingAt(dir: std.Io.Dir, path: []const u8) !std.Io.File {
    if (comptime !diskSessionCacheSupported(builtin.os.tag)) return error.UnsupportedPlatform;
    const handle = try std.posix.openat(dir.handle, path, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    return .{
        .handle = handle,
        .flags = .{ .nonblocking = true },
    };
}

fn cacheFileOwnedByCurrentUser(file: std.Io.File) bool {
    if (comptime builtin.os.tag == .windows) return false;
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
    // Credential persistence fails closed when the effective owner cannot be
    // established from the already-open file handle.
    return false;
}

fn diskSessionCacheSupported(os_tag: std.Target.Os.Tag) bool {
    // Credential persistence is limited to the same POSIX targets as the
    // Chromium pipe. Windows remains disabled until owner/DACL verification
    // and secure native handle inheritance are implemented.
    return chromium_pipe.supportedOn(os_tag);
}

fn parseCachedCookies(allocator: Allocator, value: std.json.Value) ![]Cookie {
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidSessionPayload,
    };
    if (array.items.len == 0 or array.items.len > max_session_cookies)
        return error.InvalidSessionPayload;
    var cookies: std.ArrayListUnmanaged(Cookie) = .empty;
    errdefer deinitCookieList(allocator, &cookies);

    for (array.items) |entry| {
        const obj = switch (entry) {
            .object => |fields| fields,
            else => return error.InvalidSessionPayload,
        };
        const name = try getString(obj, "name");
        const value_text = try getString(obj, "value");
        const normalized_domain = try normalizeDomain(allocator, try getString(obj, "domain"));
        defer allocator.free(normalized_domain);
        const cookie_path = try getString(obj, "path");
        if (!validCookieName(name) or !validCookieValue(value_text) or !validCookiePath(cookie_path)) return error.InvalidSessionPayload;

        const cookie = try dupeCookie(allocator, .{
            .name = name,
            .value = value_text,
            .domain = normalized_domain,
            .path = cookie_path,
            .secure = try getBool(obj, "secure"),
            .host_only = try getBool(obj, "host_only"),
            .expires_unix_seconds = try getOptionalInt(obj, "expires_unix_seconds"),
        });
        cookies.append(allocator, cookie) catch |err| {
            freeCookieFields(allocator, cookie);
            return err;
        };
    }
    return try cookies.toOwnedSlice(allocator);
}

fn parseLegacyCookieHeader(allocator: Allocator, domain: []const u8, header: []const u8) ![]Cookie {
    var cookies: std.ArrayListUnmanaged(Cookie) = .empty;
    errdefer deinitCookieList(allocator, &cookies);
    var fields = std.mem.splitScalar(u8, header, ';');
    while (fields.next()) |raw_field| {
        if (cookies.items.len == max_session_cookies) return error.InvalidSessionPayload;
        const field = std.mem.trim(u8, raw_field, " \t");
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidSessionPayload;
        const name = std.mem.trim(u8, field[0..equals], " \t");
        const value = std.mem.trim(u8, field[equals + 1 ..], " \t");
        if (!validCookieName(name) or !validCookieValue(value)) return error.InvalidSessionPayload;
        const cookie = try dupeCookie(allocator, .{
            .name = name,
            .value = value,
            .domain = domain,
            .path = "/",
            .secure = true,
            // The legacy schema did not preserve the Domain attribute. The
            // only safe migration is the narrower host-only interpretation.
            .host_only = true,
            .expires_unix_seconds = null,
        });
        cookies.append(allocator, cookie) catch |err| {
            freeCookieFields(allocator, cookie);
            return err;
        };
    }
    if (cookies.items.len == 0) return error.InvalidSessionPayload;
    return try cookies.toOwnedSlice(allocator);
}

fn writeCacheRecords(allocator: Allocator, records: []const CacheRecord, deadline: i64) !void {
    if (!build_options.enable_alldriver) return;
    try browserDeadlineCheckpoint(deadline);
    if (records.len > max_session_cache_records) return error.InvalidSessionPayload;
    for (records) |record| {
        if (record.cookies.len == 0 or record.cookies.len > max_session_cookies)
            return error.InvalidSessionPayload;
    }
    const path = try cachePath(allocator);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(runtime_io.get(), dir_path);
    }
    try browserDeadlineCheckpoint(deadline);

    const json_data = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{
        .version = 2,
        .sessions = records,
    }, .{ .whitespace = .indent_2 })});
    defer allocator.free(json_data);
    if (json_data.len > max_session_cache_bytes) return error.InvalidSessionPayload;

    try browserDeadlineCheckpoint(deadline);
    try writeSessionCacheAtomically(std.Io.Dir.cwd(), runtime_io.get(), path, json_data);
    try browserDeadlineCheckpoint(deadline);
}

fn writeSessionCacheAtomically(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, path, .{
        .replace = true,
        .permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Require an HTML response and an actual Cloudflare challenge marker. Passive
/// JavaScript detection also appears on ordinary, fully accessible pages.
pub fn isChallengeBody(body: []const u8) bool {
    var head = std.mem.trimStart(u8, body, " \t\r\n");
    if (std.mem.startsWith(u8, head, "\xef\xbb\xbf")) head = std.mem.trimStart(u8, head[3..], " \t\r\n");
    while (std.mem.startsWith(u8, head, "<!--")) {
        const end = std.mem.indexOf(u8, head[4..], "-->") orelse return false;
        head = std.mem.trimStart(u8, head[end + 7 ..], " \t\r\n");
    }

    var html_opening = false;
    for ([_][]const u8{ "<!doctype html", "<html", "<head", "<script", "<body" }) |tag| {
        if (std.ascii.startsWithIgnoreCase(head, tag) and head.len > tag.len and
            (std.ascii.isWhitespace(head[tag.len]) or head[tag.len] == '>' or head[tag.len] == '/'))
        {
            html_opening = true;
            break;
        }
    }
    return html_opening and hasChallengeMarkup(body);
}

fn hasChallengeMarkup(body: []const u8) bool {
    var remaining = body;
    while (std.mem.indexOfScalar(u8, remaining, '<')) |start| {
        remaining = remaining[start + 1 ..];
        if (std.mem.startsWith(u8, remaining, "!--")) {
            const comment_end = std.mem.indexOf(u8, remaining[3..], "-->") orelse return false;
            remaining = remaining[3 + comment_end + 3 ..];
            continue;
        }
        const tag_end = htmlTagEnd(remaining) orelse return false;
        const tag = remaining[0..tag_end];
        var name_start: usize = 0;
        const is_closing = tag.len > 0 and tag[0] == '/';
        if (is_closing) name_start = 1;
        if (name_start >= tag.len or !std.ascii.isAlphabetic(tag[name_start])) {
            remaining = remaining[tag_end + 1 ..];
            continue;
        }
        var name_end = name_start + 1;
        while (name_end < tag.len and (std.ascii.isAlphanumeric(tag[name_end]) or tag[name_end] == '-' or tag[name_end] == ':')) : (name_end += 1) {}
        const name = tag[name_start..name_end];
        if (is_closing) {
            remaining = remaining[tag_end + 1 ..];
            continue;
        }

        if (tagHasChallengeAttribute(tag) or tagHasChallengePagePath(tag)) return true;
        const after_tag = remaining[tag_end + 1 ..];
        if (!isRawTextElement(name)) {
            remaining = after_tag;
            continue;
        }

        const close = findRawTextClose(after_tag, name) orelse return false;
        if (std.ascii.eqlIgnoreCase(name, "script") and scriptHasChallengeAssignment(after_tag[0..close])) return true;
        remaining = after_tag[close + 2 + name.len ..];
    }
    return false;
}

fn htmlTagEnd(bytes: []const u8) ?usize {
    var quote: u8 = 0;
    for (bytes, 0..) |byte, index| {
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') {
            return index;
        }
    }
    return null;
}

fn isRawTextElement(name: []const u8) bool {
    for ([_][]const u8{ "script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes", "plaintext" }) |raw_name| {
        if (std.ascii.eqlIgnoreCase(name, raw_name)) return true;
    }
    return false;
}

fn findRawTextClose(content: []const u8, name: []const u8) ?usize {
    var offset: usize = 0;
    while (offset < content.len) {
        const relative = std.ascii.findIgnoreCase(content[offset..], "</") orelse return null;
        const start = offset + relative;
        const name_start = start + 2;
        const name_end = name_start + name.len;
        if (name_end <= content.len and
            std.ascii.eqlIgnoreCase(content[name_start..name_end], name) and
            (name_end == content.len or std.ascii.isWhitespace(content[name_end]) or content[name_end] == '>' or content[name_end] == '/'))
        {
            return start;
        }
        offset = name_start;
    }
    return null;
}

fn scriptHasChallengeAssignment(content: []const u8) bool {
    const marker = "_cf_chl_opt";
    var index: usize = 0;
    while (index < content.len) {
        switch (content[index]) {
            '\'', '"', '`' => |quote| {
                index += 1;
                while (index < content.len) {
                    if (content[index] == '\\') {
                        index += @min(2, content.len - index);
                    } else {
                        const byte = content[index];
                        index += 1;
                        if (byte == quote) break;
                    }
                }
                continue;
            },
            '/' => {
                if (index + 1 < content.len and content[index + 1] == '/') {
                    index += 2;
                    while (index < content.len and content[index] != '\r' and content[index] != '\n') : (index += 1) {}
                    continue;
                }
                if (index + 1 < content.len and content[index + 1] == '*') {
                    const close = std.mem.indexOf(u8, content[index + 2 ..], "*/") orelse return false;
                    index += 2 + close + 2;
                    continue;
                }
            },
            else => {},
        }

        if (index + marker.len <= content.len and
            std.ascii.eqlIgnoreCase(content[index .. index + marker.len], marker) and
            (index == 0 or !isJavaScriptIdentifierByte(content[index - 1])) and
            (index + marker.len == content.len or !isJavaScriptIdentifierByte(content[index + marker.len])))
        {
            var suffix = index + marker.len;
            while (suffix < content.len and std.ascii.isWhitespace(content[suffix])) : (suffix += 1) {}
            if (suffix < content.len and content[suffix] == '=' and
                (suffix + 1 == content.len or (content[suffix + 1] != '=' and content[suffix + 1] != '>')))
            {
                return true;
            }
            index += marker.len;
            continue;
        }
        index += 1;
    }
    return false;
}

fn isJavaScriptIdentifierByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$';
}

fn tagHasChallengeAttribute(tag: []const u8) bool {
    var index: usize = 0;
    while (index < tag.len and !std.ascii.isWhitespace(tag[index])) : (index += 1) {}
    while (index < tag.len) {
        while (index < tag.len and (std.ascii.isWhitespace(tag[index]) or tag[index] == '/')) : (index += 1) {}
        const name_start = index;
        while (index < tag.len and (std.ascii.isAlphanumeric(tag[index]) or tag[index] == '-' or tag[index] == '_' or tag[index] == ':')) : (index += 1) {}
        if (name_start == index) {
            index += 1;
            continue;
        }
        const name = tag[name_start..index];
        if (std.ascii.startsWithIgnoreCase(name, "data-cf-chl-")) return true;
        while (index < tag.len and std.ascii.isWhitespace(tag[index])) : (index += 1) {}
        if (index >= tag.len or tag[index] != '=') continue;
        index += 1;
        while (index < tag.len and std.ascii.isWhitespace(tag[index])) : (index += 1) {}
        const quote = if (index < tag.len and (tag[index] == '\'' or tag[index] == '"')) tag[index] else 0;
        if (quote != 0) index += 1;
        const value_start = index;
        if (quote != 0) {
            while (index < tag.len and tag[index] != quote) : (index += 1) {}
        } else {
            while (index < tag.len and !std.ascii.isWhitespace(tag[index])) : (index += 1) {}
        }
        const value = tag[value_start..index];
        if (index < tag.len and quote != 0) index += 1;
        if ((std.ascii.eqlIgnoreCase(name, "name") or
            std.ascii.eqlIgnoreCase(name, "id") or
            std.ascii.eqlIgnoreCase(name, "class")) and
            hasChallengeAttributeToken(value)) return true;
    }
    return false;
}

fn hasChallengeAttributeToken(value: []const u8) bool {
    var remaining = value;
    while (std.ascii.findIgnoreCase(remaining, "cf-chl-")) |index| {
        if (index == 0 or std.ascii.isWhitespace(remaining[index - 1])) return true;
        remaining = remaining[index + "cf-chl-".len ..];
    }
    return false;
}

fn tagHasChallengePagePath(tag: []const u8) bool {
    var index: usize = 0;
    while (index < tag.len and !std.ascii.isWhitespace(tag[index])) : (index += 1) {}
    while (index < tag.len) {
        while (index < tag.len and (std.ascii.isWhitespace(tag[index]) or tag[index] == '/')) : (index += 1) {}
        const name_start = index;
        while (index < tag.len and (std.ascii.isAlphanumeric(tag[index]) or tag[index] == '-' or tag[index] == '_' or tag[index] == ':')) : (index += 1) {}
        if (name_start == index) {
            index += 1;
            continue;
        }
        const name = tag[name_start..index];
        while (index < tag.len and std.ascii.isWhitespace(tag[index])) : (index += 1) {}
        if (index >= tag.len or tag[index] != '=') continue;
        index += 1;
        while (index < tag.len and std.ascii.isWhitespace(tag[index])) : (index += 1) {}
        const quote = if (index < tag.len and (tag[index] == '\'' or tag[index] == '"')) tag[index] else 0;
        if (quote != 0) index += 1;
        const value_start = index;
        if (quote != 0) {
            while (index < tag.len and tag[index] != quote) : (index += 1) {}
        } else {
            while (index < tag.len and !std.ascii.isWhitespace(tag[index])) : (index += 1) {}
        }
        const value = tag[value_start..index];
        if (index < tag.len and quote != 0) index += 1;
        if ((std.ascii.eqlIgnoreCase(name, "src") or
            std.ascii.eqlIgnoreCase(name, "href") or
            std.ascii.eqlIgnoreCase(name, "action")) and
            valueHasChallengePagePath(value)) return true;
    }
    return false;
}

fn valueHasChallengePagePath(value: []const u8) bool {
    const prefix = "/cdn-cgi/challenge-platform/";
    var remaining = value;
    while (std.ascii.findIgnoreCase(remaining, prefix)) |start| {
        remaining = remaining[start + prefix.len ..];
        const end = std.mem.indexOfAny(u8, remaining, " \t\r\n\"'<>\\?#") orelse remaining.len;
        const path = remaining[0..end];
        if (std.ascii.startsWithIgnoreCase(path, "orchestrate/chl_page/") or
            std.ascii.findIgnoreCase(path, "/orchestrate/chl_page/") != null) return true;
    }
    return false;
}

test "challenge detection accepts HTML layouts while requiring positive markers" {
    for ([_][]const u8{
        "\xef\xbb\xbf <!DOCTYPE HTML><HTML><SCRIPT>window._cf_chl_opt = {};</SCRIPT></HTML>",
        " <!-- leading comment -->\n<!-- second comment --><HEAD><script src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script></HEAD>",
        "<HEAD><TITLE>Just a moment...</TITLE><META NAME='CF-CHL-WIDGET'></HEAD>",
        "<SCRIPT>window._cf_chl_opt = {};</SCRIPT>",
        "<SCRIPT>console.log(_cf_chl_opt); window._cf_chl_opt = {};</SCRIPT>",
        "<BODY><SCRIPT SRC='/CDN-CGI/CHALLENGE-PLATFORM/h/b/orchestrate/chl_page/v1?ray=fixture'></SCRIPT></BODY>",
        "\xef\xbb\xbf<!doctype html><script src='/cdn-cgi/challenge-platform/orchestrate/chl_page/v1'></script>",
    }) |fixture| try std.testing.expect(isChallengeBody(fixture));
    for ([_][]const u8{
        "<HEAD><TITLE>Just a moment: a movie title</TITLE></HEAD>",
        "<SCRIPT>window.normalPage = {};</SCRIPT>",
        "<!doctype html><html><head><title>Subtitle details</title></head><body><button class='subtitle-prepare-download'>Download</button><div id='subtitleFilePreview'>Subtitle preview</div><script src='/cdn-cgi/challenge-platform/scripts/jsd/main.js'></script></body></html>",
        " <!-- leading comment --><HEAD><script src='/cdn-cgi/challenge-platform/scripts/jsd/main.js'></script></HEAD>",
        "\xef\xbb\xbf<BODY><SCRIPT SRC='/CDN-CGI/CHALLENGE-PLATFORM/scripts/jsd/main.js'></SCRIPT></BODY>",
        "<script src='/cdn-cgi/challenge-platform/scripts/jsd/main.js?next=/orchestrate/chl_page/v1'></script>",
        "<script src='/cdn-cgi/challenge-platform/scripts/jsd/main.js'></script><body>/orchestrate/chl_page/v1</body>",
        "{\"description\":\"<script>window._cf_chl_opt = {};</script>\"}",
        "cf-chl-widget without HTML",
        "<!-- unterminated comment <HEAD>window._cf_chl_opt = {};",
        "<scripture>cf-chl-widget</scripture>",
        "<html><body>subtitle filename cf-chl-notes.srt</body></html>",
        "<html><body><script>const filename = '_cf_chl_opt.srt';</script></body></html>",
        "<html><body><script>const backup_cf_chl_opt = {};</script></body></html>",
        "<html><body><script>const marker = '_cf_chl_opt = {}';</script></body></html>",
        "<html><body><script>/* _cf_chl_opt = {}; */ const ok = true;</script></body></html>",
        "<html><!-- <div data-cf-chl-note> --><body>normal</body></html>",
        "<html><script>const tpl = '<div data-cf-chl-note>';</script><body>normal</body></html>",
        "<html><!-- <script>window._cf_chl_opt = {};</script> --><body>normal</body></html>",
        "<html><!-- /cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1 --><body>normal</body></html>",
        "<html><body>/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1</body></html>",
        "<html><a title='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'>subtitle</a></html>",
        "<html><body><a title='cf-chl-notes.srt'>subtitle</a></body></html>",
    }) |fixture| try std.testing.expect(!isChallengeBody(fixture));
}

fn freeCacheRecords(allocator: Allocator, records: *std.ArrayListUnmanaged(CacheRecord)) void {
    for (records.items) |record| {
        freeRecordFields(allocator, record);
    }
    records.deinit(allocator);
    records.* = .empty;
}

fn cachePath(allocator: Allocator) ![]u8 {
    if (!build_options.enable_alldriver) return error.BrowserAutomationDisabled;

    const local_app_data = try common.getenvOwned(allocator, "LOCALAPPDATA");
    defer if (local_app_data) |value| allocator.free(value);
    const user_profile = try common.getenvOwned(allocator, "USERPROFILE");
    defer if (user_profile) |value| allocator.free(value);
    const xdg_cache_home = try common.getenvOwned(allocator, "XDG_CACHE_HOME");
    defer if (xdg_cache_home) |value| allocator.free(value);
    const home = try common.getenvOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);

    return cachePathFromRoots(allocator, builtin.os.tag, local_app_data, user_profile, xdg_cache_home, home);
}

fn cachePathFromRoots(
    allocator: Allocator,
    os_tag: std.Target.Os.Tag,
    local_app_data_opt: ?[]const u8,
    user_profile_opt: ?[]const u8,
    xdg_cache_home_opt: ?[]const u8,
    home_opt: ?[]const u8,
) ![]u8 {
    const local_app_data = absoluteEnvPath(os_tag, local_app_data_opt);
    const user_profile = absoluteEnvPath(os_tag, user_profile_opt);
    const xdg_cache_home = absoluteEnvPath(os_tag, xdg_cache_home_opt);
    const home = absoluteEnvPath(os_tag, home_opt);

    if (os_tag == .windows) {
        if (local_app_data) |root| return std.fs.path.join(allocator, &.{ root, "subdl", shared_cache_filename });
        if (user_profile) |root| return std.fs.path.join(allocator, &.{ root, "AppData", "Local", "subdl", shared_cache_filename });
    } else if (xdg_cache_home) |root| {
        return std.fs.path.join(allocator, &.{ root, "subdl", shared_cache_filename });
    }
    if (home) |root| return std.fs.path.join(allocator, &.{ root, ".cache", "subdl", shared_cache_filename });
    return error.EnvironmentVariableNotFound;
}

fn absoluteEnvPath(os_tag: std.Target.Os.Tag, value_opt: ?[]const u8) ?[]const u8 {
    const value = value_opt orelse return null;
    if (value.len == 0) return null;
    if (os_tag != .windows) return if (value[0] == '/') value else null;

    const is_sep = struct {
        fn check(byte: u8) bool {
            return byte == '/' or byte == '\\';
        }
    }.check;
    if (value.len >= 3 and std.ascii.isAlphabetic(value[0]) and value[1] == ':' and is_sep(value[2])) return value;
    if (value.len >= 2 and is_sep(value[0]) and is_sep(value[1])) return value;
    return null;
}

const BrowserLaunchContext = struct {
    allocator: Allocator,
    navigation_policy: *const chromium_pipe.NavigationPolicy,
    domain: []const u8,
    challenge_url: []const u8,
    user_agent_failed: *bool,
};

fn BrowserLaunchResult(comptime BrowserType: type) type {
    return struct {
        browser: BrowserType,
        headless: bool,
        deadline: i64,
    };
}

fn browserAttemptDeadline(plan: BrowserLaunchPlan, headless: bool, now: i64, global_deadline: i64) i64 {
    if (plan.mode != .automatic or headless or now >= global_deadline) return global_deadline;

    const remaining = global_deadline - now;
    // Once only the fallback reserve remains, skip all further headed launches.
    // A headed browser that starts but cannot display or complete its challenge
    // must not consume the global deadline reserved for headless operation.
    if (remaining <= automatic_headless_reserve_ms) return now;
    const fallback_boundary = global_deadline - automatic_headless_reserve_ms;
    return @min(fallback_boundary, now +| automatic_headed_probe_ms);
}

fn launchChromiumBrowser(
    context: BrowserLaunchContext,
    executable: []const u8,
    headless: bool,
    deadline: i64,
) !chromium_pipe.Browser {
    return chromium_pipe.Browser.launch(
        context.allocator,
        executable,
        context.navigation_policy,
        headless,
        deadline,
    );
}

fn launchBrowserCheckpoint(_: BrowserLaunchContext, deadline: i64) !void {
    return browserDeadlineCheckpoint(deadline);
}

fn launchBrowserNow(_: BrowserLaunchContext) i64 {
    return common.compatMilliTimestamp();
}

fn deinitChromiumBrowser(_: BrowserLaunchContext, browser: *chromium_pipe.Browser) void {
    browser.deinit();
}

fn launchNextBrowserUsing(
    comptime BrowserType: type,
    context: anytype,
    executables: anytype,
    iterator: *BrowserLaunchIterator,
    deadline: i64,
    comptime launch: anytype,
    comptime checkpoint: anytype,
    comptime now: anytype,
) !?BrowserLaunchResult(BrowserType) {
    while (iterator.next(executables.len)) |attempt| {
        try checkpoint(context, deadline);
        const current = now(context);
        const attempt_deadline = browserAttemptDeadline(iterator.plan, attempt.headless, current, deadline);
        if (attempt_deadline <= current) continue;
        const browser = launch(
            context,
            executables[attempt.executable_index],
            attempt.headless,
            attempt_deadline,
        ) catch |err| {
            const classified = normalizeBrowserOperationError(err);
            if (mustPropagateOperationError(classified)) return classified;
            try checkpoint(context, deadline);
            continue;
        };
        return .{ .browser = browser, .headless = attempt.headless, .deadline = attempt_deadline };
    }
    return null;
}

fn runBrowserAttemptsUsing(
    comptime BrowserType: type,
    comptime ResultType: type,
    context: anytype,
    executables: anytype,
    plan: BrowserLaunchPlan,
    deadline: i64,
    comptime launch: anytype,
    comptime checkpoint: anytype,
    comptime now: anytype,
    comptime deinit_browser: anytype,
    comptime try_acquire: anytype,
) !?ResultType {
    var iterator: BrowserLaunchIterator = .{ .plan = plan };
    while (try launchNextBrowserUsing(
        BrowserType,
        context,
        executables,
        &iterator,
        deadline,
        launch,
        checkpoint,
        now,
    )) |launched| {
        var browser = launched.browser;
        defer deinit_browser(context, &browser);
        if (try try_acquire(
            context,
            &browser,
            launched.headless,
            launched.deadline,
            deadline,
        )) |result| return result;
    }
    return null;
}

fn browserAttemptHasTime(attempt_deadline: i64, global_deadline: i64) !bool {
    try browserDeadlineCheckpoint(global_deadline);
    return common.compatMilliTimestamp() < attempt_deadline;
}

fn tryAcquireSessionFromBrowser(
    context: BrowserLaunchContext,
    browser: *chromium_pipe.Browser,
    headless: bool,
    attempt_deadline: i64,
    global_deadline: i64,
) !?Session {
    _ = headless;
    if (!try browserAttemptHasTime(attempt_deadline, global_deadline)) return null;

    browser.navigate(context.challenge_url, attempt_deadline) catch |err| {
        const classified = normalizeBrowserOperationError(err);
        if (mustPropagateOperationError(classified)) return classified;
        try browserDeadlineCheckpoint(global_deadline);
        return null;
    };
    while (try browserAttemptHasTime(attempt_deadline, global_deadline)) {
        const browser_cookies = browser.getCookiesForUrl(context.allocator, context.challenge_url, attempt_deadline) catch |err| {
            const classified = normalizeBrowserOperationError(err);
            if (mustPropagateOperationError(classified)) return classified;
            try browserDeadlineCheckpoint(global_deadline);
            return null;
        };
        defer chromium_pipe.freeCookies(context.allocator, browser_cookies);
        const cookies = try cloneBrowserCookiesForHost(context.allocator, browser_cookies, context.domain);
        defer freeCookies(context.allocator, cookies);

        const cf_value = findCookieValueForUrl(cookies, context.challenge_url, "cf_clearance", common.compatUnixTimestamp()) orelse {
            const pause = remainingTimeoutMs(common.compatMilliTimestamp(), attempt_deadline, challenge_poll_interval_ms) orelse {
                try browserDeadlineCheckpoint(global_deadline);
                return null;
            };
            browser.waitForPolicyEvents(pause, attempt_deadline) catch |err| {
                const classified = normalizeBrowserOperationError(err);
                if (mustPropagateOperationError(classified)) return classified;
                try browserDeadlineCheckpoint(global_deadline);
                return null;
            };
            continue;
        };

        if (!try browserAttemptHasTime(attempt_deadline, global_deadline)) return null;
        const user_agent = browser.getUserAgent(context.allocator, attempt_deadline) catch |err| {
            const classified = normalizeBrowserOperationError(err);
            if (mustPropagateOperationError(classified)) return classified;
            context.user_agent_failed.* = true;
            try browserDeadlineCheckpoint(global_deadline);
            return null;
        };
        var owns_user_agent = true;
        defer if (owns_user_agent) context.allocator.free(user_agent);
        if (!validBrowserUserAgent(user_agent)) {
            context.user_agent_failed.* = true;
            try browserDeadlineCheckpoint(global_deadline);
            return null;
        }

        const owned_cookies = try cloneCookies(context.allocator, cookies);
        var owns_cookies = true;
        defer if (owns_cookies) freeCookies(context.allocator, owned_cookies);
        const owned_clearance = try context.allocator.dupe(u8, cf_value);
        var owns_clearance = true;
        defer if (owns_clearance) context.allocator.free(owned_clearance);
        if (!try browserAttemptHasTime(attempt_deadline, global_deadline)) return null;

        owns_user_agent = false;
        owns_cookies = false;
        owns_clearance = false;
        return .{
            .cookies = owned_cookies,
            .cf_clearance = owned_clearance,
            .user_agent = user_agent,
            .acquired_at_unix = common.compatUnixTimestamp(),
            .generation = nextSessionGeneration(),
        };
    }
    return null;
}

fn acquireSessionViaBrowser(allocator: Allocator, domain: []const u8, challenge_url: []const u8, deadline: i64) !Session {
    if (!build_options.enable_alldriver) return error.BrowserAutomationDisabled;
    try browserDeadlineCheckpoint(deadline);
    var executables = chromium_pipe.discoverExecutables(allocator, deadline) catch |err|
        return normalizeBrowserAcquisitionError(err);
    defer executables.deinit(allocator);
    try browserDeadlineCheckpoint(deadline);

    if (executables.items.len == 0) return error.CloudflareSessionUnavailable;

    const launch_plan = try browserLaunchPlan(allocator);
    var user_agent_failed = false;
    var navigation_policy = chromium_pipe.NavigationPolicy.create(allocator, challenge_url, deadline) catch |err|
        return normalizeBrowserAcquisitionError(err);
    defer navigation_policy.deinit(allocator);
    const launch_context: BrowserLaunchContext = .{
        .allocator = allocator,
        .navigation_policy = &navigation_policy,
        .domain = domain,
        .challenge_url = challenge_url,
        .user_agent_failed = &user_agent_failed,
    };

    // Automatic graphical mode probes each headed browser for a bounded time,
    // then exhausts the remaining headed candidates before its headless pass.
    // Every browser remains subject to the original absolute deadline.
    const acquired = try runBrowserAttemptsUsing(
        chromium_pipe.Browser,
        Session,
        launch_context,
        executables.items,
        launch_plan,
        deadline,
        launchChromiumBrowser,
        launchBrowserCheckpoint,
        launchBrowserNow,
        deinitChromiumBrowser,
        tryAcquireSessionFromBrowser,
    );
    if (acquired) |session| return session;

    if (user_agent_failed) return error.BrowserAutomationFailed;
    return error.CloudflareSessionUnavailable;
}

fn nextSessionGeneration() u64 {
    const timestamp = common.compatMilliTimestamp();
    const floor: u64 = if (timestamp > 0) @intCast(timestamp) else 1;
    var previous = last_session_generation.load(.monotonic);
    while (true) {
        const next = @max(floor, previous +| 1);
        if (last_session_generation.cmpxchgWeak(previous, next, .monotonic, .monotonic)) |observed| {
            previous = observed;
            continue;
        }
        return next;
    }
}

fn cloneBrowserCookiesForHost(allocator: Allocator, browser_cookies: anytype, host: []const u8) ![]Cookie {
    var cookies: std.ArrayListUnmanaged(Cookie) = .empty;
    errdefer deinitCookieList(allocator, &cookies);
    const now = common.compatUnixTimestamp();

    for (browser_cookies) |browser_cookie| {
        const BrowserCookie = @TypeOf(browser_cookie);
        const raw_domain = std.mem.trim(u8, browser_cookie.domain, " \t\r\n");
        const host_only = !std.mem.startsWith(u8, raw_domain, ".");
        const domain = normalizeDomain(allocator, raw_domain) catch |err| {
            if (mustPropagateOperationError(err)) return err;
            continue;
        };
        defer allocator.free(domain);
        if (host_only) {
            if (!std.ascii.eqlIgnoreCase(domain, host)) continue;
        } else if (!isSameOrSubdomain(host, domain)) continue;

        if (!validCookieName(browser_cookie.name) or !validCookieValue(browser_cookie.value)) continue;
        const browser_path = if (comptime @hasField(BrowserCookie, "path")) browser_cookie.path else "/";
        const path = if (validCookiePath(browser_path)) browser_path else "/";
        const secure = if (comptime @hasField(BrowserCookie, "secure")) browser_cookie.secure else true;
        const expires_unix_seconds: ?i64 = if (comptime @hasField(BrowserCookie, "expires_unix_seconds")) browser_cookie.expires_unix_seconds else null;
        if (expires_unix_seconds) |expires| {
            if (expires >= 0 and expires <= now) continue;
        }
        if (cookies.items.len == max_session_cookies) return error.InvalidSessionPayload;
        const cookie = try dupeCookie(allocator, .{
            .name = browser_cookie.name,
            .value = browser_cookie.value,
            .domain = domain,
            .path = path,
            .secure = secure,
            .host_only = host_only,
            .expires_unix_seconds = expires_unix_seconds,
        });
        cookies.append(allocator, cookie) catch |err| {
            freeCookieFields(allocator, cookie);
            return err;
        };
    }
    return try cookies.toOwnedSlice(allocator);
}

fn validBrowserUserAgent(value: []const u8) bool {
    if (value.len > max_browser_user_agent_bytes or std.mem.trim(u8, value, " \t\r\n").len == 0) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn remainingTimeoutMs(now: i64, deadline: i64, cap: i64) ?u64 {
    if (now >= deadline or cap <= 0) return null;
    return @intCast(@min(deadline - now, cap));
}

fn browserDeadlineCheckpoint(deadline: i64) !void {
    if (common.compatMilliTimestamp() >= deadline) return error.CloudflareSessionUnavailable;
    try common.sleepMillisecondsCancelable(0);
    if (common.compatMilliTimestamp() >= deadline) return error.CloudflareSessionUnavailable;
}

fn normalizeBrowserAcquisitionError(err: anyerror) anyerror {
    return if (err == error.Timeout or err == error.BrowserOperationTimeout)
        error.CloudflareSessionUnavailable
    else
        normalizeBrowserOperationError(err);
}

fn normalizeBrowserOperationError(err: anyerror) anyerror {
    return if (err == error.UnsafeBrowserNavigation) error.UnsafeHttpTarget else err;
}

const CookieRequestTarget = struct {
    secure: bool,
    host: []const u8,
    path: []const u8,
};

fn parseCookieRequestTarget(url: []const u8) ?CookieRequestTarget {
    const uri = std.Uri.parse(url) catch return null;
    if (uri.user != null or uri.password != null) return null;
    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!secure and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    const host_component = uri.host orelse return null;
    const host = switch (host_component) {
        .raw => |bytes| bytes,
        .percent_encoded => |bytes| if (std.mem.indexOfScalar(u8, bytes, '%') == null) bytes else return null,
    };
    if (host.len == 0) return null;
    const path_bytes = switch (uri.path) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    return .{
        .secure = secure,
        .host = host,
        .path = if (path_bytes.len == 0) "/" else path_bytes,
    };
}

fn urlHasExactHttpsHost(url: []const u8, expected_host: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (uri.port) |port| if (port != 443) return false;
    const target = parseCookieRequestTarget(url) orelse return false;
    return target.secure and std.ascii.eqlIgnoreCase(target.host, expected_host);
}

fn validateChallengeTarget(url: []const u8, expected_host: []const u8) !void {
    if (!urlHasExactHttpsHost(url, expected_host)) return error.InvalidSessionPayload;
    // Apply the public-origin policy before consulting the credential cache.
    // A cache hit must not bypass the policy enforced by browser acquisition.
    try common.validatePublicHttpUrl(url);
}

fn buildCookieHeaderForUrl(allocator: Allocator, cookies: []const Cookie, url: []const u8, now: i64) !?[]u8 {
    const target = parseCookieRequestTarget(url) orelse return null;
    var selected: std.ArrayListUnmanaged(usize) = .empty;
    defer selected.deinit(allocator);
    for (cookies, 0..) |cookie, i| {
        if (!cookieAppliesToTarget(cookie, target, now)) continue;
        try selected.append(allocator, i);
        var position = selected.items.len - 1;
        while (position > 0 and cookies[selected.items[position]].path.len > cookies[selected.items[position - 1]].path.len) : (position -= 1) {
            std.mem.swap(usize, &selected.items[position], &selected.items[position - 1]);
        }
    }
    if (selected.items.len == 0) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (selected.items, 0..) |index, output_index| {
        const cookie = cookies[index];
        if (output_index != 0) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, cookie.name);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, cookie.value);
    }
    return try out.toOwnedSlice(allocator);
}

fn findCookieValueForUrl(cookies: []const Cookie, url: []const u8, wanted_name: []const u8, now: i64) ?[]const u8 {
    const target = parseCookieRequestTarget(url) orelse return null;
    var best: ?[]const u8 = null;
    var best_path_len: usize = 0;
    for (cookies) |cookie| {
        if (!std.mem.eql(u8, cookie.name, wanted_name)) continue;
        if (!cookieAppliesToTarget(cookie, target, now)) continue;
        // RFC cookie order gives a more specific path precedence. Keep the
        // earliest input cookie for equal-length paths, matching header order.
        if (best == null or cookie.path.len > best_path_len) {
            best = cookie.value;
            best_path_len = cookie.path.len;
        }
    }
    return best;
}

fn findCookieValueByName(cookies: []const Cookie, wanted_name: []const u8) ?[]const u8 {
    for (cookies) |cookie| {
        if (std.mem.eql(u8, cookie.name, wanted_name)) return cookie.value;
    }
    return null;
}

fn cookieAppliesToTarget(cookie: Cookie, target: CookieRequestTarget, now: i64) bool {
    if (!validCookiePath(cookie.path)) return false;
    if (cookie.secure and !target.secure) return false;
    if (cookie.expires_unix_seconds) |expires| {
        if (expires >= 0 and expires <= now) return false;
    }
    if (cookie.host_only) {
        if (!std.ascii.eqlIgnoreCase(cookie.domain, target.host)) return false;
    } else if (!isSameOrSubdomain(target.host, cookie.domain)) return false;
    return cookiePathMatches(cookie.path, target.path);
}

fn cookiePathMatches(cookie_path: []const u8, request_path: []const u8) bool {
    if (std.mem.eql(u8, cookie_path, request_path)) return true;
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;
    if (cookie_path[cookie_path.len - 1] == '/') return true;
    return request_path.len > cookie_path.len and request_path[cookie_path.len] == '/';
}

fn isSameOrSubdomain(host_input: []const u8, base_input: []const u8) bool {
    const host = stripLeadingDots(host_input);
    const base = stripLeadingDots(base_input);

    if (host.len < base.len) return false;
    if (!std.ascii.eqlIgnoreCase(host[host.len - base.len ..], base)) return false;
    if (host.len == base.len) return true;
    return host[host.len - base.len - 1] == '.';
}

fn stripLeadingDots(input: []const u8) []const u8 {
    var i: usize = 0;
    while (i < input.len and input[i] == '.') : (i += 1) {}
    return input[i..];
}

fn normalizeDomain(allocator: Allocator, input: []const u8) ![]u8 {
    var s = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.startsWith(u8, s, "http://")) s = s["http://".len..];
    if (std.mem.startsWith(u8, s, "https://")) s = s["https://".len..];

    if (std.mem.indexOfAny(u8, s, "/?#")) |idx| s = s[0..idx];
    if (std.mem.indexOfScalar(u8, s, ':')) |idx| s = s[0..idx];

    s = stripLeadingDots(s);
    if (s.len == 0) return error.InvalidSessionPayload;

    const out = try allocator.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn browserLaunchPlan(allocator: Allocator) !BrowserLaunchPlan {
    const configured = try common.getenvOwned(allocator, "SUBDL_CF_HEADLESS");
    defer if (configured) |value| allocator.free(value);
    const display = try common.getenvOwned(allocator, "DISPLAY");
    defer if (display) |value| allocator.free(value);
    const wayland_display = try common.getenvOwned(allocator, "WAYLAND_DISPLAY");
    defer if (wayland_display) |value| allocator.free(value);

    return browserLaunchPlanForEnvironment(builtin.os.tag, configured, display, wayland_display);
}

fn browserLaunchPlanForEnvironment(
    os_tag: std.Target.Os.Tag,
    configured: ?[]const u8,
    display: ?[]const u8,
    wayland_display: ?[]const u8,
) BrowserLaunchPlan {
    const mode = browserLaunchModeFromValue(configured);
    const auto_starts_headed = switch (os_tag) {
        .windows, .macos => true,
        else => hasNonEmptyEnvironmentValue(display) or hasNonEmptyEnvironmentValue(wayland_display),
    };
    return .{
        .mode = mode,
        .auto_starts_headed = auto_starts_headed,
    };
}

fn browserLaunchModeFromValue(value: ?[]const u8) BrowserLaunchMode {
    const raw = std.mem.trim(u8, value orelse return .automatic, " \t\r\n");
    if (std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "headless")) return .headless;
    if (std.mem.eql(u8, raw, "0") or
        std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        std.ascii.eqlIgnoreCase(raw, "headed")) return .headed;
    return .automatic;
}

fn hasNonEmptyEnvironmentValue(value: ?[]const u8) bool {
    const raw = value orelse return false;
    return std.mem.trim(u8, raw, " \t\r\n").len != 0;
}

fn getString(obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const v = obj.get(field) orelse return error.InvalidSessionPayload;
    return switch (v) {
        .string => |s| s,
        else => error.InvalidSessionPayload,
    };
}

fn getOptionalString(obj: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidSessionPayload,
    };
}

fn getBool(obj: std.json.ObjectMap, field: []const u8) !bool {
    const value = obj.get(field) orelse return error.InvalidSessionPayload;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidSessionPayload,
    };
}

fn getInt(obj: std.json.ObjectMap, field: []const u8) !i64 {
    const v = obj.get(field) orelse return error.InvalidSessionPayload;
    return switch (v) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch error.InvalidSessionPayload,
        .float => |f| common.jsonInt(.{ .float = f }) orelse error.InvalidSessionPayload,
        else => error.InvalidSessionPayload,
    };
}

fn getOptionalInt(obj: std.json.ObjectMap, field: []const u8) !?i64 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| integer,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch error.InvalidSessionPayload,
        .float => |float| common.jsonInt(.{ .float = float }) orelse error.InvalidSessionPayload,
        else => error.InvalidSessionPayload,
    };
}

test "session expiry heuristic" {
    const s: Session = .{
        .cookies = &.{},
        .cf_clearance = "",
        .user_agent = "",
        .acquired_at_unix = 0,
        .generation = 0,
    };
    try std.testing.expect(s.isLikelyExpired(60 * 60 * 6));
}

test "normalize domain" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeDomain(allocator, "https://WWW.Example.com:443/path?q=1");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("www.example.com", normalized);
}

test "challenge URL host validation rejects non-HTTPS origins and alternate ports" {
    try validateChallengeTarget("https://www.example.com/path", "www.example.com");
    try validateChallengeTarget("https://www.example.com:443/path", "www.example.com");
    try std.testing.expectError(error.InvalidSessionPayload, validateChallengeTarget("https://www.example.com:8443/path", "www.example.com"));
    try std.testing.expectError(error.InvalidSessionPayload, validateChallengeTarget("http://www.example.com/path", "www.example.com"));
    try std.testing.expectError(error.InvalidSessionPayload, validateChallengeTarget("https://api.example.com/path", "www.example.com"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateChallengeTarget("https://127.0.0.1/path", "127.0.0.1"));
}

test "cache and browser operations preserve cancellation, allocation, and browser configuration failures" {
    try std.testing.expect(mustPropagateOperationError(error.Canceled));
    try std.testing.expect(mustPropagateOperationError(error.OutOfMemory));
    try std.testing.expect(mustPropagateOperationError(error.CloudflareSessionUnavailable));
    try std.testing.expect(mustPropagateOperationError(error.BrowserAutomationDisabled));
    try std.testing.expect(mustPropagateOperationError(error.BrowserAutomationUnavailable));
    try std.testing.expect(mustPropagateOperationError(error.InvalidBrowserExecutable));
    try std.testing.expect(mustPropagateOperationError(error.UnsafeHttpTarget));
    try std.testing.expect(!mustPropagateOperationError(error.FileNotFound));
    try std.testing.expect(!mustPropagateOperationError(error.BrowserAutomationFailed));

    const ordinary_failure: anyerror!void = error.BrowserAutomationFailed;
    try ignoreOrdinaryOperationFailure(ordinary_failure);
    const canceled: anyerror!void = error.Canceled;
    try std.testing.expectError(error.Canceled, ignoreOrdinaryOperationFailure(canceled));
    const out_of_memory: anyerror!void = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, ignoreOrdinaryOperationFailure(out_of_memory));
}

test "deadline failure after successful cache validation releases the owned session" {
    const Fixture = struct {
        var checkpoints: usize = 0;
        var remove_called = false;

        fn checkpoint(_: i64) !void {
            checkpoints += 1;
            if (checkpoints == 2) return error.CloudflareSessionUnavailable;
        }

        fn remove(_: Allocator, _: []const u8, _: Session, _: i64) !void {
            remove_called = true;
        }
    };

    const cookies = [_]Cookie{.{
        .name = "cf_clearance",
        .value = "cached-token",
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .host_only = true,
        .expires_unix_seconds = null,
    }};
    const loaded = try cloneSession(std.testing.allocator, .{
        .cookies = &cookies,
        .cf_clearance = "cached-token",
        .user_agent = "fixture-agent",
        .acquired_at_unix = 100,
        .generation = 1,
    });
    Fixture.checkpoints = 0;
    Fixture.remove_called = false;

    try std.testing.expectError(
        error.CloudflareSessionUnavailable,
        reuseLoadedSessionUsing(
            std.testing.allocator,
            "example.com",
            loaded,
            .{ .domain = "example.com" },
            "https://example.com/",
            101,
            200,
            Fixture.checkpoint,
            Fixture.remove,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), Fixture.checkpoints);
    try std.testing.expect(!Fixture.remove_called);
}

test "acquired session checks deadline after best effort persistence" {
    const Fixture = struct {
        var checkpoints: usize = 0;
        var saves: usize = 0;

        fn checkpoint(_: i64) !void {
            checkpoints += 1;
            if (checkpoints == 2) return error.CloudflareSessionUnavailable;
        }

        fn save(_: Allocator, _: []const u8, _: Session, _: i64) !void {
            saves += 1;
            return error.BrowserAutomationFailed;
        }
    };

    const cookies = [_]Cookie{.{
        .name = "cf_clearance",
        .value = "fresh-token",
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .host_only = true,
        .expires_unix_seconds = null,
    }};
    const acquired = try cloneSession(std.testing.allocator, .{
        .cookies = &cookies,
        .cf_clearance = "fresh-token",
        .user_agent = "fixture-agent",
        .acquired_at_unix = 100,
        .generation = 2,
    });
    Fixture.checkpoints = 0;
    Fixture.saves = 0;

    try std.testing.expectError(
        error.CloudflareSessionUnavailable,
        finishAcquiredSessionUsing(
            std.testing.allocator,
            "example.com",
            acquired,
            200,
            Fixture.checkpoint,
            Fixture.save,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), Fixture.checkpoints);
    try std.testing.expectEqual(@as(usize, 1), Fixture.saves);
}

test "browser resolver deadline is a classified session failure" {
    try std.testing.expectEqual(error.CloudflareSessionUnavailable, normalizeBrowserAcquisitionError(error.Timeout));
    try std.testing.expectEqual(error.CloudflareSessionUnavailable, normalizeBrowserAcquisitionError(error.BrowserOperationTimeout));
    try std.testing.expectEqual(error.Canceled, normalizeBrowserAcquisitionError(error.Canceled));
    try std.testing.expectEqual(error.OutOfMemory, normalizeBrowserAcquisitionError(error.OutOfMemory));
    try std.testing.expectEqual(error.BrowserAutomationUnavailable, normalizeBrowserAcquisitionError(error.BrowserAutomationUnavailable));
    try std.testing.expectEqual(error.InvalidBrowserExecutable, normalizeBrowserAcquisitionError(error.InvalidBrowserExecutable));
    try std.testing.expectEqual(error.UnsafeHttpTarget, normalizeBrowserOperationError(error.UnsafeBrowserNavigation));
    try std.testing.expectEqual(error.BrowserOperationTimeout, normalizeBrowserOperationError(error.BrowserOperationTimeout));
}

test "disabled browser support reports its build configuration" {
    if (!build_options.enable_alldriver) {
        try std.testing.expectError(error.BrowserAutomationDisabled, cachePath(std.testing.allocator));
        try std.testing.expectError(
            error.BrowserAutomationDisabled,
            acquireSessionViaBrowser(
                std.testing.allocator,
                "example.com",
                "https://example.com/",
                std.math.maxInt(i64),
            ),
        );
    }
}

test "session acquisition lock wait preserves cancellation" {
    const Fixture = struct {
        fn now() i64 {
            return 0;
        }
        fn cancel(_: u64) !void {
            return error.Canceled;
        }
    };
    session_acquire_lock.store(1, .release);
    defer session_acquire_lock.store(0, .release);
    try std.testing.expectError(error.Canceled, SessionAcquireGuard.lockUntilWith(100, Fixture.now, Fixture.cancel));
}

test "session acquisition lock wait consumes the browser deadline" {
    const Fixture = struct {
        var current: i64 = 0;
        fn now() i64 {
            return current;
        }
        fn pause(delay: u64) !void {
            current += @intCast(delay);
        }
    };
    Fixture.current = 0;
    session_acquire_lock.store(1, .release);
    defer session_acquire_lock.store(0, .release);
    try std.testing.expectError(
        error.CloudflareSessionUnavailable,
        SessionAcquireGuard.lockUntilWith(50, Fixture.now, Fixture.pause),
    );
    try std.testing.expectEqual(@as(i64, 50), Fixture.current);
}

test "challenge timeout is global and bounded" {
    try std.testing.expectEqual(@as(?u64, 100), remainingTimeoutMs(100, 250, 100));
    try std.testing.expectEqual(@as(?u64, 50), remainingTimeoutMs(200, 250, 100));
    try std.testing.expectEqual(@as(?u64, null), remainingTimeoutMs(250, 250, 100));
}

test "browser launch mode distinguishes explicit choices from automatic" {
    try std.testing.expectEqual(BrowserLaunchMode.automatic, browserLaunchModeFromValue(null));
    try std.testing.expectEqual(BrowserLaunchMode.automatic, browserLaunchModeFromValue("auto"));
    try std.testing.expectEqual(BrowserLaunchMode.automatic, browserLaunchModeFromValue("invalid"));
    try std.testing.expectEqual(BrowserLaunchMode.headless, browserLaunchModeFromValue(" true "));
    try std.testing.expectEqual(BrowserLaunchMode.headless, browserLaunchModeFromValue("headless"));
    try std.testing.expectEqual(BrowserLaunchMode.headed, browserLaunchModeFromValue("0"));
    try std.testing.expectEqual(BrowserLaunchMode.headed, browserLaunchModeFromValue("headed"));
}

test "automatic browser mode ignores empty display variables" {
    const linux_empty = browserLaunchPlanForEnvironment(.linux, null, "", " \t");
    try std.testing.expect(linux_empty.primaryHeadless());
    try std.testing.expectEqual(@as(usize, 1), linux_empty.passCount());

    const linux_x11 = browserLaunchPlanForEnvironment(.linux, "auto", ":0", null);
    try std.testing.expect(!linux_x11.primaryHeadless());
    try std.testing.expectEqual(@as(usize, 2), linux_x11.passCount());
    const linux_wayland = browserLaunchPlanForEnvironment(.linux, null, null, "wayland-1");
    try std.testing.expect(!linux_wayland.primaryHeadless());
    const windows = browserLaunchPlanForEnvironment(.windows, null, null, null);
    try std.testing.expect(!windows.primaryHeadless());
    const macos = browserLaunchPlanForEnvironment(.macos, null, null, null);
    try std.testing.expect(!macos.primaryHeadless());

    const explicit_headed = browserLaunchPlanForEnvironment(.linux, "false", "", "");
    try std.testing.expect(!explicit_headed.primaryHeadless());
    const explicit_headless = browserLaunchPlanForEnvironment(.linux, "true", ":0", null);
    try std.testing.expect(explicit_headless.primaryHeadless());
}

test "automatic launch exhausts headed candidates before one headless pass" {
    const Fixture = struct {
        executables: [4][]const u8 = undefined,
        attempts: [4]bool = undefined,
        deadlines: [4]i64 = undefined,
        attempt_count: usize = 0,
        checkpoint_deadlines: [8]i64 = undefined,
        checkpoint_count: usize = 0,

        fn launch(self: *@This(), executable: []const u8, headless: bool, deadline: i64) !u8 {
            const attempt = self.attempt_count;
            self.executables[attempt] = executable;
            self.attempts[attempt] = headless;
            self.deadlines[attempt] = deadline;
            self.attempt_count += 1;
            if (std.mem.eql(u8, executable, "missing") or !headless)
                return error.BrowserAutomationFailed;
            return 7;
        }

        fn checkpoint(self: *@This(), deadline: i64) !void {
            self.checkpoint_deadlines[self.checkpoint_count] = deadline;
            self.checkpoint_count += 1;
        }

        fn now(_: *@This()) i64 {
            return 0;
        }
    };

    const deadline: i64 = challenge_timeout_ms;
    const plan = browserLaunchPlanForEnvironment(.linux, "auto", ":0", null);
    var iterator: BrowserLaunchIterator = .{ .plan = plan };
    var fixture: Fixture = .{};
    const launched = (try launchNextBrowserUsing(
        u8,
        &fixture,
        &[_][]const u8{ "missing", "browser" },
        &iterator,
        deadline,
        Fixture.launch,
        Fixture.checkpoint,
        Fixture.now,
    )) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 7), launched.browser);
    try std.testing.expect(launched.headless);
    try std.testing.expectEqual(@as(usize, 4), fixture.attempt_count);
    try std.testing.expectEqualStrings("missing", fixture.executables[0]);
    try std.testing.expectEqualStrings("browser", fixture.executables[1]);
    try std.testing.expectEqualStrings("missing", fixture.executables[2]);
    try std.testing.expectEqualStrings("browser", fixture.executables[3]);
    try std.testing.expect(!fixture.attempts[0]);
    try std.testing.expect(!fixture.attempts[1]);
    try std.testing.expect(fixture.attempts[2]);
    try std.testing.expect(fixture.attempts[3]);
    const headed_deadline = browserAttemptDeadline(plan, false, 0, deadline);
    for (fixture.deadlines[0..2]) |attempt_deadline|
        try std.testing.expectEqual(headed_deadline, attempt_deadline);
    for (fixture.deadlines[2..fixture.attempt_count]) |attempt_deadline|
        try std.testing.expectEqual(deadline, attempt_deadline);
    try std.testing.expectEqual(deadline, launched.deadline);
    for (fixture.checkpoint_deadlines[0..fixture.checkpoint_count]) |checkpoint_deadline|
        try std.testing.expectEqual(deadline, checkpoint_deadline);
    try std.testing.expectEqual(@as(usize, 7), fixture.checkpoint_count);

    if (try launchNextBrowserUsing(
        u8,
        &fixture,
        &[_][]const u8{ "missing", "browser" },
        &iterator,
        deadline,
        Fixture.launch,
        Fixture.checkpoint,
        Fixture.now,
    )) |_| return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), fixture.attempt_count);
}

test "automatic headed probe expiry leaves time for a successful headless fallback" {
    const Fixture = struct {
        current: i64 = 0,
        launch_headless: [2]bool = undefined,
        launch_deadlines: [2]i64 = undefined,
        launch_count: usize = 0,
        navigation_count: usize = 0,
        clearance_checks: usize = 0,
        deinit_count: usize = 0,

        fn checkpoint(self: *@This(), deadline: i64) !void {
            if (self.current >= deadline) return error.CloudflareSessionUnavailable;
        }

        fn now(self: *@This()) i64 {
            return self.current;
        }

        fn launch(self: *@This(), _: []const u8, headless: bool, deadline: i64) !u8 {
            self.launch_headless[self.launch_count] = headless;
            self.launch_deadlines[self.launch_count] = deadline;
            self.launch_count += 1;
            return @intCast(self.launch_count);
        }

        fn deinit(self: *@This(), _: *u8) void {
            self.deinit_count += 1;
        }

        fn acquire(
            self: *@This(),
            browser: *u8,
            headless: bool,
            attempt_deadline: i64,
            global_deadline: i64,
        ) !?u8 {
            self.navigation_count += 1;
            self.clearance_checks += 1;
            if (!headless) {
                // Navigation succeeded, but this headed browser never produced
                // clearance. Advance deterministically to its bounded deadline.
                self.current = attempt_deadline;
                return null;
            }
            try std.testing.expect(self.current < global_deadline);
            try std.testing.expectEqual(global_deadline, attempt_deadline);
            return browser.*;
        }
    };

    const global_deadline: i64 = challenge_timeout_ms;
    const plan = browserLaunchPlanForEnvironment(.linux, "auto", ":0", null);
    var fixture: Fixture = .{};
    const acquired = (try runBrowserAttemptsUsing(
        u8,
        u8,
        &fixture,
        &[_][]const u8{"browser"},
        plan,
        global_deadline,
        Fixture.launch,
        Fixture.checkpoint,
        Fixture.now,
        Fixture.deinit,
        Fixture.acquire,
    )) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u8, 2), acquired);
    try std.testing.expectEqual(@as(usize, 2), fixture.launch_count);
    try std.testing.expectEqual(@as(usize, 2), fixture.navigation_count);
    try std.testing.expectEqual(@as(usize, 2), fixture.clearance_checks);
    try std.testing.expectEqual(@as(usize, 2), fixture.deinit_count);
    try std.testing.expect(!fixture.launch_headless[0]);
    try std.testing.expect(fixture.launch_headless[1]);
    try std.testing.expectEqual(automatic_headed_probe_ms, fixture.launch_deadlines[0]);
    try std.testing.expectEqual(global_deadline, fixture.launch_deadlines[1]);
    try std.testing.expectEqual(automatic_headed_probe_ms, fixture.current);
}

test "explicit headed launch never enters a headless pass" {
    const Fixture = struct {
        attempts: [4]bool = undefined,
        deadlines: [4]i64 = undefined,
        attempt_count: usize = 0,
        checkpoint_count: usize = 0,

        fn launch(self: *@This(), _: []const u8, headless: bool, deadline: i64) !u8 {
            self.attempts[self.attempt_count] = headless;
            self.deadlines[self.attempt_count] = deadline;
            self.attempt_count += 1;
            return error.BrowserAutomationFailed;
        }

        fn checkpoint(self: *@This(), _: i64) !void {
            self.checkpoint_count += 1;
        }

        fn now(_: *@This()) i64 {
            return 0;
        }
    };

    const explicit_headed = browserLaunchPlanForEnvironment(.linux, "0", ":0", null);
    var iterator: BrowserLaunchIterator = .{ .plan = explicit_headed };
    var headed_fixture: Fixture = .{};
    if (try launchNextBrowserUsing(
        u8,
        &headed_fixture,
        &[_][]const u8{ "missing", "browser" },
        &iterator,
        900,
        Fixture.launch,
        Fixture.checkpoint,
        Fixture.now,
    )) |_| return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), headed_fixture.attempt_count);
    try std.testing.expect(!headed_fixture.attempts[0]);
    try std.testing.expect(!headed_fixture.attempts[1]);
    try std.testing.expectEqual(@as(i64, 900), headed_fixture.deadlines[0]);
    try std.testing.expectEqual(@as(i64, 900), headed_fixture.deadlines[1]);
    try std.testing.expectEqual(@as(usize, 4), headed_fixture.checkpoint_count);
}

test "session cache path uses native cache roots with deterministic fallbacks" {
    const allocator = std.testing.allocator;

    const windows_local = try cachePathFromRoots(allocator, .windows, "C:/Local", "C:/User", "/xdg", "/home/user");
    defer allocator.free(windows_local);
    const expected_windows_local = try std.fs.path.join(allocator, &.{ "C:/Local", "subdl", shared_cache_filename });
    defer allocator.free(expected_windows_local);
    try std.testing.expectEqualStrings(expected_windows_local, windows_local);

    const windows_profile = try cachePathFromRoots(allocator, .windows, "", "C:/User", null, null);
    defer allocator.free(windows_profile);
    const expected_windows_profile = try std.fs.path.join(allocator, &.{ "C:/User", "AppData", "Local", "subdl", shared_cache_filename });
    defer allocator.free(expected_windows_profile);
    try std.testing.expectEqualStrings(expected_windows_profile, windows_profile);

    const xdg = try cachePathFromRoots(allocator, .linux, null, null, "/var/cache/user", "/home/user");
    defer allocator.free(xdg);
    const expected_xdg = try std.fs.path.join(allocator, &.{ "/var/cache/user", "subdl", shared_cache_filename });
    defer allocator.free(expected_xdg);
    try std.testing.expectEqualStrings(expected_xdg, xdg);

    const home = try cachePathFromRoots(allocator, .macos, null, null, ".relative-cache", "/Users/example");
    defer allocator.free(home);
    const expected_home = try std.fs.path.join(allocator, &.{ "/Users/example", ".cache", "subdl", shared_cache_filename });
    defer allocator.free(expected_home);
    try std.testing.expectEqualStrings(expected_home, home);

    try std.testing.expectError(
        error.EnvironmentVariableNotFound,
        cachePathFromRoots(allocator, .linux, null, null, ".relative-cache", "relative-home"),
    );
    try std.testing.expect(!diskSessionCacheSupported(.windows));
    try std.testing.expect(diskSessionCacheSupported(.linux));
}

test "cookie selection preserves host domain path secure and expiry semantics" {
    const cookies = [_]Cookie{
        .{ .name = "parent", .value = "domain-token", .domain = "example.com", .path = "/", .secure = true, .host_only = false, .expires_unix_seconds = null },
        .{ .name = "session", .value = "exact-token", .domain = "www.example.com", .path = "/account", .secure = true, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "plain", .value = "http-token", .domain = "www.example.com", .path = "/", .secure = false, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "expired", .value = "old", .domain = "www.example.com", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = 9 },
        .{ .name = "sibling", .value = "wrong", .domain = "api.example.com", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
    };
    const header = (try buildCookieHeaderForUrl(std.testing.allocator, &cookies, "https://www.example.com/account/profile", 10)).?;
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("session=exact-token; parent=domain-token; plain=http-token", header);

    const api_header = (try buildCookieHeaderForUrl(std.testing.allocator, &cookies, "https://api.example.com/account/profile", 10)).?;
    defer std.testing.allocator.free(api_header);
    try std.testing.expectEqualStrings("parent=domain-token; sibling=wrong", api_header);
    try std.testing.expect((try buildCookieHeaderForUrl(std.testing.allocator, cookies[1..2], "https://api.example.com/", 10)) == null);
    try std.testing.expect((try buildCookieHeaderForUrl(std.testing.allocator, cookies[0..1], "http://www.example.com/", 10)) == null);

    const duplicate_clearance = [_]Cookie{
        .{ .name = "cf_clearance", .value = "root-token", .domain = "www.example.com", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "cf_clearance", .value = "download-token", .domain = "www.example.com", .path = "/download", .secure = true, .host_only = true, .expires_unix_seconds = null },
    };
    const download_header = (try buildCookieHeaderForUrl(std.testing.allocator, &duplicate_clearance, "https://www.example.com/download/file", 10)).?;
    defer std.testing.allocator.free(download_header);
    try std.testing.expectEqualStrings("cf_clearance=download-token; cf_clearance=root-token", download_header);
    try std.testing.expectEqualStrings("download-token", findCookieValueForUrl(&duplicate_clearance, "https://www.example.com/download/file", "cf_clearance", 10).?);
    try std.testing.expectEqualStrings("root-token", findCookieValueForUrl(&duplicate_clearance, "https://www.example.com/", "cf_clearance", 10).?);
}

test "cookie names are case-sensitive in clearance lookup and cache validation" {
    const cookies = [_]Cookie{
        .{ .name = "CF_CLEARANCE", .value = "wrong", .domain = "www.example.com", .path = "/download", .secure = true, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "cf_clearance", .value = "right", .domain = "www.example.com", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
    };
    try std.testing.expectEqualStrings("right", findCookieValueForUrl(&cookies, "https://www.example.com/download/1", "cf_clearance", 10).?);
    try std.testing.expectEqualStrings("right", findCookieValueByName(&cookies, "cf_clearance").?);
    try std.testing.expect(findCookieValueByName(cookies[0..1], "cf_clearance") == null);

    const valid: CacheRecord = .{
        .domain = "www.example.com",
        .cookies = cookies[1..2],
        .cf_clearance = "right",
        .user_agent = "fixture-agent",
        .acquired_at_unix = 9,
        .generation = 1,
    };
    try std.testing.expect(!cacheRecordStale(valid, 10));
    var wrong_case = valid;
    wrong_case.cookies = cookies[0..1];
    wrong_case.cf_clearance = "wrong";
    try std.testing.expect(cacheRecordStale(wrong_case, 10));
}

test "forced refresh only coalesces to a different cached generation" {
    const cookies = [_]Cookie{.{ .name = "cf_clearance", .value = "token", .domain = "example.com", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null }};
    const session: Session = .{
        .cookies = &cookies,
        .cf_clearance = "token",
        .user_agent = "fixture",
        .acquired_at_unix = 100,
        .generation = 7,
    };
    const challenge_url = "https://example.com/download/1";
    try std.testing.expect(!canReuseCachedSession(session, .{ .domain = "example.com", .force_refresh = true }, challenge_url, 101));
    try std.testing.expect(!canReuseCachedSession(session, .{ .domain = "example.com", .force_refresh = true, .rejected_generation = 7 }, challenge_url, 101));
    try std.testing.expect(canReuseCachedSession(session, .{ .domain = "example.com", .force_refresh = true, .rejected_generation = 6 }, challenge_url, 101));
}

test "cached clearance must apply to the challenged URL" {
    var cookies = [_]Cookie{.{ .name = "cf_clearance", .value = "token", .domain = "www.example.com", .path = "/download", .secure = true, .host_only = true, .expires_unix_seconds = 200 }};
    const session: Session = .{
        .cookies = &cookies,
        .cf_clearance = "token",
        .user_agent = "fixture",
        .acquired_at_unix = 100,
        .generation = 7,
    };
    const options: EnsureDomainOptions = .{ .domain = "www.example.com" };
    const challenge_url = "https://www.example.com/download/1?format=srt";
    try std.testing.expect(canReuseCachedSession(session, options, challenge_url, 101));
    for ([_][]const u8{
        "https://www.example.com/",
        "https://www.example.com/downloads/1",
        "https://api.example.com/download/1",
        "http://www.example.com/download/1",
    }) |url| try std.testing.expect(!canReuseCachedSession(session, options, url, 101));
    try std.testing.expect(!canReuseCachedSession(session, options, challenge_url, 200));

    cookies[0].value = "different-token";
    try std.testing.expect(!canReuseCachedSession(session, options, challenge_url, 101));
    cookies[0].value = "token";
    cookies[0].domain = "example.com";
    try std.testing.expect(!canReuseCachedSession(session, options, challenge_url, 101));
    cookies[0].host_only = false;
    try std.testing.expect(canReuseCachedSession(session, options, challenge_url, 101));
}

test "browser cookie snapshots may be empty while verification is pending" {
    const allocator = std.testing.allocator;
    const browser_cookies = [_]Cookie{
        .{ .name = "cf_clearance", .value = "foreign", .domain = "other.example", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "cf_clearance", .value = "ready", .domain = "www.example.com", .path = "/download", .secure = true, .host_only = true, .expires_unix_seconds = null },
    };
    const challenge_url = "https://www.example.com/download/1";
    for ([_][]const Cookie{ browser_cookies[0..0], browser_cookies[0..1] }) |snapshot| {
        const pending = try cloneBrowserCookiesForHost(allocator, snapshot, "www.example.com");
        defer freeCookies(allocator, pending);
        try std.testing.expectEqual(@as(usize, 0), pending.len);
        try std.testing.expect(findCookieValueForUrl(pending, challenge_url, "cf_clearance", 101) == null);
    }
    const ready = try cloneBrowserCookiesForHost(allocator, &browser_cookies, "www.example.com");
    defer freeCookies(allocator, ready);
    try std.testing.expectEqualStrings("ready", findCookieValueForUrl(ready, challenge_url, "cf_clearance", 101).?);
}

test "session cache publication replaces complete bytes with private permissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions.json", .data = "old bytes" });
    try writeSessionCacheAtomically(tmp.dir, io, "sessions.json", "{\"sessions\":[]}");
    const bytes = try tmp.dir.readFileAlloc(io, "sessions.json", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"sessions\":[]}", bytes);
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        const file = try tmp.dir.openFile(io, "sessions.json", .{});
        defer file.close(io);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try file.stat(io)).permissions.toMode() & 0o777);
    }
}

test "session cache open does not block on a FIFO" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = std.os.linux.mknodat(
        tmp.dir.handle,
        "sessions.fifo",
        std.os.linux.S.IFIFO | std.os.linux.S.IRUSR | std.os.linux.S.IWUSR,
        0,
    );
    try std.testing.expect(std.os.linux.errno(result) == .SUCCESS);

    const file = try openCacheFileNonblockingAt(tmp.dir, "sessions.fifo");
    defer file.close(std.testing.io);
    try std.testing.expectEqual(std.Io.File.Kind.named_pipe, (try file.stat(std.testing.io)).kind);
}

test "session cache lock serializes writers and remains private" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const first = acquireSessionCacheLockAt(tmp.dir, io, "sessions.lock", std.math.maxInt(i64)) catch |err| switch (err) {
        error.FileLocksUnsupported => return error.SkipZigTest,
        else => return err,
    };
    defer first.close(io);

    const second = try tmp.dir.openFile(io, "sessions.lock", .{
        .mode = .read_write,
        .follow_symlinks = false,
    });
    defer second.close(io);
    try std.testing.expect(!(try second.tryLock(io, .exclusive)));

    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try first.stat(io)).permissions.toMode() & 0o777);
    }
}

test "session cache lock refuses ownership after its deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try std.testing.expectError(
        error.SessionCacheLockTimeout,
        acquireSessionCacheLockAt(tmp.dir, io, "expired.lock", common.compatMilliTimestamp()),
    );
    const recovered = acquireSessionCacheLockAt(tmp.dir, io, "expired.lock", std.math.maxInt(i64)) catch |err| switch (err) {
        error.FileLocksUnsupported => return error.SkipZigTest,
        else => return err,
    };
    defer recovered.close(io);
}

test "browser user agent must be nonempty bounded and header safe" {
    try std.testing.expect(validBrowserUserAgent("Mozilla/5.0 fixture"));
    try std.testing.expect(!validBrowserUserAgent(""));
    try std.testing.expect(!validBrowserUserAgent("   "));
    try std.testing.expect(!validBrowserUserAgent("Mozilla/5.0\r\nInjected: yes"));
    try std.testing.expect(!validBrowserUserAgent(&@as([max_browser_user_agent_bytes + 1]u8, @splat('x'))));
}

fn checkRecordClone(allocator: Allocator) !void {
    const cookies = [_]Cookie{.{ .name = "cf_clearance", .value = "dummy", .domain = "fixture.invalid", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null }};
    const record = try dupRecord(allocator, "fixture.invalid", .{ .cookies = &cookies, .cf_clearance = "dummy", .user_agent = "fixture", .acquired_at_unix = 1, .generation = 1 });
    defer freeRecordFields(allocator, record);
    try std.testing.expectEqualStrings("fixture", record.user_agent);
}
test "session record cloning frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRecordClone, .{});
}

test "cache upsert cannot let an older process overwrite a newer session" {
    const allocator = std.testing.allocator;
    const cookies = [_]Cookie{.{
        .name = "cf_clearance",
        .value = "dummy",
        .domain = "fixture.invalid",
        .path = "/",
        .secure = true,
        .host_only = true,
        .expires_unix_seconds = null,
    }};
    var records: std.ArrayListUnmanaged(CacheRecord) = .empty;
    defer freeCacheRecords(allocator, &records);

    const current: Session = .{
        .cookies = &cookies,
        .cf_clearance = "dummy",
        .user_agent = "fixture",
        .acquired_at_unix = 200,
        .generation = 1,
    };
    try std.testing.expect(try upsertCacheRecord(allocator, &records, "fixture.invalid", current));

    var older_process = current;
    older_process.acquired_at_unix = 199;
    older_process.generation = std.math.maxInt(u64);
    try std.testing.expect(!try upsertCacheRecord(allocator, &records, "FIXTURE.INVALID", older_process));
    try std.testing.expectEqual(@as(i64, 200), records.items[0].acquired_at_unix);
    try std.testing.expectEqual(@as(u64, 1), records.items[0].generation);

    var newer_process = current;
    newer_process.acquired_at_unix = 201;
    try std.testing.expect(try upsertCacheRecord(allocator, &records, "fixture.invalid", newer_process));
    try std.testing.expectEqual(@as(i64, 201), records.items[0].acquired_at_unix);
}

test "cache pruning removes stale malformed and duplicate sessions" {
    const allocator = std.testing.allocator;
    const valid_cookies = [_]Cookie{.{
        .name = "cf_clearance",
        .value = "dummy",
        .domain = "fixture.invalid",
        .path = "/",
        .secure = true,
        .host_only = true,
        .expires_unix_seconds = null,
    }};
    const wrong_scope_cookies = [_]Cookie{.{
        .name = "cf_clearance",
        .value = "dummy",
        .domain = "elsewhere.invalid",
        .path = "/",
        .secure = true,
        .host_only = true,
        .expires_unix_seconds = null,
    }};
    const now: i64 = session_ttl_seconds + 1000;
    const older: Session = .{ .cookies = &valid_cookies, .cf_clearance = "dummy", .user_agent = "fixture", .acquired_at_unix = now - 20, .generation = 500 };
    const newer: Session = .{ .cookies = &valid_cookies, .cf_clearance = "dummy", .user_agent = "fixture", .acquired_at_unix = now - 10, .generation = 1 };
    const malformed: Session = .{ .cookies = &wrong_scope_cookies, .cf_clearance = "dummy", .user_agent = "fixture", .acquired_at_unix = now - 5, .generation = 1 };
    const expired: Session = .{ .cookies = &valid_cookies, .cf_clearance = "dummy", .user_agent = "fixture", .acquired_at_unix = now - session_ttl_seconds - 1, .generation = 1 };

    var records: std.ArrayListUnmanaged(CacheRecord) = .empty;
    defer freeCacheRecords(allocator, &records);
    try records.append(allocator, try dupRecord(allocator, "fixture.invalid", older));
    try records.append(allocator, try dupRecord(allocator, "fixture.invalid", newer));
    try records.append(allocator, try dupRecord(allocator, "malformed.invalid", malformed));
    try records.append(allocator, try dupRecord(allocator, "expired.invalid", expired));

    try std.testing.expect(pruneCacheRecords(allocator, &records, now));
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqualStrings("fixture.invalid", records.items[0].domain);
    try std.testing.expectEqual(newer.acquired_at_unix, records.items[0].acquired_at_unix);
    try std.testing.expect(!pruneCacheRecords(allocator, &records, now));
}

test "cache pruning removes only the rejected session generation" {
    const allocator = std.testing.allocator;
    const cookies = [_]Cookie{.{ .name = "cf_clearance", .value = "dummy", .domain = "fixture.invalid", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null }};
    const different_cookies = [_]Cookie{
        .{ .name = "cf_clearance", .value = "dummy", .domain = "fixture.invalid", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "session", .value = "newer-process", .domain = "fixture.invalid", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
    };
    const session: Session = .{ .cookies = &cookies, .cf_clearance = "dummy", .user_agent = "fixture", .acquired_at_unix = 1, .generation = 1 };
    var records: std.ArrayListUnmanaged(CacheRecord) = .empty;
    defer freeCacheRecords(allocator, &records);
    try records.append(allocator, try dupRecord(allocator, "fixture.invalid", session));
    var concurrent = session;
    concurrent.cookies = &different_cookies;
    try records.append(allocator, try dupRecord(allocator, "fixture.invalid", concurrent));
    var replacement = session;
    replacement.generation = 2;
    try records.append(allocator, try dupRecord(allocator, "fixture.invalid", replacement));
    try records.append(allocator, try dupRecord(allocator, "other.invalid", session));

    try std.testing.expect(removeMatchingCacheRecords(allocator, &records, "FIXTURE.INVALID", session));
    try std.testing.expectEqual(@as(usize, 3), records.items.len);
    try std.testing.expectEqualStrings("fixture.invalid", records.items[0].domain);
    try std.testing.expectEqual(@as(usize, 2), records.items[0].cookies.len);
    try std.testing.expectEqual(@as(u64, 2), records.items[1].generation);
    try std.testing.expectEqualStrings("other.invalid", records.items[2].domain);
    try std.testing.expect(!removeMatchingCacheRecords(allocator, &records, "missing.invalid", session));
}
