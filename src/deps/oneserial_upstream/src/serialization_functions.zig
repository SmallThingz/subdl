const std = @import("std");
const meta = @import("meta.zig");
const root = @import("root.zig");
const shim_allocation = @import("shim_allocation.zig");

pub const ValidationError = error{
    NotEnoughBytes,
    /// Returned when object parsing succeeded but trailing bytes remain.
    /// Callers that frame multiple objects may intentionally ignore this.
    TooManyBytes,
    LengthOverflow,
    InvalidTag,
    InvalidEnumTag,
    InvalidUnionTag,
    OutOfBounds,
};

pub const SerializeError = ValidationError || error{ OutOfMemory, NoSpaceLeft };
pub const DeserializeError = ValidationError || error{OutOfMemory};

/// Tag-level support. Some tags (pointer/union) require additional shape checks;
/// use `supportsType` for full type-level validation.
pub fn supportsTypeId(tag: std.builtin.TypeId) bool {
    return switch (tag) {
        .void,
        .bool,
        .int,
        .float,
        .vector,
        .@"enum",
        .array,
        .pointer,
        .@"struct",
        .optional,
        .@"union",
        .null,
        => true,
        else => false,
    };
}

fn seenType(comptime seen: []const type, comptime T: type) bool {
    inline for (seen) |s| if (s == T) return true;
    return false;
}

fn supportsTypeInner(comptime T: type, comptime seen: []const type) bool {
    @setEvalBranchQuota(1_000_000);
    if (seenType(seen, T)) return true;
    const next_seen = seen ++ [1]type{T};

    return switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .vector, .null => true,
        .@"enum" => true,
        .array => |ai| supportsTypeInner(ai.child, next_seen),
        .pointer => |pi| switch (pi.size) {
            .one, .slice => supportsTypeInner(pi.child, next_seen),
            .many, .c => false,
        },
        .@"struct" => |si| blk: {
            inline for (si.fields) |field| {
                if (!supportsTypeInner(field.type, next_seen)) break :blk false;
            }
            break :blk true;
        },
        .optional => |oi| supportsTypeInner(oi.child, next_seen),
        .error_union => false,
        .@"union" => |ui| blk: {
            if (ui.tag_type == null) break :blk false;
            inline for (ui.fields) |field| {
                if (!supportsTypeInner(field.type, next_seen)) break :blk false;
            }
            break :blk true;
        },
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
        => false,
    };
}

/// Returns whether `T` is supported by this serializer.
pub fn supportsType(comptime T: type) bool {
    return supportsTypeInner(T, &.{});
}

