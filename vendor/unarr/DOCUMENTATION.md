# Archive API

Requires Zig 0.17.0. The public module is `unarr`; raw interoperability is available explicitly through `unarr.c`.

## Opening and ownership

- `Archive.openFile(allocator, format, path, options)` accepts a normal UTF-8 slice, rejects embedded NULs, and uses wide paths on Windows. The allocator owns only temporary path conversion.
- `Archive.openMemory(format, bytes, options)` borrows bytes until `deinit`; keep them alive and unchanged.
- `Archive.openStream(format, stream, options)` borrows a raw C stream. Close that stream after the archive is deinitialized; never seek it while reading an entry.
- `.auto`, `.zip`, `.tar`, `.rar`, and `.@"7z"` select a format. `OpenOptions.zip_deflated_only` restricts ZIP methods to those allowed by upstream's deflate-only mode.

Archives own native decoder resources, which upstream allocates through libc. Call `deinit` exactly once. Archive values must not be copied after opening, and their address must remain stable while entries are in use. Calls on an archive require external serialization.

## Navigation

`next() !?Entry` returns an entry, null at EOF, or an error. `find(name) !?Entry` restarts the archive and matches the exact slice. `seek(offset) !Entry` returns a fresh entry at a previously obtained offset; negative offsets are rejected. Every navigation attempt invalidates previous entry handles, including failed lookups and EOF.

The previous `nextEntry`, `parseEntryAt`, and sentinel-name `parseEntryFor` methods remain for migration. Prefer `find` over `parseEntryFor`, whose boolean result cannot distinguish parse failure from a missing name.

## Entries and extraction

Entry size, offset and raw Windows FILETIME (100 ns ticks since 1601) are captured values. `name()` and `rawName()` return borrowed slices, valid only until archive navigation or teardown; stale handles return null. Duplicate names if retaining them. Handles must not outlive their archive.

- `remaining() !usize` reports unread bytes.
- `readSome(buffer) !usize` reads up to the buffer length; zero means EOF (or an empty buffer).
- `read(buffer) !void` reads exactly the requested length. An oversized request returns `EndOfEntry` without consuming data.
- `readAlloc(allocator, limit) ![]u8` allocates and reads only the remaining bytes. Free the result with the same allocator. A limit or allocation failure leaves the cursor unchanged.
- `writeTo(writer: *std.Io.Writer) !void` streams remaining bytes through an 8 KiB scratch buffer. A writer error can occur after archive input has been consumed.

Reads through an invalidated handle return `StaleEntry`. Decompression or checksum failure poisons the current entry cursor; navigation creates a new cursor. Allocation bounds limit returned buffers, not upstream decoder memory or CPU use. No automatic filesystem extraction occurs: archive names are untrusted and must not be joined to an output path without validation.

ZIP comments are available through `globalCommentSize()` and `readGlobalComment(buffer)`. `runtimeVersion()` exposes native version fields and a borrowed version string.

## Build and migration

The package exports the `unarr` module and native `unarr` artifact, including its generated header. The same library artifact is reused by tests and consumers. `zig build check` compiles library and tests; `zig build test-bin` installs the test executable for a target runtime. `-Dshared=true` selects shared linkage.

The custom libc dependency and `-Dstatic_libc` option have been removed in favor of Zig's target libc support. Repository name: `unarr.zig`; module/dependency name remains `unarr`. `openFile` now takes an allocator and an ordinary path slice. Construct entries through navigation methods instead of struct literals. `readAlloc` after a partial read returns the unread suffix.

LLVM and LLD are selected for package executables because Zig 0.16's native linker cannot handle the host GCC 16 CRT's SFrame relocations. The bundled LZMA SDK intentionally uses unaligned native loads; only its C alignment sanitizer is disabled, while other C checks remain enabled.
