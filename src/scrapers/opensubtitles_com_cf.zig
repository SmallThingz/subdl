const std = @import("std");
const driver = @import("alldriver");

const Allocator = std.mem.Allocator;
const opensubtitles_domain = "www.opensubtitles.com";
const opensubtitles_challenge_url = "https://www.opensubtitles.com/en";
const shared_cache_relpath = ".cache/subdl/cloudflare_shared_sessions.json";
const fallback_user_agent = "subdl-zig-scrapers/0.2 (+https://subdl.com)";
const session_ttl_seconds: i64 = 5 * 60 * 60;
const challenge_timeout_ms: i64 = 4 * 60 * 1000;
const challenge_poll_interval_ms: i64 = 1000;

pub const Error = error{
    CloudflareSessionUnavailable,
    BrowserAutomationFailed,
    InvalidSessionPayload,
};

pub const Session = struct {
    cookie_header: []const u8,
    cf_clearance: []const u8,
    user_agent: []const u8,
    csrf_token: ?[]const u8,
    acquired_at_unix: i64,

    pub fn isLikelyExpired(self: Session, now_unix: i64) bool {
        return now_unix - self.acquired_at_unix > session_ttl_seconds;
    }

    pub fn deinit(self: *Session, allocator: Allocator) void {
        allocator.free(self.cookie_header);
        allocator.free(self.cf_clearance);
        allocator.free(self.user_agent);
        if (self.csrf_token) |token| allocator.free(token);
        self.* = undefined;
    }
};

pub const EnsureOptions = struct {
    force_refresh: bool = false,
};

pub const EnsureDomainOptions = struct {
    domain: []const u8,
    challenge_url: ?[]const u8 = null,
    force_refresh: bool = false,
};

const CacheRecord = struct {
    domain: []const u8,
    cookie_header: []const u8,
    cf_clearance: []const u8,
    user_agent: []const u8,
    csrf_token: ?[]const u8,
    acquired_at_unix: i64,
};

pub fn ensureSession(allocator: Allocator, options: EnsureOptions) !Session {
    return ensureDomainSession(allocator, .{
        .domain = opensubtitles_domain,
        .challenge_url = opensubtitles_challenge_url,
        .force_refresh = options.force_refresh,
    });
}

pub fn ensureDomainSession(allocator: Allocator, options: EnsureDomainOptions) !Session {
    const normalized_domain = try normalizeDomain(allocator, options.domain);
    defer allocator.free(normalized_domain);

    var owned_challenge_url: ?[]u8 = null;
    defer if (owned_challenge_url) |url| allocator.free(url);

    const challenge_url = if (options.challenge_url) |url|
        url
    else blk: {
        owned_challenge_url = try std.fmt.allocPrint(allocator, "https://{s}/", .{normalized_domain});
        break :blk owned_challenge_url.?;
    };

    const now = std.time.timestamp();
    if (!options.force_refresh) {
        if (try loadSessionForDomain(allocator, normalized_domain)) |cached| {
            if (!cached.isLikelyExpired(now) and isUsableSession(cached)) return cached;
            var owned = cached;
            owned.deinit(allocator);
        }
    }

    const acquired = try acquireSessionViaAllDriver(allocator, normalized_domain, challenge_url);
    try saveSessionForDomain(allocator, normalized_domain, acquired);
    return acquired;
}

pub fn loadSession(allocator: Allocator) !?Session {
    return loadSessionForDomain(allocator, opensubtitles_domain);
}

pub fn saveSession(allocator: Allocator, session: Session) !void {
    try saveSessionForDomain(allocator, opensubtitles_domain, session);
}

fn isUsableSession(session: Session) bool {
    if (session.cf_clearance.len == 0) return false;
    if (session.user_agent.len == 0) return false;
    return std.mem.indexOf(u8, session.cookie_header, "cf_clearance=") != null;
}