fn maxAlignmentInner(comptime T: type, comptime seen: []const type) std.mem.Alignment {
    @setEvalBranchQuota(1_000_000);
    if (seenType(seen, T)) return .@"1";
    const next_seen = seen ++ [1]type{T};
    return switch (@typeInfo(T)) {
        .void, .null => .@"1",
        .bool, .int, .float, .vector => std.mem.Alignment.fromByteUnits(@alignOf(T)),
        .@"enum" => |ei| std.mem.Alignment.fromByteUnits(@alignOf(ei.tag_type)),
        .array => |ai| maxAlignmentInner(ai.child, next_seen),
        .pointer => |pi| switch (pi.size) {
            .one => maxAlignmentInner(pi.child, next_seen),
            .slice => maxAlignmentInner(pi.child, next_seen)
                .max(std.mem.Alignment.fromByteUnits(pi.alignment orelse @alignOf(pi.child)))
                .max(std.mem.Alignment.fromByteUnits(@alignOf(root.Size))),
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .@"struct" => |si| blk: {
            var out: std.mem.Alignment = .@"1";
            inline for (si.fields) |field| {
                out = out.max(maxAlignmentInner(field.type, next_seen));
            }
            break :blk out;
        },
        .optional => |oi| maxAlignmentInner(oi.child, next_seen).max(.@"1"),
        .error_union => @compileError("Unsupported type in oneserial: " ++ @typeName(T)),
        .@"union" => |ui| blk: {
            var out: std.mem.Alignment = .@"1";
            if (ui.tag_type) |Tag| out = out.max(std.mem.Alignment.fromByteUnits(@alignOf(Tag)));
            inline for (ui.fields) |field| {
                out = out.max(maxAlignmentInner(field.type, next_seen));
            }
            break :blk out;
        },
        .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal, .@"opaque", .error_set => {
            @compileError("Unsupported type in oneserial: " ++ @typeName(T));
        },
    };
}

/// Returns the maximum alignment requirement for serialized `T`.
pub fn maxAlignmentOf(comptime T: type) std.mem.Alignment {
    @setEvalBranchQuota(1_000_000);
    return maxAlignmentInner(T, &.{});
}

/// Byte buffer type used for serialized `T` payloads.
pub fn SerializeBytes(comptime T: type) type {
    return []align(maxAlignmentOf(T).toByteUnits()) u8;
}

fn ReturnType(comptime trusted: bool, comptime T: type) type {
    return if (trusted) T else ValidationError!T;
}

fn containsDynamic(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one, .slice => true,
            .many, .c => false,
        },
        .array => |ai| containsDynamic(ai.child),
        .@"struct" => |si| blk: {
            inline for (si.fields) |field| {
                if (containsDynamic(field.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |oi| containsDynamic(oi.child),
        .error_union => false,
        .@"union" => |ui| blk: {
            inline for (ui.fields) |field| {
                if (containsDynamic(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn pointerSentinelInt(comptime P: type) usize {
    const ti = @typeInfo(P);
    if (ti != .pointer) {
        @compileError("invalidPointer() expects a pointer type, got " ++ @typeName(P));
    }
    if (ti.pointer.size == .slice) {
        @compileError("invalidPointer() does not accept slice types directly; pass the pointer type used by the slice `.ptr` field.");
    }
    const pointer_alignment = if (ti.pointer.alignment == 0) @alignOf(ti.pointer.child) else ti.pointer.alignment;
    const sentinel_alignment = @max(pointer_alignment, maxAlignmentOf(ti.pointer.child).toByteUnits());
    return std.math.maxInt(usize) & ~(sentinel_alignment - 1);
}

/// Returns a pointer sentinel value that is reserved for shim-based shape allocation.
/// Passing this pointer in a shim signals "allocate container, do not recurse through pointee data".
pub fn invalidPointer(comptime P: type) P {
    return @ptrFromInt(pointerSentinelInt(P));
}

fn isInvalidPointer(ptr: anytype) bool {
    const P = @TypeOf(ptr);
    return @intFromPtr(ptr) == pointerSentinelInt(P);
}

fn allocFromShimValue(comptime T: type, shim: *const T, gpa: std.mem.Allocator) error{OutOfMemory}!T {
    return shim_allocation.allocFromShimValue(T, shim, gpa, isInvalidPointer);
}

fn maybeSwapPod(comptime T: type, value: T, endian: std.builtin.Endian) T {
    if (endian == @import("builtin").target.cpu.arch.endian() or @sizeOf(T) <= 1) return value;

    return switch (@typeInfo(T)) {
        .int => if (@bitSizeOf(T) % 8 == 0) @byteSwap(value) else value,
        .float => blk: {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits: Bits = @bitCast(value);
            break :blk @bitCast(@byteSwap(bits));
        },
        .vector => |vi| blk: {
            if (@sizeOf(vi.child) <= 1 or @bitSizeOf(vi.child) % 8 != 0) break :blk value;
            var arr: [vi.len]vi.child = @bitCast(value);
            inline for (0..vi.len) |i| arr[i] = maybeSwapPod(vi.child, arr[i], endian);
            break :blk @bitCast(arr);
        },
        else => value,
    };
}

fn Writer() type {
    return struct {
        buffer: ?[]u8,
        endian: std.builtin.Endian,
        pos: usize = 0,

        fn init(buffer: ?[]u8, endian: std.builtin.Endian) @This() {
            return .{ .buffer = buffer, .endian = endian };
        }

        fn alignTo(self: *@This(), comptime alignment: usize) ValidationError!void {
            const new_pos = meta.alignForward(self.pos, alignment) catch return error.LengthOverflow;
            if (self.buffer) |buf| {
                if (new_pos > buf.len) return error.NotEnoughBytes;
                if (new_pos > self.pos) @memset(buf[self.pos..new_pos], 0);
            }
            self.pos = new_pos;
        }

        fn writeBytes(self: *@This(), bytes: []const u8) ValidationError!void {
            const end = std.math.add(usize, self.pos, bytes.len) catch return error.LengthOverflow;
            if (self.buffer) |buf| {
                if (end > buf.len) return error.NotEnoughBytes;
                @memcpy(buf[self.pos..end], bytes);
            }
            self.pos = end;
        }

        fn writePod(self: *@This(), comptime T: type, value: T) ValidationError!void {
            var tmp = maybeSwapPod(T, value, self.endian);
            try self.alignTo(@alignOf(T));
            try self.writeBytes(std.mem.asBytes(&tmp));
        }
    };
}

fn Reader() type {
    return struct {
        bytes: []const u8,
        pos: usize,
        checked: bool,
        endian: std.builtin.Endian,

        fn init(bytes: []const u8, checked: bool, endian: std.builtin.Endian) @This() {
            return .{ .bytes = bytes, .pos = 0, .checked = checked, .endian = endian };
        }

        fn initAt(bytes: []const u8, start: usize, checked: bool, endian: std.builtin.Endian) @This() {
            return .{ .bytes = bytes, .pos = start, .checked = checked, .endian = endian };
        }

        fn alignTo(self: *@This(), comptime alignment: usize) ValidationError!void {
            const new_pos = meta.alignForward(self.pos, alignment) catch return error.LengthOverflow;
            if (self.checked and new_pos > self.bytes.len) return error.NotEnoughBytes;
            self.pos = new_pos;
        }

        fn readBytes(self: *@This(), len: usize) ValidationError![]const u8 {
            const end = std.math.add(usize, self.pos, len) catch return error.LengthOverflow;
            if (self.checked and end > self.bytes.len) return error.NotEnoughBytes;
            const out = self.bytes[self.pos..end];
            self.pos = end;
            return out;
        }

        fn readPod(self: *@This(), comptime T: type) ValidationError!T {
            try self.alignTo(@alignOf(T));
            const bytes = try self.readBytes(@sizeOf(T));
            var out: T = undefined;
            @memcpy(std.mem.asBytes(&out), bytes);
            return maybeSwapPod(T, out, self.endian);
        }
    };
}

fn toOutOfBounds(_: anyerror) ValidationError {
    return error.OutOfBounds;
}

fn writeTag(comptime Tag: type, w: *Writer(), tag: Tag) ValidationError!void {
    switch (@typeInfo(Tag)) {
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw: Raw = @intCast(@intFromEnum(tag));
            try w.writePod(Raw, raw);
        },
        .int => try w.writePod(Tag, tag),
        else => @compileError("Unsupported union tag type: " ++ @typeName(Tag)),
    }
}

fn readTag(comptime Tag: type, r: *Reader()) ValidationError!Tag {
    switch (@typeInfo(Tag)) {
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw = try r.readPod(Raw);
            inline for (std.meta.fields(Tag)) |field| {
                const value: Tag = @field(Tag, field.name);
                if (raw == @as(Raw, @intCast(@intFromEnum(value)))) return value;
            }
            return error.InvalidUnionTag;
        },
        .int => return try r.readPod(Tag),
        else => @compileError("Unsupported union tag type: " ++ @typeName(Tag)),
    }
}

fn serializeValue(comptime T: type, w: *Writer(), value: *const T) ValidationError!void {
    switch (@typeInfo(T)) {
        .void, .null => return,
        .bool, .int, .float, .vector => try w.writePod(T, value.*),
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw: Raw = @intCast(@intFromEnum(value.*));
            try w.writePod(Raw, raw);
        },
        .array => |ai| {
            inline for (0..ai.len) |i| {
                try serializeValue(ai.child, w, &value.*[i]);
            }
        },
        .pointer => |pi| switch (pi.size) {
            .one => try serializeValue(pi.child, w, value.*),
            .slice => {
                const len_size: root.Size = meta.castUsize(root.Size, value.*.len) catch return error.LengthOverflow;
                try w.writePod(root.Size, len_size);
                for (value.*) |*elem| {
                    try serializeValue(pi.child, w, elem);
                }
            },
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                var field_copy = @field(value.*, field.name);
                try serializeValue(field.type, w, &field_copy);
            }
        },
        .optional => |oi| {
            if (value.*) |payload| {
                try w.writePod(u8, 1);
                var p = payload;
                try serializeValue(oi.child, w, &p);
            } else {
                try w.writePod(u8, 0);
            }
        },
        .error_union => @compileError("Unsupported type in oneserial: " ++ @typeName(T)),
        .@"union" => |ui| {
            const Tag = ui.tag_type orelse @compileError("Cannot serialize untagged union: " ++ @typeName(T));
            const tag: Tag = std.meta.activeTag(value.*);
            try writeTag(Tag, w, tag);
            switch (value.*) {
                inline else => |payload| {
                    var p = payload;
                    try serializeValue(@TypeOf(payload), w, &p);
                },
            }
        },
        .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal, .@"opaque", .error_set => {
            @compileError("Unsupported type in oneserial: " ++ @typeName(T));
        },
    }
}

fn skipValue(comptime T: type, r: *Reader()) ValidationError!void {
    switch (@typeInfo(T)) {
        .void, .null => return,
        .bool, .int, .float, .vector => {
            _ = try r.readPod(T);
        },
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw = try r.readPod(Raw);
            _ = std.meta.intToEnum(T, raw) catch return error.InvalidEnumTag;
        },
        .array => |ai| {
            inline for (0..ai.len) |_| {
                try skipValue(ai.child, r);
            }
        },
        .pointer => |pi| switch (pi.size) {
            .one => try skipValue(pi.child, r),
            .slice => {
                const len_size = try r.readPod(root.Size);
                const len = meta.usizeFromAnyInt(len_size) catch return error.LengthOverflow;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    try skipValue(pi.child, r);
                }
            },
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                try skipValue(field.type, r);
            }
        },
        .optional => |oi| {
            const tag = try r.readPod(u8);
            switch (tag) {
                0 => {},
                1 => try skipValue(oi.child, r),
                else => return error.InvalidTag,
            }
        },
        .error_union => @compileError("Unsupported type in oneserial: " ++ @typeName(T)),
        .@"union" => |ui| {
            const Tag = ui.tag_type orelse @compileError("Cannot skip untagged union: " ++ @typeName(T));
            const tag = try readTag(Tag, r);
            inline for (ui.fields) |field| {
                if (@field(Tag, field.name) == tag) {
                    try skipValue(field.type, r);
                    return;
                }
            }
            return error.InvalidUnionTag;
        },
        .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal, .@"opaque", .error_set => {
            @compileError("Unsupported type in oneserial: " ++ @typeName(T));
        },
    }
}

fn Decoded(comptime T: type) type {
    return struct { value: T };
}

fn freeDecoded(comptime T: type, gpa: std.mem.Allocator, value: *T) void {
    switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one => {
                freeDecoded(pi.child, gpa, @constCast(value.*));
                gpa.destroy(@constCast(value.*));
            },
            .slice => {
                if (@sizeOf(pi.child) > 0) {
                    for (value.*) |*elem| freeDecoded(pi.child, gpa, @constCast(elem));
                }
                gpa.free(@constCast(value.*));
            },
            .many, .c => {},
        },
        .array => |ai| inline for (0..ai.len) |i| freeDecoded(ai.child, gpa, &value.*[i]),
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                var field_copy = @field(value.*, field.name);
                freeDecoded(field.type, gpa, &field_copy);
            }
        },
        .optional => |oi| {
            if (value.*) |*payload| freeDecoded(oi.child, gpa, @constCast(payload));
        },
        .error_union => {},
        .@"union" => switch (value.*) {
            inline else => |*payload| freeDecoded(@TypeOf(payload.*), gpa, @constCast(payload)),
        },
        else => {},
    }
}

