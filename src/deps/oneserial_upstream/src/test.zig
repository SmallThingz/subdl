const std = @import("std");
const builtin = @import("builtin");
const one = @import("root.zig");
const meta = @import("meta.zig");
const testing = std.testing;

fn expectEquivalent(expected: anytype, actual: anytype) anyerror!void {
    const T = @TypeOf(expected);
    if (T != @TypeOf(actual)) return error.TestExpectedEqual;

    switch (@typeInfo(T)) {
        .noreturn, .@"opaque", .frame, .@"anyframe" => @compileError("Unsupported type in expectEquivalent: " ++ @typeName(T)),
        .void => return,
        .type => try testing.expect(expected == actual),
        .bool, .int, .float, .comptime_float, .comptime_int, .enum_literal, .@"enum", .@"fn", .error_set => {
            try testing.expect(expected == actual);
        },
        .pointer => |pointer| switch (pointer.size) {
            .one, .c => try expectEquivalent(expected.*, actual.*),
            .many => try testing.expect(expected == actual),
            .slice => {
                try testing.expectEqual(expected.len, actual.len);
                for (expected, actual) |ev, av| {
                    try expectEquivalent(ev, av);
                }
            },
        },
        .array => |array| {
            inline for (0..array.len) |i| {
                try expectEquivalent(expected[i], actual[i]);
            }
        },
        .vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                try testing.expect(std.meta.eql(expected[i], actual[i]));
            }
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                try expectEquivalent(@field(expected, field.name), @field(actual, field.name));
            }
        },
        .@"union" => |ui| {
            if (ui.tag_type == null) @compileError("Cannot compare untagged union: " ++ @typeName(T));
            const Tag = std.meta.Tag(T);
            try expectEquivalent(@as(Tag, expected), @as(Tag, actual));
            switch (expected) {
                inline else => |payload, tag| try expectEquivalent(payload, @field(actual, @tagName(tag))),
            }
        },
        .optional => {
            if (expected) |ep| {
                if (actual) |ap| {
                    try expectEquivalent(ep, ap);
                } else {
                    return error.TestExpectedEqual;
                }
            } else {
                try testing.expect(actual == null);
            }
        },
        .error_union => {
            if (expected) |ep| {
                if (actual) |ap| {
                    try expectEquivalent(ep, ap);
                } else |_| {
                    return error.TestExpectedEqual;
                }
            } else |ee| {
                if (actual) |_| {
                    return error.TestExpectedEqual;
                } else |ae| {
                    try expectEquivalent(ee, ae);
                }
            }
        },
        else => @compileError("Unsupported type in expectEquivalent: " ++ @typeName(T)),
    }
}

fn needsFree(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one, .slice => true,
            .many, .c => false,
        },
        .array => |ai| needsFree(ai.child),
        .@"struct" => |si| blk: {
            inline for (si.fields) |field| {
                if (needsFree(field.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |oi| needsFree(oi.child),
        .error_union => |ei| needsFree(ei.payload),
        .@"union" => |ui| blk: {
            inline for (ui.fields) |field| {
                if (needsFree(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn freeOwned(comptime T: type, gpa: std.mem.Allocator, value: *T) void {
    switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one => {
                freeOwned(pi.child, gpa, @constCast(value.*));
                gpa.destroy(@constCast(value.*));
            },
            .slice => {
                if (needsFree(pi.child) and @sizeOf(pi.child) > 0) {
                    for (value.*) |elem| {
                        var item = elem;
                        freeOwned(pi.child, gpa, &item);
                    }
                }
                gpa.free(@constCast(value.*));
            },
            .many, .c => {},
        },
        .array => |ai| {
            if (needsFree(ai.child)) {
                inline for (0..ai.len) |i| {
                    var item = value.*[i];
                    freeOwned(ai.child, gpa, &item);
                }
            }
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                if (needsFree(field.type)) {
                    var field_copy = @field(value.*, field.name);
                    freeOwned(field.type, gpa, &field_copy);
                }
            }
        },
        .optional => |oi| {
            if (value.*) |*payload| freeOwned(oi.child, gpa, @constCast(payload));
        },
        .error_union => |ei| {
            if (value.*) |*payload| freeOwned(ei.payload, gpa, @constCast(payload)) else |_| {}
        },
        .@"union" => {
            switch (value.*) {
                inline else => |*payload| freeOwned(@TypeOf(payload.*), gpa, @constCast(payload)),
            }
        },
        else => {},
    }
}

fn testRoundtrip(_value: anytype) !void {
    const value = _value;
    const T = @TypeOf(value);

    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const expected_alignment = one.Converter(T, .{}).alignment.toByteUnits();
    try testing.expect(std.mem.isAligned(@intFromPtr(bytes.ptr), expected_alignment));

    const untrusted = one.Untrusted(T, .{}).init(bytes);
    const trusted = try untrusted.validate();
    const unsafe_trusted = untrusted.unsafeTrusted();

    const out_untrusted = try untrusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_untrusted));
    try expectEquivalent(value, out_untrusted);

    const out_trusted = try trusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_trusted));
    try expectEquivalent(value, out_trusted);

    const out_unsafe = try unsafe_trusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_unsafe));
    try expectEquivalent(value, out_unsafe);

    var wrapped = try one.Wrapper(T, .{}).init(&value, testing.allocator);
    defer wrapped.deinit(testing.allocator);
    try testing.expect(std.mem.isAligned(@intFromPtr(wrapped.memory.ptr), expected_alignment));

    const wrapped_trusted = try wrapped.validate();
    const out_wrapped = try wrapped_trusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_wrapped));
    try expectEquivalent(value, out_wrapped);
}

fn toOwnedNoLeakOnOom(allocator: std.mem.Allocator) !void {
    const T = struct {
        a: []const u8,
        b: []const []const u8,
        c: struct {
            x: []const u16,
            y: []const u8,
        },
    };

    const value = T{
        .a = "hello",
        .b = &.{ "one", "two", "three" },
        .c = .{ .x = &.{ 10, 20, 30, 40 }, .y = "world" },
    };

    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const out = try one.Untrusted(T, .{}).init(bytes).toOwned(allocator);
    defer freeOwned(T, allocator, @constCast(&out));
}

fn allocFromShimNoLeakOnOom(allocator: std.mem.Allocator) !void {
    const Child = struct {
        weights: []const u16,
    };
    const T = struct {
        names: []const []const u8,
        maybe: ?[]const u8,
        child: *const Child,
    };

    const child_shim = Child{ .weights = &.{ 1, 2, 3, 4 } };
    const shim = T{
        .names = &.{ "one", "two", "three" },
        .maybe = "present",
        .child = &child_shim,
    };

    const out = try one.allocFromShim(T, .{}, &shim, allocator);
    defer freeOwned(T, allocator, @constCast(&out));

    try testing.expectEqual(@as(usize, 3), out.names.len);
    try testing.expect(out.maybe != null);
    try testing.expectEqual(@as(usize, 7), out.maybe.?.len);
    try testing.expectEqual(@as(usize, 4), out.child.weights.len);
}

