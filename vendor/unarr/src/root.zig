const std = @import("std");

pub const c = @import("unarr_c");

pub const Error = error{
    OpenStreamFailed,
    OpenArchiveFailed,
    ParseFailed,
    DecompressFailed,
    EntryTooLarge,
    OutOfMemory,
    InvalidPath,
    InvalidOffset,
    StaleEntry,
    EndOfEntry,
    UnsupportedFormat,
    InvalidUtf8,
};

pub const Format = enum {
    auto,
    rar,
    tar,
    zip,
    @"7z",
};

pub const Version = struct {
    packed_version: u32,
    major: u8,
    minor: u8,
    patch: u8,
    string: []const u8,
};

pub fn runtimeVersion() Version {
    const packed_version = c.ar_get_version();
    return .{
        .packed_version = packed_version,
        .major = @as(u8, @intCast((packed_version >> 16) & 0xff)),
        .minor = @as(u8, @intCast((packed_version >> 8) & 0xff)),
        .patch = @as(u8, @intCast(packed_version & 0xff)),
        .string = zStr(c.ar_get_version_str()),
    };
}

pub const Archive = struct {
    stream: *c.ar_stream,
    archive: *c.ar_archive,
    owns_stream: bool,
    generation: u64 = 0,
    consumed: usize = 0,
    read_failed: bool = false,
    empty_validated: bool = false,

    /// Opens a UTF-8 path. The temporary terminated path is freed before return.
    pub fn openFile(allocator: std.mem.Allocator, format: Format, path: []const u8, options: OpenOptions) Error!Archive {
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);
        const stream = if (@import("builtin").os.tag == .windows) blk: {
            const wide_path = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch |err| return switch (err) {
                error.InvalidUtf8 => error.InvalidUtf8,
                error.OutOfMemory => error.OutOfMemory,
            };
            defer allocator.free(wide_path);
            break :blk c.ar_open_file_w(wide_path.ptr) orelse return error.OpenStreamFailed;
        } else c.ar_open_file(path_z.ptr) orelse return error.OpenStreamFailed;
        errdefer c.ar_close(stream);
        const archive = try openArchive(format, stream, options);
        return .{
            .stream = stream,
            .archive = archive,
            .owns_stream = true,
        };
    }

    pub fn openMemory(format: Format, data: []const u8, options: OpenOptions) Error!Archive {
        if (data.len == 0) return error.OpenStreamFailed;
        const stream = c.ar_open_memory(data.ptr, data.len) orelse return error.OpenStreamFailed;
        errdefer c.ar_close(stream);
        const archive = try openArchive(format, stream, options);
        return .{
            .stream = stream,
            .archive = archive,
            .owns_stream = true,
        };
    }

    pub fn openStream(format: Format, stream: *c.ar_stream, options: OpenOptions) Error!Archive {
        const archive = try openArchive(format, stream, options);
        return .{
            .stream = stream,
            .archive = archive,
            .owns_stream = false,
        };
    }

    pub fn deinit(self: *Archive) void {
        c.ar_close_archive(self.archive);
        if (self.owns_stream) c.ar_close(self.stream);
    }

    pub fn nextEntry(self: *Archive) Error!?Entry {
        self.invalidateEntry();
        if (c.ar_parse_entry(self.archive)) {
            return currentEntry(self);
        }
        if (c.ar_at_eof(self.archive)) return null;
        return error.ParseFailed;
    }

    pub fn parseEntryAt(self: *Archive, offset: i64) Error!void {
        self.invalidateEntry();
        if (offset < 0) return error.InvalidOffset;
        if (!c.ar_parse_entry_at(self.archive, @as(c.off64_t, @intCast(offset)))) {
            return error.ParseFailed;
        }
    }

    pub fn parseEntryFor(self: *Archive, name: [:0]const u8) bool {
        self.invalidateEntry();
        return c.ar_parse_entry_for(self.archive, name.ptr);
    }

    pub fn next(self: *Archive) Error!?Entry {
        return self.nextEntry();
    }

    /// Restarts iteration and finds an exact UTF-8 name without sentinel strings.
    pub fn find(self: *Archive, name: []const u8) Error!?Entry {
        self.invalidateEntry();
        if (!c.ar_parse_entry_at(self.archive, 0)) {
            if (c.ar_at_eof(self.archive)) return null;
            return error.ParseFailed;
        }
        while (true) {
            const entry = currentEntry(self);
            if (entry.name()) |entry_name| {
                if (std.mem.eql(u8, entry_name, name)) return entry;
            }
            if (try self.next() == null) return null;
        }
    }

    pub fn seek(self: *Archive, offset: i64) Error!Entry {
        try self.parseEntryAt(offset);
        return currentEntry(self);
    }

    fn invalidateEntry(self: *Archive) void {
        self.generation +%= 1;
        self.consumed = 0;
        self.read_failed = false;
        self.empty_validated = false;
    }

    pub fn atEof(self: *Archive) bool {
        return c.ar_at_eof(self.archive);
    }

    pub fn globalCommentSize(self: *Archive) usize {
        return c.ar_get_global_comment(self.archive, null, 0);
    }

    pub fn readGlobalComment(self: *Archive, buffer: []u8) usize {
        if (buffer.len == 0) return 0;
        return c.ar_get_global_comment(self.archive, buffer.ptr, buffer.len);
    }
};

