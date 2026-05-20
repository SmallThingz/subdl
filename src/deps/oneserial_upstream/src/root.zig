const std = @import("std");
const builtin = @import("builtin");
pub const SerializationFunctions = @import("serialization_functions.zig");

/// Global wire length type. Keep a single definition here.
pub const Size = u32;

/// Reserved for future behavior switches.
pub const MergeOptions = struct {
    /// Wire endianness for serialization and view decoding.
    /// Defaults to native-endian for current behavior compatibility.
    endian: std.builtin.Endian = builtin.target.cpu.arch.endian(),
};

pub const ValidationError = SerializationFunctions.ValidationError;
pub const SerializeError = SerializationFunctions.SerializeError;
pub const DeserializeError = SerializationFunctions.DeserializeError;

/// Returns a sentinel pointer used by shim allocation.
/// Use this for pointer fields (or slice `.ptr`) when you want allocation without deep recursion.
pub fn invalidPointer(comptime P: type) P {
    return SerializationFunctions.invalidPointer(P);
}

/// Returns the per-type converter namespace for `T` and the selected options.
pub fn Converter(comptime T: type, comptime options: MergeOptions) type {
    return SerializationFunctions.Converter(T, options.endian);
}

/// Returns the owned serialized wrapper type for `T`.
pub fn Wrapper(comptime T: type, comptime options: MergeOptions) type {
    return Converter(T, options).Wrapper;
}

/// Returns the untrusted view type for serialized `T` bytes.
pub fn Untrusted(comptime T: type, comptime options: MergeOptions) type {
    return Converter(T, options).Untrusted;
}

/// Returns the trusted view type for serialized `T` bytes.
pub fn Trusted(comptime T: type, comptime options: MergeOptions) type {
    return Converter(T, options).Trusted;
}

/// Serializes `value` into a newly allocated contiguous byte buffer.
pub fn serializeAlloc(
    comptime T: type,
    comptime options: MergeOptions,
    value: *const T,
    gpa: std.mem.Allocator,
) SerializeError!SerializationFunctions.SerializeBytes(T) {
    return Converter(T, options).serializeAlloc(value, gpa);
}

/// Allocates an owned shape from `shim` without copying payload bytes.
/// Pointer sentinels from `invalidPointer()` stop deep recursion for that subtree.
pub fn allocFromShim(
    comptime T: type,
    comptime options: MergeOptions,
    shim: *const T,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!T {
    return Converter(T, options).allocFromShim(shim, gpa);
}

test {
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDeclsRecursive(SerializationFunctions);
}
