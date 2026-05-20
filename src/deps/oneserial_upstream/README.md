# OneSerial: Typed Single-Buffer Serialization For Zig

Serialize supported Zig values into one contiguous byte buffer, then read them through checked or unchecked typed views.

This is useful when you want:
- Compact binary snapshots of nested data.
- Fast field/slice access without fully decoding everything.
- A clear trust boundary (`Untrusted` -> `validate()` -> `Trusted`).

> [!WARNING]
> **Experimental:** API and wire details may change.<br/>
> **Trust model:** Always treat incoming bytes as untrusted until validated.<br/>
> **Portability:** Wire format uses native type representation (for example endianness and tag layout), so cross-platform compatibility is limited unless environments match.

## Why OneSerial?

Many serializers force full decoding before you can inspect anything. `oneserial` gives you typed views so you can:
- Validate once.
- Traverse fields/slices directly from the byte buffer.
- Decode to owned memory only when needed.

## Quick Start

```zig
const std = @import("std");
const oneserial = @import("oneserial");

const Msg = struct {
    id: u64,
    user: struct {
        name: []const u8,
        level: u8,
    },
    tags: []const []const u8,
    maybe_ptr: ?*const u32,
    payload: union(enum) {
        text: []const u8,
        code: u16,
        none: void,
    },
    result: union(enum) { ok: []const u8, offline: void },
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var n: u32 = 7;
    const msg = Msg{
        .id = 42,
        .user = .{ .name = "zig", .level = 3 },
        .tags = &.{ "alpha", "beta", "gamma" },
        .maybe_ptr = &n,
        .payload = .{ .text = "hello" },
        .result = .{ .ok = "ok" },
    };

    var wrapper = try oneserial.Wrapper(Msg, .{}).init(&msg, gpa);
    defer wrapper.deinit(gpa);

    // Validate once, then use trusted typed views.
    const trusted = try wrapper.untrusted().validate();

    const id = trusted.field("id").value();
    const tags = trusted.field("tags");

    std.debug.print("id={d}, tags={d}\n", .{ id, tags.len() });
}
```

## Installation

1. Add dependency in `build.zig.zon`:

```zig
.dependencies = .{
    .oneserial = .{
        .url = "git+https://github.com/SmallThingz/oneserial#<commit>",
        .hash = "<hash>",
    },
},
```

2. Add module import in `build.zig`:

```zig
const dep = b.dependency("oneserial", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("oneserial", dep.module("oneserial"));
```

## Core API

- `oneserial.Converter(T, .{})`
  - Entry point for per-type operations.
- `oneserial.serializeAlloc(T, .{}, &value, allocator)`
  - Serialize value into one aligned byte buffer.
- `oneserial.allocFromShim(T, .{}, &shim, allocator)`
  - Allocate dynamic shape from a shim value without copying payload bytes.
- `oneserial.invalidPointer(P)`
  - Pointer sentinel for shim fields where recursion should stop.
- `oneserial.Wrapper(T, .{})`
  - Owns serialized bytes and provides `.untrusted()`.
- `oneserial.Untrusted(T, .{})`
  - Checked access. Call `.validate()` for full-buffer validation.
- `oneserial.Trusted(T, .{})`
  - Assumes bytes are valid; cheaper typed access.

### Endianness

`MergeOptions` has `endian` (default: native). Use it when producing or consuming non-native wire bytes:

```zig
const opposite: std.builtin.Endian = if (@import("builtin").target.cpu.arch.endian() == .little) .big else .little;
const bytes = try oneserial.serializeAlloc(MyType, .{ .endian = opposite }, &value, allocator);
const u = oneserial.Untrusted(MyType, .{}).init(bytes).withEndian(opposite);
const trusted = try u.validate();
```

### Shim Allocation

`allocFromShim` is useful when you only know allocation shape (lengths/presence/tag) and want to fill payload bytes later.

```zig
const T = struct {
    a: []const u8,
    b: []const u8,
};

const s = oneserial.invalidPointer([*]const u8);
const shim = T{
    .a = s[0..8],
    .b = s[0..32],
};

const out = try oneserial.allocFromShim(T, .{}, &shim, allocator);
// out.a/out.b are allocated with matching lengths; payload bytes are not copied.
```

Nested shapes are supported:

```zig
const T = struct { a: []const []const u8 };
const s = oneserial.invalidPointer([*]const u8);

const inner = [_][]const u8{
    s[0..4],
    s[0..2],
};
const shim = T{ .a = inner[0..] };

const out = try oneserial.allocFromShim(T, .{}, &shim, allocator);
```

When a pointer (or slice `.ptr`) equals `invalidPointer(...)`, OneSerial allocates that container but does not recurse deeper into pointee/element payloads.

For `[]const []const u8` specifically:
- Outer slice sentinel (`[*]const []const u8`) with `len = N` allocates `N` inner-slice headers.
- Inner `[]const u8` element sentinels allocate each inner byte buffer by its `len`.

> [!IMPORTANT]
> Values returned by `allocFromShim` may contain undefined non-shape data.  
> You must initialize payload data before reading it.

### View Accessors

Available on `Untrusted`, `Trusted`, and nested views as type-appropriate:
- `.field("name")` for structs
- `.get()` for dynamic values
- `.len()` / `.at(i)` / `.atUnchecked(i)` for slices
- `.value()` to decode the current view value
- `.toOwned(allocator)` to allocate and decode owned value

## Supported Types

- Primitives: `void`, `bool`, integers, floats, vectors, `null`
- Containers: arrays, structs, tagged unions, optionals
- Indirection: `*T` (one pointers) and `[]T` (slices)
- Enums

## Not Supported

- `[*]T` and `[*c]T`
- `error` and `error_union` values
- Untagged unions
- `type`, `noreturn`, comptime-only value types, `opaque`, standalone `error_set`, function/frame types

## Limitations

1. Recursive **types** are supported, but recursive **cyclic data** is not. Cycles can recurse forever.
2. This format is intentionally low-level and destructive: it prioritizes speed and simple traversal over schema evolution guarantees.
3. `Trusted` access should only be used after validation or in already-trusted contexts.

## Development

Run tests:

```bash
zig build test
```