pub const OpenOptions = struct {
    zip_deflated_only: bool = false,
};

pub const Entry = struct {
    archive: *Archive,
    generation: u64,
    byte_size: usize,
    entry_offset: i64,
    modified_filetime: i64,

    pub fn name(self: Entry) ?[]const u8 {
        if (self.generation != self.archive.generation) return null;
        const ptr = c.ar_entry_get_name(self.archive.archive) orelse return null;
        return zStr(ptr);
    }

    pub fn rawName(self: Entry) ?[]const u8 {
        if (self.generation != self.archive.generation) return null;
        const ptr = c.ar_entry_get_raw_name(self.archive.archive) orelse return null;
        return zStr(ptr);
    }

    pub fn offset(self: Entry) i64 {
        return self.entry_offset;
    }

    pub fn size(self: Entry) usize {
        return self.byte_size;
    }

    pub fn filetime(self: Entry) i64 {
        return self.modified_filetime;
    }

    pub fn read(self: Entry, out: []u8) Error!void {
        const left = try self.remaining();
        if (self.archive.read_failed) return error.DecompressFailed;
        if (out.len > left) return error.EndOfEntry;
        if (out.len == 0) {
            // Empty ZIP/RAR entries still carry checksums and restrictions.
            // A zero-sized caller buffer on a nonempty entry is only a no-op.
            if (self.byte_size != 0 or self.archive.empty_validated) return;
            var sentinel: u8 = 0;
            if (!c.ar_entry_uncompress(self.archive.archive, &sentinel, 0)) {
                self.archive.read_failed = true;
                return error.DecompressFailed;
            }
            self.archive.empty_validated = true;
            return;
        }
        if (!c.ar_entry_uncompress(self.archive.archive, out.ptr, out.len)) {
            self.archive.read_failed = true;
            return error.DecompressFailed;
        }
        self.archive.consumed += out.len;
    }

    pub fn remaining(self: Entry) Error!usize {
        if (self.generation != self.archive.generation) return error.StaleEntry;
        return self.byte_size - self.archive.consumed;
    }

    /// Reads up to the supplied buffer length; zero denotes entry EOF.
    pub fn readSome(self: Entry, out: []u8) Error!usize {
        const count = @min(out.len, try self.remaining());
        try self.read(out[0..count]);
        return count;
    }

    pub fn writeTo(self: Entry, writer: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
        var buffer: [8192]u8 = undefined;
        while (true) {
            const count = try self.readSome(&buffer);
            if (count == 0) return;
            try writer.writeAll(buffer[0..count]);
        }
    }

    pub fn readAlloc(self: Entry, allocator: std.mem.Allocator, limit: usize) Error![]u8 {
        const n = try self.remaining();
        if (n > limit) return error.EntryTooLarge;
        const out = allocator.alloc(u8, n) catch return error.OutOfMemory;
        errdefer allocator.free(out);
        try self.read(out);
        return out;
    }
};

