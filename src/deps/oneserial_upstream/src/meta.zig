const std = @import("std");

pub const MathError = error{Overflow};

/// Aligns `pos` down to the nearest multiple of `alignment`.
pub fn alignBackward(pos: usize, comptime alignment: usize) MathError!usize {
    comptime std.debug.assert(std.mem.isValidAlignGeneric(usize, alignment));
    return pos & ~(alignment - 1);
}

/// Aligns `pos` up to the nearest multiple of `alignment`.
pub fn alignForward(pos: usize, comptime alignment: usize) MathError!usize {
    comptime std.debug.assert(std.mem.isValidAlignGeneric(usize, alignment));
    return std.math.add(usize, pos, ((alignment - 1) & ~pos) + @intFromBool(alignment != 1));
}

/// Converts an integer-like value to `usize` with overflow checking.
pub fn usizeFromAnyInt(v: anytype) MathError!usize {
    return std.math.cast(usize, v) orelse error.Overflow;
}

/// Casts `usize` to integer type `T` with overflow checking.
pub fn castUsize(comptime T: type, value: usize) MathError!T {
    return std.math.cast(T, value) orelse error.Overflow;
}