fn returnDecoded(comptime T: type, decoded: Decoded(T)) T {
    return decoded.value;
}

fn decodeValue(comptime T: type, r: *Reader(), gpa: std.mem.Allocator) DeserializeError!Decoded(T) {
    switch (@typeInfo(T)) {
        .void => return .{ .value = {} },
        .null => return .{ .value = null },
        .bool, .int, .float, .vector => return .{ .value = try r.readPod(T) },
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw = try r.readPod(Raw);
            inline for (std.meta.fields(T)) |field| {
                const value: T = @field(T, field.name);
                if (raw == @as(Raw, @intCast(@intFromEnum(value)))) return .{ .value = value };
            }
            return error.InvalidEnumTag;
        },
        .array => |ai| {
            var out: T = undefined;
            var initialized: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < initialized) : (i += 1) {
                    freeDecoded(ai.child, gpa, &out[i]);
                }
            }
            inline for (0..ai.len) |i| {
                out[i] = (try decodeValue(ai.child, r, gpa)).value;
                initialized = i + 1;
            }
            return .{ .value = out };
        },
        .pointer => |pi| switch (pi.size) {
            .one => {
                const child_ptr = try gpa.create(pi.child);
                errdefer gpa.destroy(child_ptr);
                child_ptr.* = (try decodeValue(pi.child, r, gpa)).value;
                return .{ .value = @as(T, child_ptr) };
            },
            .slice => {
                const len_size = try r.readPod(root.Size);
                const len = meta.usizeFromAnyInt(len_size) catch return error.LengthOverflow;
                const alignment = comptime std.mem.Alignment.fromByteUnits(pi.alignment orelse @alignOf(pi.child));
                var out = try gpa.alignedAlloc(pi.child, alignment, len);
                var initialized: usize = 0;
                errdefer {
                    var i: usize = 0;
                    while (i < initialized) : (i += 1) {
                        freeDecoded(pi.child, gpa, &out[i]);
                    }
                    gpa.free(out);
                }
                for (0..len) |i| {
                    out[i] = (try decodeValue(pi.child, r, gpa)).value;
                    initialized = i + 1;
                }
                return .{ .value = @as(T, out) };
            },
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .@"struct" => |si| {
            var out: T = undefined;
            var initialized: usize = 0;
            errdefer {
                inline for (si.fields, 0..) |field, i| {
                    if (i < initialized) {
                        var field_copy = @field(out, field.name);
                        freeDecoded(field.type, gpa, &field_copy);
                    }
                }
            }
            inline for (si.fields, 0..) |field, i| {
                @field(out, field.name) = (try decodeValue(field.type, r, gpa)).value;
                initialized = i + 1;
            }
            return .{ .value = out };
        },
        .optional => |oi| {
            const tag = try r.readPod(u8);
            var out: T = null;
            switch (tag) {
                0 => {},
                1 => out = (try decodeValue(oi.child, r, gpa)).value,
                else => return error.InvalidTag,
            }
            return .{ .value = out };
        },
        .error_union => @compileError("Unsupported type in oneserial: " ++ @typeName(T)),
        .@"union" => |ui| {
            const Tag = ui.tag_type orelse @compileError("Cannot decode untagged union: " ++ @typeName(T));
            const tag = try readTag(Tag, r);
            inline for (ui.fields) |field| {
                if (@field(Tag, field.name) == tag) {
                    const payload = (try decodeValue(field.type, r, gpa)).value;
                    return .{ .value = @unionInit(T, field.name, payload) };
                }
            }
            return error.InvalidUnionTag;
        },
        .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal, .@"opaque", .error_set => {
            @compileError("Unsupported type in oneserial: " ++ @typeName(T));
        },
    }
}

