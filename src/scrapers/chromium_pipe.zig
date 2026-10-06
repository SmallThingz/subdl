const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const runtime_io = @import("runtime_io");

const Allocator = std.mem.Allocator;
const cdp_operation_timeout_ms: i64 = 15_000;
const max_cdp_frame_bytes: usize = 1024 * 1024;
const max_cdp_command_bytes: usize = 64 * 1024;
const max_unsolicited_frames: usize = 256;
const max_cookie_count: usize = 4096;
const max_browser_path_bytes: usize = 4096;
const max_zero_length_reads: usize = 8;
const profile_cleanup_attempts: usize = 5;
const minimum_secure_chromium_major: u16 = 154;
const browser_path_env = "SUBDL_CHROMIUM_PATH";
const pipe_shell = "/bin/sh";
const pipe_shell_script = "exec 3<&0 4>&1 0</dev/null 1>/dev/null; exec \"$@\"";
const cloudflare_challenge_url = "https://challenges.cloudflare.com/";
const cloudflare_challenge_host = "challenges.cloudflare.com";
const secure_profile_preferences =
    \\{"profile":{"default_content_setting_values":{"local_network_access":2}}}
;

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    secure: bool,
    expires_unix_seconds: ?i64,
};

pub fn freeCookies(allocator: Allocator, cookies: []Cookie) void {
    for (cookies) |cookie| {
        allocator.free(cookie.name);
        allocator.free(cookie.value);
        allocator.free(cookie.domain);
        allocator.free(cookie.path);
    }
    allocator.free(cookies);
}

pub const ExecutableList = struct {
    items: [][]u8,

    pub fn deinit(self: *ExecutableList, allocator: Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn supportedOn(os_tag: std.Target.Os.Tag) bool {
    return os_tag == .linux;
}

pub fn discoverExecutables(allocator: Allocator, deadline_ms: i64) !ExecutableList {
    if (comptime !supportedOn(builtin.os.tag)) return error.BrowserAutomationUnavailable;
    if (!std.process.can_spawn) return error.BrowserAutomationUnavailable;
    try deadlineCheckpoint(deadline_ms);

    if (try common.getenvOwned(allocator, browser_path_env)) |configured| {
        defer allocator.free(configured);
        if (!validExecutablePath(configured)) return error.InvalidBrowserExecutable;
        const items = try allocator.alloc([]u8, 1);
        errdefer allocator.free(items);
        items[0] = try allocator.dupe(u8, configured);
        return .{ .items = items };
    }

    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .linux => &.{
            "/usr/bin/google-chrome-stable",
            "/usr/bin/google-chrome",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/usr/bin/microsoft-edge-stable",
            "/usr/bin/microsoft-edge",
            "/usr/bin/brave-browser",
            "/usr/bin/brave-browser-stable",
            "/usr/bin/vivaldi-stable",
            "/usr/bin/vivaldi",
            "/opt/google/chrome/chrome",
            "/opt/microsoft/msedge/msedge",
            "/opt/brave.com/brave/brave-browser",
            "/opt/brave-bin/brave",
            "/opt/vivaldi/vivaldi",
            "/snap/bin/chromium",
        },
        .macos => &.{
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi",
        },
        .freebsd => &.{
            "/usr/local/bin/chrome",
            "/usr/local/bin/chromium",
            "/usr/local/bin/brave-browser",
        },
        else => unreachable,
    };

    var found: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (found.items) |item| allocator.free(item);
        found.deinit(allocator);
    }
    for (candidates) |candidate| {
        try deadlineCheckpoint(deadline_ms);
        const owned = try allocator.dupe(u8, candidate);
        found.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    return .{ .items = try found.toOwnedSlice(allocator) };
}

fn validExecutablePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_browser_path_bytes or !std.fs.path.isAbsolute(path)) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

const RequestDecision = enum {
    allow,
    block,
    abort,
};

const FetchPattern = struct {
    urlPattern: []const u8 = "*",
    requestStage: []const u8 = "Request",
};

