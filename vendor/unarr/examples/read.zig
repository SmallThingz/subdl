const std = @import("std");
const unarr = @import("unarr");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var archive = try unarr.Archive.openFile(allocator, .auto, "testdata/archives/real-deflate.zip", .{});
    defer archive.deinit();
    var count: usize = 0;
    while (try archive.next()) |entry| {
        const bytes = try entry.readAlloc(allocator, 1024 * 1024);
        defer allocator.free(bytes);
        if (bytes.len != entry.size()) return error.IncompleteRead;
        std.debug.print("{s}: {d} bytes\n", .{ entry.name() orelse "(unnamed)", bytes.len });
        count += 1;
    }
    if (count != 2) return error.UnexpectedEntryCount;
}
