const std = @import("std");
const cli = @import("cli.zig");
const tui = @import("tui_backend");
const runtime_io = @import("runtime_io");

pub const panic = tui.panic;

pub fn main(init: std.process.Init) !void {
    runtime_io.set(init.io);
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |mode| {
        if (std.mem.eql(u8, mode, "tui") or std.mem.eql(u8, mode, "--tui")) {
            try tui.main(init);
            return;
        }
        if (std.mem.eql(u8, mode, "help") or std.mem.eql(u8, mode, "--help") or std.mem.eql(u8, mode, "-h")) {
            try printUsage(init.io);
            return;
        }
    }

    try cli.main(init);
}

fn printUsage(io: std.Io) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("Interactive mode: scrapers --tui\n\n");
    try cli.printUsage(stdout);
    try stdout.flush();
}

test {
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(tui);
}
