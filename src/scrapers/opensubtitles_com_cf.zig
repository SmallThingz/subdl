const std = @import("std");
const builtin = @import("builtin");
const driver = @import("alldriver");
const common = @import("common.zig");
const runtime_io = @import("runtime_io");

const Allocator = std.mem.Allocator;
const shared_cache_relpath = ".cache/subdl/cloudflare_shared_sessions.json";
const fallback_user_agent = "subdl-zig-scrapers/0.2 (+https://subdl.com)";
const session_ttl_seconds: i64 = 5 * 60 * 60;
const challenge_timeout_ms: i64 = 4 * 60 * 1000;
const challenge_poll_interval_ms: i64 = 1000;
var session_acquire_lock = std.atomic.Value(u8).init(0);
var last_session_generation = std.atomic.Value(u64).init(0);

const SessionAcquireGuard = struct {
    fn lock() SessionAcquireGuard {
        while (session_acquire_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            common.sleepMilliseconds(25);
        }
        return .{};
    }

    fn unlock(_: SessionAcquireGuard) void {
        session_acquire_lock.store(0, .release);
    }
};

pub const Error = error{
    CloudflareSessionUnavailable,
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
    csrf_token: ?[]const u8,
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
        if (self.csrf_token) |token| allocator.free(token);
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
    csrf_token: ?[]const u8,
    acquired_at_unix: i64,
    generation: u64,
};

pub fn ensureDomainSession(allocator: Allocator, options: EnsureDomainOptions) !Session {
    const acquire_guard = SessionAcquireGuard.lock();
    defer acquire_guard.unlock();

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
    if (!urlHasExactHttpsHost(challenge_url, normalized_domain)) return error.InvalidSessionPayload;

    const now = common.compatUnixTimestamp();
    if (try loadSessionForDomain(allocator, normalized_domain)) |cached| {
        if (canReuseCachedSession(cached, options, challenge_url, now)) return cached;
        var owned = cached;
        owned.deinit(allocator);
    }

    var acquired = try acquireSessionViaAllDriver(allocator, normalized_domain, challenge_url);
    errdefer acquired.deinit(allocator);
    try saveSessionForDomain(allocator, normalized_domain, acquired);
    return acquired;
}

fn isUsableSession(session: Session, challenge_url: []const u8, now: i64) bool {
    if (session.cf_clearance.len == 0) return false;
    if (session.user_agent.len == 0) return false;
    const clearance = findCookieValueForUrl(session.cookies, challenge_url, "cf_clearance", now) orelse return false;
    return std.mem.eql(u8, clearance, session.cf_clearance);
}

fn canReuseCachedSession(session: Session, options: EnsureDomainOptions, challenge_url: []const u8, now: i64) bool {
    if (session.isLikelyExpired(now) or !isUsableSession(session, challenge_url, now)) return false;
    if (!options.force_refresh) return true;
    const rejected = options.rejected_generation orelse return false;
    return session.generation != 0 and session.generation != rejected;
}

fn loadSessionForDomain(allocator: Allocator, domain_input: []const u8) !?Session {
    const domain = try normalizeDomain(allocator, domain_input);
    defer allocator.free(domain);

    var records = try readCacheRecords(allocator);
    defer freeCacheRecords(allocator, &records);

    for (records.items) |record| {
        if (!std.ascii.eqlIgnoreCase(record.domain, domain)) continue;

        return try cloneSession(allocator, .{
            .cookies = record.cookies,
            .cf_clearance = record.cf_clearance,
            .user_agent = record.user_agent,
            .csrf_token = if (record.csrf_token) |token|
                if (token.len > 0 and !std.mem.eql(u8, token, "string"))
                    token
                else
                    null
            else
                null,
            .acquired_at_unix = record.acquired_at_unix,
            .generation = record.generation,
        });
    }

    return null;
}

fn saveSessionForDomain(allocator: Allocator, domain_input: []const u8, session: Session) !void {
    const domain = try normalizeDomain(allocator, domain_input);
    defer allocator.free(domain);

    var records = try readCacheRecords(allocator);
    defer freeCacheRecords(allocator, &records);

    for (records.items) |*record| {
        if (!std.ascii.eqlIgnoreCase(record.domain, domain)) continue;
        const replacement = try dupRecord(allocator, domain, session);
        freeRecordFields(allocator, record.*);
        record.* = replacement;
        try writeCacheRecords(allocator, records.items);
        return;
    }

    const additional = try dupRecord(allocator, domain, session);
    records.append(allocator, additional) catch |err| {
        freeRecordFields(allocator, additional);
        return err;
    };
    try writeCacheRecords(allocator, records.items);
}

