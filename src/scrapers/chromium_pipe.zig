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
const deny_download_behavior = "deny";
const block_new_web_contents_arg = "--block-new-web-contents";
const force_webrtc_ip_policy_arg = "--force-webrtc-ip-handling-policy=disable_non_proxied_udp";
const dead_proxy_server_arg = "--proxy-server=http://subdl-proxy.invalid:9";
const proxy_bypass_prefix = "--proxy-bypass-list=<-loopback>;";
const blocked_session_bus_socket = "blocked-session-bus";
const blocked_executable_path = "blocked-external-handlers";
const blocked_external_handler_script = "#!/bin/sh\nexit 1\n";
const EmptyCdpParams = struct {};
const secure_profile_preferences =
    \\{"profile":{"default_content_setting_values":{"local_network_access":2,"popups":2}},"webrtc":{"ip_handling_policy":"disable_non_proxied_udp"}}
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

const TargetFilterEntry = struct {
    type: []const u8 = "",
    exclude: bool = false,
};

const unexpected_target_filter = [_]TargetFilterEntry{
    .{ .type = "page" },
    .{ .exclude = true },
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

    fn allowsNavigation(self: NavigationPolicy, url: []const u8) bool {
        if (std.mem.eql(u8, url, "about:blank") or
            std.mem.startsWith(u8, url, "data:") or
            std.mem.startsWith(u8, url, "blob:")) return true;

        const uri = std.Uri.parse(url) catch return false;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "https") and
            (uri.port == null or uri.port.? == 443) and
            uri.user == null and uri.password == null)
        {
            var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
            const host_name = uri.getHost(&host_buffer) catch return false;
            const host = host_name.bytes;
            if (std.ascii.eqlIgnoreCase(host, self.origin_host) or
                std.ascii.eqlIgnoreCase(host, cloudflare_challenge_host)) return true;
        }
        return false;
    }

    fn allowsPageNavigation(self: NavigationPolicy, url: []const u8) bool {
        // Script URLs execute in the already-confined renderer and do not invoke
        // an OS protocol handler. Other non-network schemes must stay blocked.
        if (std.ascii.startsWithIgnoreCase(url, "javascript:") or
            std.ascii.eqlIgnoreCase(url, "about:srcdoc") or
            std.ascii.startsWithIgnoreCase(url, "about:blank#") or
            std.ascii.eqlIgnoreCase(url, "chrome-error://chromewebdata/")) return true;
        return self.allowsNavigation(url);
    }
};

fn validResolverHost(host: []const u8) bool {
    if (host.len == 0 or host.len > std.Io.net.HostName.max_len) return false;
    for (host) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.')) return false;
    }
    return std.mem.indexOfScalar(u8, host, '.') != null;
}

