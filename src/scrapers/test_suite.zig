const std = @import("std");
const common = @import("common.zig");

pub const Allocator = std.mem.Allocator;

pub fn shouldRunExtensiveLiveSuite(allocator: Allocator) bool {
    _ = allocator;
    return common.liveExtensiveSuiteEnabled();
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

test "provider filter matcher" {
    try std.testing.expect(common.providerMatchesLiveFilter(null, "tvsubtitles.net"));
    try std.testing.expect(common.providerMatchesLiveFilter("tvsubtitles.net", "tvsubtitles.net"));
    try std.testing.expect(common.providerMatchesLiveFilter("tvsubtitles", "tvsubtitles.net"));
    try std.testing.expect(common.providerMatchesLiveFilter("subdl.com,tvsubtitles.net", "tvsubtitles.net"));
    try std.testing.expect(common.providerMatchesLiveFilter("*", "tvsubtitles.net"));
    try std.testing.expect(!common.providerMatchesLiveFilter("podnapisi.net", "tvsubtitles.net"));
}