pub const NavigationPolicy = struct {
    origin_host: []const u8,
    resolver_rules: []const u8,

    pub fn create(allocator: Allocator, challenge_url: []const u8, deadline_ms: i64) !NavigationPolicy {
        try deadlineCheckpoint(deadline_ms);
        try common.validatePublicHttpUrl(challenge_url);
        const uri = std.Uri.parse(challenge_url) catch return error.InvalidBrowserNavigation;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or
            (uri.port != null and uri.port.? != 443) or
            uri.user != null or uri.password != null)
        {
            return error.InvalidBrowserNavigation;
        }

        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_name = uri.getHost(&host_buffer) catch return error.InvalidBrowserNavigation;
        const host = host_name.bytes;
        if (!validResolverHost(host)) return error.InvalidBrowserNavigation;
        const origin_host = try allocator.dupe(u8, host);
        errdefer allocator.free(origin_host);

        const origin_ip = try common.resolvePublicHttpIpv4(allocator, runtime_io.get(), challenge_url, deadline_ms);
        try deadlineCheckpoint(deadline_ms);
        const cloudflare_ip = if (std.ascii.eqlIgnoreCase(host, cloudflare_challenge_host))
            origin_ip
        else
            try common.resolvePublicHttpIpv4(allocator, runtime_io.get(), cloudflare_challenge_url, deadline_ms);
        try deadlineCheckpoint(deadline_ms);

        const resolver_rules = if (std.ascii.eqlIgnoreCase(host, cloudflare_challenge_host))
            try std.fmt.allocPrint(
                allocator,
                "MAP {s} {d}.{d}.{d}.{d}, MAP * ~NOTFOUND",
                .{ host, origin_ip[0], origin_ip[1], origin_ip[2], origin_ip[3] },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "MAP {s} {d}.{d}.{d}.{d}, MAP {s} {d}.{d}.{d}.{d}, MAP * ~NOTFOUND",
                .{
                    host,
                    origin_ip[0],
                    origin_ip[1],
                    origin_ip[2],
                    origin_ip[3],
                    cloudflare_challenge_host,
                    cloudflare_ip[0],
                    cloudflare_ip[1],
                    cloudflare_ip[2],
                    cloudflare_ip[3],
                },
            );
        return .{ .origin_host = origin_host, .resolver_rules = resolver_rules };
    }

    pub fn deinit(self: *NavigationPolicy, allocator: Allocator) void {
        allocator.free(self.origin_host);
        allocator.free(self.resolver_rules);
        self.* = undefined;
    }

    fn requestDecision(self: NavigationPolicy, url: []const u8, resource_type: []const u8) RequestDecision {
        if (std.mem.eql(u8, url, "about:blank") or
            std.mem.startsWith(u8, url, "data:") or
            std.mem.startsWith(u8, url, "blob:")) return .allow;

        const uri = std.Uri.parse(url) catch return .abort;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "https") and
            (uri.port == null or uri.port.? == 443) and
            uri.user == null and uri.password == null)
        {
            var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
            const host_name = uri.getHost(&host_buffer) catch return .abort;
            const host = host_name.bytes;
            if (std.ascii.eqlIgnoreCase(host, self.origin_host) or
                std.ascii.eqlIgnoreCase(host, cloudflare_challenge_host)) return .allow;
        }

        common.validatePublicHttpUrl(url) catch return .abort;
        return if (std.mem.eql(u8, resource_type, "Document")) .abort else .block;
    }
};

fn validResolverHost(host: []const u8) bool {
    if (host.len == 0 or host.len > std.Io.net.HostName.max_len) return false;
    for (host) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.')) return false;
    }
    return std.mem.indexOfScalar(u8, host, '.') != null;
}