fn loadSessionForDomain(allocator: Allocator, domain_input: []const u8) !?Session {
    const domain = try normalizeDomain(allocator, domain_input);
    defer allocator.free(domain);

    var records = try readCacheRecords(allocator);
    defer freeCacheRecords(allocator, &records);

    for (records.items) |record| {
        if (!std.ascii.eqlIgnoreCase(record.domain, domain)) continue;

        return .{
            .cookie_header = try allocator.dupe(u8, record.cookie_header),
            .cf_clearance = try allocator.dupe(u8, record.cf_clearance),
            .user_agent = try allocator.dupe(u8, record.user_agent),
            .csrf_token = if (record.csrf_token) |token|
                if (token.len > 0 and !std.mem.eql(u8, token, "string"))
                    try allocator.dupe(u8, token)
                else
                    null
            else
                null,
            .acquired_at_unix = record.acquired_at_unix,
        };
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
        freeRecordFields(allocator, record.*);
        record.* = try dupRecord(allocator, domain, session);
        try writeCacheRecords(allocator, records.items);
        return;
    }

    try records.append(allocator, try dupRecord(allocator, domain, session));
    try writeCacheRecords(allocator, records.items);
}

fn dupRecord(allocator: Allocator, domain: []const u8, session: Session) !CacheRecord {
    return .{
        .domain = try allocator.dupe(u8, domain),
        .cookie_header = try allocator.dupe(u8, session.cookie_header),
        .cf_clearance = try allocator.dupe(u8, session.cf_clearance),
        .user_agent = try allocator.dupe(u8, session.user_agent),
        .csrf_token = if (session.csrf_token) |token| try allocator.dupe(u8, token) else null,
        .acquired_at_unix = session.acquired_at_unix,
    };
}

fn freeRecordFields(allocator: Allocator, record: CacheRecord) void {
    allocator.free(record.domain);
    allocator.free(record.cookie_header);
    allocator.free(record.cf_clearance);
    allocator.free(record.user_agent);
    if (record.csrf_token) |token| allocator.free(token);
}

fn readCacheRecords(allocator: Allocator) !std.ArrayListUnmanaged(CacheRecord) {
    var records: std.ArrayListUnmanaged(CacheRecord) = .empty;
    errdefer freeCacheRecords(allocator, &records);

    const path = try cachePath(allocator);
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return records,
        else => return err,
    };
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidSessionPayload,
    };

    const sessions_val = root.get("sessions") orelse return records;
    const sessions = switch (sessions_val) {
        .array => |a| a,
        else => return error.InvalidSessionPayload,
    };

    for (sessions.items) |entry| {
        const obj = switch (entry) {
            .object => |o| o,
            else => continue,
        };

        const domain = try getString(obj, "domain");
        const cookie_header = try getString(obj, "cookie_header");
        const cf_clearance = if (obj.get("cf_clearance")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";
        const user_agent = try getString(obj, "user_agent");
        const csrf_token = if (obj.get("csrf_token")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;
        const acquired_at_unix = try getInt(obj, "acquired_at_unix");

        try records.append(allocator, .{
            .domain = try allocator.dupe(u8, domain),
            .cookie_header = try allocator.dupe(u8, cookie_header),
            .cf_clearance = try allocator.dupe(u8, cf_clearance),
            .user_agent = try allocator.dupe(u8, user_agent),
            .csrf_token = if (csrf_token) |token|
                if (token.len > 0 and !std.mem.eql(u8, token, "string"))
                    try allocator.dupe(u8, token)
                else
                    null
            else
                null,
            .acquired_at_unix = acquired_at_unix,
        });
    }

    return records;
}

fn writeCacheRecords(allocator: Allocator, records: []const CacheRecord) !void {
    const path = try cachePath(allocator);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    const json_data = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{
        .version = 1,
        .sessions = records,
    }, .{ .whitespace = .indent_2 })});
    defer allocator.free(json_data);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json_data });
}

fn freeCacheRecords(allocator: Allocator, records: *std.ArrayListUnmanaged(CacheRecord)) void {
    for (records.items) |record| {
        freeRecordFields(allocator, record);
    }
    records.deinit(allocator);
    records.* = .empty;
}