test "primitives" {
    try testRoundtrip(@as(u32, 42));
    try testRoundtrip(@as(f64, 123.456));
    try testRoundtrip(@as(bool, true));
    try testRoundtrip(@as(void, {}));
}

test "pointers" {
    var x: u64 = 12345;
    try testRoundtrip(@as(*const u64, &x));

    const p1: *const u64 = &x;
    const p2: *const *const u64 = &p1;
    try testRoundtrip(p2);
}

test "slices" {
    try testRoundtrip(@as([]const u8, "hello zig"));

    const Point = struct { x: u8, y: u8 };
    try testRoundtrip(@as([]const Point, &.{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } }));

    try testRoundtrip(@as([]const []const u8, &.{ "hello", "world", "zig", "rocks" }));
    try testRoundtrip(@as([]const u8, &.{}));
    try testRoundtrip(@as([]const []const u8, &.{}));
    try testRoundtrip(@as([]const []const u8, &.{ "", "a", "" }));
}

test "arrays" {
    try testRoundtrip([4]u8{ 1, 2, 3, 4 });

    const Point = struct { x: u8, y: u8 };
    try testRoundtrip([2]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } });
    try testRoundtrip([2][2]u8{ .{ 1, 2 }, .{ 3, 4 } });
    try testRoundtrip([0]u8{});
}

test "structs and enums" {
    const Point = struct { x: i32, y: i32 };
    const Line = struct { p1: Point, p2: Point };
    const Color = enum { red, green, blue };

    try testRoundtrip(Point{ .x = -10, .y = 20 });
    try testRoundtrip(Line{ .p1 = .{ .x = 1, .y = 2 }, .p2 = .{ .x = 3, .y = 4 } });
    try testRoundtrip(Color.green);
}

test "optionals" {
    try testRoundtrip(@as(?i32, 42));
    try testRoundtrip(@as(?i32, null));

    var y: i32 = 123;
    try testRoundtrip(@as(?*const i32, &y));
    try testRoundtrip(@as(?*const i32, null));
}

test "tagged unions" {
    const Payload = union(enum) {
        a: u32,
        b: bool,
        c: void,
    };

    try testRoundtrip(Payload{ .a = 99 });
    try testRoundtrip(Payload{ .b = false });
    try testRoundtrip(Payload{ .c = {} });
}

test "complex struct" {
    const Nested = struct {
        c: u4,
        d: bool,
    };

    const KitchenSink = struct {
        a: i32,
        b: []const u8,
        c: [2]Nested,
        d: ?*const i32,
        e: f32,
    };

    const i: i32 = 42;
    var value = KitchenSink{
        .a = -1,
        .b = "dynamic slice",
        .c = .{ .{ .c = 1, .d = true }, .{ .c = 2, .d = false } },
        .d = &i,
        .e = 3.14,
    };

    try testRoundtrip(value);

    value.b = "";
    try testRoundtrip(value);

    value.d = null;
    try testRoundtrip(value);
}

test "slice of complex structs" {
    const Item = struct {
        id: u64,
        name: []const u8,
        is_active: bool,
    };

    const items = [_]Item{
        .{ .id = 1, .name = "first", .is_active = true },
        .{ .id = 2, .name = "second", .is_active = false },
        .{ .id = 3, .name = "", .is_active = true },
    };

    try testRoundtrip(items[0..]);
}

test "complex composition" {
    const Complex1 = struct { a: u32, b: u32, c: u32 };
    const Complex2 = struct { a: Complex1, b: []const Complex1 };
    const SuperComplex = struct {
        a: Complex1,
        b: Complex2,
        c: []const union(enum) {
            a: Complex1,
            b: Complex2,
        },
    };

    const value = SuperComplex{
        .a = .{ .a = 1, .b = 2, .c = 3 },
        .b = .{
            .a = .{ .a = 4, .b = 5, .c = 6 },
            .b = &.{.{ .a = 7, .b = 8, .c = 9 }},
        },
        .c = &.{
            .{ .a = .{ .a = 10, .b = 11, .c = 12 } },
            .{ .b = .{ .a = .{ .a = 13, .b = 14, .c = 15 }, .b = &.{.{ .a = 16, .b = 17, .c = 18 }} } },
        },
    };

    try testRoundtrip(value);
}

test "multiple dynamic fields and non contiguous layout" {
    const UserProfile = struct {
        username: []const u8,
        user_id: u64,
        bio: []const u8,
        karma: i32,
        avatar_url: []const u8,
    };

    try testRoundtrip(UserProfile{
        .username = "zigger",
        .user_id = 1234,
        .bio = "Loves comptime and robust software.",
        .karma = 9999,
        .avatar_url = "http://ziglang.org/logo.svg",
    });
}

test "packed struct with mixed alignment fields" {
    const MixedPack = packed struct {
        a: u2,
        b: u8,
        c: u32,
        d: bool,
    };

    try testRoundtrip(MixedPack{ .a = 3, .b = 't', .c = 1234567, .d = true });
}

test "zero-sized and void-heavy types" {
    const ZST1 = struct {
        a: u32,
        b: void,
        c: [0]u8,
        d: []const u8,
        e: bool,
    };

    try testRoundtrip(ZST1{ .a = 123, .b = {}, .c = .{}, .d = "non-zst", .e = false });

    const ZST2 = struct {
        a: u32,
        zst1: void,
        zst_array: [0]u64,
        dynamic_zst_slice: []const void,
        zst_union: union(enum) { z: void, d: u64 },
        e: bool,
    };

    try testRoundtrip(ZST2{
        .a = 123,
        .zst1 = {},
        .zst_array = .{},
        .dynamic_zst_slice = &.{ {}, {}, {} },
        .zst_union = .{ .z = {} },
        .e = true,
    });

    try testRoundtrip(ZST2{
        .a = 123,
        .zst1 = {},
        .zst_array = .{},
        .dynamic_zst_slice = &.{ {}, {}, {} },
        .zst_union = .{ .d = 999 },
        .e = true,
    });
}

test "array of unions with dynamic fields" {
    const Message = union(enum) {
        text: []const u8,
        code: u32,
        err: void,
    };

    const messages = [3]Message{
        .{ .text = "hello" },
        .{ .code = 404 },
        .{ .text = "world" },
    };

    try testRoundtrip(messages);
}

test "pointer and optional abuse" {
    const Point = struct { x: i32, y: i32 };
    const PointerAbuse = struct {
        a: ?*const Point,
        b: *const ?Point,
        c: ?*const ?Point,
        d: []const ?*const ?Point,
    };

    const p1: Point = .{ .x = 1, .y = 1 };
    const p2: ?Point = .{ .x = 2, .y = 2 };
    const p3: ?Point = null;

    const value = PointerAbuse{
        .a = &p1,
        .b = &p2,
        .c = &p2,
        .d = &.{ &p2, null, &p3 },
    };

    try testRoundtrip(value);
}