const SecureProfile = struct {
    path: []u8,

    fn create(allocator: Allocator) !SecureProfile {
        if (comptime !supportedOn(builtin.os.tag) or
            !@hasDecl(std.Io.File.Permissions, "fromMode") or
            !@hasDecl(std.Io.File.Permissions, "toMode"))
        {
            return error.BrowserAutomationUnavailable;
        }

        const io = runtime_io.get();
        const permissions = std.Io.File.Permissions.fromMode(0o700);
        var attempt: usize = 0;
        while (attempt < 32) : (attempt += 1) {
            var nonce: [16]u8 = undefined;
            try io.randomSecure(&nonce);
            var nonce_hex: [nonce.len * 2]u8 = undefined;
            const digits = "0123456789abcdef";
            for (nonce, 0..) |byte, index| {
                nonce_hex[index * 2] = digits[byte >> 4];
                nonce_hex[index * 2 + 1] = digits[byte & 0x0f];
            }
            const path = try std.fmt.allocPrint(allocator, "/tmp/subdl-browser-{s}", .{&nonce_hex});
            errdefer allocator.free(path);
            std.Io.Dir.cwd().createDir(io, path, permissions) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(path);
                    continue;
                },
                else => return err,
            };
            errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};

            const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
            if (stat.kind != .directory or stat.permissions.toMode() & 0o077 != 0)
                return error.BrowserAutomationFailed;

            const default_path = try std.fs.path.join(allocator, &.{ path, "Default" });
            defer allocator.free(default_path);
            try std.Io.Dir.cwd().createDir(io, default_path, permissions);
            const preferences_path = try std.fs.path.join(allocator, &.{ default_path, "Preferences" });
            defer allocator.free(preferences_path);
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = preferences_path,
                .data = secure_profile_preferences,
                .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
            });
            return .{ .path = path };
        }
        return error.BrowserAutomationFailed;
    }

    fn deinit(self: *SecureProfile, allocator: Allocator, deadline_ms: i64) void {
        const io = runtime_io.get();
        var last_error: ?anyerror = null;
        var attempt: usize = 0;
        while (attempt < profile_cleanup_attempts) : (attempt += 1) {
            if (attempt > 0 and common.compatMilliTimestamp() >= deadline_ms) break;
            std.Io.Dir.cwd().deleteTree(io, self.path) catch |err| {
                last_error = err;
                const now = common.compatMilliTimestamp();
                if (attempt + 1 >= profile_cleanup_attempts or now >= deadline_ms) break;
                const pause_ms: u64 = @intCast(@min(@as(i64, 100), deadline_ms - now));
                common.sleepMillisecondsCancelable(pause_ms) catch break;
                if (common.compatMilliTimestamp() >= deadline_ms) break;
                continue;
            };
            last_error = null;
            break;
        }
        if (last_error) |err| {
            std.log.warn("failed to remove temporary browser profile ({s})", .{@errorName(err)});
        }
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Browser = struct {
    allocator: Allocator,
    child: std.process.Child,
    profile: SecureProfile,
    navigation_policy: *const NavigationPolicy,
    read_buffer: []u8,
    read_len: usize = 0,
    next_command_id: u64 = 1,
    session_id: ?[]u8 = null,
    deadline_ms: i64,

    pub fn launch(
        allocator: Allocator,
        executable: []const u8,
        navigation_policy: *const NavigationPolicy,
        headless: bool,
        deadline_ms: i64,
    ) !Browser {
        if (comptime !supportedOn(builtin.os.tag)) return error.BrowserAutomationUnavailable;
        try deadlineCheckpoint(deadline_ms);
        if (!validExecutablePath(executable)) return error.InvalidBrowserExecutable;
        var browser = try spawnBrowser(allocator, executable, navigation_policy, headless, deadline_ms);
        errdefer browser.deinit();
        try browser.initialize(deadline_ms);
        try deadlineCheckpoint(deadline_ms);
        return browser;
    }

    pub fn deinit(self: *Browser) void {
        killProcessTree(&self.child);
        self.profile.deinit(self.allocator, self.deadline_ms);
        if (self.session_id) |session_id| self.allocator.free(session_id);
        self.allocator.free(self.read_buffer);
        self.* = undefined;
    }

    fn initialize(self: *Browser, deadline_ms: i64) !void {
        const response = try self.sendCommand("Browser.getVersion", .{}, deadline_ms);
        defer self.allocator.free(response);
        const product = try extractResultString(self.allocator, response, "product");
        defer self.allocator.free(product);
        if (!supportedChromiumProduct(product)) return error.BrowserSecurityFeaturesUnavailable;
        const user_agent = try extractResultString(self.allocator, response, "userAgent");
        self.allocator.free(user_agent);
    }

    pub fn navigate(self: *Browser, url: []const u8, deadline_ms: i64) !void {
        if (self.navigation_policy.requestDecision(url, "Document") != .allow)
            return error.UnsafeBrowserNavigation;

        const create_response = try self.sendCommand("Target.createTarget", .{ .url = "about:blank" }, deadline_ms);
        defer self.allocator.free(create_response);
        const target_id = try extractResultString(self.allocator, create_response, "targetId");
        defer self.allocator.free(target_id);

        const activate_response = try self.sendCommand("Target.activateTarget", .{ .targetId = target_id }, deadline_ms);
        self.allocator.free(activate_response);

        const attach_response = try self.sendCommand("Target.attachToTarget", .{
            .targetId = target_id,
            .flatten = true,
        }, deadline_ms);
        defer self.allocator.free(attach_response);
        const session_id = try extractResultString(self.allocator, attach_response, "sessionId");
        if (self.session_id) |old_session_id| self.allocator.free(old_session_id);
        self.session_id = session_id;

        const patterns = [_]FetchPattern{.{}};
        const enable_response = try self.sendSessionCommand(session_id, "Fetch.enable", .{
            .patterns = &patterns,
        }, deadline_ms);
        self.allocator.free(enable_response);

        const navigate_response = try self.sendSessionCommand(session_id, "Page.navigate", .{ .url = url }, deadline_ms);
        defer self.allocator.free(navigate_response);
        if (try resultHasNonEmptyString(self.allocator, navigate_response, "errorText"))
            return error.BrowserNavigationFailed;
    }

    pub fn getCookiesForUrl(self: *Browser, allocator: Allocator, url: []const u8, deadline_ms: i64) ![]Cookie {
        const session_id = self.session_id orelse return error.BrowserTargetUnavailable;
        const response = try self.sendSessionCommand(session_id, "Network.getCookies", .{
            .urls = &[_][]const u8{url},
        }, deadline_ms);
        defer self.allocator.free(response);
        return parseCookies(allocator, response);
    }

    pub fn getUserAgent(self: *Browser, allocator: Allocator, deadline_ms: i64) ![]u8 {
        const response = try self.sendCommand("Browser.getVersion", .{}, deadline_ms);
        defer self.allocator.free(response);
        return extractResultString(allocator, response, "userAgent");
    }

    fn sendCommand(
        self: *Browser,
        method: []const u8,
        params: anytype,
        deadline_ms: i64,
    ) ![]u8 {
        return self.sendCommandOnSession(null, method, params, deadline_ms);
    }

    fn sendSessionCommand(
        self: *Browser,
        session_id: []const u8,
        method: []const u8,
        params: anytype,
        deadline_ms: i64,
    ) ![]u8 {
        return self.sendCommandOnSession(session_id, method, params, deadline_ms);
    }

    fn sendCommandOnSession(
        self: *Browser,
        session_id: ?[]const u8,
        method: []const u8,
        params: anytype,
        deadline_ms: i64,
    ) ![]u8 {
        try deadlineCheckpoint(deadline_ms);
        const timeout = try operationTimeout(deadline_ms);
        const command_id = try self.writeCommand(session_id, method, params, timeout);

        var unsolicited: usize = 0;
        while (unsolicited < max_unsolicited_frames) : (unsolicited += 1) {
            const frame = try self.readFrameWithTimeout(timeout);
            defer self.allocator.free(frame);
            if (frame.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{}) catch |err| {
                if (err == error.OutOfMemory) return err;
                return error.InvalidBrowserResponse;
            };
            defer parsed.deinit();
            const root = switch (parsed.value) {
                .object => |object| object,
                else => return error.InvalidBrowserResponse,
            };
            if (try self.handleFetchRequest(root, timeout)) continue;
            const response_id = responseId(root.get("id") orelse continue) orelse
                return error.InvalidBrowserResponse;
            if (response_id != command_id) continue;
            if (!responseSessionMatches(root, session_id)) return error.InvalidBrowserResponse;
            if (root.get("error") != null) return error.BrowserProtocolError;
            if (root.get("result") == null) return error.InvalidBrowserResponse;
            return self.allocator.dupe(u8, frame);
        }
        return error.TooManyBrowserEvents;
    }

    fn writeCommand(
        self: *Browser,
        session_id: ?[]const u8,
        method: []const u8,
        params: anytype,
        timeout: std.Io.Timeout,
    ) !u64 {
        const command_id = self.next_command_id;
        self.next_command_id +%= 1;
        if (self.next_command_id == 0) self.next_command_id = 1;

        const command = if (session_id) |target_session_id|
            try std.fmt.allocPrint(self.allocator, "{f}\x00", .{std.json.fmt(.{
                .id = command_id,
                .method = method,
                .params = params,
                .sessionId = target_session_id,
            }, .{})})
        else
            try std.fmt.allocPrint(self.allocator, "{f}\x00", .{std.json.fmt(.{
                .id = command_id,
                .method = method,
                .params = params,
            }, .{})});
        defer self.allocator.free(command);
        if (command.len > max_cdp_command_bytes) return error.BrowserCommandTooLarge;
        try writeWithTimeout(self.child.stdin.?, command, timeout);
        return command_id;
    }

    fn handleFetchRequest(self: *Browser, root: std.json.ObjectMap, timeout: std.Io.Timeout) !bool {
        const method_value = root.get("method") orelse return false;
        const method = switch (method_value) {
            .string => |value| value,
            else => return error.InvalidBrowserResponse,
        };
        if (!std.mem.eql(u8, method, "Fetch.requestPaused")) return false;

        const session_id = self.session_id orelse return error.InvalidBrowserResponse;
        if (!responseSessionMatches(root, session_id)) return error.InvalidBrowserResponse;
        const params = switch (root.get("params") orelse return error.InvalidBrowserResponse) {
            .object => |object| object,
            else => return error.InvalidBrowserResponse,
        };
        const request_id = try requiredString(params, "requestId");
        const request = switch (params.get("request") orelse return error.InvalidBrowserResponse) {
            .object => |object| object,
            else => return error.InvalidBrowserResponse,
        };
        const url = try requiredString(request, "url");
        const resource_type = if (params.get("resourceType")) |value| switch (value) {
            .string => |text| text,
            else => return error.InvalidBrowserResponse,
        } else "Document";

        switch (self.navigation_policy.requestDecision(url, resource_type)) {
            .allow => {
                _ = try self.writeCommand(session_id, "Fetch.continueRequest", .{
                    .requestId = request_id,
                }, timeout);
            },
            .block, .abort => |decision| {
                _ = try self.writeCommand(session_id, "Fetch.failRequest", .{
                    .requestId = request_id,
                    .errorReason = "BlockedByClient",
                }, timeout);
                if (decision == .abort) return error.UnsafeBrowserNavigation;
            },
        }
        return true;
    }

    fn readFrameWithTimeout(self: *Browser, timeout: std.Io.Timeout) ![]u8 {
        var zero_length_reads: usize = 0;
        while (true) {
            if (try takeBufferedFrame(self.allocator, self.read_buffer, &self.read_len)) |frame| return frame;

            var vectors = [_][]u8{self.read_buffer[self.read_len..]};
            const result = std.Io.operateTimeout(runtime_io.get(), .{
                .file_read_streaming = .{
                    .file = self.child.stdout.?,
                    .data = &vectors,
                },
            }, timeout) catch |err| return mapTimedOperationError(err);
            const bytes_read = switch (result) {
                .file_read_streaming => |read_result| read_result catch |err| switch (err) {
                    error.EndOfStream => return error.BrowserPipeClosed,
                    error.WouldBlock => continue,
                    else => return err,
                },
                else => unreachable,
            };
            if (bytes_read == 0) {
                zero_length_reads += 1;
                if (zero_length_reads >= max_zero_length_reads) return error.BrowserPipeClosed;
                continue;
            }
            zero_length_reads = 0;
            self.read_len += bytes_read;
        }
    }
};

fn takeBufferedFrame(allocator: Allocator, buffer: []u8, read_len: *usize) !?[]u8 {
    if (std.mem.indexOfScalar(u8, buffer[0..read_len.*], 0)) |delimiter| {
        const frame = try allocator.dupe(u8, buffer[0..delimiter]);
        const remaining = buffer[delimiter + 1 .. read_len.*];
        @memmove(buffer[0..remaining.len], remaining);
        read_len.* = remaining.len;
        return frame;
    }
    if (read_len.* == buffer.len) return error.BrowserResponseTooLarge;
    return null;
}

fn spawnBrowser(
    allocator: Allocator,
    executable: []const u8,
    navigation_policy: *const NavigationPolicy,
    headless: bool,
    deadline_ms: i64,
) !Browser {
    var profile = try SecureProfile.create(allocator);
    errdefer profile.deinit(allocator, deadline_ms);
    const profile_arg = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{profile.path});
    defer allocator.free(profile_arg);
    const resolver_arg = try std.fmt.allocPrint(allocator, "--host-resolver-rules={s}", .{navigation_policy.resolver_rules});
    defer allocator.free(resolver_arg);

    var argv_storage: [24][]const u8 = undefined;
    var count: usize = 0;
    argv_storage[count] = pipe_shell;
    count += 1;
    argv_storage[count] = "-c";
    count += 1;
    argv_storage[count] = pipe_shell_script;
    count += 1;
    argv_storage[count] = "subdl-chromium-pipe";
    count += 1;
    argv_storage[count] = executable;
    count += 1;
    if (headless) {
        argv_storage[count] = "--headless=new";
        count += 1;
    }
    argv_storage[count] = "--no-first-run";
    count += 1;
    argv_storage[count] = "--no-default-browser-check";
    count += 1;
    argv_storage[count] = "--disable-default-apps";
    count += 1;
    argv_storage[count] = "--disable-background-networking";
    count += 1;
    argv_storage[count] = "--disable-component-update";
    count += 1;
    argv_storage[count] = "--no-proxy-server";
    count += 1;
    argv_storage[count] = "--enable-features=LocalNetworkAccessChecks,LocalNetworkAccessForNavigations,LocalNetworkAccessForSubframeNavigations,LocalNetworkAccessForWorkers,LocalNetworkAccessChecksWebSockets,LocalNetworkAccessChecksWebTransport,LocalNetworkAccessChecksWebRTC";
    count += 1;
    argv_storage[count] = resolver_arg;
    count += 1;
    argv_storage[count] = "--remote-debugging-pipe";
    count += 1;
    argv_storage[count] = profile_arg;
    count += 1;
    argv_storage[count] = "about:blank";
    count += 1;

    var child = try std.process.spawn(runtime_io.get(), .{
        .argv = argv_storage[0..count],
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    errdefer killProcessTree(&child);
    if (child.stdin) |*file| try setPipeNonblocking(file) else return error.BrowserPipeClosed;
    if (child.stdout) |*file| try setPipeNonblocking(file) else return error.BrowserPipeClosed;
    const read_buffer = try allocator.alloc(u8, max_cdp_frame_bytes + 1);
    errdefer allocator.free(read_buffer);

    return .{
        .allocator = allocator,
        .child = child,
        .profile = profile,
        .navigation_policy = navigation_policy,
        .read_buffer = read_buffer,
        .deadline_ms = deadline_ms,
    };
}

fn setPipeNonblocking(file: *std.Io.File) !void {
    const FlagInt = std.meta.Int(.unsigned, @bitSizeOf(std.posix.O));
    const current: FlagInt = while (true) {
        const result = std.posix.system.fcntl(file.handle, std.posix.F.GETFL, @as(c_int, 0));
        switch (std.posix.errno(result)) {
            .SUCCESS => break @intCast(result),
            .INTR => continue,
            else => return error.BrowserPipeConfigurationFailed,
        }
    };
    var flags: std.posix.O = @bitCast(current);
    flags.NONBLOCK = true;
    const updated: FlagInt = @bitCast(flags);
    while (true) {
        const result = std.posix.system.fcntl(file.handle, std.posix.F.SETFL, @as(usize, @intCast(updated)));
        switch (std.posix.errno(result)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.BrowserPipeConfigurationFailed,
        }
    }
    file.flags.nonblocking = true;
}

fn killProcessTree(child: *std.process.Child) void {
    if (comptime supportedOn(builtin.os.tag)) {
        if (child.id) |pid| {
            if (pid > 0) {
                std.posix.kill(-pid, .KILL) catch {
                    // If process-group signaling fails, kill the owned child
                    // directly before Child.kill performs its blocking reap.
                    std.posix.kill(pid, .KILL) catch {};
                };
            }
        }
    }
    child.kill(runtime_io.get());
}

fn responseId(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch null,
        .float => |number| blk: {
            if (!std.math.isFinite(number) or number < 0 or @floor(number) != number or
                number >= 0x1p64) break :blk null;
            break :blk @intFromFloat(number);
        },
        else => null,
    };
}

fn responseSessionMatches(root: std.json.ObjectMap, expected: ?[]const u8) bool {
    const actual = root.get("sessionId");
    if (expected) |expected_session| {
        const actual_session = switch (actual orelse return false) {
            .string => |value| value,
            else => return false,
        };
        return std.mem.eql(u8, actual_session, expected_session);
    }
    return actual == null;
}

fn supportedChromiumProduct(product: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, product, '/') orelse return false;
    const family = product[0..slash];
    if (!std.ascii.eqlIgnoreCase(family, "Chrome") and
        !std.ascii.eqlIgnoreCase(family, "Chromium")) return false;
    const version = product[slash + 1 ..];
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse version.len;
    if (dot == 0) return false;
    const major = std.fmt.parseInt(u16, version[0..dot], 10) catch return false;
    return major >= minimum_secure_chromium_major;
}