fn cloneSession(allocator: Allocator, source: Session) !Session {
    const cookies = try cloneCookies(allocator, source.cookies);
    errdefer freeCookies(allocator, cookies);
    const clearance = try allocator.dupe(u8, source.cf_clearance);
    errdefer allocator.free(clearance);
    const agent = try allocator.dupe(u8, source.user_agent);
    errdefer allocator.free(agent);
    const csrf = if (source.csrf_token) |value| try allocator.dupe(u8, value) else null;
    return .{
        .cookies = cookies,
        .cf_clearance = clearance,
        .user_agent = agent,
        .csrf_token = csrf,
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
        .csrf_token = owned.csrf_token,
        .acquired_at_unix = owned.acquired_at_unix,
        .generation = owned.generation,
    };
}

fn freeRecordFields(allocator: Allocator, record: CacheRecord) void {
    allocator.free(record.domain);
    freeCookies(allocator, record.cookies);
    allocator.free(record.cf_clearance);
    allocator.free(record.user_agent);
    if (record.csrf_token) |token| allocator.free(token);
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

fn readCacheRecords(allocator: Allocator) !std.ArrayListUnmanaged(CacheRecord) {
    return readCacheRecordsStrict(allocator) catch |err| {
        if (err == error.OutOfMemory) return err;
        // Session state is an optimization. Corrupt, stale-schema, or unsafe
        // cache files must not prevent ordinary browser acquisition.
        return .empty;
    };
}

fn readCacheRecordsStrict(allocator: Allocator) !std.ArrayListUnmanaged(CacheRecord) {
    var records: std.ArrayListUnmanaged(CacheRecord) = .empty;
    errdefer freeCacheRecords(allocator, &records);
    if (!driver.enabled) return records;

    const path = try cachePath(allocator);
    defer allocator.free(path);

    const io = runtime_io.get();
    const file = std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .follow_symlinks = false,
    }) catch return records;
    defer file.close(io);

    const stat = file.stat(io) catch return records;
    if (stat.kind != .file or !cacheFileOwnedByCurrentUser(file)) return records;
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) {
        file.setPermissions(io, .fromMode(0o600)) catch return records;
    }

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const data = try file_reader.interface.allocRemaining(allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(data);

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

        const cf_clearance = (try getOptionalString(obj, "cf_clearance")) orelse
            findCookieValueByName(cookies, "cf_clearance") orelse "";
        const user_agent = try getString(obj, "user_agent");
        const csrf_token = try getOptionalString(obj, "csrf_token");
        const acquired_at_unix = try getInt(obj, "acquired_at_unix");
        const generation_i64 = if (version == 1) 0 else try getInt(obj, "generation");
        if (generation_i64 < 0) return error.InvalidSessionPayload;

        const record = try dupRecord(allocator, domain, .{
            .cookies = cookies,
            .cf_clearance = cf_clearance,
            .user_agent = user_agent,
            .csrf_token = if (csrf_token) |token|
                if (token.len > 0 and !std.mem.eql(u8, token, "string"))
                    token
                else
                    null
            else
                null,
            .acquired_at_unix = acquired_at_unix,
            .generation = @intCast(generation_i64),
        });
        records.append(allocator, record) catch |err| {
            freeRecordFields(allocator, record);
            return err;
        };
    }

    return records;
}

fn cacheFileOwnedByCurrentUser(file: std.Io.File) bool {
    if (comptime builtin.os.tag == .linux) {
        var statx_buf: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(
            @intCast(file.handle),
            "",
            std.os.linux.AT.EMPTY_PATH,
            .{ .UID = true },
            &statx_buf,
        );
        return std.os.linux.errno(rc) == .SUCCESS and statx_buf.mask.UID and statx_buf.uid == std.os.linux.geteuid();
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
    return true;
}

fn parseCachedCookies(allocator: Allocator, value: std.json.Value) ![]Cookie {
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidSessionPayload,
    };
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
    if (cookies.items.len == 0) return error.InvalidSessionPayload;
    return try cookies.toOwnedSlice(allocator);
}

fn parseLegacyCookieHeader(allocator: Allocator, domain: []const u8, header: []const u8) ![]Cookie {
    var cookies: std.ArrayListUnmanaged(Cookie) = .empty;
    errdefer deinitCookieList(allocator, &cookies);
    var fields = std.mem.splitScalar(u8, header, ';');
    while (fields.next()) |raw_field| {
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

fn writeCacheRecords(allocator: Allocator, records: []const CacheRecord) !void {
    if (!driver.enabled) return;
    const path = try cachePath(allocator);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(runtime_io.get(), dir_path);
    }

    const json_data = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{
        .version = 2,
        .sessions = records,
    }, .{ .whitespace = .indent_2 })});
    defer allocator.free(json_data);

    try writeSessionCacheAtomically(std.Io.Dir.cwd(), runtime_io.get(), path, json_data);
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
    return html_opening and
        (std.ascii.indexOfIgnoreCase(body, "cf-chl-") != null or
            std.ascii.indexOfIgnoreCase(body, "_cf_chl_opt") != null or
            hasChallengePagePath(body));
}

