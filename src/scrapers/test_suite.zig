const std = @import("std");
const common = @import("common.zig");

pub const Allocator = std.mem.Allocator;

pub const ProviderProbe = struct {
    name: []const u8,
    run: *const fn (allocator: Allocator, client: *std.http.Client) anyerror!void,
};

pub fn shouldRunExtensiveLiveSuite(allocator: Allocator) bool {
    _ = allocator;
    return common.liveExtensiveSuiteEnabled();
}

pub fn runSuite(allocator: Allocator, probes: []const ProviderProbe) !void {
    const provider_filter = common.liveProviderFilter();
    var selected: std.ArrayListUnmanaged(ProviderProbe) = .empty;
    defer selected.deinit(allocator);
    for (probes) |probe| {
        if (!isProbeSelected(provider_filter, probe.name)) continue;
        try selected.append(allocator, probe);
    }
    if (selected.items.len == 0) return;
    std.debug.print("[live][suite] starting threaded probe batch count={d}\n", .{selected.items.len});

    const states = try allocator.alloc(ProbeState, selected.items.len);
    defer allocator.free(states);
    for (selected.items, 0..) |probe, idx| {
        states[idx] = .{ .probe = probe };
    }

    const threads = try allocator.alloc(std.Thread, selected.items.len);
    defer allocator.free(threads);
    for (threads, states) |*thread, *state| {
        thread.* = try std.Thread.spawn(.{}, runProbeWorker, .{state});
    }
    for (threads) |thread| thread.join();
    std.debug.print("[live][suite] threaded probe batch complete count={d}\n", .{selected.items.len});

    var first_err: ?anyerror = null;
    for (states) |state| {
        if (state.err) |err| {
            std.log.err("live suite provider {s} failed on attempt {d}: {s}", .{
                state.probe.name,
                state.attempts + 1,
                @errorName(err),
            });
            if (first_err == null) first_err = err;
        }
    }
    if (first_err) |err| return err;
}

const ProbeState = struct {
    probe: ProviderProbe,
    attempts: usize = 0,
    err: ?anyerror = null,
};

fn runProbeWorker(state: *ProbeState) void {
    const start_ms = std.time.milliTimestamp();
    std.debug.print("[live][suite][{s}] worker_start state=0x{x}\n", .{
        state.probe.name,
        @intFromPtr(state),
    });
    defer {
        const elapsed_ms = std.time.milliTimestamp() - start_ms;
        if (state.err) |err| {
            std.debug.print("[live][suite][{s}] worker_end status=err err={s} elapsed_ms={d}\n", .{
                state.probe.name,
                @errorName(err),
                elapsed_ms,
            });
        } else {
            std.debug.print("[live][suite][{s}] worker_end status=ok attempts={d} elapsed_ms={d}\n", .{
                state.probe.name,
                state.attempts + 1,
                elapsed_ms,
            });
        }
    }

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        state.probe.run(allocator, &client) catch |err| {
            if (attempt < 2 and isRetryable(err)) {
                const base_ms: u64 = if (err == error.RateLimited) 5000 else 300;
                std.Thread.sleep((@as(u64, 1) << @intCast(@min(attempt, 6))) * base_ms * std.time.ns_per_ms);
                continue;
            }
            state.attempts = attempt;
            state.err = err;
            break;
        };
        state.attempts = attempt;
        break;
    }
}

fn isProbeSelected(filter: ?[]const u8, probe_name: []const u8) bool {
    return common.providerMatchesLiveFilter(filter, probe_name);
}

pub fn expectNonEmpty(value: []const u8) !void {
    try std.testing.expect(value.len > 0);
}

pub fn expectMaybeNonEmpty(value: ?[]const u8) !void {
    try std.testing.expect(value != null);
    try std.testing.expect(value.?.len > 0);
}

pub fn expectHttpUrl(value: []const u8) !void {
    const ok = std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://");
    try std.testing.expect(ok);
}

pub fn expectUrlOrAbsolutePath(value: []const u8) !void {
    const ok = std.mem.startsWith(u8, value, "http://") or
        std.mem.startsWith(u8, value, "https://") or
        std.mem.startsWith(u8, value, "/");
    try std.testing.expect(ok);
}

pub fn expectPositive(value: usize) !void {
    try std.testing.expect(value > 0);
}

fn isRetryable(err: anyerror) bool {
    return err == error.UnexpectedHttpStatus or
        err == error.HttpRequestFailed or
        err == error.ConnectionRefused or
        err == error.ConnectionResetByPeer or
        err == error.BrokenPipe or
        err == error.WriteFailed or
        err == error.TemporaryNameServerFailure or
        err == error.NetworkUnreachable or
        err == error.ConnectionTimedOut or
        err == error.RateLimited;
}

test "test suite retry classifier" {
    try std.testing.expect(isRetryable(error.UnexpectedHttpStatus));
    try std.testing.expect(isRetryable(error.WriteFailed));
    try std.testing.expect(!isRetryable(error.OutOfMemory));
}

test "provider filter matcher" {
    try std.testing.expect(isProbeSelected(null, "tvsubtitles.net"));
    try std.testing.expect(isProbeSelected("tvsubtitles.net", "tvsubtitles.net"));
    try std.testing.expect(isProbeSelected("tvsubtitles", "tvsubtitles.net"));
    try std.testing.expect(isProbeSelected("subdl.com,tvsubtitles.net", "tvsubtitles.net"));
    try std.testing.expect(isProbeSelected("*", "tvsubtitles.net"));
    try std.testing.expect(!isProbeSelected("podnapisi.net", "tvsubtitles.net"));
}