fn extractResultString(allocator: Allocator, payload: []const u8, field: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidBrowserResponse;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidBrowserResponse,
    };
    const result_value = root.get("result") orelse return error.InvalidBrowserResponse;
    const result = switch (result_value) {
        .object => |object| object,
        else => return error.InvalidBrowserResponse,
    };
    const value = result.get(field) orelse return error.InvalidBrowserResponse;
    const text = switch (value) {
        .string => |string| string,
        else => return error.InvalidBrowserResponse,
    };
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null)
        return error.InvalidBrowserResponse;
    return allocator.dupe(u8, text);
}

fn resultHasNonEmptyString(allocator: Allocator, payload: []const u8, field: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidBrowserResponse;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidBrowserResponse,
    };
    const result = switch (root.get("result") orelse return error.InvalidBrowserResponse) {
        .object => |object| object,
        else => return error.InvalidBrowserResponse,
    };
    const value = result.get(field) orelse return false;
    return switch (value) {
        .string => |text| text.len != 0,
        else => error.InvalidBrowserResponse,
    };
}

pub fn parseCookies(allocator: Allocator, payload: []const u8) ![]Cookie {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidBrowserResponse;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidBrowserResponse,
    };
    const result_value = root.get("result") orelse return error.InvalidBrowserResponse;
    const result = switch (result_value) {
        .object => |object| object,
        else => return error.InvalidBrowserResponse,
    };
    const cookies_value = result.get("cookies") orelse return error.InvalidBrowserResponse;
    const cookies_json = switch (cookies_value) {
        .array => |array| array,
        else => return error.InvalidBrowserResponse,
    };
    if (cookies_json.items.len > max_cookie_count) return error.InvalidBrowserResponse;

    var cookies: std.ArrayListUnmanaged(Cookie) = .empty;
    errdefer freeCookieList(allocator, &cookies);
    for (cookies_json.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => return error.InvalidBrowserResponse,
        };
        const name = try requiredString(object, "name");
        const value = try requiredString(object, "value");
        const domain = try requiredString(object, "domain");
        const path = try requiredString(object, "path");
        const secure = try requiredBool(object, "secure");
        const expires = try optionalExpiration(object.get("expires"));

        const cookie = Cookie{
            .name = try allocator.dupe(u8, name),
            .value = undefined,
            .domain = undefined,
            .path = undefined,
            .secure = secure,
            .expires_unix_seconds = expires,
        };
        var owned = cookie;
        errdefer allocator.free(owned.name);
        owned.value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned.value);
        owned.domain = try allocator.dupe(u8, domain);
        errdefer allocator.free(owned.domain);
        owned.path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned.path);
        try cookies.append(allocator, owned);
    }
    return cookies.toOwnedSlice(allocator);
}