test "deeply nested with late dynamic field" {
    const Level4 = struct { data: []const u8 };
    const Level3 = struct { l4: Level4 };
    const Level2 = struct { l3: Level3, val: u64 };
    const Level1 = struct { l2: Level2 };

    try testRoundtrip(Level1{
        .l2 = .{
            .l3 = .{ .l4 = .{ .data = "we need to go deeper" } },
            .val = 99,
        },
    });
}

test "union with multiple dynamic fields" {
    const Packet = union(enum) {
        message: []const u8,
        points: []const struct { x: f32, y: f32 },
        code: u32,
    };

    try testRoundtrip(Packet{ .message = "hello world" });
    try testRoundtrip(Packet{ .points = &.{ .{ .x = 1.0, .y = 2.0 }, .{ .x = 3.0, .y = 4.0 } } });
    try testRoundtrip(Packet{ .code = 404 });
}

test "deep optional and pointer nesting" {
    const DeepOptional = struct { val: ??*const u32 };
    const x: u32 = 123;

    try testRoundtrip(DeepOptional{ .val = &x });
    try testRoundtrip(DeepOptional{ .val = @as(?*const u32, null) });
    try testRoundtrip(DeepOptional{ .val = @as(??*const u32, null) });
}

test "recursive linked list" {
    const Node = struct {
        payload: u32,
        next: ?*const @This(),
    };

    const n4 = Node{ .payload = 4, .next = null };
    const n3 = Node{ .payload = 3, .next = &n4 };
    const n2 = Node{ .payload = 2, .next = &n3 };
    const n1 = Node{ .payload = 1, .next = &n2 };

    try testRoundtrip(n1);
}

test "mutual recursion" {
    const Namespace = struct {
        const NodeA = struct {
            name: []const u8,
            b: ?*const NodeB,
        };
        const NodeB = struct {
            value: u32,
            a: ?*const NodeA,
        };
    };

    const NodeA = Namespace.NodeA;
    const NodeB = Namespace.NodeB;

    const a2 = NodeA{ .name = "a2", .b = null };
    const b1 = NodeB{ .value = 100, .a = &a2 };
    const a1 = NodeA{ .name = "a1", .b = &b1 };

    try testRoundtrip(a1);
}

test "deeply nested mutual recursion without cycles" {
    const Namespace = struct {
        const MegaA = struct {
            id: u32,
            description: []const u8,
            next: ?*const @This(),
            child_b: *const NodeB,
        };

        const NodeB = struct {
            value: f64,
            relatives: [2]?*const @This(),
            next_a: ?*const MegaA,
            leaf: ?*const Leaf,
        };

        const Leaf = struct {
            data: []const u8,
        };
    };

    const MegaA = Namespace.MegaA;
    const NodeB = Namespace.NodeB;
    const Leaf = Namespace.Leaf;

    const leaf1 = Leaf{ .data = "Leaf Node One" };
    const leaf2 = Leaf{ .data = "Leaf Node Two" };

    const b_leaf_1 = NodeB{ .value = 1.1, .next_a = null, .relatives = .{ null, null }, .leaf = &leaf1 };
    const b_leaf_2 = NodeB{ .value = 2.2, .next_a = null, .relatives = .{ null, null }, .leaf = &leaf2 };

    const a_intermediate = MegaA{ .id = 100, .description = "Intermediate A", .next = null, .child_b = &b_leaf_1 };
    const b_middle = NodeB{ .value = 3.3, .next_a = &a_intermediate, .relatives = .{ &b_leaf_1, &b_leaf_2 }, .leaf = null };
    const a_before_root = MegaA{ .id = 200, .description = "Almost Root A", .next = null, .child_b = &b_leaf_2 };
    const root_node = MegaA{ .id = 1, .description = "The Root", .next = &a_before_root, .child_b = &b_middle };

    try testRoundtrip(root_node);
}

test "mutual recursion with complex mixed layout (acyclic data)" {
    const Namespace = struct {
        const Stage = enum { cold, warm, hot };
        const Kind = enum { leaf, branch };

        const NodeA = struct {
            id: u32,
            stage: Stage,
            label: []const u8,
            links: [2]?*const NodeB,
            meta: union(enum) {
                none: void,
                codes: [3]u16,
                tags: []const []const u8,
            },
            status: union(enum) { ok: []const u8, bad: void },
        };

        const NodeB = struct {
            kind: Kind,
            weights: []const f32,
            back: ?*const NodeA,
            children: []const ?*const NodeA,
            payload: union(enum) {
                n: i64,
                bytes: []const u8,
                flags: [4]bool,
            },
        };
    };

    const NodeA = Namespace.NodeA;
    const NodeB = Namespace.NodeB;

    const a3 = NodeA{
        .id = 3,
        .stage = .hot,
        .label = "a3",
        .links = .{ null, null },
        .meta = .{ .codes = .{ 1, 2, 3 } },
        .status = .{ .ok = "ok-a3" },
    };

    const b2 = NodeB{
        .kind = .leaf,
        .weights = &.{ 0.5, 0.75 },
        .back = &a3,
        .children = &.{null},
        .payload = .{ .flags = .{ true, false, true, false } },
    };

    const a2 = NodeA{
        .id = 2,
        .stage = .warm,
        .label = "a2",
        .links = .{ null, &b2 },
        .meta = .{ .tags = &.{ "k1", "k2" } },
        .status = .{ .bad = {} },
    };

    const b1 = NodeB{
        .kind = .branch,
        .weights = &.{ 1.0, 2.0, 4.0 },
        .back = &a2,
        .children = &.{ &a2, &a3, null },
        .payload = .{ .bytes = "b1-payload" },
    };

    const a1 = NodeA{
        .id = 1,
        .stage = .cold,
        .label = "a1-root",
        .links = .{ &b1, null },
        .meta = .{ .none = {} },
        .status = .{ .ok = "ok-a1" },
    };

    try testRoundtrip(a1);
}