fn makeProxyBypassArg(allocator: Allocator, origin_host: []const u8) ![]u8 {
    if (!validResolverHost(origin_host)) return error.InvalidBrowserNavigation;
    return std.fmt.allocPrint(
        allocator,
        "{s}https://{s}:443;https://{s}:443",
        .{ proxy_bypass_prefix, origin_host, cloudflare_challenge_host },
    );
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
            errdefer {
                const protection = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(protection);
                std.Io.Dir.cwd().deleteTree(io, path) catch {};
            }

            const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
            if (stat.kind != .directory or stat.permissions.toMode() & 0o077 != 0)
                return error.BrowserAutomationFailed;

            const blocker_path = try std.fs.path.join(allocator, &.{ path, blocked_executable_path });
            defer allocator.free(blocker_path);
            try std.Io.Dir.cwd().createDir(io, blocker_path, permissions);
            inline for (.{ "xdg-email", "xdg-open" }) |helper| {
                const helper_path = try std.fs.path.join(allocator, &.{ blocker_path, helper });
                defer allocator.free(helper_path);
                try std.Io.Dir.cwd().writeFile(io, .{
                    .sub_path = helper_path,
                    .data = blocked_external_handler_script,
                    .flags = .{ .permissions = permissions },
                });
                // execvp may continue searching PATH after EACCES (for
                // example, when /tmp is mounted noexec). Prove this exact
                // blocker can execute before putting inherited PATH entries
                // behind it; otherwise browser launch must fail closed.
                try verifyExternalHandlerBlocker(helper_path);
            }

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
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
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

fn verifyExternalHandlerBlocker(path: []const u8) !void {
    const io = runtime_io.get();
    var child = std.process.spawn(io, .{
        .argv = &.{path},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => return error.BrowserAutomationFailed,
    };
    const term = child.wait(io) catch |err| {
        child.kill(io);
        return switch (err) {
            error.Canceled => err,
            else => error.BrowserAutomationFailed,
        };
    };
    switch (term) {
        .exited => |code| if (code != 1) return error.BrowserAutomationFailed,
        else => return error.BrowserAutomationFailed,
    }
}

pub const Browser = struct {
    allocator: Allocator,
    child: std.process.Child,
    profile: SecureProfile,
    navigation_policy: *const NavigationPolicy,
    read_buffer: []u8,
    read_len: usize = 0,
    next_command_id: u64 = 1,
    primary_target_id: ?[]u8 = null,
    session_id: ?[]u8 = null,
    downloads_denied: bool = false,
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
        if (self.primary_target_id) |target_id| self.allocator.free(target_id);
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

        const download_response = try self.sendCommand("Browser.setDownloadBehavior", .{
            .behavior = deny_download_behavior,
            .eventsEnabled = false,
        }, deadline_ms);
        self.allocator.free(download_response);
        self.downloads_denied = true;
    }

    pub fn navigate(self: *Browser, url: []const u8, deadline_ms: i64) !void {
        if (!self.downloads_denied) return error.BrowserSecurityFeaturesUnavailable;
        if (self.primary_target_id != null or self.session_id != null) return error.BrowserTargetUnavailable;
        if (!self.navigation_policy.allowsNavigation(url))
            return error.UnsafeBrowserNavigation;

        const target_id = try self.waitForInitialPageTarget(deadline_ms);
        self.primary_target_id = target_id;

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

        const page_response = try self.sendSessionCommand(session_id, "Page.enable", EmptyCdpParams{}, deadline_ms);
        self.allocator.free(page_response);

        const browser_auto_attach_response = try self.sendCommand("Target.setAutoAttach", .{
            .autoAttach = true,
            .waitForDebuggerOnStart = true,
            .flatten = true,
            .filter = &unexpected_target_filter,
        }, deadline_ms);
        self.allocator.free(browser_auto_attach_response);

        const auto_attach_response = try self.sendSessionCommand(session_id, "Target.setAutoAttach", .{
            .autoAttach = true,
            .waitForDebuggerOnStart = true,
            .flatten = true,
            .filter = &unexpected_target_filter,
        }, deadline_ms);
        self.allocator.free(auto_attach_response);

        // Keep challenge APIs and request scheduling native. The process-wide proxy,
        // resolver, WebRTC policy, and target rejection are the security boundary.
        const navigate_response = try self.sendSessionCommand(session_id, "Page.navigate", .{ .url = url }, deadline_ms);
        defer self.allocator.free(navigate_response);
        if (try resultHasNonEmptyString(self.allocator, navigate_response, "errorText"))
            return error.BrowserNavigationFailed;
    }

    fn waitForInitialPageTarget(self: *Browser, deadline_ms: i64) ![]u8 {
        while (true) {
            try deadlineCheckpoint(deadline_ms);
            const targets_response = try self.sendCommand("Target.getTargets", EmptyCdpParams{}, deadline_ms);
            defer self.allocator.free(targets_response);
            const target_id = extractInitialPageTargetId(self.allocator, targets_response) catch |err| switch (err) {
                error.BrowserTargetNotReady => {
                    try deadlineCheckpoint(deadline_ms);
                    const remaining_ms = deadline_ms - common.compatMilliTimestamp();
                    if (remaining_ms <= 0) return error.BrowserOperationTimeout;
                    try common.sleepMillisecondsCancelable(@intCast(@min(remaining_ms, 10)));
                    continue;
                },
                else => return err,
            };
            return target_id;
        }
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
            try self.validateBrowserEvent(root);
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

    /// Wait while continuing to inspect browser events. The Cloudflare caller
    /// uses this instead of sleeping so an external-protocol navigation is
    /// detected and the private browser is torn down immediately.
    pub fn waitForPolicyEvents(self: *Browser, delay_ms: u64, deadline_ms: i64) !void {
        try deadlineCheckpoint(deadline_ms);
        if (delay_ms == 0) return;
        const now = common.compatMilliTimestamp();
        const requested_deadline = std.math.add(i64, now, @intCast(@min(
            delay_ms,
            @as(u64, std.math.maxInt(i64)),
        ))) catch std.math.maxInt(i64);
        const wait_deadline = @min(deadline_ms, requested_deadline);

        var unsolicited: usize = 0;
        while (unsolicited < max_unsolicited_frames) : (unsolicited += 1) {
            if (common.compatMilliTimestamp() >= wait_deadline) return;
            const timeout = try operationTimeout(wait_deadline);
            const frame = self.readFrameWithTimeout(timeout) catch |err| switch (err) {
                error.BrowserOperationTimeout => return,
                else => return err,
            };
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
            if (root.get("id") != null) return error.InvalidBrowserResponse;
            try self.validateBrowserEvent(root);
        }
        return error.TooManyBrowserEvents;
    }

    fn validateBrowserEvent(self: *Browser, root: std.json.ObjectMap) !void {
        try self.rejectUnexpectedTarget(root);
        if (try pageNavigationEventUrl(root)) |url| {
            if (!self.navigation_policy.allowsPageNavigation(url))
                return error.UnsafeBrowserNavigation;
        }
    }

    fn rejectUnexpectedTarget(self: *Browser, root: std.json.ObjectMap) !void {
        const method_value = root.get("method") orelse return;
        const method = switch (method_value) {
            .string => |value| value,
            else => return error.InvalidBrowserResponse,
        };
        if (!std.mem.eql(u8, method, "Target.attachedToTarget")) return;

        const params = switch (root.get("params") orelse return error.InvalidBrowserResponse) {
            .object => |object| object,
            else => return error.InvalidBrowserResponse,
        };
        const attached_session_id = try requiredString(params, "sessionId");
        const target_info = switch (params.get("targetInfo") orelse return error.InvalidBrowserResponse) {
            .object => |object| object,
            else => return error.InvalidBrowserResponse,
        };
        const target_type = try requiredString(target_info, "type");
        const target_id = try requiredString(target_info, "targetId");
        if (self.primary_target_id) |primary_target_id| {
            if (std.mem.eql(u8, target_type, "page") and std.mem.eql(u8, target_id, primary_target_id)) {
                _ = attached_session_id;
                if (root.get("sessionId") != null)
                    return error.InvalidBrowserResponse;
                return;
            }
        }
        if (!std.mem.eql(u8, target_type, "page") and
            !std.mem.eql(u8, target_type, "worker") and
            !std.mem.eql(u8, target_type, "shared_worker") and
            !std.mem.eql(u8, target_type, "service_worker"))
        {
            return error.InvalidBrowserResponse;
        }
        return error.UnexpectedBrowserTarget;
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

fn pageNavigationEventUrl(root: std.json.ObjectMap) !?[]const u8 {
    const method_value = root.get("method") orelse return null;
    const method = switch (method_value) {
        .string => |value| value,
        else => return error.InvalidBrowserResponse,
    };
    const nested_frame = std.mem.eql(u8, method, "Page.frameNavigated");
    if (!std.mem.eql(u8, method, "Page.frameScheduledNavigation") and
        !std.mem.eql(u8, method, "Page.frameRequestedNavigation") and
        !std.mem.eql(u8, method, "Page.frameStartedNavigating") and
        !std.mem.eql(u8, method, "Page.navigatedWithinDocument") and
        !nested_frame and
        !std.mem.eql(u8, method, "Page.windowOpen")) return null;
    const params = switch (root.get("params") orelse return error.InvalidBrowserResponse) {
        .object => |object| object,
        else => return error.InvalidBrowserResponse,
    };
    if (!nested_frame) return try requiredString(params, "url");
    const frame = switch (params.get("frame") orelse return error.InvalidBrowserResponse) {
        .object => |object| object,
        else => return error.InvalidBrowserResponse,
    };
    return try requiredString(frame, "url");
}

fn makeBrowserEnvironment(allocator: Allocator, profile_path: []const u8) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(allocator);
    errdefer environment.deinit();
    for (std.mem.span(std.c.environ)) |entry_optional| {
        const entry_z = entry_optional orelse return error.InvalidBrowserEnvironment;
        const entry = std.mem.span(entry_z);
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse
            return error.InvalidBrowserEnvironment;
        if (separator == 0) return error.InvalidBrowserEnvironment;
        try environment.put(entry[0..separator], entry[separator + 1 ..]);
    }
    const blocked_path = try std.fs.path.join(allocator, &.{ profile_path, blocked_executable_path });
    defer allocator.free(blocked_path);
    const blocked_bus_path = try std.fs.path.join(allocator, &.{ profile_path, blocked_session_bus_socket });
    defer allocator.free(blocked_bus_path);
    const blocked_bus_address = try std.fmt.allocPrint(allocator, "unix:path={s}", .{blocked_bus_path});
    defer allocator.free(blocked_bus_address);
    const inherited_path = environment.get("PATH") orelse "";
    const confined_path = if (inherited_path.len == 0)
        try allocator.dupe(u8, blocked_path)
    else
        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ blocked_path, inherited_path });
    defer allocator.free(confined_path);
    // Chromium's Linux external-protocol path first tries the desktop portal,
    // then xdg-email/xdg-open. Shadow both helpers while retaining the inherited
    // PATH for distro browser wrappers and display utilities.
    try environment.put("DBUS_SESSION_BUS_ADDRESS", blocked_bus_address);
    try environment.put("DBUS_STARTER_ADDRESS", blocked_bus_address);
    try environment.put("DBUS_STARTER_BUS_TYPE", "session");
    try environment.put("PATH", confined_path);
    return environment;
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
    const proxy_bypass_arg = try makeProxyBypassArg(allocator, navigation_policy.origin_host);
    defer allocator.free(proxy_bypass_arg);
    var environment = try makeBrowserEnvironment(allocator, profile.path);
    defer environment.deinit();

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
    argv_storage[count] = dead_proxy_server_arg;
    count += 1;
    argv_storage[count] = proxy_bypass_arg;
    count += 1;
    argv_storage[count] = block_new_web_contents_arg;
    count += 1;
    argv_storage[count] = force_webrtc_ip_policy_arg;
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
        .environ_map = &environment,
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

fn extractInitialPageTargetId(allocator: Allocator, payload: []const u8) ![]u8 {
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
    const target_infos = switch (result.get("targetInfos") orelse return error.InvalidBrowserResponse) {
        .array => |array| array,
        else => return error.InvalidBrowserResponse,
    };

    var selected: ?[]const u8 = null;
    for (target_infos.items) |target_value| {
        const target = switch (target_value) {
            .object => |object| object,
            else => return error.InvalidBrowserResponse,
        };
        const target_type = try requiredString(target, "type");
        const target_url = try requiredString(target, "url");
        if (!std.mem.eql(u8, target_type, "page")) continue;
        if (!std.mem.eql(u8, target_url, "about:blank"))
            return error.BrowserTargetUnavailable;
        if (try requiredBool(target, "attached") or target.get("openerId") != null)
            return error.BrowserTargetUnavailable;
        if (selected != null) return error.BrowserTargetUnavailable;
        const target_id = try requiredString(target, "targetId");
        if (target_id.len == 0 or std.mem.indexOfScalar(u8, target_id, 0) != null)
            return error.InvalidBrowserResponse;
        selected = target_id;
    }
    return allocator.dupe(u8, selected orelse return error.BrowserTargetNotReady);
}

const PageTargetSummary = struct {
    count: usize = 0,
    has_opener: bool = false,
};

fn pageTargetSummary(allocator: Allocator, payload: []const u8) !PageTargetSummary {
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
    const target_infos = switch (result.get("targetInfos") orelse return error.InvalidBrowserResponse) {
        .array => |array| array,
        else => return error.InvalidBrowserResponse,
    };
    var summary: PageTargetSummary = .{};
    for (target_infos.items) |target_value| {
        const target = switch (target_value) {
            .object => |object| object,
            else => return error.InvalidBrowserResponse,
        };
        if (!std.mem.eql(u8, try requiredString(target, "type"), "page")) continue;
        summary.count += 1;
        if (target.get("openerId")) |opener_value| {
            const opener_id = switch (opener_value) {
                .string => |value| value,
                else => return error.InvalidBrowserResponse,
            };
            if (opener_id.len == 0) return error.InvalidBrowserResponse;
            summary.has_opener = true;
        }
    }
    return summary;
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

fn extractRuntimeBoolean(allocator: Allocator, payload: []const u8) !bool {
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
    if (result.get("exceptionDetails") != null) return error.InvalidBrowserResponse;
    const remote_object = switch (result.get("result") orelse return error.InvalidBrowserResponse) {
        .object => |object| object,
        else => return error.InvalidBrowserResponse,
    };
    const value_type = try requiredString(remote_object, "type");
    if (!std.mem.eql(u8, value_type, "boolean")) return error.InvalidBrowserResponse;
    return requiredBool(remote_object, "value");
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

test "browser hardening denies downloads and rejects alternate page targets" {
    try std.testing.expectEqualStrings("deny", deny_download_behavior);
    try std.testing.expectEqualStrings("--block-new-web-contents", block_new_web_contents_arg);
    try std.testing.expectEqualStrings(
        "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
        force_webrtc_ip_policy_arg,
    );
    try std.testing.expectEqualStrings("--proxy-server=http://subdl-proxy.invalid:9", dead_proxy_server_arg);
    try std.testing.expectEqualStrings("--proxy-bypass-list=<-loopback>;", proxy_bypass_prefix);
    try std.testing.expect(std.mem.indexOf(u8, secure_profile_preferences, "disable_non_proxied_udp") != null);
    try std.testing.expect(std.mem.indexOf(u8, secure_profile_preferences, "\"popups\":2") != null);

    try std.testing.expectEqual(@as(usize, 2), unexpected_target_filter.len);
    try std.testing.expectEqualStrings("page", unexpected_target_filter[0].type);
    try std.testing.expect(!unexpected_target_filter[0].exclude);
    try std.testing.expect(unexpected_target_filter[1].exclude);
}

test "startup page selection cannot attach to popup or ambiguous targets" {
    const allocator = std.testing.allocator;
    const target_id = try extractInitialPageTargetId(
        allocator,
        "{\"result\":{\"targetInfos\":[{\"targetId\":\"worker\",\"type\":\"service_worker\",\"url\":\"https://example.org/sw.js\",\"attached\":false},{\"targetId\":\"startup-page\",\"type\":\"page\",\"url\":\"about:blank\",\"attached\":false}]}}",
    );
    defer allocator.free(target_id);
    try std.testing.expectEqualStrings("startup-page", target_id);

    try std.testing.expectError(
        error.BrowserTargetNotReady,
        extractInitialPageTargetId(
            allocator,
            "{\"result\":{\"targetInfos\":[{\"targetId\":\"worker\",\"type\":\"service_worker\",\"url\":\"https://example.org/sw.js\",\"attached\":false}]}}",
        ),
    );

    try std.testing.expectError(
        error.BrowserTargetUnavailable,
        extractInitialPageTargetId(
            allocator,
            "{\"result\":{\"targetInfos\":[{\"targetId\":\"popup\",\"type\":\"page\",\"url\":\"about:blank\",\"attached\":false,\"openerId\":\"parent\"}]}}",
        ),
    );
    try std.testing.expectError(
        error.BrowserTargetUnavailable,
        extractInitialPageTargetId(
            allocator,
            "{\"result\":{\"targetInfos\":[{\"targetId\":\"one\",\"type\":\"page\",\"url\":\"about:blank\",\"attached\":false},{\"targetId\":\"two\",\"type\":\"page\",\"url\":\"about:blank\",\"attached\":false}]}}",
        ),
    );
    try std.testing.expectError(
        error.BrowserTargetUnavailable,
        extractInitialPageTargetId(
            allocator,
            "{\"result\":{\"targetInfos\":[{\"targetId\":\"unexpected\",\"type\":\"page\",\"url\":\"chrome://new-tab-page/\",\"attached\":false},{\"targetId\":\"startup-page\",\"type\":\"page\",\"url\":\"about:blank\",\"attached\":false}]}}",
        ),
    );
    const popup_summary = try pageTargetSummary(
        allocator,
        "{\"result\":{\"targetInfos\":[{\"targetId\":\"popup\",\"type\":\"page\",\"url\":\"about:blank\",\"attached\":false,\"openerId\":\"parent\"}]}}",
    );
    try std.testing.expectEqual(@as(usize, 1), popup_summary.count);
    try std.testing.expect(popup_summary.has_opener);
    const startup_summary = try pageTargetSummary(
        allocator,
        "{\"result\":{\"targetInfos\":[{\"targetId\":\"startup-page\",\"type\":\"page\",\"url\":\"about:blank\",\"attached\":true}]}}",
    );
    try std.testing.expectEqual(@as(usize, 1), startup_summary.count);
    try std.testing.expect(!startup_summary.has_opener);
}

test "runtime boolean responses fail closed" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try extractRuntimeBoolean(
        allocator,
        "{\"result\":{\"result\":{\"type\":\"boolean\",\"value\":true}}}",
    ));
    try std.testing.expect(!try extractRuntimeBoolean(
        allocator,
        "{\"result\":{\"result\":{\"type\":\"boolean\",\"value\":false}}}",
    ));
    try std.testing.expectError(
        error.InvalidBrowserResponse,
        extractRuntimeBoolean(allocator, "{\"result\":{\"result\":{\"type\":\"string\",\"value\":\"true\"}}}"),
    );
    try std.testing.expectError(
        error.InvalidBrowserResponse,
        extractRuntimeBoolean(allocator, "{\"result\":{\"result\":{\"type\":\"boolean\",\"value\":true},\"exceptionDetails\":{}}}"),
    );
}

test "initial browser navigation allows only pinned challenge origins" {
    const policy = NavigationPolicy{
        .origin_host = "provider.example.org",
        .resolver_rules = "",
    };
    try std.testing.expect(policy.allowsNavigation("https://provider.example.org/challenge"));
    try std.testing.expect(policy.allowsNavigation("https://challenges.cloudflare.com/turnstile/v0/api.js"));
    try std.testing.expect(policy.allowsNavigation("data:text/plain,fixture"));
    try std.testing.expect(!policy.allowsNavigation("https://www.google.com/image.png"));
    try std.testing.expect(!policy.allowsNavigation("http://provider.example.org/downgrade"));
    try std.testing.expect(!policy.allowsNavigation("http://127.0.0.1/private"));
    try std.testing.expect(!policy.allowsNavigation("https://user:pass@provider.example.org/private"));
    try std.testing.expect(policy.allowsPageNavigation("javascript:void(0)"));
    try std.testing.expect(policy.allowsPageNavigation("about:srcdoc"));
    try std.testing.expect(!policy.allowsPageNavigation("mailto:fixture@example.invalid"));
    try std.testing.expect(!policy.allowsPageNavigation("tel:+10000000000"));
    try std.testing.expect(!policy.allowsPageNavigation("subdl-fixture:external"));
}

test "browser navigation events expose every policy-relevant URL" {
    const fixtures = [_]struct { payload: []const u8, expected: []const u8 }{
        .{ .payload = "{\"method\":\"Page.frameScheduledNavigation\",\"params\":{\"url\":\"mailto:fixture@example.invalid\"}}", .expected = "mailto:fixture@example.invalid" },
        .{ .payload = "{\"method\":\"Page.frameRequestedNavigation\",\"params\":{\"url\":\"tel:+10000000000\"}}", .expected = "tel:+10000000000" },
        .{ .payload = "{\"method\":\"Page.frameStartedNavigating\",\"params\":{\"url\":\"subdl-fixture:external\"}}", .expected = "subdl-fixture:external" },
        .{ .payload = "{\"method\":\"Page.navigatedWithinDocument\",\"params\":{\"url\":\"https://provider.example.org/#done\"}}", .expected = "https://provider.example.org/#done" },
        .{ .payload = "{\"method\":\"Page.frameNavigated\",\"params\":{\"frame\":{\"url\":\"https://challenges.cloudflare.com/turnstile/\"}}}", .expected = "https://challenges.cloudflare.com/turnstile/" },
        .{ .payload = "{\"method\":\"Page.windowOpen\",\"params\":{\"url\":\"https://off-origin.invalid/\"}}", .expected = "https://off-origin.invalid/" },
    };
    for (fixtures) |fixture| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture.payload, .{});
        defer parsed.deinit();
        const url = try pageNavigationEventUrl(parsed.value.object);
        try std.testing.expectEqualStrings(fixture.expected, url.?);
    }

    var malformed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"method\":\"Page.frameNavigated\",\"params\":{\"frame\":{}}}",
        .{},
    );
    defer malformed.deinit();
    try std.testing.expectError(error.InvalidBrowserResponse, pageNavigationEventUrl(malformed.value.object));
}

