const std = @import("std");

fn needsShimInit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one, .slice => true,
            .many, .c => false,
        },
        .array => |ai| needsShimInit(ai.child),
        .@"struct" => |si| blk: {
            inline for (si.fields) |field| {
                if (needsShimInit(field.type)) break :blk true;
            }
            break :blk false;
        },
        .optional, .@"union" => true,
        else => false,
    };
}

/// Internal cleanup for partially allocated shim builds.
/// Frees only memory that `allocFromShimValue` allocated.
pub fn freeShimAllocated(
    comptime T: type,
    gpa: std.mem.Allocator,
    value: *const T,
    shim: *const T,
    comptime is_invalid_pointer_fn: anytype,
) void {
    switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one => {
                const child_ptr = value.*;
                if (!is_invalid_pointer_fn(shim.*) and needsShimInit(pi.child)) {
                    freeShimAllocated(pi.child, gpa, child_ptr, shim.*, is_invalid_pointer_fn);
                }
                gpa.destroy(@constCast(child_ptr));
            },
            .slice => {
                const out = value.*;
                if (out.len > 0 and !is_invalid_pointer_fn(shim.*.ptr) and needsShimInit(pi.child)) {
                    for (0..out.len) |i| {
                        var elem_copy = out[i];
                        var shim_elem = shim.*[i];
                        freeShimAllocated(pi.child, gpa, &elem_copy, &shim_elem, is_invalid_pointer_fn);
                    }
                }
                gpa.free(@constCast(out));
            },
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .array => |ai| {
            if (!needsShimInit(ai.child)) return;
            for (0..ai.len) |i| {
                var elem_copy = value.*[i];
                var shim_elem = shim.*[i];
                freeShimAllocated(ai.child, gpa, &elem_copy, &shim_elem, is_invalid_pointer_fn);
            }
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                if (needsShimInit(field.type)) {
                    var field_copy = @field(value.*, field.name);
                    var shim_field = @field(shim.*, field.name);
                    freeShimAllocated(field.type, gpa, &field_copy, &shim_field, is_invalid_pointer_fn);
                }
            }
        },
        .optional => |oi| {
            if (!needsShimInit(oi.child)) return;
            if (value.*) |payload| {
                std.debug.assert(shim.* != null);
                var payload_copy = payload;
                var shim_payload = shim.*.?;
                freeShimAllocated(oi.child, gpa, &payload_copy, &shim_payload, is_invalid_pointer_fn);
            }
        },
        .@"union" => |ui| {
            const Tag = ui.tag_type orelse @compileError("Cannot free shim allocation for untagged union: " ++ @typeName(T));
            switch (value.*) {
                inline else => |payload, tag| {
                    _ = @as(Tag, tag);
                    const PayloadT = @TypeOf(payload);
                    if (!needsShimInit(PayloadT)) return;
                    std.debug.assert(std.meta.activeTag(shim.*) == tag);
                    var payload_copy = payload;
                    var shim_payload = @field(shim.*, @tagName(tag));
                    freeShimAllocated(PayloadT, gpa, &payload_copy, &shim_payload, is_invalid_pointer_fn);
                },
            }
        },
        else => {},
    }
}

/// Internal shim allocator for `oneserial`.
/// Builds an owned shape from `shim` while skipping deep recursion when
/// `is_invalid_pointer_fn` reports a pointer sentinel.
pub fn allocFromShimValue(
    comptime T: type,
    shim: *const T,
    gpa: std.mem.Allocator,
    comptime is_invalid_pointer_fn: anytype,
) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .void => return {},
        .null => return null,
        .bool, .int, .float, .vector, .@"enum" => return undefined,
        .array => |ai| {
            var out: T = undefined;
            if (!needsShimInit(ai.child) or ai.len == 0) return out;

            var initialized: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < initialized) : (i += 1) {
                    freeShimAllocated(ai.child, gpa, &out[i], &shim.*[i], is_invalid_pointer_fn);
                }
            }

            for (0..ai.len) |i| {
                out[i] = try allocFromShimValue(ai.child, &shim.*[i], gpa, is_invalid_pointer_fn);
                initialized = i + 1;
            }
            return out;
        },
        .pointer => |pi| switch (pi.size) {
            .one => {
                const child_ptr = try gpa.create(pi.child);
                errdefer gpa.destroy(child_ptr);

                if (is_invalid_pointer_fn(shim.*) or !needsShimInit(pi.child)) {
                    child_ptr.* = undefined;
                } else {
                    child_ptr.* = try allocFromShimValue(pi.child, shim.*, gpa, is_invalid_pointer_fn);
                }
                return @as(T, child_ptr);
            },
            .slice => {
                const len = shim.*.len;
                const alignment = comptime std.mem.Alignment.fromByteUnits(pi.alignment);
                var out = try gpa.alignedAlloc(pi.child, alignment, len);
                errdefer gpa.free(out);

                if (len == 0 or is_invalid_pointer_fn(shim.*.ptr) or !needsShimInit(pi.child)) {
                    return @as(T, out);
                }

                var initialized: usize = 0;
                errdefer {
                    var i: usize = 0;
                    while (i < initialized) : (i += 1) {
                        freeShimAllocated(pi.child, gpa, &out[i], &shim.*[i], is_invalid_pointer_fn);
                    }
                }

                for (0..len) |i| {
                    out[i] = try allocFromShimValue(pi.child, &shim.*[i], gpa, is_invalid_pointer_fn);
                    initialized = i + 1;
                }
                return @as(T, out);
            },
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .@"struct" => |si| {
            var out: T = undefined;
            var initialized: usize = 0;
            errdefer {
                inline for (si.fields, 0..) |field, i| {
                    if (i < initialized and needsShimInit(field.type)) {
                        freeShimAllocated(field.type, gpa, &@field(out, field.name), &@field(shim.*, field.name), is_invalid_pointer_fn);
                    }
                }
            }
            inline for (si.fields, 0..) |field, i| {
                if (needsShimInit(field.type)) {
                    @field(out, field.name) = try allocFromShimValue(field.type, &@field(shim.*, field.name), gpa, is_invalid_pointer_fn);
                }
                initialized = i + 1;
            }
            return out;
        },
        .optional => |oi| {
            if (shim.* == null) return null;
            if (!needsShimInit(oi.child)) {
                const payload: oi.child = undefined;
                return @as(T, payload);
            }
            var shim_payload = shim.*.?;
            const payload = try allocFromShimValue(oi.child, &shim_payload, gpa, is_invalid_pointer_fn);
            return @as(T, payload);
        },
        .@"union" => |ui| {
            const Tag = ui.tag_type orelse @compileError("Cannot allocate shim for untagged union: " ++ @typeName(T));
            switch (shim.*) {
                inline else => |payload, tag| {
                    _ = @as(Tag, tag);
                    const PayloadT = @TypeOf(payload);
                    if (!needsShimInit(PayloadT)) {
                        const out_payload: PayloadT = undefined;
                        return @unionInit(T, @tagName(tag), out_payload);
                    }
                    var shim_payload = payload;
                    const out_payload = try allocFromShimValue(PayloadT, &shim_payload, gpa, is_invalid_pointer_fn);
                    return @unionInit(T, @tagName(tag), out_payload);
                },
            }
        },
        .error_union => @compileError("Unsupported type in oneserial: " ++ @typeName(T)),
        .type,
        .noreturn,
        .comptime_int,
        .comptime_float,
        .undefined,
        .@"fn",
        .frame,
        .@"anyframe",
        .enum_literal,
        .@"opaque",
        .error_set,
        => @compileError("Unsupported type in oneserial: " ++ @typeName(T)),
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