fn openArchive(format: Format, stream: *c.ar_stream, options: OpenOptions) Error!*c.ar_archive {
    if (format == .@"7z" and !@import("build_options").enable_7z) return error.UnsupportedFormat;
    if (format == .auto) {
        const formats = [_]Format{ .zip, .rar, .@"7z", .tar };
        for (formats) |candidate| {
            if (candidate == .@"7z" and !@import("build_options").enable_7z) continue;
            if (!c.ar_seek(stream, 0, 0)) return error.OpenStreamFailed;
            return openArchive(candidate, stream, options) catch |err| switch (err) {
                error.OpenArchiveFailed => continue,
                else => return err,
            };
        }
        return error.OpenArchiveFailed;
    }
    return switch (format) {
        .auto => unreachable,
        .rar => c.ar_open_rar_archive(stream),
        .tar => c.ar_open_tar_archive(stream),
        .zip => c.ar_open_zip_archive(stream, options.zip_deflated_only),
        .@"7z" => c.ar_open_7z_archive(stream),
    } orelse error.OpenArchiveFailed;
}

fn zStr(ptr: [*c]const u8) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

fn currentEntry(archive: *Archive) Entry {
    return .{
        .archive = archive,
        .generation = archive.generation,
        .byte_size = c.ar_entry_get_size(archive.archive),
        .entry_offset = c.ar_entry_get_offset(archive.archive),
        .modified_filetime = c.ar_entry_get_filetime(archive.archive),
    };
}

fn appendLe16(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

fn appendLe32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

fn appendZeroes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, count: usize) !void {
    for (0..count) |_| {
        try list.append(allocator, 0);
    }
}

fn buildZipSingleFileFixture(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    content: []const u8,
    comment: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const crc = std.hash.Crc32.hash(content);
    std.debug.assert(file_name.len <= std.math.maxInt(u16));
    std.debug.assert(content.len <= std.math.maxInt(u32));
    std.debug.assert(comment.len <= std.math.maxInt(u16));

    const local_header_offset: u32 = 0;
    try appendLe32(&out, allocator, 0x04034B50);
    try appendLe16(&out, allocator, 20);
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 0); // Store (no compression)
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 0);
    try appendLe32(&out, allocator, crc);
    try appendLe32(&out, allocator, @as(u32, @intCast(content.len)));
    try appendLe32(&out, allocator, @as(u32, @intCast(content.len)));
    try appendLe16(&out, allocator, @as(u16, @intCast(file_name.len)));
    try appendLe16(&out, allocator, 0);
    try out.appendSlice(allocator, file_name);
    try out.appendSlice(allocator, content);

    const central_dir_offset = @as(u32, @intCast(out.items.len));
    try appendLe32(&out, allocator, 0x02014B50);
    try appendLe16(&out, allocator, 20);
    try appendLe16(&out, allocator, 20);
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 0);
    try appendLe32(&out, allocator, crc);
    try appendLe32(&out, allocator, @as(u32, @intCast(content.len)));
    try appendLe32(&out, allocator, @as(u32, @intCast(content.len)));
    try appendLe16(&out, allocator, @as(u16, @intCast(file_name.len)));
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 0);
    try appendLe32(&out, allocator, 0);
    try appendLe32(&out, allocator, local_header_offset);
    try out.appendSlice(allocator, file_name);

    const central_dir_size = @as(u32, @intCast(out.items.len)) - central_dir_offset;
    try appendLe32(&out, allocator, 0x06054B50);
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 0);
    try appendLe16(&out, allocator, 1);
    try appendLe16(&out, allocator, 1);
    try appendLe32(&out, allocator, central_dir_size);
    try appendLe32(&out, allocator, central_dir_offset);
    try appendLe16(&out, allocator, @as(u16, @intCast(comment.len)));
    try out.appendSlice(allocator, comment);

    return out.toOwnedSlice(allocator);
}

const TarFixtureEntry = struct {
    name: []const u8,
    data: []const u8,
};

fn writeTarOctal(field: []u8, value: usize) void {
    std.debug.assert(field.len >= 2);
    @memset(field, '0');
    field[field.len - 1] = 0;
    var v = value;
    var idx = field.len - 1;
    while (v > 0 and idx > 0) {
        idx -= 1;
        field[idx] = @as(u8, @intCast('0' + (v & 7)));
        v >>= 3;
    }
}

fn writeTarChecksum(field: []u8, checksum: u32) void {
    std.debug.assert(field.len == 8);
    @memset(field[0..6], '0');
    field[6] = 0;
    field[7] = ' ';
    var v = checksum;
    var idx: usize = 6;
    while (idx > 0) : (idx -= 1) {
        field[idx - 1] = @as(u8, @intCast('0' + (v & 7)));
        v >>= 3;
    }
}