fn freeCookieList(allocator: Allocator, cookies: *std.ArrayListUnmanaged(Cookie)) void {
    for (cookies.items) |cookie| {
        allocator.free(cookie.name);
        allocator.free(cookie.value);
        allocator.free(cookie.domain);
        allocator.free(cookie.path);
    }
    cookies.deinit(allocator);
    cookies.* = .empty;
}

fn requiredString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidBrowserResponse;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidBrowserResponse,
    };
}

fn requiredBool(object: std.json.ObjectMap, field: []const u8) !bool {
    const value = object.get(field) orelse return error.InvalidBrowserResponse;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidBrowserResponse,
    };
}

fn optionalExpiration(value_opt: ?std.json.Value) !?i64 {
    const value = value_opt orelse return null;
    const seconds: i64 = switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch
            return error.InvalidBrowserResponse,
        .float => |number| blk: {
            if (!std.math.isFinite(number) or
                number < -0x1p63 or number >= 0x1p63)
                return error.InvalidBrowserResponse;
            break :blk @intFromFloat(@floor(number));
        },
        else => return error.InvalidBrowserResponse,
    };
    return if (seconds > 0) seconds else null;
}

fn deadlineCheckpoint(deadline_ms: i64) !void {
    try std.Io.checkCancel(runtime_io.get());
    if (common.compatMilliTimestamp() >= deadline_ms) return error.BrowserOperationTimeout;
}

