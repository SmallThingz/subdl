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
    try common.validateFetchTarget(value, .{ .require_public_origin = true });
}

pub fn expectUrlOrAbsolutePath(value: []const u8) !void {
    if (value.len == 0 or value[0] != '/') return expectHttpUrl(value);
    var ok = value.len > 1 and value[0] == '/' and value[1] != '/';
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '\\') ok = false;
    }
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

test "URL expectations reject prefix-only URLs and authority-like paths" {
    try expectHttpUrl("https://example.com/subtitle/1");
    try expectUrlOrAbsolutePath("/subtitle/1?language=en");
    try std.testing.expectError(error.InvalidDownloadUrl, expectHttpUrl("https://"));
    try std.testing.expectError(error.UnsafeHttpTarget, expectHttpUrl("https://user@example.com/subtitle/1"));
    try std.testing.expectError(error.UnsafeHttpTarget, expectHttpUrl("http://127.0.0.1/subtitle/1"));
    try std.testing.expectError(error.TestUnexpectedResult, expectUrlOrAbsolutePath("//example.test/subtitle/1"));
    try std.testing.expectError(error.TestUnexpectedResult, expectUrlOrAbsolutePath("/"));
    try std.testing.expectError(error.TestUnexpectedResult, expectUrlOrAbsolutePath("/subtitle\\path"));
}