fn buildTarFixture(allocator: std.mem.Allocator, entries: []const TarFixtureEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (entries) |entry| {
        std.debug.assert(entry.name.len <= 100);

        var header: [512]u8 = @splat(0);
        @memcpy(header[0..entry.name.len], entry.name);
        writeTarOctal(header[100..108], 0o644);
        writeTarOctal(header[108..116], 0);
        writeTarOctal(header[116..124], 0);
        writeTarOctal(header[124..136], entry.data.len);
        writeTarOctal(header[136..148], 0);
        @memset(header[148..156], ' ');
        header[156] = '0';
        @memcpy(header[257..263], "ustar\x00");
        @memcpy(header[263..265], "00");

        var checksum: u32 = 0;
        for (header) |byte| checksum += byte;
        writeTarChecksum(header[148..156], checksum);

        try out.appendSlice(allocator, &header);
        try out.appendSlice(allocator, entry.data);

        const remainder = entry.data.len % 512;
        if (remainder != 0) {
            try appendZeroes(&out, allocator, 512 - remainder);
        }
    }

    try appendZeroes(&out, allocator, 1024);
    return out.toOwnedSlice(allocator);
}

fn expectNamedEntryData(
    archive: *Archive,
    allocator: std.mem.Allocator,
    name: []const u8,
    expected: []const u8,
) !void {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);

    try std.testing.expect(archive.parseEntryFor(name_z));
    const entry = currentEntry(archive);
    const got = try entry.readAlloc(allocator, expected.len);
    defer allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

fn readFixtureFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
}

test "runtime version matches generated header values" {
    const v = runtimeVersion();
    try std.testing.expectEqual(@as(u8, 1), v.major);
    try std.testing.expectEqual(@as(u8, 2), v.minor);
    try std.testing.expectEqual(@as(u8, 0), v.patch);
    try std.testing.expectEqualStrings("1.2.0", v.string);
}

test "automatic format detection streams remaining bytes and invalidates stale entries" {
    const allocator = std.testing.allocator;
    const bytes = try buildTarFixture(allocator, &.{
        .{ .name = "first.txt", .data = "abcdef" },
        .{ .name = "second.txt", .data = "1234" },
    });
    defer allocator.free(bytes);
    var archive = try Archive.openMemory(.auto, bytes, .{});
    defer archive.deinit();
    const first = (try archive.next()).?;
    var prefix: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try first.readSome(&prefix));
    try std.testing.expectEqualStrings("ab", &prefix);
    try std.testing.expectEqual(@as(usize, 4), try first.remaining());
    const rest = try first.readAlloc(allocator, 4);
    defer allocator.free(rest);
    try std.testing.expectEqualStrings("cdef", rest);
    try std.testing.expectEqual(@as(usize, 0), try first.readSome(&prefix));
    try std.testing.expectError(error.EndOfEntry, first.read(&prefix));
    const second = (try archive.next()).?;
    try std.testing.expectError(error.StaleEntry, first.readSome(&prefix));
    try std.testing.expect(first.name() == null);
    try std.testing.expectEqual(@as(usize, 6), first.size());
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try second.writeTo(&output.writer);
    try std.testing.expectEqualStrings("1234", output.written());
    const found = (try archive.find("first.txt")).?;
    const all = try found.readAlloc(allocator, 6);
    defer allocator.free(all);
    try std.testing.expectEqualStrings("abcdef", all);
    try std.testing.expectError(error.InvalidOffset, archive.seek(-1));
    try std.testing.expectError(error.StaleEntry, found.remaining());
    try std.testing.expect((try archive.find("missing.txt")) == null);
    try std.testing.expectError(error.StaleEntry, found.remaining());
}

test "bounded extraction and allocation failure leave entry readable" {
    const allocator = std.testing.allocator;
    const bytes = try buildZipSingleFileFixture(allocator, "a.txt", "allocated data", "");
    defer allocator.free(bytes);
    var archive = try Archive.openMemory(.auto, bytes, .{});
    defer archive.deinit();
    const entry = (try archive.next()).?;
    try std.testing.expectError(error.EntryTooLarge, entry.readAlloc(allocator, 1));
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, entry.readAlloc(failing.allocator(), 100));
    const value = try entry.readAlloc(allocator, 100);
    defer allocator.free(value);
    try std.testing.expectEqualStrings("allocated data", value);
    try std.testing.expectError(error.InvalidPath, Archive.openFile(allocator, .auto, "file\x00.zip", .{}));
}

