# unarr.zig

Archive reading for Zig 0.17.0, backed by pinned unarr 1.2.0 sources. The build compiles C directly through `std.Build`; CMake, Make, an installed unarr library, and a separate C compiler are unnecessary.

```zig
const std = @import("std");
const unarr = @import("unarr");

fn read(allocator: std.mem.Allocator, path: []const u8) !void {
    var archive = try unarr.Archive.openFile(allocator, .auto, path, .{});
    defer archive.deinit();
    while (try archive.next()) |entry| {
        const bytes = try entry.readAlloc(allocator, 16 * 1024 * 1024);
        defer allocator.free(bytes);
        std.debug.print("{s}: {d} bytes\n", .{ entry.name() orelse "(unnamed)", bytes.len });
    }
}
```

The API offers format detection, optional-entry iteration, slice-based lookup, bounded allocation, partial reads, and `std.Io.Writer` streaming. Stale entry handles reject reads instead of reading a different entry.

## Build

```sh
zig build test
zig build test -Doptimize=safe
zig build example
zig build check -Denable_7z=false
zig build -Dshared=true
```

RAR, TAR, ZIP and 7z are available; `.auto` probes them. `-Denable_7z=false` removes 7z decoding and explicit 7z opens return `UnsupportedFormat`. Static libraries are the default. Zig's target libc replaces the former custom `ziglibc` dependency; `-Dstatic_libc` is removed. For a static Linux application, select a musl target in the consuming build.

## Dependency

Fetch a pinned commit from `https://github.com/SmallThingz/unarr.zig`, then import the module:

```zig
const dep = b.dependency("unarr", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("unarr", dep.module("unarr"));
```

See [API and ownership](DOCUMENTATION.md), [security policy](SECURITY.md), and [license](LICENSE).