fn operationDelay(deadline_ms: i64) !u64 {
    try deadlineCheckpoint(deadline_ms);
    const remaining = deadline_ms - common.compatMilliTimestamp();
    if (remaining <= 0) return error.BrowserOperationTimeout;
    return @intCast(@min(remaining, cdp_operation_timeout_ms));
}

fn operationTimeout(deadline_ms: i64) !std.Io.Timeout {
    const delay_ms = try operationDelay(deadline_ms);
    const duration: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(delay_ms)),
        .clock = .awake,
    };
    return .{ .deadline = std.Io.Clock.Timestamp.fromNow(runtime_io.get(), duration) };
}

fn mapTimedOperationError(err: anyerror) anyerror {
    return if (err == error.Timeout) error.BrowserOperationTimeout else err;
}

fn writeWithTimeout(file: std.Io.File, bytes: []const u8, timeout: std.Io.Timeout) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var vectors = [_][]const u8{bytes[offset..]};
        const result = std.Io.operateTimeout(runtime_io.get(), .{
            .file_write_streaming = .{
                .file = file,
                .data = &vectors,
                .splat = 1,
            },
        }, timeout) catch |err| return mapTimedOperationError(err);
        const bytes_written = switch (result) {
            .file_write_streaming => |write_result| write_result catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            },
            else => unreachable,
        };
        if (bytes_written == 0) return error.BrowserPipeClosed;
        offset += bytes_written;
    }
}

