const std = @import("std");
const cli = @import("cli.zig");
const tui = @import("tui_backend");
const runtime_io = @import("runtime_io");

pub const panic = tui.panic;

const MainMode = enum { cli, tui, help };

fn mainMode(arg: ?[]const u8) MainMode {
    const value = arg orelse return .cli;
    if (std.mem.eql(u8, value, "tui") or std.mem.eql(u8, value, "--tui")) return .tui;
    if (std.mem.eql(u8, value, "help")) return .help;
    return .cli;
}

fn validateModeArguments(mode: MainMode, has_trailing_argument: bool) !void {
    if ((mode == .tui or mode == .help) and has_trailing_argument) return error.UnexpectedModeArgument;
}

fn validateModeAvailability(mode: MainMode, tui_available: bool) !void {
    if (mode == .tui and !tui_available) return error.TuiUnavailable;
}

pub fn main(init: std.process.Init) !void {
    runtime_io.set(init.io);
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = mainMode(args.next());
    validateModeArguments(mode, args.next() != null) catch |err| {
        try printMainError(init.io, "mode argument error", err);
        std.process.exit(2);
    };
    validateModeAvailability(mode, tui.available) catch {
        try printMainError(init.io, "TUI support is unavailable in this build; enable TUI and use a threaded build", null);
        std.process.exit(2);
    };

    switch (mode) {
        .tui => {
            try tui.main(init);
            return;
        },
        .help => {
            try printUsage(init.io);
            return;
        },
        .cli => try cli.mainWithTuiAvailability(init, tui.available),
    }
}

fn printMainError(io: std.Io, message: []const u8, err: ?anyerror) !void {
    var stderr_buf: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll(message);
    if (err) |value| try stderr.print(": {s}", .{@errorName(value)});
    try stderr.writeByte('\n');
    try stderr.flush();
}

fn printUsage(io: std.Io) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try cli.printUsageWithTuiAvailability(stdout, tui.available);
    try stdout.flush();
}

test "main modes and trailing argument policy are explicit" {
    try std.testing.expectEqual(MainMode.cli, mainMode(null));
    try std.testing.expectEqual(MainMode.cli, mainMode("--query"));
    try std.testing.expectEqual(MainMode.cli, mainMode("--help"));
    try std.testing.expectEqual(MainMode.cli, mainMode("-h"));
    try std.testing.expectEqual(MainMode.tui, mainMode("--tui"));
    try std.testing.expectEqual(MainMode.help, mainMode("help"));
    try validateModeArguments(.cli, true);
    try validateModeArguments(.tui, false);
    try std.testing.expectError(error.UnexpectedModeArgument, validateModeArguments(.tui, true));
    try validateModeArguments(.help, false);
    try std.testing.expectError(error.UnexpectedModeArgument, validateModeArguments(.help, true));
    try validateModeAvailability(.cli, false);
    try validateModeAvailability(.help, false);
    try validateModeAvailability(.tui, true);
    try std.testing.expectError(error.TuiUnavailable, validateModeAvailability(.tui, false));
}

test {
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(tui);
}