fn hasChallengePagePath(body: []const u8) bool {
    const prefix = "/cdn-cgi/challenge-platform/";
    var remaining = body;
    while (std.ascii.indexOfIgnoreCase(remaining, prefix)) |start| {
        remaining = remaining[start + prefix.len ..];
        const end = std.mem.indexOfAny(u8, remaining, " \t\r\n\"'<>\\?#") orelse remaining.len;
        const path = remaining[0..end];
        if (std.ascii.startsWithIgnoreCase(path, "orchestrate/chl_page/") or
            std.ascii.indexOfIgnoreCase(path, "/orchestrate/chl_page/") != null) return true;
    }
    return false;
}

test "challenge detection accepts HTML layouts while requiring positive markers" {
    for ([_][]const u8{
        "\xef\xbb\xbf <!DOCTYPE HTML><HTML><SCRIPT>window._cf_chl_opt = {};</SCRIPT></HTML>",
        " <!-- leading comment -->\n<!-- second comment --><HEAD><script src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script></HEAD>",
        "<HEAD><TITLE>Just a moment...</TITLE><META NAME='CF-CHL-WIDGET'></HEAD>",
        "<SCRIPT>window._cf_chl_opt = {};</SCRIPT>",
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
    if (!driver.enabled) return error.CloudflareSessionUnavailable;
    const home = common.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, shared_cache_relpath });
}

fn acquireSessionViaAllDriver(allocator: Allocator, domain: []const u8, challenge_url: []const u8) !Session {
    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .brave, .firefox, .vivaldi },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) return error.CloudflareSessionUnavailable;

    const headless = shouldLaunchHeadless();

    for (installs.items) |install| {
        var browser = driver.modern.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = headless,
            .args = &.{},
        }) catch continue;
        defer browser.deinit();

        var page = browser.page();
        page.navigate(challenge_url) catch continue;
        _ = browser.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 120_000 }) catch {};

        if (!headless) {
            std.log.info("cloudflare verification opened for {s}; complete challenge if prompted", .{challenge_url});
            clearTerminalScreen();
        }

        const deadline = common.compatMilliTimestamp() + challenge_timeout_ms;
        var storage = browser.storage();
        while (common.compatMilliTimestamp() < deadline) {
            const browser_cookies = storage.getCookies(allocator) catch break;
            defer storage.freeCookies(allocator, browser_cookies);
            const cookies = try cloneBrowserCookiesForHost(allocator, browser_cookies, domain);
            defer freeCookies(allocator, cookies);

            const cf_value = findCookieValueForUrl(cookies, challenge_url, "cf_clearance", common.compatUnixTimestamp()) orelse {
                common.sleepMilliseconds(@intCast(challenge_poll_interval_ms));
                continue;
            };

            const user_agent = try fetchUserAgent(allocator, &browser);
            errdefer allocator.free(user_agent);
            const csrf_token = try fetchCsrfToken(allocator, &browser);
            errdefer if (csrf_token) |value| allocator.free(value);
            const owned_cookies = try cloneCookies(allocator, cookies);
            errdefer freeCookies(allocator, owned_cookies);
            const owned_clearance = try allocator.dupe(u8, cf_value);
            errdefer allocator.free(owned_clearance);

            return .{
                .cookies = owned_cookies,
                .cf_clearance = owned_clearance,
                .user_agent = user_agent,
                .csrf_token = csrf_token,
                .acquired_at_unix = common.compatUnixTimestamp(),
                .generation = nextSessionGeneration(),
            };
        }
    }

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
        const domain = normalizeDomain(allocator, raw_domain) catch continue;
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

fn clearTerminalScreen() void {
    std.debug.print("\x1b[2J\x1b[H", .{});
}

fn fetchUserAgent(allocator: Allocator, browser: *driver.modern.ModernSession) ![]const u8 {
    if (try evaluateAsString(allocator, browser, "(function(){return navigator.userAgent || '';})();")) |ua| {
        if (ua.len > 0) return ua;
        allocator.free(ua);
    }
    return allocator.dupe(u8, fallback_user_agent);
}