fn fieldTypeByName(comptime S: type, comptime field_name: []const u8) type {
    const si = @typeInfo(S).@"struct";
    inline for (si.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, field_name)) return field.type;
    }
    @compileError("Unknown field '" ++ field_name ++ "' on " ++ @typeName(S));
}

fn fieldStart(comptime S: type, comptime field_name: []const u8, bytes: []const u8, start: usize, checked: bool, endian: std.builtin.Endian) ValidationError!usize {
    var r = Reader().initAt(bytes, start, checked, endian);
    const si = @typeInfo(S).@"struct";
    inline for (si.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, field_name)) return r.pos;
        try skipValue(field.type, &r);
    }
    unreachable;
}

fn sliceLen(comptime SliceT: type, bytes: []const u8, start: usize, checked: bool, endian: std.builtin.Endian) ValidationError!usize {
    _ = SliceT;
    var r = Reader().initAt(bytes, start, checked, endian);
    const len_size = try r.readPod(root.Size);
    return meta.usizeFromAnyInt(len_size) catch error.LengthOverflow;
}

fn sliceElementStart(comptime SliceT: type, bytes: []const u8, start: usize, index: usize, checked: bool, endian: std.builtin.Endian) ValidationError!usize {
    const pi = @typeInfo(SliceT).pointer;
    var r = Reader().initAt(bytes, start, checked, endian);
    const len_size = try r.readPod(root.Size);
    const len = meta.usizeFromAnyInt(len_size) catch return error.LengthOverflow;
    if (checked and index >= len) return error.OutOfBounds;

    var i: usize = 0;
    while (i < index) : (i += 1) {
        try skipValue(pi.child, &r);
    }
    return r.pos;
}