test "multi-level mutual recursion with unions slices arrays pointers enums (acyclic data)" {
    const Namespace = struct {
        const Mode = enum { stable, degraded, emergency };
        const BranchKind = enum { ingest, process, emit };
        const ChunkTag = enum { alpha, beta, gamma };

        const Root = struct {
            mode: Mode,
            title: []const u8,
            branch: *const Branch,
            history: [2]?*const Branch,
            annotations: []const union(enum) {
                text: []const u8,
                marker: u32,
                empty: void,
            },
        };

        const Branch = struct {
            kind: BranchKind,
            parent: ?*const Root,
            leaves: []const *const Leaf,
            chooser: union(enum) {
                primary: *const Leaf,
                alt: ?*const Leaf,
                packed_bytes: [2]u8,
            },
            health: union(enum) { healthy: []const u8, offline: void },
        };

        const Leaf = struct {
            idx: u16,
            attrs: [3]u8,
            next: ?*const Leaf,
            owner: ?*const Branch,
            chunks: []const Chunk,
        };

        const Chunk = struct {
            tag: ChunkTag,
            data: []const u8,
            root_ref: ?*const Root,
        };
    };

    const Root = Namespace.Root;
    const Branch = Namespace.Branch;
    const Leaf = Namespace.Leaf;
    const Chunk = Namespace.Chunk;

    const c1 = Chunk{ .tag = .alpha, .data = "c1", .root_ref = null };
    const c2 = Chunk{ .tag = .beta, .data = "chunk-two", .root_ref = null };
    const c3 = Chunk{ .tag = .gamma, .data = "", .root_ref = null };

    const leaf3 = Leaf{
        .idx = 3,
        .attrs = .{ 9, 9, 9 },
        .next = null,
        .owner = null,
        .chunks = &.{c3},
    };

    const leaf2 = Leaf{
        .idx = 2,
        .attrs = .{ 4, 5, 6 },
        .next = &leaf3,
        .owner = null,
        .chunks = &.{c2},
    };

    const leaf1 = Leaf{
        .idx = 1,
        .attrs = .{ 1, 2, 3 },
        .next = &leaf2,
        .owner = null,
        .chunks = &.{ c1, c2 },
    };

    const branch2 = Branch{
        .kind = .emit,
        .parent = null,
        .leaves = &.{&leaf3},
        .chooser = .{ .primary = &leaf3 },
        .health = .{ .offline = {} },
    };

    const branch1 = Branch{
        .kind = .process,
        .parent = null,
        .leaves = &.{ &leaf1, &leaf2, &leaf3 },
        .chooser = .{ .alt = &leaf2 },
        .health = .{ .healthy = "healthy" },
    };

    const root2 = Root{
        .mode = .degraded,
        .title = "root-2",
        .branch = &branch2,
        .history = .{ null, null },
        .annotations = &.{ .{ .marker = 2 }, .{ .text = "backup" } },
    };

    const root1 = Root{
        .mode = .stable,
        .title = "root-1",
        .branch = &branch1,
        .history = .{ &branch2, null },
        .annotations = &.{ .{ .text = "primary" }, .{ .empty = {} }, .{ .marker = 42 } },
    };

    _ = root2; // keep second root alive for pointer shape variations in this test scope
    try testRoundtrip(root1);
}

test "nested unions and optionals" {
    const Payload = union(enum) { none: void, some: ?[]const u8, fail: bool };
    const S = struct { p: Payload };

    try testRoundtrip(S{ .p = .{ .some = @as([]const u8, "nest") } });
    try testRoundtrip(S{ .p = .{ .some = @as(?[]const u8, null) } });
    try testRoundtrip(S{ .p = .{ .fail = true } });
}

test "union with mixed static and dynamic fields" {
    const MixedUnion = union(enum) {
        static: u64,
        dynamic: []const u8,
        nested_dynamic: struct { a: []const u32 },
    };

    try testRoundtrip(MixedUnion{ .static = 12345 });
    try testRoundtrip(MixedUnion{ .dynamic = "hello union" });
    try testRoundtrip(MixedUnion{ .nested_dynamic = .{ .a = &.{ 1, 2, 3 } } });
}

test "zero-sized array of dynamic types" {
    const S = struct {
        items: [0]struct { s: []const u8 },
    };
    try testRoundtrip(S{ .items = .{} });
}

test "alignment stress tests" {
    const StrictAlign = struct {
        a: []const u8,
        b: []align(16) const u32,
        c: u8,
    };

    const v1 = StrictAlign{
        .a = "bit",
        .b = comptime blk: {
            const retval: [2]u32 align(16) = .{ 0xDEADBEEF, 0xCAFEBABE };
            break :blk retval[0..];
        },
        .c = 1,
    };

    const v2 = StrictAlign{
        .a = "bit_by_bitset",
        .b = comptime blk: {
            const retval: [6]u32 align(16) = .{ 0xDEADBEEF, 0xCAFEBABE, 0xB00BF00D, 0xDEADBEEF, 0xCAFEBABE, 0xB00BF00D };
            break :blk retval[0..];
        },
        .c = 1,
    };

    try testRoundtrip(v1);
    try testRoundtrip(v2);

    const expected = one.Converter(StrictAlign, .{}).alignment.toByteUnits();
    try testing.expectEqual(@as(usize, 16), expected);
}

test "vector types" {
    const v: @Vector(4, f32) = .{ 1.1, 2.2, 3.3, 4.4 };
    try testRoundtrip(v);
}

test "recursive struct with multiple paths" {
    const Node = struct {
        child_a: ?*const @This(),
        child_b: ?*const @This(),
        data: u32,
    };

    const leaf = Node{ .child_a = null, .child_b = null, .data = 100 };
    const root_node = Node{ .child_a = &leaf, .child_b = &leaf, .data = 200 };

    try testRoundtrip(root_node);
}

test "validate distinguishes too many vs too few bytes" {
    const T = struct { a: []const u8 };
    const value = T{ .a = "hello" };
    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const short = bytes[0 .. bytes.len - 1];
    try testing.expectError(error.NotEnoughBytes, one.Untrusted(T, .{}).init(short).validate());

    var long = try testing.allocator.alignedAlloc(u8, one.Converter(T, .{}).alignment, bytes.len + 1);
    defer testing.allocator.free(long);
    @memcpy(long[0..bytes.len], bytes);
    long[bytes.len] = 0;
    try testing.expectError(error.TooManyBytes, one.Untrusted(T, .{}).init(long).validate());
}

test "untrusted checked access reports OutOfBounds" {
    const T = struct { a: []const u8 };
    const value = T{ .a = "abc" };
    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const short = bytes[0 .. bytes.len - 1];
    const u = one.Untrusted(T, .{}).init(short);

    const a = try u.field("a");
    const elem = try a.at(2);
    try testing.expectError(error.OutOfBounds, elem.value());
    try testing.expectError(error.OutOfBounds, a.at(10));
}

test "invalid enum tag is rejected by validate and toOwned" {
    const T = enum(u8) { a = 1, b = 2 };
    const value: T = .a;
    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    bytes[0] = 255;
    const u = one.Untrusted(T, .{}).init(bytes);
    try testing.expectError(error.InvalidEnumTag, u.validate());
    try testing.expectError(error.InvalidEnumTag, u.toOwned(testing.allocator));
}

test "invalid union tag is rejected by validate and toOwned" {
    const T = union(enum(u8)) {
        a: u8,
        b: u8,
    };
    const value: T = .{ .a = 7 };
    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    bytes[0] = 99;
    const u = one.Untrusted(T, .{}).init(bytes);
    try testing.expectError(error.InvalidUnionTag, u.validate());
    try testing.expectError(error.InvalidUnionTag, u.toOwned(testing.allocator));
}

test "invalid optional tag is rejected by validate and toOwned" {
    const T = ?u8;
    const value: T = 12;
    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    bytes[0] = 2;
    const u = one.Untrusted(T, .{}).init(bytes);
    try testing.expectError(error.InvalidTag, u.validate());
    try testing.expectError(error.InvalidTag, u.toOwned(testing.allocator));
}

test "meta.alignForward reports overflow" {
    try testing.expectError(error.Overflow, meta.alignForward(std.math.maxInt(usize), 8));
}

test "toOwned does not leak on induced OutOfMemory" {
    try std.testing.checkAllAllocationFailures(testing.allocator, toOwnedNoLeakOnOom, .{});
}