test "secure browser pipe support fails closed by platform" {
    try std.testing.expect(supportedOn(.linux));
    try std.testing.expect(!supportedOn(.macos));
    try std.testing.expect(!supportedOn(.freebsd));
    try std.testing.expect(!supportedOn(.windows));
    try std.testing.expect(!supportedOn(.wasi));
}

test "CDP response ids are exact nonnegative integers" {
    try std.testing.expectEqual(@as(?u64, 7), responseId(.{ .integer = 7 }));
    try std.testing.expectEqual(@as(?u64, 7), responseId(.{ .float = 7.0 }));
    try std.testing.expectEqual(@as(?u64, null), responseId(.{ .float = 7.5 }));
    try std.testing.expectEqual(@as(?u64, null), responseId(.{ .integer = -1 }));
    try std.testing.expectEqual(@as(?u64, null), responseId(.{ .float = 0x1p64 }));
}

test "Chromium version gate fails closed without verified LNA support" {
    try std.testing.expect(supportedChromiumProduct("Chrome/154.0.8037.98"));
    try std.testing.expect(supportedChromiumProduct("Chromium/155.1"));
    try std.testing.expect(!supportedChromiumProduct("Chrome/153.9"));
    try std.testing.expect(!supportedChromiumProduct("Brave/154.0"));
    try std.testing.expect(!supportedChromiumProduct("Chrome/not-a-version"));
}

test "browser navigation policy allows only pinned challenge origins" {
    const policy = NavigationPolicy{
        .origin_host = "provider.example.org",
        .resolver_rules = "",
    };
    try std.testing.expectEqual(RequestDecision.allow, policy.requestDecision("https://provider.example.org/challenge", "Document"));
    try std.testing.expectEqual(RequestDecision.allow, policy.requestDecision("https://challenges.cloudflare.com/turnstile/v0/api.js", "Script"));
    try std.testing.expectEqual(RequestDecision.allow, policy.requestDecision("data:text/plain,fixture", "Other"));
    try std.testing.expectEqual(RequestDecision.block, policy.requestDecision("https://www.google.com/image.png", "Image"));
    try std.testing.expectEqual(RequestDecision.abort, policy.requestDecision("https://www.google.com/redirect", "Document"));
    try std.testing.expectEqual(RequestDecision.abort, policy.requestDecision("http://provider.example.org/downgrade", "Document"));
    try std.testing.expectEqual(RequestDecision.abort, policy.requestDecision("http://127.0.0.1/private", "Image"));
    try std.testing.expectEqual(RequestDecision.abort, policy.requestDecision("https://user:pass@provider.example.org/private", "Image"));
}

test "resolver-rule hosts reject argument injection" {
    try std.testing.expect(validResolverHost("provider.example.org"));
    try std.testing.expect(!validResolverHost("localhost"));
    try std.testing.expect(!validResolverHost("provider.example.org, MAP * 127.0.0.1"));
    try std.testing.expect(!validResolverHost("provider.example.org\n--no-sandbox"));
}

test "CDP responses stay on their requested session" {
    var root_response = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"id\":1,\"result\":{}}", .{});
    defer root_response.deinit();
    try std.testing.expect(responseSessionMatches(root_response.value.object, null));
    try std.testing.expect(!responseSessionMatches(root_response.value.object, "session-a"));

    var session_response = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"id\":2,\"sessionId\":\"session-a\",\"result\":{}}", .{});
    defer session_response.deinit();
    try std.testing.expect(responseSessionMatches(session_response.value.object, "session-a"));
    try std.testing.expect(!responseSessionMatches(session_response.value.object, "session-b"));
    try std.testing.expect(!responseSessionMatches(session_response.value.object, null));
}