/// Returns a typed view over serialized bytes for `T`.
/// When `trusted` is false, operations perform bounds/tag validation.
pub fn View(comptime T: type, comptime trusted: bool) type {
    return struct {
        bytes: []const u8,
        start: usize,
        endian: std.builtin.Endian,

        /// Returns a view for the named struct field.
        pub fn field(self: @This(), comptime field_name: []const u8) ReturnType(trusted, View(fieldTypeByName(T, field_name), trusted)) {
            if (@typeInfo(T) != .@"struct") {
                @compileError("field() only exists for struct views, got " ++ @typeName(T));
            }
            if (comptime trusted) {
                const s = fieldStart(T, field_name, self.bytes, self.start, false, self.endian) catch unreachable;
                return .{ .bytes = self.bytes, .start = s, .endian = self.endian };
            }
            const s = fieldStart(T, field_name, self.bytes, self.start, true, self.endian) catch |err| return toOutOfBounds(err);
            return .{ .bytes = self.bytes, .start = s, .endian = self.endian };
        }

        /// For dynamic values, returns a validated dynamic view.
        pub fn get(self: @This()) ReturnType(trusted, blk: {
            switch (@typeInfo(T)) {
                .pointer => |pi| if (pi.size == .one) break :blk View(pi.child, trusted),
                else => {},
            }
            break :blk @This();
        }) {
            switch (@typeInfo(T)) {
                .pointer => |pi| switch (pi.size) {
                    .one => {
                        if (comptime trusted) {
                            return .{ .bytes = self.bytes, .start = self.start, .endian = self.endian };
                        }
                        var r = Reader().initAt(self.bytes, self.start, true, self.endian);
                        skipValue(pi.child, &r) catch |err| return toOutOfBounds(err);
                        return .{ .bytes = self.bytes, .start = self.start, .endian = self.endian };
                    },
                    .slice => {
                        if (comptime trusted) return self;
                        var r = Reader().initAt(self.bytes, self.start, true, self.endian);
                        skipValue(T, &r) catch |err| return toOutOfBounds(err);
                        return self;
                    },
                    else => @compileError("get() unsupported for " ++ @typeName(T)),
                },
                else => {
                    if (!containsDynamic(T)) {
                        @compileError("get() is only available for dynamic values, got " ++ @typeName(T));
                    }
                    if (comptime trusted) return self;
                    var r = Reader().initAt(self.bytes, self.start, true, self.endian);
                    skipValue(T, &r) catch |err| return toOutOfBounds(err);
                    return self;
                },
            }
        }

        /// Returns slice length for slice views.
        pub fn len(self: @This()) ReturnType(trusted, usize) {
            const ti = @typeInfo(T);
            if (ti != .pointer or ti.pointer.size != .slice) {
                @compileError("len() is only available on slice views, got " ++ @typeName(T));
            }
            if (comptime trusted) {
                return sliceLen(T, self.bytes, self.start, false, self.endian) catch unreachable;
            }
            return sliceLen(T, self.bytes, self.start, true, self.endian) catch |err| return toOutOfBounds(err);
        }

        /// Returns the element view at `index` for slice views.
        pub fn at(self: @This(), index: usize) ReturnType(trusted, View(@typeInfo(T).pointer.child, trusted)) {
            const ti = @typeInfo(T);
            if (ti != .pointer or ti.pointer.size != .slice) {
                @compileError("at() is only available on slice views, got " ++ @typeName(T));
            }
            if (comptime trusted) {
                const s = sliceElementStart(T, self.bytes, self.start, index, false, self.endian) catch unreachable;
                return .{ .bytes = self.bytes, .start = s, .endian = self.endian };
            }
            const s = sliceElementStart(T, self.bytes, self.start, index, true, self.endian) catch |err| return toOutOfBounds(err);
            return .{ .bytes = self.bytes, .start = s, .endian = self.endian };
        }

        /// Returns the element view at `index` without bounds checks.
        pub fn atUnchecked(self: @This(), index: usize) View(@typeInfo(T).pointer.child, trusted) {
            const ti = @typeInfo(T);
            if (ti != .pointer or ti.pointer.size != .slice) {
                @compileError("atUnchecked() is only available on slice views, got " ++ @typeName(T));
            }
            const s = sliceElementStart(T, self.bytes, self.start, index, false, self.endian) catch unreachable;
            return .{ .bytes = self.bytes, .start = s, .endian = self.endian };
        }

        /// Returns a copy of this view using a different wire endianness.
        pub fn withEndian(self: @This(), endian: std.builtin.Endian) @This() {
            var out = self;
            out.endian = endian;
            return out;
        }

        /// Decodes the view into a value, using the page allocator for dynamic children.
        pub fn value(self: @This()) ReturnType(trusted, T) {
            var r = Reader().initAt(self.bytes, self.start, !trusted, self.endian);
            const decoded = decodeValue(T, &r, std.heap.page_allocator) catch |err| {
                if (comptime trusted) unreachable;
                return toOutOfBounds(err);
            };
            const out: T = returnDecoded(T, decoded);
            return @as(T, out);
        }

        /// Deep-decodes the view into owned memory allocated from `gpa`.
        pub fn toOwned(self: @This(), gpa: std.mem.Allocator) DeserializeError!T {
            var r = Reader().initAt(self.bytes, self.start, !trusted, self.endian);
            const decoded = try decodeValue(T, &r, gpa);
            const out: T = returnDecoded(T, decoded);
            return @as(T, out);
        }
    };
}

