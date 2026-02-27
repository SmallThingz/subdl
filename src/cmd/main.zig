const std = @import("std");
const cli = @import("cli.zig");
const tui = @import("tui.zig");

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    _ = args.next();
    if (args.next()) |mode| {
        if (std.mem.eql(u8, mode, "tui") or std.mem.eql(u8, mode, "--tui")) {
            try tui.main();
            return;
        }
        if (std.mem.eql(u8, mode, "help") or std.mem.eql(u8, mode, "--help") or std.mem.eql(u8, mode, "-h")) {
            try printUsage();
            return;
        }
    }

    try cli.main();
}

fn printUsage() !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\Usage:
        \\  scrapers [tui|--tui]
        \\  scrapers [cli args...]
        \\
        \\Examples:
        \\  scrapers --provider subsource_net --query "The Matrix"
        \\  scrapers --tui
        \\
    ,
        .{},
    );
    try stdout.flush();
}