test "corrupt entry bytes fail checksum and poison only the current read cursor" {
    const allocator = std.testing.allocator;
    const bytes = try buildZipSingleFileFixture(allocator, "a.txt", "original", "");
    defer allocator.free(bytes);
    bytes[30 + "a.txt".len] ^= 1;
    var archive = try Archive.openMemory(.auto, bytes, .{});
    defer archive.deinit();
    const entry = (try archive.next()).?;
    try std.testing.expectError(error.DecompressFailed, entry.readAlloc(allocator, 100));
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.DecompressFailed, entry.read(&buffer));
}

test "RAR4 stored entry auto detection validates content and EOF" {
    const allocator = std.testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    try data.appendSlice(allocator, "Rar!\x1a\x07\x00");
    var main = [_]u8{ 0, 0, 0x73, 0, 0, 13, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u16, main[0..2], @truncate(std.hash.Crc32.hash(main[2..])), .little);
    try data.appendSlice(allocator, &main);
    const name = "stored.txt";
    const content = "RAR stored payload\x00\xff";
    var header: [32 + name.len]u8 = @splat(0);
    header[2] = 0x74;
    std.mem.writeInt(u16, header[3..5], 0x8000, .little);
    std.mem.writeInt(u16, header[5..7], header.len, .little);
    std.mem.writeInt(u32, header[7..11], content.len, .little);
    std.mem.writeInt(u32, header[11..15], content.len, .little);
    header[15] = 3;
    std.mem.writeInt(u32, header[16..20], std.hash.Crc32.hash(content), .little);
    header[24] = 20;
    header[25] = 0x30;
    std.mem.writeInt(u16, header[26..28], name.len, .little);
    std.mem.writeInt(u32, header[28..32], 0o100644, .little);
    @memcpy(header[32..], name);
    std.mem.writeInt(u16, header[0..2], @truncate(std.hash.Crc32.hash(header[2..])), .little);
    try data.appendSlice(allocator, &header);
    try data.appendSlice(allocator, content);
    var end = [_]u8{ 0, 0, 0x7b, 0, 0, 7, 0 };
    std.mem.writeInt(u16, end[0..2], @truncate(std.hash.Crc32.hash(end[2..])), .little);
    try data.appendSlice(allocator, &end);
    var archive = try Archive.openMemory(.auto, data.items, .{});
    defer archive.deinit();
    const entry = (try archive.next()).?;
    try std.testing.expectEqualStrings(name, entry.name().?);
    const decoded = try entry.readAlloc(allocator, 100);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, content, decoded);
    try std.testing.expect((try archive.next()) == null);
}

test "open memory rejects empty slices" {
    try std.testing.expectError(error.OpenStreamFailed, Archive.openMemory(.zip, "", .{}));
    try std.testing.expectError(error.OpenStreamFailed, Archive.openMemory(.tar, "", .{}));
    try std.testing.expectError(error.OpenStreamFailed, Archive.openMemory(.rar, "", .{}));
    try std.testing.expectError(error.OpenStreamFailed, Archive.openMemory(.@"7z", "", .{}));
}

test "invalid bytes are rejected for all formats" {
    const bogus = "not-an-archive";
    try std.testing.expectError(error.OpenArchiveFailed, Archive.openMemory(.zip, bogus, .{}));
    try std.testing.expectError(error.OpenArchiveFailed, Archive.openMemory(.tar, bogus, .{}));
    try std.testing.expectError(error.OpenArchiveFailed, Archive.openMemory(.rar, bogus, .{}));
    try std.testing.expectError(if (@import("build_options").enable_7z) error.OpenArchiveFailed else error.UnsupportedFormat, Archive.openMemory(.@"7z", bogus, .{}));
}