fn fetchCsrfToken(allocator: Allocator, browser: *driver.modern.ModernSession) !?[]const u8 {
    const script =
        "(function(){" ++
        "const el=document.querySelector(\"meta[name='csrf-token']\");" ++
        "return el ? (el.getAttribute('content') || '') : '';" ++
        "})();";

    if (try evaluateAsString(allocator, browser, script)) |token| {
        if (token.len == 0 or std.mem.eql(u8, token, "string")) {
            allocator.free(token);
            return null;
        }
        return token;
    }
    return null;
}

fn evaluateAsString(allocator: Allocator, browser: *driver.modern.ModernSession, script: []const u8) !?[]const u8 {
    var runtime = browser.runtime();
    const payload = runtime.evaluate(script) catch return null;
    defer allocator.free(payload);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
        const trimmed = std.mem.trim(u8, payload, " \t\r\n\"");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    };
    defer parsed.deinit();

    return try extractEvaluatedString(allocator, parsed.value);
}

fn extractEvaluatedString(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    switch (value) {
        .string => |s| {
            if (s.len == 0) return null;
            return try allocator.dupe(u8, s);
        },
        .object => |obj| {
            if (obj.get("value")) |nested| {
                if (try extractEvaluatedString(allocator, nested)) |s| return s;
            }
            if (obj.get("result")) |result| {
                if (try extractEvaluatedString(allocator, result)) |s| return s;
            }
            if (obj.get("data")) |data| {
                if (try extractEvaluatedString(allocator, data)) |s| return s;
            }
            if (obj.get("payload")) |payload| {
                if (try extractEvaluatedString(allocator, payload)) |s| return s;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (try extractEvaluatedString(allocator, item)) |s| return s;
            }
        },
        else => {},
    }

    return null;
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
    const target = parseCookieRequestTarget(url) orelse return false;
    return target.secure and std.ascii.eqlIgnoreCase(target.host, expected_host);
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
    for (cookies) |cookie| {
        if (!std.ascii.eqlIgnoreCase(cookie.name, wanted_name)) continue;
        if (!cookieAppliesToTarget(cookie, target, now)) continue;
        return cookie.value;
    }
    return null;
}

fn findCookieValueByName(cookies: []const Cookie, wanted_name: []const u8) ?[]const u8 {
    for (cookies) |cookie| {
        if (std.ascii.eqlIgnoreCase(cookie.name, wanted_name)) return cookie.value;
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

fn shouldLaunchHeadless() bool {
    if (common.getenv("SUBDL_CF_HEADLESS")) |raw| {
        if (std.mem.eql(u8, raw, "1") or std.ascii.eqlIgnoreCase(raw, "true") or std.ascii.eqlIgnoreCase(raw, "yes")) return true;
        if (std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "false") or std.ascii.eqlIgnoreCase(raw, "no")) return false;
    }

    return common.getenv("DISPLAY") == null and common.getenv("WAYLAND_DISPLAY") == null;
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
        .csrf_token = null,
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
}

test "forced refresh only coalesces to a different cached generation" {
    const cookies = [_]Cookie{.{ .name = "cf_clearance", .value = "token", .domain = "example.com", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null }};
    const session: Session = .{
        .cookies = &cookies,
        .cf_clearance = "token",
        .user_agent = "fixture",
        .csrf_token = null,
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
        .csrf_token = null,
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

test "extract evaluated string prefers value over type label" {
    const allocator = std.testing.allocator;
    const json_text =
        \\{
        \\  "result": {
        \\    "type": "string",
        \\    "value": "csrf-real-token"
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const extracted = try extractEvaluatedString(allocator, parsed.value);
    try std.testing.expect(extracted != null);
    defer allocator.free(extracted.?);
    try std.testing.expectEqualStrings("csrf-real-token", extracted.?);
}

test "extract evaluated string does not return type marker alone" {
    const allocator = std.testing.allocator;
    const json_text =
        \\{
        \\  "result": {
        \\    "type": "string"
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const extracted = try extractEvaluatedString(allocator, parsed.value);
    try std.testing.expect(extracted == null);
}

fn checkRecordClone(allocator: Allocator) !void {
    const cookies = [_]Cookie{.{ .name = "cf_clearance", .value = "dummy", .domain = "fixture.invalid", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null }};
    const record = try dupRecord(allocator, "fixture.invalid", .{ .cookies = &cookies, .cf_clearance = "dummy", .user_agent = "fixture", .csrf_token = "dummy-csrf", .acquired_at_unix = 1, .generation = 1 });
    defer freeRecordFields(allocator, record);
    try std.testing.expectEqualStrings("fixture", record.user_agent);
}
test "session record cloning frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRecordClone, .{});
}