fn validateExact(comptime T: type, bytes: []const u8, endian: std.builtin.Endian) ValidationError!void {
    var r = Reader().init(bytes, true, endian);
    try skipValue(T, &r);
    if (r.pos != bytes.len) return error.TooManyBytes;
}

fn decodeRootExact(comptime T: type, bytes: []const u8, checked: bool, endian: std.builtin.Endian, gpa: std.mem.Allocator) DeserializeError!Decoded(T) {
    var r = Reader().init(bytes, checked, endian);
    const out = try decodeValue(T, &r, gpa);
    if (checked and r.pos != bytes.len) return error.TooManyBytes;
    return out;
}

/// Returns the converter namespace for `T` with a default wire endianness.
pub fn Converter(comptime T: type, comptime default_endian: std.builtin.Endian) type {
    return struct {
        /// Source value type handled by this converter namespace.
        pub const Type = T;
        /// Maximum alignment required by serialized bytes for `T`.
        pub const alignment = maxAlignmentOf(T);
        /// A wrapper around untrusted data.
        /// Bound checks are done on every access
        pub const Untrusted = struct {
            bytes: []const u8,
            endian: std.builtin.Endian,
            view: View(T, false),

            /// Creates an untrusted handle around raw serialized bytes.
            pub fn init(bytes: []const u8) @This() {
                return .{
                    .bytes = bytes,
                    .endian = default_endian,
                    .view = .{ .bytes = bytes, .start = 0, .endian = default_endian },
                };
            }

            /// Returns a copy with a different wire endianness.
            pub fn withEndian(self: @This(), endian: std.builtin.Endian) @This() {
                var out = self;
                out.endian = endian;
                out.view.endian = endian;
                return out;
            }

            /// Fully validates the buffer and upgrades to a trusted handle.
            pub fn validate(self: @This()) ValidationError!Trusted {
                try validateExact(T, self.bytes, self.endian);
                return Trusted.initWithEndian(self.bytes, self.endian);
            }

            /// Converts to trusted without validation.
            pub fn unsafeTrusted(self: @This()) Trusted {
                return Trusted.initWithEndian(self.bytes, self.endian);
            }

            /// Decodes the full buffer into owned memory after validation.
            pub fn toOwned(self: @This(), gpa: std.mem.Allocator) DeserializeError!T {
                const decoded = try decodeRootExact(T, self.bytes, true, self.endian, gpa);
                const out: T = returnDecoded(T, decoded);
                return @as(T, out);
            }

            /// Returns a checked field view for struct roots.
            pub fn field(self: @This(), comptime field_name: []const u8) ValidationError!View(fieldTypeByName(T, field_name), false) {
                return self.view.field(field_name);
            }

            /// For dynamic roots, returns a checked dynamic view.
            pub fn get(self: @This()) ReturnType(false, blk: {
                switch (@typeInfo(T)) {
                    .pointer => |pi| if (pi.size == .one) break :blk View(pi.child, false),
                    else => {},
                }
                break :blk View(T, false);
            }) {
                return self.view.get();
            }

            /// Returns the length for slice roots.
            pub fn len(self: @This()) ValidationError!usize {
                return self.view.len();
            }

            /// Returns a checked element view for slice roots.
            pub fn at(self: @This(), index: usize) ValidationError!View(@typeInfo(T).pointer.child, false) {
                return self.view.at(index);
            }

            /// Returns an unchecked element view for slice roots.
            pub fn atUnchecked(self: @This(), index: usize) View(@typeInfo(T).pointer.child, false) {
                return self.view.atUnchecked(index);
            }

            /// Decodes the root value using checked semantics.
            pub fn value(self: @This()) ReturnType(false, T) {
                return self.view.value();
            }
        };

        /// Trusted typed access over serialized bytes.
        pub const Trusted = struct {
            bytes: []const u8,
            endian: std.builtin.Endian,
            view: View(T, true),

            /// Creates a trusted handle around bytes that are already trusted.
            pub fn init(bytes: []const u8) @This() {
                return .{
                    .bytes = bytes,
                    .endian = default_endian,
                    .view = .{ .bytes = bytes, .start = 0, .endian = default_endian },
                };
            }

            fn initWithEndian(bytes: []const u8, endian: std.builtin.Endian) @This() {
                var out = init(bytes);
                out.endian = endian;
                out.view.endian = endian;
                return out;
            }

            /// Returns a copy with a different wire endianness.
            pub fn withEndian(self: @This(), endian: std.builtin.Endian) @This() {
                var out = self;
                out.endian = endian;
                out.view.endian = endian;
                return out;
            }

            /// Deep-decodes the full buffer into owned memory.
            pub fn toOwned(self: @This(), gpa: std.mem.Allocator) DeserializeError!T {
                const decoded = try decodeRootExact(T, self.bytes, false, self.endian, gpa);
                const out: T = returnDecoded(T, decoded);
                return @as(T, out);
            }

            /// Returns a field view for struct roots.
            pub fn field(self: @This(), comptime field_name: []const u8) View(fieldTypeByName(T, field_name), true) {
                return self.view.field(field_name);
            }

            /// For dynamic roots, returns a dynamic view.
            pub fn get(self: @This()) ReturnType(true, blk: {
                switch (@typeInfo(T)) {
                    .pointer => |pi| if (pi.size == .one) break :blk View(pi.child, true),
                    else => {},
                }
                break :blk View(T, true);
            }) {
                return self.view.get();
            }

            /// Returns the length for slice roots.
            pub fn len(self: @This()) usize {
                return self.view.len();
            }

            /// Returns an element view for slice roots.
            pub fn at(self: @This(), index: usize) View(@typeInfo(T).pointer.child, true) {
                return self.view.at(index);
            }

            /// Returns an unchecked element view for slice roots.
            pub fn atUnchecked(self: @This(), index: usize) View(@typeInfo(T).pointer.child, true) {
                return self.view.atUnchecked(index);
            }

            /// Decodes the root value.
            pub fn value(self: @This()) T {
                return self.view.value();
            }
        };

        /// Owns the serialized byte buffer for a value of `T`.
        pub const Wrapper = struct {
            memory: SerializeBytes(T),

            /// Serializes `value` into newly allocated wrapper-owned memory.
            pub fn init(value: *const T, gpa: std.mem.Allocator) SerializeError!@This() {
                return .{ .memory = try serializeAlloc(value, gpa) };
            }

            /// Frees the owned serialized memory.
            pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
                gpa.free(self.memory);
            }

            /// Create an untrusted wrapper around the data; bound checks are done on every access
            pub fn untrusted(self: @This()) Untrusted {
                return Untrusted.init(self.memory);
            }

            /// Assume that all the pointers do infact point to in-bounds memory.
            /// DANGER: ONLY CALL THIS ON DATA YOU TRUST
            pub fn trustedUnchecked(self: @This()) Trusted {
                return Trusted.init(self.memory);
            }

            /// Do bounds checking and Converter to trusted
            pub fn validate(self: @This()) !Trusted {
                return self.untrusted().validate();
            }
        };

        /// Returns the serialized byte size needed for `value`.
        pub fn serializedSize(value: *const T) ValidationError!usize {
            var w = Writer().init(null, default_endian);
            try serializeValue(T, &w, value);
            return w.pos;
        }

        /// Allocates an owned shape from `shim` without copying payload bytes.
        /// Pointer sentinels from `invalidPointer()` stop deep recursion for that subtree.
        pub fn allocFromShim(shim: *const T, gpa: std.mem.Allocator) error{OutOfMemory}!T {
            return allocFromShimValue(T, shim, gpa);
        }

        /// Serializes `value` into a newly allocated byte buffer.
        pub fn serializeAlloc(value: *const T, gpa: std.mem.Allocator) SerializeError!SerializeBytes(T) {
            const size = try serializedSize(value);
            const bytes = try gpa.alignedAlloc(u8, alignment, size);
            errdefer gpa.free(bytes);
            var w = Writer().init(bytes, default_endian);
            try serializeValue(T, &w, value);
            if (w.pos != size) return error.NoSpaceLeft;
            return bytes;
        }

        /// Creates an untrusted handle over `bytes`.
        pub fn untrusted(bytes: []const u8) Untrusted {
            return Untrusted.init(bytes);
        }

        /// Creates a trusted handle over `bytes` without validation.
        pub fn trustedUnchecked(bytes: []const u8) Trusted {
            return Trusted.init(bytes);
        }
    };
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