test "allocFromShim allocates top-level slice lengths without copying payload" {
    const T = struct {
        a: []const u8,
        b: []const u8,
    };

    const sentinel = one.invalidPointer([*]const u8);
    const shim = T{
        .a = sentinel[0..5],
        .b = sentinel[0..9],
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const out = try one.allocFromShim(T, .{}, &shim, arena.allocator());
    try testing.expectEqual(@as(usize, 5), out.a.len);
    try testing.expectEqual(@as(usize, 9), out.b.len);
    try testing.expect(@intFromPtr(out.a.ptr) != @intFromPtr(sentinel));
    try testing.expect(@intFromPtr(out.b.ptr) != @intFromPtr(sentinel));
}

test "allocFromShim recursively allocates nested slice shapes" {
    const T = struct {
        a: []const []const u8,
    };

    const sentinel = one.invalidPointer([*]const u8);
    const inners = [_][]const u8{
        sentinel[0..1],
        sentinel[0..4],
        sentinel[0..0],
    };
    const shim = T{ .a = inners[0..] };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const out = try one.allocFromShim(T, .{}, &shim, arena.allocator());
    try testing.expectEqual(@as(usize, 3), out.a.len);
    try testing.expectEqual(@as(usize, 1), out.a[0].len);
    try testing.expectEqual(@as(usize, 4), out.a[1].len);
    try testing.expectEqual(@as(usize, 0), out.a[2].len);
    try testing.expect(@intFromPtr(out.a[0].ptr) != @intFromPtr(sentinel));
    try testing.expect(@intFromPtr(out.a[1].ptr) != @intFromPtr(sentinel));
}

test "allocFromShim sentinel slice allocates child array and skips deep recursion" {
    const T = struct {
        items: []const []const u8,
    };

    const outer_sentinel = one.invalidPointer([*]const []const u8);
    const shim = T{
        .items = outer_sentinel[0..4],
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const out = try one.allocFromShim(T, .{}, &shim, arena.allocator());
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expect(@intFromPtr(out.items.ptr) != @intFromPtr(outer_sentinel));
}

test "allocFromShim sentinel one-pointer allocates pointee and stops recursion" {
    const Child = struct {
        name: []const u8,
    };
    const T = struct {
        child: *const Child,
    };

    const child_sentinel = one.invalidPointer(*const Child);
    const shim = T{ .child = child_sentinel };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const out = try one.allocFromShim(T, .{}, &shim, arena.allocator());
    try testing.expect(@intFromPtr(out.child) != @intFromPtr(child_sentinel));
}

test "allocFromShim preserves optional presence and tagged-union active branch" {
    const T = struct {
        maybe_none: ?[]const u8,
        maybe_some: ?[]const u8,
        pick: union(enum) {
            bytes: []const u8,
            code: u16,
        },
    };

    const sentinel = one.invalidPointer([*]const u8);
    const shim_some = T{
        .maybe_none = null,
        .maybe_some = sentinel[0..7],
        .pick = .{ .bytes = sentinel[0..3] },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const out_some = try one.allocFromShim(T, .{}, &shim_some, arena.allocator());
    try testing.expect(out_some.maybe_none == null);
    try testing.expect(out_some.maybe_some != null);
    try testing.expectEqual(@as(usize, 7), out_some.maybe_some.?.len);
    switch (out_some.pick) {
        .bytes => |bytes| try testing.expectEqual(@as(usize, 3), bytes.len),
        .code => return error.TestUnexpectedResult,
    }

    const shim_code = T{
        .maybe_none = null,
        .maybe_some = null,
        .pick = .{ .code = 1234 },
    };
    const out_code = try one.allocFromShim(T, .{}, &shim_code, arena.allocator());
    switch (out_code.pick) {
        .code => {},
        .bytes => return error.TestUnexpectedResult,
    }
}

test "allocFromShim does not leak on induced OutOfMemory" {
    try std.testing.checkAllAllocationFailures(testing.allocator, allocFromShimNoLeakOnOom, .{});
}

test "accessor chaining and dynamic get" {
    const T = struct {
        user: struct {
            id: u32,
            name: []const u8,
        },
        tags: []const []const u8,
    };

    const value = T{
        .user = .{ .id = 7, .name = "bob" },
        .tags = &.{ "a", "bb", "ccc" },
    };

    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const u = one.Untrusted(T, .{}).init(bytes);
    const user = try u.field("user");
    const id = try user.field("id");
    try testing.expectEqual(@as(u32, 7), try id.value());

    const name = try user.field("name");
    const name_checked = try name.get();
    try testing.expectEqual(@as(usize, 3), try name_checked.len());

    const tags = try u.field("tags");
    const tags_checked = try tags.get();
    const second = try tags_checked.at(1);
    const second_checked = try second.get();
    const ch = try second_checked.at(1);
    try testing.expectEqual(@as(u8, 'b'), try ch.value());
}

test "single massive messy quadruple-mutual-recursive type graph (acyclic data)" {
    const Namespace = struct {
        const Mode = enum { alpha, beta, gamma };
        const Class = enum { leaf, branch, core };
        const Status = union(enum) { ok: []const u8, fail: enum { disconnected, corrupt } };

        const Event = union(enum) {
            none: void,
            count: i64,
            bytes: []const u8,
            flags: [4]bool,
            ints: [3]u16,
            vec: @Vector(4, u8),
            nested: struct {
                score: f32,
                tag: ?[]const u8,
                arr: [2]u32,
            },
        };

        const NodeA = struct {
            active: bool,
            count: i32,
            ratio: f64,
            mode: Mode,
            main_b: *const NodeB,
            aux_b: []const ?*const NodeB,
            main_c: ?*const NodeC,
            head_d: ?*const NodeD,
            title: []const u8,
            notes: []const union(enum) { text: []const u8, code: u16, flag: bool },
            route: [2]Event,
            maybe_status: ?Status,
            packed_bits: packed struct { a: u3, b: bool, c: u4 },
            scratch: [2][3]u8,
            vec4: @Vector(4, f32),
            nothing: void,
            meta: union(enum) {
                plain: u32,
                pair: [2]i16,
                ptr: ?*const NodeD,
                details: struct { ok: bool, msg: []const u8, maybe: ?[]const u8 },
            },
        };

        const NodeB = struct {
            bid: u32,
            label: []const u8,
            parent: ?*const NodeA,
            primary_c: *const NodeC,
            secondary: ?*const NodeC,
            d_list: []const *const NodeD,
            payload: union(enum) {
                n: u64,
                text: []const u8,
                ev: Event,
                bits: packed struct { x: u2, y: u3, z: bool },
            },
            opt_num: ?u64,
            tags: []const []const u8,
        };

        const Chunk = struct {
            kind: Class,
            data: []const u8,
            ref_a: ?*const NodeA,
            ref_c: ?*const NodeC,
            refs_d: [3]?*const NodeD,
            vv: @Vector(2, i16),
        };

        const NodeC = struct {
            cid: u16,
            owner: ?*const NodeB,
            branch: *const NodeD,
            backlinks: [2]?*const NodeD,
            chunks: []const Chunk,
            maybe_event: ?Event,
            status: Status,
            matrix: [2][3]u8,
        };

        const NodeD = struct {
            did: u32,
            class: Class,
            name: []const u8,
            next: ?*const NodeD,
            mirror_a: ?*const NodeA,
            mirror_c: ?*const NodeC,
            events: []const Event,
            watchers: []const ?*const NodeB,
            state: union(enum) {
                empty: void,
                bytes: []const u8,
                ids: [3]u16,
                opt: ?*const NodeC,
            },
            outcome: Status,
        };
    };

    const Event = Namespace.Event;
    const NodeA = Namespace.NodeA;
    const NodeB = Namespace.NodeB;
    const NodeC = Namespace.NodeC;
    const NodeD = Namespace.NodeD;
    const Chunk = Namespace.Chunk;

    const ev1: Event = .{ .none = {} };
    const ev2: Event = .{ .count = -5 };
    const ev3: Event = .{ .bytes = "ev-three" };
    const ev4: Event = .{ .flags = .{ true, false, true, false } };
    const ev5: Event = .{ .ints = .{ 10, 20, 30 } };
    const ev6: Event = .{ .vec = .{ 1, 2, 3, 4 } };
    const ev7: Event = .{ .nested = .{ .score = 9.25, .tag = "tagged", .arr = .{ 7, 8 } } };

    const d3 = NodeD{
        .did = 300,
        .class = .leaf,
        .name = "d3",
        .next = null,
        .mirror_a = null,
        .mirror_c = null,
        .events = &.{ ev1, ev2, ev7 },
        .watchers = &.{ null, null },
        .state = .{ .empty = {} },
        .outcome = .{ .ok = "d3-ok" },
    };

    const d2 = NodeD{
        .did = 200,
        .class = .branch,
        .name = "d2",
        .next = &d3,
        .mirror_a = null,
        .mirror_c = null,
        .events = &.{ ev3, ev4, ev5 },
        .watchers = &.{ null, null, null },
        .state = .{ .ids = .{ 1, 2, 3 } },
        .outcome = .{ .fail = .disconnected },
    };

    const d1 = NodeD{
        .did = 100,
        .class = .core,
        .name = "d1",
        .next = &d2,
        .mirror_a = null,
        .mirror_c = null,
        .events = &.{ ev6, ev7, ev1, ev3 },
        .watchers = &.{ null, null },
        .state = .{ .bytes = "d1-state" },
        .outcome = .{ .ok = "d1-ok" },
    };

    const ch1 = Chunk{
        .kind = .leaf,
        .data = "chunk-1",
        .ref_a = null,
        .ref_c = null,
        .refs_d = .{ &d1, &d2, null },
        .vv = .{ 1, 2 },
    };

    const ch2 = Chunk{
        .kind = .branch,
        .data = "chunk-2",
        .ref_a = null,
        .ref_c = null,
        .refs_d = .{ &d2, &d3, null },
        .vv = .{ -3, 4 },
    };

    const ch3 = Chunk{
        .kind = .core,
        .data = "",
        .ref_a = null,
        .ref_c = null,
        .refs_d = .{ null, null, &d3 },
        .vv = .{ 7, -8 },
    };

    const c3 = NodeC{
        .cid = 30,
        .owner = null,
        .branch = &d3,
        .backlinks = .{ &d3, null },
        .chunks = &.{ch3},
        .maybe_event = null,
        .status = .{ .ok = "c3-ok" },
        .matrix = .{ .{ 9, 8, 7 }, .{ 6, 5, 4 } },
    };

    const c2 = NodeC{
        .cid = 20,
        .owner = null,
        .branch = &d2,
        .backlinks = .{ &d3, &d2 },
        .chunks = &.{ ch2, ch3 },
        .maybe_event = ev5,
        .status = .{ .fail = .disconnected },
        .matrix = .{ .{ 4, 5, 6 }, .{ 7, 8, 9 } },
    };

    const c1 = NodeC{
        .cid = 10,
        .owner = null,
        .branch = &d1,
        .backlinks = .{ &d2, &d3 },
        .chunks = &.{ ch1, ch2, ch3 },
        .maybe_event = ev7,
        .status = .{ .ok = "c1-ok" },
        .matrix = .{ .{ 1, 2, 3 }, .{ 3, 2, 1 } },
    };

    const b2 = NodeB{
        .bid = 2,
        .label = "b2",
        .parent = null,
        .primary_c = &c3,
        .secondary = null,
        .d_list = &.{ &d2, &d3 },
        .payload = .{ .ev = ev5 },
        .opt_num = null,
        .tags = &.{ "b2", "leaf" },
    };

    const b1 = NodeB{
        .bid = 1,
        .label = "b1",
        .parent = null,
        .primary_c = &c1,
        .secondary = &c2,
        .d_list = &.{ &d1, &d2, &d3 },
        .payload = .{ .bits = .{ .x = 2, .y = 5, .z = true } },
        .opt_num = 77,
        .tags = &.{ "b1", "root", "messy" },
    };

    const root = NodeA{
        .active = true,
        .count = -123,
        .ratio = 2.5,
        .mode = .gamma,
        .main_b = &b1,
        .aux_b = &.{ &b2, null, &b1 },
        .main_c = &c1,
        .head_d = &d1,
        .title = "mega-root",
        .notes = &.{ .{ .text = "note-a" }, .{ .code = 42 }, .{ .flag = true } },
        .route = .{ ev4, ev7 },
        .maybe_status = .{ .fail = .corrupt },
        .packed_bits = .{ .a = 5, .b = true, .c = 9 },
        .scratch = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 } },
        .vec4 = .{ 1.0, 2.0, 3.5, 4.5 },
        .nothing = {},
        .meta = .{ .details = .{ .ok = false, .msg = "details", .maybe = null } },
    };

    try testRoundtrip(root);
}

test "single gigantic all-supported-types chaos graph with triple and quadruple mutual recursion" {
    const NS = struct {
        const Mode = enum(u8) { m0, m1, m2, m3 };
        const Flavor = enum { sour, sweet, bitter };
        const Fault = enum { broken, missing, timeout };
        const Status = union(enum) { ok: []const u8, err: Fault };

        const Bits = packed struct { a: u1, b: u3, c: bool, d: u4 };
        const Mini = struct {
            n: i16,
            maybe: ?u32,
            z: [0]u8,
        };

        const TrioX = struct {
            id: u16,
            y: ?*const TrioY,
            bag: []const u8,
            picks: [2]?*const TrioZ,
            state: union(enum) {
                off: void,
                on: bool,
                code: u8,
                names: []const []const u8,
            },
        };

        const TrioY = struct {
            id: u16,
            z: ?*const TrioZ,
            xs: []const ?*const TrioX,
            res: Status,
            maybe: ?[]const u8,
            bucket: [2]union(enum) {
                n: i32,
                t: []const u8,
                f: bool,
            },
        };

        const TrioZ = struct {
            id: u16,
            x: ?*const TrioX,
            ys: [3]?*const TrioY,
            mode: Mode,
            opt: ?union(enum) { a: u8, b: []const u8 },
        };

        const QuadA = struct {
            aid: u32,
            b: *const QuadB,
            c: ?*const QuadC,
            ds: []const *const QuadD,
            tags: []const []const u8,
            pack: Bits,
            note: ?[]const u8,
            event: union(enum) {
                none: void,
                text: []const u8,
                n: i64,
                maybe_d: ?*const QuadD,
            },
        };

        const QuadB = struct {
            bid: u32,
            parent: ?*const QuadA,
            c: *const QuadC,
            maybe_d: ?*const QuadD,
            links: [2]?*const QuadA,
            choice: union(enum) {
                bytes: []const u8,
                ids: [3]u16,
                ok: bool,
                err: Status,
            },
            values: [3]u8,
        };

        const QuadC = struct {
            cid: u32,
            owner: ?*const QuadB,
            lead: *const QuadD,
            peers: []const ?*const QuadC,
            tri: ?*const TrioX,
            grid: [2][2]u8,
            status: Status,
        };

        const QuadD = struct {
            did: u32,
            next: ?*const QuadD,
            a: ?*const QuadA,
            c: ?*const QuadC,
            watchers: []const ?*const QuadB,
            route: [2]Mode,
            shape: union(enum) {
                voidy: void,
                numbers: [4]u16,
                ptr: ?*const QuadC,
                msg: []const u8,
            },
        };

        const Payload = union(enum) {
            none: void,
            num: i64,
            text: []const u8,
            mini: Mini,
            vec: @Vector(4, u8),
            arr: [3]u16,
            bits: Bits,
            err: Status,
            maybe_d: ?*const QuadD,
            maybe_z: ?*const TrioZ,
            inner: union(enum) {
                flag: bool,
                data: []const u8,
                pair: [2]i8,
            },
        };

        const Root = struct {
            mode: Mode,
            flavor: Flavor,
            ok: bool,
            count: i64,
            ratio: f64,
            nothing: void,
            bits: Bits,
            vecf: @Vector(4, f32),
            matrix: [2][3]u8,
            labels: []const []const u8,
            bytes: []const u8,
            tiny: [2]Mini,
            payloads: []const Payload,
            pick: Payload,
            maybe_pick: ?Payload,
            status: Status,
            maybe_status: ?Status,
            one_d: *const QuadD,
            maybe_c: ?*const QuadC,
            many_b: []const ?*const QuadB,
            d_chain: [3]?*const QuadD,
            pp_d: *const *const QuadD,
            xyz: *const TrioX,
            maybe_y: ?*const TrioY,
            grid_c: [2][2]?*const QuadC,
            voids: []const void,
            alt: union(enum) {
                raw: []const u8,
                nums: [4]u16,
                mixed: struct {
                    maybe_ptr: ?*const QuadA,
                    note: []const u8,
                    e: ?Status,
                },
            },
        };
    };

    const TrioX = NS.TrioX;
    const TrioY = NS.TrioY;
    const TrioZ = NS.TrioZ;
    const QuadA = NS.QuadA;
    const QuadB = NS.QuadB;
    const QuadC = NS.QuadC;
    const QuadD = NS.QuadD;
    const Payload = NS.Payload;
    const Root = NS.Root;

    const z2 = TrioZ{
        .id = 202,
        .x = null,
        .ys = .{ null, null, null },
        .mode = .m2,
        .opt = .{ .a = 7 },
    };

    const y2 = TrioY{
        .id = 102,
        .z = &z2,
        .xs = &.{null},
        .res = .{ .err = .timeout },
        .maybe = null,
        .bucket = .{ .{ .n = -1 }, .{ .t = "y2" } },
    };

    const x2 = TrioX{
        .id = 2,
        .y = &y2,
        .bag = "x2-bag",
        .picks = .{ &z2, null },
        .state = .{ .code = 23 },
    };

    const z1 = TrioZ{
        .id = 201,
        .x = &x2,
        .ys = .{ &y2, null, null },
        .mode = .m1,
        .opt = .{ .b = "z1-opt" },
    };

    const y1 = TrioY{
        .id = 101,
        .z = &z1,
        .xs = &.{ &x2, null },
        .res = .{ .ok = "y1-ok" },
        .maybe = "optional-y1",
        .bucket = .{ .{ .f = true }, .{ .t = "bucket" } },
    };

    const x1 = TrioX{
        .id = 1,
        .y = &y1,
        .bag = "x1-bag",
        .picks = .{ &z1, &z2 },
        .state = .{ .names = &.{ "x1", "mess", "triple" } },
    };

    const d4 = QuadD{
        .did = 40,
        .next = null,
        .a = null,
        .c = null,
        .watchers = &.{ null, null },
        .route = .{ .m3, .m0 },
        .shape = .{ .voidy = {} },
    };

    const d3 = QuadD{
        .did = 30,
        .next = &d4,
        .a = null,
        .c = null,
        .watchers = &.{null},
        .route = .{ .m2, .m3 },
        .shape = .{ .numbers = .{ 9, 8, 7, 6 } },
    };

    const d2 = QuadD{
        .did = 20,
        .next = &d3,
        .a = null,
        .c = null,
        .watchers = &.{ null, null, null },
        .route = .{ .m1, .m2 },
        .shape = .{ .msg = "d2-shape" },
    };

    const d1 = QuadD{
        .did = 10,
        .next = &d2,
        .a = null,
        .c = null,
        .watchers = &.{null},
        .route = .{ .m0, .m1 },
        .shape = .{ .ptr = null },
    };

    const c3 = QuadC{
        .cid = 300,
        .owner = null,
        .lead = &d4,
        .peers = &.{null},
        .tri = &x2,
        .grid = .{ .{ 9, 8 }, .{ 7, 6 } },
        .status = .{ .ok = "c3-ok" },
    };

    const c2 = QuadC{
        .cid = 200,
        .owner = null,
        .lead = &d3,
        .peers = &.{ &c3, null },
        .tri = &x1,
        .grid = .{ .{ 4, 3 }, .{ 2, 1 } },
        .status = .{ .err = .missing },
    };

    const c1 = QuadC{
        .cid = 100,
        .owner = null,
        .lead = &d2,
        .peers = &.{ &c2, &c3 },
        .tri = null,
        .grid = .{ .{ 1, 2 }, .{ 3, 4 } },
        .status = .{ .ok = "c1-ok" },
    };

    const b2 = QuadB{
        .bid = 2,
        .parent = null,
        .c = &c3,
        .maybe_d = &d4,
        .links = .{ null, null },
        .choice = .{ .ids = .{ 11, 22, 33 } },
        .values = .{ 5, 6, 7 },
    };

    const b1 = QuadB{
        .bid = 1,
        .parent = null,
        .c = &c1,
        .maybe_d = &d2,
        .links = .{ null, null },
        .choice = .{ .err = .{ .err = .broken } },
        .values = .{ 1, 2, 3 },
    };

    const a1 = QuadA{
        .aid = 1,
        .b = &b1,
        .c = &c1,
        .ds = &.{ &d1, &d2, &d3, &d4 },
        .tags = &.{ "a1", "main", "chaos" },
        .pack = .{ .a = 0, .b = 6, .c = true, .d = 15 },
        .note = "a1-note",
        .event = .{ .maybe_d = &d1 },
    };

    const p1: Payload = .{ .none = {} };
    const p2: Payload = .{ .num = -1234567 };
    const p3: Payload = .{ .text = "payload-text" };
    const p4: Payload = .{ .mini = .{ .n = -7, .maybe = 11, .z = .{} } };
    const p5: Payload = .{ .vec = .{ 1, 2, 3, 4 } };
    const p6: Payload = .{ .arr = .{ 8, 9, 10 } };
    const p7: Payload = .{ .bits = .{ .a = 1, .b = 5, .c = true, .d = 12 } };
    const p8: Payload = .{ .err = .{ .err = .timeout } };
    const p9: Payload = .{ .maybe_d = &d3 };
    const p10: Payload = .{ .maybe_z = &z1 };
    const p11: Payload = .{ .inner = .{ .pair = .{ -4, 5 } } };

    const d_head: *const QuadD = &d1;

    const root = Root{
        .mode = .m3,
        .flavor = .bitter,
        .ok = true,
        .count = -99_999_999,
        .ratio = 6.25,
        .nothing = {},
        .bits = .{ .a = 1, .b = 4, .c = false, .d = 11 },
        .vecf = .{ 0.5, 1.25, 2.5, 5.0 },
        .matrix = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 } },
        .labels = &.{ "alpha", "beta", "", "delta" },
        .bytes = "root-bytes",
        .tiny = .{
            .{ .n = -10, .maybe = null, .z = .{} },
            .{ .n = 88, .maybe = 700, .z = .{} },
        },
        .payloads = &.{ p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11 },
        .pick = p11,
        .maybe_pick = p7,
        .status = .{ .ok = "status-ok" },
        .maybe_status = .{ .err = .missing },
        .one_d = &d1,
        .maybe_c = &c2,
        .many_b = &.{ &b1, null, &b2 },
        .d_chain = .{ &d1, &d2, null },
        .pp_d = &d_head,
        .xyz = &x1,
        .maybe_y = &y2,
        .grid_c = .{ .{ &c1, null }, .{ &c2, &c3 } },
        .voids = &.{ {}, {}, {}, {} },
        .alt = .{ .mixed = .{
            .maybe_ptr = &a1,
            .note = "alt-note",
            .e = .{ .ok = "inner-ok" },
        } },
    };

    try testRoundtrip(root);
}

