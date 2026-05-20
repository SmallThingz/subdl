const std = @import("std");
const builtin = @import("builtin");

var current_io: ?std.Io = null;

pub fn set(io: std.Io) void {
    current_io = io;
}

pub fn get() std.Io {
    if (current_io) |io| return io;
    if (builtin.is_test) return std.testing.io;
    @panic("runtime_io not initialized");
}