test "zip fixture supports entry reading, offsets, and comments" {
    const allocator = std.testing.allocator;
    const file_name = "hello.txt";
    const payload = "hello world";
    const comment = "fixture-comment";
    const zip = try buildZipSingleFileFixture(allocator, file_name, payload, comment);
    defer allocator.free(zip);

    var archive = try Archive.openMemory(.zip, zip, .{});
    defer archive.deinit();

    try std.testing.expectEqual(comment.len, archive.globalCommentSize());
    var comment_buf: [64]u8 = undefined;
    const copied = archive.readGlobalComment(comment_buf[0..]);
    try std.testing.expectEqual(comment.len, copied);
    try std.testing.expectEqualStrings(comment, comment_buf[0..copied]);

    var short_comment_buf: [4]u8 = undefined;
    const short_copied = archive.readGlobalComment(short_comment_buf[0..]);
    try std.testing.expectEqual(@as(usize, 4), short_copied);
    try std.testing.expectEqualStrings(comment[0..4], short_comment_buf[0..]);

    const first = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(file_name, first.name() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings(file_name, first.rawName() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(payload.len, first.size());

    const offset = first.offset();
    try std.testing.expect(offset >= 0);

    try std.testing.expectError(error.EntryTooLarge, first.readAlloc(allocator, payload.len - 1));
    const read_once = try first.readAlloc(allocator, payload.len);
    defer allocator.free(read_once);
    try std.testing.expectEqualStrings(payload, read_once);

    try archive.parseEntryAt(offset);
    const reparsed = currentEntry(&archive);
    var read_buf: [payload.len]u8 = undefined;
    try reparsed.read(read_buf[0..]);
    try std.testing.expectEqualStrings(payload, read_buf[0..]);

    const file_name_z = try allocator.dupeSentinel(u8, file_name, 0);
    defer allocator.free(file_name_z);
    try std.testing.expect(archive.parseEntryFor(file_name_z));
    const named = currentEntry(&archive);
    const named_payload = try named.readAlloc(allocator, payload.len);
    defer allocator.free(named_payload);
    try std.testing.expectEqualStrings(payload, named_payload);

    try std.testing.expect((try archive.nextEntry()) == null);
    try std.testing.expect(archive.atEof());
}

test "openFile works with generated zip fixture" {
    const allocator = std.testing.allocator;
    const zip = try buildZipSingleFileFixture(allocator, "from_file.txt", "abc123", "");
    defer allocator.free(zip);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.zip",
        .data = zip,
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const abs_path = try std.fs.path.join(allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "sample.zip",
    });
    defer allocator.free(abs_path);

    const abs_path_z = try allocator.dupeSentinel(u8, abs_path, 0);
    defer allocator.free(abs_path_z);

    var archive = try Archive.openFile(allocator, .zip, abs_path_z, .{});
    defer archive.deinit();

    const entry = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    const data = try entry.readAlloc(allocator, 1024);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("abc123", data);
    try std.testing.expect((try archive.nextEntry()) == null);
}

test "tar fixture supports multi-entry iteration and parseEntryAt" {
    const allocator = std.testing.allocator;
    const tar = try buildTarFixture(allocator, &.{
        .{ .name = "one.txt", .data = "111" },
        .{ .name = "two.txt", .data = "22222" },
    });
    defer allocator.free(tar);

    var archive = try Archive.openMemory(.tar, tar, .{});
    defer archive.deinit();

    const first = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("one.txt", first.name() orelse return error.TestUnexpectedResult);
    const first_data = try first.readAlloc(allocator, 16);
    defer allocator.free(first_data);
    try std.testing.expectEqualStrings("111", first_data);

    const second = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("two.txt", second.name() orelse return error.TestUnexpectedResult);
    const second_offset = second.offset();
    const second_data = try second.readAlloc(allocator, 16);
    defer allocator.free(second_data);
    try std.testing.expectEqualStrings("22222", second_data);
    try std.testing.expect((try archive.nextEntry()) == null);

    try archive.parseEntryAt(second_offset);
    const reparsed = currentEntry(&archive);
    const reparsed_data = try reparsed.readAlloc(allocator, 16);
    defer allocator.free(reparsed_data);
    try std.testing.expectEqualStrings("22222", reparsed_data);
}

test "parseEntryFor locates entries and misses unknown names" {
    const allocator = std.testing.allocator;
    const tar = try buildTarFixture(allocator, &.{
        .{ .name = "a.txt", .data = "A" },
        .{ .name = "b.txt", .data = "BBBB" },
    });
    defer allocator.free(tar);

    var archive = try Archive.openMemory(.tar, tar, .{});
    defer archive.deinit();

    const exists = try allocator.dupeSentinel(u8, "b.txt", 0);
    defer allocator.free(exists);
    try std.testing.expect(archive.parseEntryFor(exists));
    const found = currentEntry(&archive);
    const found_data = try found.readAlloc(allocator, 8);
    defer allocator.free(found_data);
    try std.testing.expectEqualStrings("BBBB", found_data);

    const missing = try allocator.dupeSentinel(u8, "missing.txt", 0);
    defer allocator.free(missing);
    try std.testing.expect(!archive.parseEntryFor(missing));
}

test "openStream does not take stream ownership" {
    const allocator = std.testing.allocator;
    const zip = try buildZipSingleFileFixture(allocator, "stream.txt", "stream-data", "");
    defer allocator.free(zip);

    const stream = c.ar_open_memory(zip.ptr, zip.len) orelse return error.TestUnexpectedResult;
    defer c.ar_close(stream);

    var first_archive = try Archive.openStream(.zip, stream, .{});
    first_archive.deinit();

    // If openStream incorrectly owned/closed the stream, this second seek/open
    // sequence is likely to fail or crash.
    try std.testing.expect(c.ar_seek(stream, 0, 0));
    var second_archive = try Archive.openStream(.zip, stream, .{});
    defer second_archive.deinit();
    const entry = (try second_archive.nextEntry()) orelse return error.TestUnexpectedResult;
    const data = try entry.readAlloc(allocator, 64);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("stream-data", data);
}

test "real zip fixture from disk decompresses deflate entries" {
    const allocator = std.testing.allocator;
    const real_alpha = try readFixtureFile(allocator, "testdata/src/alpha.txt");
    defer allocator.free(real_alpha);
    const real_beta = try readFixtureFile(allocator, "testdata/src/beta.bin");
    defer allocator.free(real_beta);

    const path_z = try allocator.dupeSentinel(u8, "testdata/archives/real-deflate.zip", 0);
    defer allocator.free(path_z);

    var archive = try Archive.openFile(allocator, .zip, path_z, .{});
    defer archive.deinit();

    try std.testing.expectEqual(@as(usize, 0), archive.globalCommentSize());
    try expectNamedEntryData(&archive, allocator, "alpha.txt", real_alpha);
    try expectNamedEntryData(&archive, allocator, "beta.bin", real_beta);

    const missing = try allocator.dupeSentinel(u8, "missing.file", 0);
    defer allocator.free(missing);
    try std.testing.expect(!archive.parseEntryFor(missing));
}

test "real zip fixture in memory iterates entries and reparses offsets" {
    const allocator = std.testing.allocator;
    const archive_bytes = try readFixtureFile(allocator, "testdata/archives/real-deflate.zip");
    defer allocator.free(archive_bytes);
    const real_alpha = try readFixtureFile(allocator, "testdata/src/alpha.txt");
    defer allocator.free(real_alpha);
    const real_beta = try readFixtureFile(allocator, "testdata/src/beta.bin");
    defer allocator.free(real_beta);

    var archive = try Archive.openMemory(.zip, archive_bytes, .{});
    defer archive.deinit();

    const first = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("alpha.txt", first.name() orelse return error.TestUnexpectedResult);
    const first_data = try first.readAlloc(allocator, real_alpha.len);
    defer allocator.free(first_data);
    try std.testing.expectEqualStrings(real_alpha, first_data);

    const second = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("beta.bin", second.name() orelse return error.TestUnexpectedResult);
    const second_offset = second.offset();
    const second_data = try second.readAlloc(allocator, real_beta.len);
    defer allocator.free(second_data);
    try std.testing.expectEqualSlices(u8, real_beta, second_data);
    try std.testing.expect((try archive.nextEntry()) == null);

    try archive.parseEntryAt(second_offset);
    const reparsed = currentEntry(&archive);
    const reparsed_data = try reparsed.readAlloc(allocator, real_beta.len);
    defer allocator.free(reparsed_data);
    try std.testing.expectEqualSlices(u8, real_beta, reparsed_data);
}

test "real tar fixture from disk parses entries" {
    const allocator = std.testing.allocator;
    const real_alpha = try readFixtureFile(allocator, "testdata/src/alpha.txt");
    defer allocator.free(real_alpha);
    const real_beta = try readFixtureFile(allocator, "testdata/src/beta.bin");
    defer allocator.free(real_beta);

    const path_z = try allocator.dupeSentinel(u8, "testdata/archives/real.tar", 0);
    defer allocator.free(path_z);

    var archive = try Archive.openFile(allocator, .tar, path_z, .{});
    defer archive.deinit();

    const first = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("alpha.txt", first.name() orelse return error.TestUnexpectedResult);
    const first_data = try first.readAlloc(allocator, real_alpha.len);
    defer allocator.free(first_data);
    try std.testing.expectEqualStrings(real_alpha, first_data);

    const second = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("beta.bin", second.name() orelse return error.TestUnexpectedResult);
    const second_offset = second.offset();
    const second_data = try second.readAlloc(allocator, real_beta.len);
    defer allocator.free(second_data);
    try std.testing.expectEqualSlices(u8, real_beta, second_data);
    try std.testing.expect((try archive.nextEntry()) == null);

    try archive.parseEntryAt(second_offset);
    const reparsed = currentEntry(&archive);
    const reparsed_data = try reparsed.readAlloc(allocator, real_beta.len);
    defer allocator.free(reparsed_data);
    try std.testing.expectEqualSlices(u8, real_beta, reparsed_data);
}

test "real 7z fixture from disk decompresses entries" {
    if (!@import("build_options").enable_7z) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const real_alpha = try readFixtureFile(allocator, "testdata/src/alpha.txt");
    defer allocator.free(real_alpha);
    const real_beta = try readFixtureFile(allocator, "testdata/src/beta.bin");
    defer allocator.free(real_beta);

    const path_z = try allocator.dupeSentinel(u8, "testdata/archives/real.7z", 0);
    defer allocator.free(path_z);

    var archive = try Archive.openFile(allocator, .@"7z", path_z, .{});
    defer archive.deinit();

    try expectNamedEntryData(&archive, allocator, "alpha.txt", real_alpha);
    try expectNamedEntryData(&archive, allocator, "beta.bin", real_beta);
}

test "real 7z fixture in memory iterates entries" {
    if (!@import("build_options").enable_7z) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const archive_bytes = try readFixtureFile(allocator, "testdata/archives/real.7z");
    defer allocator.free(archive_bytes);
    const real_alpha = try readFixtureFile(allocator, "testdata/src/alpha.txt");
    defer allocator.free(real_alpha);
    const real_beta = try readFixtureFile(allocator, "testdata/src/beta.bin");
    defer allocator.free(real_beta);

    var archive = try Archive.openMemory(.@"7z", archive_bytes, .{});
    defer archive.deinit();

    const first = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("alpha.txt", first.name() orelse return error.TestUnexpectedResult);
    const first_data = try first.readAlloc(allocator, real_alpha.len);
    defer allocator.free(first_data);
    try std.testing.expectEqualStrings(real_alpha, first_data);

    const second = (try archive.nextEntry()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("beta.bin", second.name() orelse return error.TestUnexpectedResult);
    const second_data = try second.readAlloc(allocator, real_beta.len);
    defer allocator.free(second_data);
    try std.testing.expectEqualSlices(u8, real_beta, second_data);
    try std.testing.expect((try archive.nextEntry()) == null);
    try std.testing.expect(archive.atEof());
}

test "empty ZIP extraction validates native checksum and encryption flags" {
    const allocator = std.testing.allocator;
    const bytes = try buildZipSingleFileFixture(allocator, "empty", "", "");
    defer allocator.free(bytes);
    {
        var archive = try Archive.openMemory(.zip, bytes, .{});
        defer archive.deinit();
        const entry = (try archive.next()).?;
        const output = try entry.readAlloc(allocator, 0);
        defer allocator.free(output);
        try std.testing.expectEqual(@as(usize, 0), output.len);
        var writer: std.Io.Writer = .fixed(&.{});
        try entry.writeTo(&writer);
    }
    // Central-directory CRC is authoritative for this parser.
    const central = 30 + "empty".len;
    std.mem.writeInt(u32, bytes[central + 16 ..][0..4], 0x12345678, .little);
    {
        var archive = try Archive.openMemory(.zip, bytes, .{});
        defer archive.deinit();
        const entry = (try archive.next()).?;
        try std.testing.expectError(error.DecompressFailed, entry.readAlloc(allocator, 0));
        try std.testing.expectError(error.DecompressFailed, entry.read(&.{}));
    }
    std.mem.writeInt(u32, bytes[central + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u16, bytes[central + 8 ..][0..2], 1, .little);
    {
        var archive = try Archive.openMemory(.zip, bytes, .{});
        defer archive.deinit();
        const entry = (try archive.next()).?;
        var writer: std.Io.Writer = .fixed(&.{});
        try std.testing.expectError(error.DecompressFailed, entry.writeTo(&writer));
    }
}