test "type-id coverage for every Zig language type tag" {
    const SF = one.SerializationFunctions;
    const fields = @typeInfo(std.builtin.TypeId).@"enum".fields;

    inline for (fields) |f| {
        const tag: std.builtin.TypeId = @enumFromInt(f.value);
        const expected = switch (tag) {
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
            .error_union,
            .error_set,
            => false,
        };
        try testing.expectEqual(expected, SF.supportsTypeId(tag));
    }
}

test "type-level support coverage with representative types" {
    const SF = one.SerializationFunctions;

    // Supported
    try testing.expect(SF.supportsType(void));
    try testing.expect(SF.supportsType(bool));
    try testing.expect(SF.supportsType(i64));
    try testing.expect(SF.supportsType(f64));
    try testing.expect(SF.supportsType(@Vector(4, f32)));
    try testing.expect(SF.supportsType(enum { a, b }));
    try testing.expect(SF.supportsType([3]u8));
    try testing.expect(SF.supportsType(*const u8));
    try testing.expect(SF.supportsType([]const u8));
    try testing.expect(SF.supportsType(struct { a: u8, b: []const u8 }));
    try testing.expect(SF.supportsType(?[]const u8));
    try testing.expect(SF.supportsType(union(enum) { a: u8, b: []const u8 }));
    try testing.expect(SF.supportsType(@TypeOf(null)));

    // Unsupported
    try testing.expect(!SF.supportsType(type));
    try testing.expect(!SF.supportsType(noreturn));
    try testing.expect(!SF.supportsType(@TypeOf(1)));
    try testing.expect(!SF.supportsType(@TypeOf(1.5)));
    try testing.expect(!SF.supportsType(@TypeOf(undefined)));
    try testing.expect(!SF.supportsType(fn () void));
    try testing.expect(!SF.supportsType(@TypeOf(.foo)));
    try testing.expect(!SF.supportsType(opaque {}));
    try testing.expect(!SF.supportsType(error{A}));
    try testing.expect(!SF.supportsType(error{E}![]const u8));
    try testing.expect(!SF.supportsType([*]const u8));
    try testing.expect(!SF.supportsType([*c]const u8));
    try testing.expect(!SF.supportsType(union { a: u8, b: u16 }));
}