fn cachePath(allocator: Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
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
        }

        const deadline = std.time.milliTimestamp() + challenge_timeout_ms;
        var storage = browser.storage();
        while (std.time.milliTimestamp() < deadline) {
            const cookies = storage.getCookies(allocator) catch break;
            defer storage.freeCookies(allocator, cookies);

            const cf_value = findCookieValueForDomain(cookies, domain, "cf_clearance") orelse {
                std.Thread.sleep(@as(u64, @intCast(challenge_poll_interval_ms)) * std.time.ns_per_ms);
                continue;
            };

            const cookie_header = try buildCookieHeaderForDomain(allocator, cookies, domain);
            const user_agent = try fetchUserAgent(allocator, &browser);
            const csrf_token = try fetchCsrfToken(allocator, &browser);

            return .{
                .cookie_header = cookie_header,
                .cf_clearance = try allocator.dupe(u8, cf_value),
                .user_agent = user_agent,
                .csrf_token = csrf_token,
                .acquired_at_unix = std.time.timestamp(),
            };
        }
    }

    return error.CloudflareSessionUnavailable;
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

fn buildCookieHeaderForDomain(allocator: Allocator, cookies: anytype, domain: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var has_any = false;
    for (cookies) |cookie| {
        if (!cookieDomainMatches(cookie.domain, domain)) continue;
        if (has_any) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, cookie.name);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, cookie.value);
        has_any = true;
    }

    if (!has_any) {
        for (cookies) |cookie| {
            if (has_any) try out.appendSlice(allocator, "; ");
            try out.appendSlice(allocator, cookie.name);
            try out.append(allocator, '=');
            try out.appendSlice(allocator, cookie.value);
            has_any = true;
        }
    }

    if (!has_any) return error.CloudflareSessionUnavailable;
    return try out.toOwnedSlice(allocator);
}

fn findCookieValueForDomain(cookies: anytype, domain: []const u8, wanted_name: []const u8) ?[]const u8 {
    for (cookies) |cookie| {
        if (!std.ascii.eqlIgnoreCase(cookie.name, wanted_name)) continue;
        if (!cookieDomainMatches(cookie.domain, domain)) continue;
        return cookie.value;
    }
    return null;
}

fn cookieDomainMatches(cookie_domain_input: []const u8, target_domain_input: []const u8) bool {
    const cookie_domain = stripLeadingDots(cookie_domain_input);
    const target_domain = stripLeadingDots(target_domain_input);

    if (cookie_domain.len == 0 or target_domain.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(cookie_domain, target_domain)) return true;

    return isSameOrSubdomain(target_domain, cookie_domain) or isSameOrSubdomain(cookie_domain, target_domain);
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
    if (std.posix.getenv("SUBDL_CF_HEADLESS")) |raw| {
        if (std.mem.eql(u8, raw, "1") or std.ascii.eqlIgnoreCase(raw, "true") or std.ascii.eqlIgnoreCase(raw, "yes")) return true;
        if (std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "false") or std.ascii.eqlIgnoreCase(raw, "no")) return false;
    }

    return std.posix.getenv("DISPLAY") == null and std.posix.getenv("WAYLAND_DISPLAY") == null;
}

fn getString(obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const v = obj.get(field) orelse return error.InvalidSessionPayload;
    return switch (v) {
        .string => |s| s,
        else => error.InvalidSessionPayload,
    };
}

fn getInt(obj: std.json.ObjectMap, field: []const u8) !i64 {
    const v = obj.get(field) orelse return error.InvalidSessionPayload;
    return switch (v) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch error.InvalidSessionPayload,
        .float => |f| @intFromFloat(f),
        else => error.InvalidSessionPayload,
    };
}

test "session expiry heuristic" {
    const s: Session = .{
        .cookie_header = "",
        .cf_clearance = "",
        .user_agent = "",
        .csrf_token = null,
        .acquired_at_unix = 0,
    };
    try std.testing.expect(s.isLikelyExpired(60 * 60 * 6));
}

test "normalize domain" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeDomain(allocator, "https://WWW.Example.com:443/path?q=1");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("www.example.com", normalized);
}

test "cookie domain match" {
    try std.testing.expect(cookieDomainMatches(".example.com", "www.example.com"));
    try std.testing.expect(cookieDomainMatches("www.example.com", "example.com"));
    try std.testing.expect(!cookieDomainMatches("example.net", "example.com"));
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