test "CDP framing handles split multiple and oversized frames" {
    const allocator = std.testing.allocator;
    var buffer: [32]u8 = undefined;
    @memcpy(buffer[0..3], "one");
    var read_len: usize = 3;
    try std.testing.expect((try takeBufferedFrame(allocator, &buffer, &read_len)) == null);

    @memcpy(buffer[read_len..][0..9], "\x00two\x00tail");
    read_len += 9;
    const first = (try takeBufferedFrame(allocator, &buffer, &read_len)).?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings("one", first);
    const second = (try takeBufferedFrame(allocator, &buffer, &read_len)).?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("two", second);
    try std.testing.expect((try takeBufferedFrame(allocator, &buffer, &read_len)) == null);
    try std.testing.expectEqualStrings("tail", buffer[0..read_len]);

    @memset(&buffer, 'x');
    read_len = buffer.len;
    try std.testing.expectError(error.BrowserResponseTooLarge, takeBufferedFrame(allocator, &buffer, &read_len));
}

test "CDP cookie parsing preserves scope and expiry data" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"id":3,"result":{"cookies":[
        \\  {"name":"cf_clearance","value":"token","domain":".example.com","path":"/download","secure":true,"expires":200.75},
        \\  {"name":"session","value":"value","domain":"www.example.com","path":"/","secure":false,"expires":-1}
        \\]}}
    ;
    const cookies = try parseCookies(allocator, payload);
    defer freeCookies(allocator, cookies);
    try std.testing.expectEqual(@as(usize, 2), cookies.len);
    try std.testing.expectEqualStrings("cf_clearance", cookies[0].name);
    try std.testing.expectEqual(@as(?i64, 200), cookies[0].expires_unix_seconds);
    try std.testing.expect(cookies[0].secure);
    try std.testing.expectEqual(@as(?i64, null), cookies[1].expires_unix_seconds);
}

fn checkCookieAllocationFailures(allocator: Allocator) !void {
    const payload =
        \\{"id":3,"result":{"cookies":[
        \\  {"name":"a","value":"b","domain":"example.com","path":"/","secure":true,"expires":200.5},
        \\  {"name":"c","value":"d","domain":".example.com","path":"/x","secure":false,"expires":-1}
        \\]}}
    ;
    const cookies = try parseCookies(allocator, payload);
    defer freeCookies(allocator, cookies);
}

test "CDP cookie parsing frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkCookieAllocationFailures, .{});
}

test "CDP numeric exponent boundaries fail closed" {
    try std.testing.expectError(error.InvalidBrowserResponse, optionalExpiration(.{ .float = 0x1p63 }));
    try std.testing.expectError(error.InvalidBrowserResponse, optionalExpiration(.{ .float = -0x1p63 - 2048 }));
    try std.testing.expectEqual(@as(?i64, null), try optionalExpiration(.{ .float = -0x1p63 }));
    try std.testing.expectError(
        error.InvalidBrowserResponse,
        parseCookies(std.testing.allocator, "{\"result\":{\"cookies\":[{\"name\":\"a\",\"value\":\"b\",\"domain\":\"example.com\",\"path\":\"/\",\"secure\":true,\"expires\":9.223372036854776e18}]}}"),
    );
}

test "configured browser paths are absolute bounded and control free" {
    try std.testing.expect(validExecutablePath("/usr/bin/chromium"));
    try std.testing.expect(!validExecutablePath("chromium"));
    try std.testing.expect(!validExecutablePath("/usr/bin/chromium\n--flag"));
    try std.testing.expect(!validExecutablePath("/" ++ ("x" ** max_browser_path_bytes)));
}

test "CDP payload extractors reject malformed envelopes" {
    const allocator = std.testing.allocator;
    const session = try extractResultString(allocator, "{\"id\":2,\"result\":{\"sessionId\":\"abc\"}}", "sessionId");
    defer allocator.free(session);
    try std.testing.expectEqualStrings("abc", session);
    try std.testing.expectError(
        error.InvalidBrowserResponse,
        extractResultString(allocator, "{\"id\":2,\"error\":{}}", "sessionId"),
    );
    try std.testing.expectError(error.InvalidBrowserResponse, parseCookies(allocator, "{\"result\":{\"cookies\":{}}}"));
}

test "opt-in local Chromium pipe smoke test" {
    const enabled = common.getenv("SUBDL_CHROMIUM_SMOKE") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    const executable = common.getenv("SUBDL_CHROMIUM_PATH") orelse return error.SkipZigTest;
    const deadline = common.compatMilliTimestamp() + 30_000;
    const challenge_url = "https://example.com/";
    var policy = try NavigationPolicy.create(std.testing.allocator, challenge_url, deadline);
    defer policy.deinit(std.testing.allocator);
    var browser = try Browser.launch(std.testing.allocator, executable, &policy, true, deadline);
    defer browser.deinit();
    try browser.navigate(challenge_url, deadline);
    const user_agent = try browser.getUserAgent(std.testing.allocator, deadline);
    defer std.testing.allocator.free(user_agent);
    try std.testing.expect(user_agent.len > 0);
    const cookies = try browser.getCookiesForUrl(std.testing.allocator, challenge_url, deadline);
    defer freeCookies(std.testing.allocator, cookies);
}