test "null type roundtrip" {
    const NullT = @TypeOf(null);
    const v = @as(NullT, null);
    const C = one.Converter(NullT, .{});

    const size = try C.serializedSize(&v);
    try testing.expectEqual(@as(usize, 0), size);

    const bytes = try one.serializeAlloc(NullT, .{}, &v, testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);

    const untrusted = one.Untrusted(NullT, .{}).init(bytes);
    _ = try untrusted.validate();
}

test "opposite-endian wire roundtrip" {
    const opposite: std.builtin.Endian = comptime if (builtin.target.cpu.arch.endian() == .little) .big else .little;

    const T = struct {
        id: u32,
        values: []const u16,
        mode: enum(u16) { a = 1, b = 2, c = 3 },
        payload: union(enum) { text: []const u8, count: u32 },
        result: union(enum) { ok: u64, fail: bool },
        vec: @Vector(4, u16),
    };

    const value = T{
        .id = 0x12_34_56_78,
        .values = &.{ 10, 20, 30, 40 },
        .mode = .c,
        .payload = .{ .text = "wire" },
        .result = .{ .ok = 0x11_22_33_44_55_66_77_88 },
        .vec = .{ 1, 2, 3, 4 },
    };

    const bytes = try one.serializeAlloc(T, .{ .endian = opposite }, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const untrusted = one.Untrusted(T, .{ .endian = opposite }).init(bytes);
    const trusted = try untrusted.validate();
    const out = try trusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out));
    try expectEquivalent(value, out);
}

test "view endianness can be switched on-the-fly" {
    const opposite: std.builtin.Endian = comptime if (builtin.target.cpu.arch.endian() == .little) .big else .little;
    const T = struct {
        data: []const u8,
        tail: u16,
    };

    const value = T{ .data = "x", .tail = 0x1234 };
    const bytes = try one.serializeAlloc(T, .{ .endian = opposite }, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const wrong = one.Untrusted(T, .{}).init(bytes);
    const wrong_data = try wrong.field("data");
    try testing.expectEqual(@as(usize, 16_777_216), try wrong_data.len());
    try testing.expectError(error.NotEnoughBytes, wrong.validate());

    const fixed = wrong.withEndian(opposite);
    const fixed_data = try fixed.field("data");
    try testing.expectEqual(@as(usize, 1), try fixed_data.len());

    const out = try (try fixed.validate()).toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out));
    try expectEquivalent(value, out);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