test "browser environment blocks desktop protocol launchers and preserves display" {
    const allocator = std.testing.allocator;
    var environment = try makeBrowserEnvironment(allocator, "/tmp/subdl-profile-fixture");
    defer environment.deinit();
    const expected_path = if (common.getenv("PATH")) |inherited_path|
        try std.fmt.allocPrint(
            allocator,
            "/tmp/subdl-profile-fixture/blocked-external-handlers:{s}",
            .{inherited_path},
        )
    else
        try allocator.dupe(u8, "/tmp/subdl-profile-fixture/blocked-external-handlers");
    defer allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, environment.get("PATH").?);
    try std.testing.expectEqualStrings(
        "unix:path=/tmp/subdl-profile-fixture/blocked-session-bus",
        environment.get("DBUS_SESSION_BUS_ADDRESS").?,
    );
    for ([_][]const u8{ "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR" }) |name| {
        if (common.getenv(name)) |value|
            try std.testing.expectEqualStrings(value, environment.get(name).?);
    }
}

test "secure browser profile shadows external protocol helpers" {
    var profile = try SecureProfile.create(std.testing.allocator);
    defer profile.deinit(std.testing.allocator, common.compatMilliTimestamp() + 5_000);
    const io = runtime_io.get();
    inline for (.{ "xdg-email", "xdg-open" }) |helper| {
        const helper_path = try std.fs.path.join(
            std.testing.allocator,
            &.{ profile.path, blocked_executable_path, helper },
        );
        defer std.testing.allocator.free(helper_path);
        const stat = try std.Io.Dir.cwd().statFile(io, helper_path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
        try std.testing.expectEqual(@as(u32, 0), stat.permissions.toMode() & 0o077);
        try std.testing.expect(stat.permissions.toMode() & 0o100 != 0);
        const contents = try std.Io.Dir.cwd().readFileAlloc(
            io,
            helper_path,
            std.testing.allocator,
            .limited(64),
        );
        defer std.testing.allocator.free(contents);
        try std.testing.expectEqualStrings(blocked_external_handler_script, contents);
    }
}

test "resolver-rule hosts reject argument injection" {
    try std.testing.expect(validResolverHost("provider.example.org"));
    try std.testing.expect(!validResolverHost("localhost"));
    try std.testing.expect(!validResolverHost("provider.example.org, MAP * 127.0.0.1"));
    try std.testing.expect(!validResolverHost("provider.example.org\n--no-sandbox"));
}

test "proxy bypass is limited to pinned HTTPS origins on port 443" {
    const argument = try makeProxyBypassArg(std.testing.allocator, "provider.example.org");
    defer std.testing.allocator.free(argument);
    try std.testing.expectEqualStrings(
        "--proxy-bypass-list=<-loopback>;https://provider.example.org:443;https://challenges.cloudflare.com:443",
        argument,
    );
    try std.testing.expectError(
        error.InvalidBrowserNavigation,
        makeProxyBypassArg(std.testing.allocator, "provider.example.org;*.invalid"),
    );
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

test "opt-in local Chromium hardening smoke test" {
    const enabled = common.getenv("SUBDL_CHROMIUM_SMOKE") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    const executable = common.getenv("SUBDL_CHROMIUM_PATH") orelse return error.SkipZigTest;
    const deadline = common.compatMilliTimestamp() + 30_000;
    const data_url = "data:text/html,<title>subdl-browser-hardening</title>";
    const policy = NavigationPolicy{
        .origin_host = "example.invalid",
        .resolver_rules = "MAP * ~NOTFOUND",
    };
    var browser = try Browser.launch(std.testing.allocator, executable, &policy, true, deadline);
    defer browser.deinit();
    try std.testing.expect(browser.downloads_denied);
    try browser.navigate(data_url, deadline);

    const session_id = browser.session_id orelse return error.BrowserTargetUnavailable;
    const challenge_capabilities = try browser.sendSessionCommand(session_id, "Runtime.evaluate", .{
        .expression = "typeof globalThis.open === 'function' && typeof Window === 'function' && typeof RTCPeerConnection === 'function' && typeof Worker === 'function' && typeof SharedWorker === 'function' && (typeof ServiceWorkerContainer !== 'function' || typeof ServiceWorkerContainer.prototype.register === 'function')",
        .returnByValue = true,
    }, deadline);
    defer std.testing.allocator.free(challenge_capabilities);
    try std.testing.expect(try extractRuntimeBoolean(std.testing.allocator, challenge_capabilities));

    const named_frame_compatibility = try browser.sendSessionCommand(session_id, "Runtime.evaluate", .{
        .expression = "(() => { const frame = document.createElement('iframe'); frame.name = 'challenge-frame'; frame.src = 'about:blank'; document.body.append(frame); const named = document.createElement('a'); named.href = 'about:blank'; named.target = 'challenge-frame'; document.body.append(named); named.click(); const compatible = named.target === 'challenge-frame'; named.remove(); frame.remove(); return compatible; })()",
        .returnByValue = true,
    }, deadline);
    defer std.testing.allocator.free(named_frame_compatibility);
    try std.testing.expect(try extractRuntimeBoolean(std.testing.allocator, named_frame_compatibility));

    const targets_response = browser.sendCommand("Target.getTargets", EmptyCdpParams{}, deadline) catch |err| {
        try std.testing.expectEqual(error.UnexpectedBrowserTarget, err);
        return;
    };
    defer std.testing.allocator.free(targets_response);
    const target_summary = try pageTargetSummary(std.testing.allocator, targets_response);
    try std.testing.expectEqual(@as(usize, 1), target_summary.count);
    try std.testing.expect(!target_summary.has_opener);

    const popup_attempt = browser.sendSessionCommand(session_id, "Runtime.evaluate", .{
        .expression = "(() => { const link = document.createElement('a'); link.href = 'data:text/html,popup'; link.target = '_blank'; document.body.append(link); link.click(); link.remove(); const opened = globalThis.open('data:text/html,programmatic-popup', '_blank'); if (opened) opened.close(); return true; })()",
        .returnByValue = true,
        .userGesture = true,
    }, deadline) catch |err| {
        try std.testing.expectEqual(error.UnexpectedBrowserTarget, err);
        return;
    };
    defer std.testing.allocator.free(popup_attempt);
    try std.testing.expect(try extractRuntimeBoolean(std.testing.allocator, popup_attempt));

    const final_targets_response = browser.sendCommand("Target.getTargets", EmptyCdpParams{}, deadline) catch |err| {
        try std.testing.expectEqual(error.UnexpectedBrowserTarget, err);
        return;
    };
    defer std.testing.allocator.free(final_targets_response);
    const final_target_summary = try pageTargetSummary(std.testing.allocator, final_targets_response);
    try std.testing.expectEqual(@as(usize, 1), final_target_summary.count);
    try std.testing.expect(!final_target_summary.has_opener);
}

fn runExternalProtocolSmoke(executable: []const u8, headless: bool) !void {
    const deadline = common.compatMilliTimestamp() + 30_000;
    const policy = NavigationPolicy{
        .origin_host = "example.invalid",
        .resolver_rules = "MAP * ~NOTFOUND",
    };
    var browser = try Browser.launch(std.testing.allocator, executable, &policy, headless, deadline);
    defer browser.deinit();
    try browser.navigate("data:text/html,<title>subdl-external-protocol</title>", deadline);
    const session_id = browser.session_id orelse return error.BrowserTargetUnavailable;

    // Keep this as the final action. Event rejection makes the production
    // caller tear down the browser; PATH/DBus isolation is what prevents an OS
    // handler from starting before that teardown completes.
    const response = browser.sendSessionCommand(session_id, "Runtime.evaluate", .{
        .expression = "location.href = 'mailto:subdl-fixture@example.invalid'; true",
        .returnByValue = true,
        .userGesture = true,
    }, deadline) catch |err| {
        try std.testing.expectEqual(error.UnsafeBrowserNavigation, err);
        return;
    };
    defer std.testing.allocator.free(response);
    browser.waitForPolicyEvents(1_000, deadline) catch |err| {
        try std.testing.expectEqual(error.UnsafeBrowserNavigation, err);
        return;
    };
    return error.TestExpectedError;
}

test "opt-in local Chromium blocks external protocol navigation" {
    const enabled = common.getenv("SUBDL_CHROMIUM_SMOKE") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    const executable = common.getenv("SUBDL_CHROMIUM_PATH") orelse return error.SkipZigTest;
    try runExternalProtocolSmoke(executable, true);
}

test "opt-in headed Chromium blocks external protocol navigation" {
    const enabled = common.getenv("SUBDL_CHROMIUM_HEADED_SMOKE") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    const executable = common.getenv("SUBDL_CHROMIUM_PATH") orelse return error.SkipZigTest;
    try runExternalProtocolSmoke(executable, false);
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
