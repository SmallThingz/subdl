const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const ProviderProbe = struct {
    name: []const u8,
    run: *const fn (allocator: Allocator, client: *std.http.Client) anyerror!void,
};

pub fn shouldRunExtensiveLiveSuite(allocator: Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SCRAPERS_EXTENSIVE_LIVE_TEST") catch return false;
    defer allocator.free(value);
    if (value.len == 0) return false;
    return !std.mem.eql(u8, value, "0");
}

pub fn runSuite(allocator: Allocator, probes: []const ProviderProbe) !void {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    for (probes) |probe| {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            probe.run(allocator, &client) catch |err| {
                if (attempt < 2 and isRetryable(err)) {
                    std.Thread.sleep((@as(u64, 1) << @intCast(@min(attempt, 6))) * 300 * std.time.ns_per_ms);
                    continue;
                }
                std.log.err("live suite provider {s} failed on attempt {d}: {s}", .{ probe.name, attempt + 1, @errorName(err) });
                return err;
            };
            break;
        }
    }
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
        err == error.TemporaryNameServerFailure or
        err == error.NetworkUnreachable or
        err == error.ConnectionTimedOut or
        err == error.RateLimited;
}

test "test suite retry classifier" {
    try std.testing.expect(isRetryable(error.UnexpectedHttpStatus));
    try std.testing.expect(!isRetryable(error.OutOfMemory));
}
