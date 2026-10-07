const std = @import("std");
const vaxis = @import("../main.zig");
const uucode = @import("uucode");
const ScrollView = vaxis.widgets.ScrollView;

/// Simple grapheme representation to replace Graphemes.Grapheme
const Grapheme = struct {
    len: u16,
    offset: u32,
};

fn byteSlicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;

    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return if (a_start <= b_start)
        b_start - a_start < a.len
    else
        a_start - b_start < b.len;
}

pub fn isNewlineCluster(cluster: []const u8) bool {
    return std.mem.eql(u8, cluster, "\n") or std.mem.eql(u8, cluster, "\r\n");
}

pub const BufferWriter = struct {
    pub const Error = error{OutOfMemory};

    allocator: std.mem.Allocator,
    buffer: *Buffer,

    pub fn write(self: @This(), bytes: []const u8) Error!usize {
        try self.buffer.append(self.allocator, .{ .bytes = bytes });
        return bytes.len;
    }

    pub fn writer(self: @This()) Writer {
        return .{ .context = self };
    }

    pub fn writeAll(self: @This(), bytes: []const u8) Error!void {
        return self.writer().writeAll(bytes);
    }

    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) Error!void {
        return self.writer().print(fmt, args);
    }

    /// Zig 0.17 replacement for the former `std.io.GenericWriter`. Keeping the
    /// context field and common convenience methods avoids needless API churn.
    pub const Writer = struct {
        pub const Error = BufferWriter.Error;

        context: BufferWriter,
        interface: std.Io.Writer = .{
            .vtable = &vtable,
            .buffer = &.{},
        },
        failure: ?BufferWriter.Error = null,

        const vtable: std.Io.Writer.VTable = .{
            .drain = drain,
            .flush = std.Io.Writer.noopFlush,
            .rebase = std.Io.Writer.failingRebase,
        };

        pub fn write(self: @This(), bytes: []const u8) BufferWriter.Error!usize {
            var copy = self;
            copy.failure = null;
            return copy.interface.write(bytes) catch {
                return copy.failure orelse error.OutOfMemory;
            };
        }

        pub fn writeAll(self: @This(), bytes: []const u8) BufferWriter.Error!void {
            var copy = self;
            copy.failure = null;
            copy.interface.writeAll(bytes) catch {
                return copy.failure orelse error.OutOfMemory;
            };
        }

        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) BufferWriter.Error!void {
            var copy = self;
            copy.failure = null;
            copy.interface.print(fmt, args) catch {
                return copy.failure orelse error.OutOfMemory;
            };
        }

        pub fn writeByte(self: @This(), byte: u8) BufferWriter.Error!void {
            var copy = self;
            copy.failure = null;
            copy.interface.writeByte(byte) catch {
                return copy.failure orelse error.OutOfMemory;
            };
        }

        pub fn writeByteNTimes(self: @This(), byte: u8, n: usize) BufferWriter.Error!void {
            return self.writeRepeated(&.{byte}, n);
        }

        pub fn writeBytesNTimes(self: @This(), bytes: []const u8, n: usize) BufferWriter.Error!void {
            return self.writeRepeated(bytes, n);
        }

        pub inline fn writeStruct(self: @This(), value: anytype, endian: std.lang.Endian) BufferWriter.Error!void {
            var copy = self;
            copy.failure = null;
            copy.interface.writeStruct(value, endian) catch {
                return copy.failure orelse error.OutOfMemory;
            };
        }

        pub fn writeInt(self: @This(), comptime T: type, value: T, endian: std.lang.Endian) BufferWriter.Error!void {
            var copy = self;
            copy.failure = null;
            copy.interface.writeInt(T, value, endian) catch {
                return copy.failure orelse error.OutOfMemory;
            };
        }

        /// Returns Zig 0.17's standard writer interface. Keep this owner at a
        /// stable address while the returned pointer is in use. Zig's raw
        /// splat helpers require their logical byte count to fit in `usize`;
        /// prefer the checked `writeByteNTimes` and `writeBytesNTimes`
        /// conveniences when the repetition count is not trusted.
        pub fn stdWriter(self: *@This()) *std.Io.Writer {
            return &self.interface;
        }

        pub fn lastError(self: *const @This()) ?BufferWriter.Error {
            return self.failure;
        }

        fn drain(writer_interface: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("interface", writer_interface));
            std.debug.assert(writer_interface.end == 0);
            std.debug.assert(data.len != 0);
            self.failure = null;

            var total: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                total = std.math.add(usize, total, bytes.len) catch {
                    self.failure = error.OutOfMemory;
                    return error.WriteFailed;
                };
            }

            const pattern = data[data.len - 1];
            const repeated_len = std.math.mul(usize, pattern.len, splat) catch {
                self.failure = error.OutOfMemory;
                return error.WriteFailed;
            };
            total = std.math.add(usize, total, repeated_len) catch {
                self.failure = error.OutOfMemory;
                return error.WriteFailed;
            };

            if (total == 0) return 0;
            if (data.len == 1 and splat == 1) {
                try self.append(pattern);
                return total;
            }

            // One drain is one logical byte stream. Joining it before parsing
            // prevents vector and splat boundaries from splitting UTF-8 or an
            // extended grapheme. Allocation is exactly the logical byte count.
            const joined = self.context.allocator.alloc(u8, total) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            defer self.context.allocator.free(joined);

            var offset: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                @memcpy(joined[offset..][0..bytes.len], bytes);
                offset += bytes.len;
            }
            if (pattern.len != 0) {
                for (0..splat) |_| {
                    @memcpy(joined[offset..][0..pattern.len], pattern);
                    offset += pattern.len;
                }
            }
            std.debug.assert(offset == joined.len);

            try self.append(joined);
            return total;
        }

        fn append(self: *@This(), bytes: []const u8) std.Io.Writer.Error!void {
            self.context.buffer.append(self.context.allocator, .{ .bytes = bytes }) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
        }

        fn writeRepeated(self: @This(), bytes: []const u8, n: usize) BufferWriter.Error!void {
            var copy = self;
            copy.failure = null;
            _ = drain(&copy.interface, &.{bytes}, n) catch {
                return copy.failure orelse error.OutOfMemory;
            };
        }
    };
};

pub const Buffer = struct {
    const StyleList = std.ArrayList(vaxis.Style);
    const StyleMap = std.HashMapUnmanaged(usize, usize, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage);

    pub const Content = struct {
        bytes: []const u8,
    };

    pub const Style = struct {
        begin: usize,
        end: usize,
        style: vaxis.Style,
    };

    pub const Error = error{OutOfMemory};

    grapheme: std.MultiArrayList(Grapheme) = .empty,
    content: std.ArrayListUnmanaged(u8) = .empty,
    style_list: StyleList = .empty,
    style_map: StyleMap = .empty,
    // Number of LF line breaks. The visible line count is always `rows + 1`,
    // including the trailing empty line after a final newline.
    rows: usize = 0,
    cols: usize = 0,
    // used when appending to a buffer
    last_cols: usize = 0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.style_map.deinit(allocator);
        self.style_list.deinit(allocator);
        self.grapheme.deinit(allocator);
        self.content.deinit(allocator);
        self.* = undefined;
    }

    /// Clears all buffer data.
    pub fn clear(self: *@This(), allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.* = .{};
    }

    /// Replaces contents of the buffer, all previous buffer data is lost.
    pub fn update(self: *@This(), allocator: std.mem.Allocator, content: Content) Error!void {
        // `content.bytes` may point into this buffer. Preserve it before
        // `clear` releases the backing allocation.
        var staged_bytes: ?[]u8 = null;
        defer if (staged_bytes) |bytes| allocator.free(bytes);
        const bytes: []const u8 = if (byteSlicesOverlap(content.bytes, self.content.allocatedSlice())) blk: {
            const copy = try allocator.dupe(u8, content.bytes);
            staged_bytes = copy;
            break :blk copy;
        } else content.bytes;

        self.clear(allocator);
        errdefer self.clear(allocator);
        try self.append(allocator, .{ .bytes = bytes });
    }

    /// Appends content to the buffer.
    pub fn append(self: *@This(), allocator: std.mem.Allocator, content: Content) Error!void {
        if (content.bytes.len == 0) return;

        // Re-segment the combined byte stream so append and writer call
        // boundaries cannot split UTF-8 or an extended grapheme. Build all
        // replacement storage first, keeping both self-aliases and failures
        // harmless until the final non-failing swap.
        var rebuilt_content: std.ArrayListUnmanaged(u8) = .empty;
        errdefer rebuilt_content.deinit(allocator);
        try rebuilt_content.appendSlice(allocator, self.content.items);
        try rebuilt_content.appendSlice(allocator, content.bytes);

        var rebuilt_grapheme: std.MultiArrayList(Grapheme) = .empty;
        errdefer rebuilt_grapheme.deinit(allocator);

        const bytes = rebuilt_content.items;
        var cols: usize = 0;
        var max_cols: usize = 0;
        var iter = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(bytes));

        while (iter.nextGrapheme()) |grapheme| {
            const grapheme_len = grapheme.end - grapheme.start;

            try rebuilt_grapheme.append(allocator, .{
                .len = std.math.cast(u16, grapheme_len) orelse return error.OutOfMemory,
                .offset = std.math.cast(u32, grapheme.start) orelse return error.OutOfMemory,
            });

            const cluster = bytes[grapheme.start..grapheme.end];
            if (isNewlineCluster(cluster)) {
                max_cols = @max(max_cols, cols);
                cols = 0;
            } else {
                // Calculate width using gwidth.
                const w = vaxis.gwidth.gwidth(cluster, .unicode);
                cols +|= w;
            }
        }

        max_cols = @max(max_cols, cols);

        self.grapheme.deinit(allocator);
        self.content.deinit(allocator);
        self.grapheme = rebuilt_grapheme;
        self.content = rebuilt_content;
        self.last_cols = cols;
        self.cols = max_cols;
        self.rows = std.mem.count(u8, bytes, "\n");
    }

    /// Clears all styling data.
    pub fn clearStyle(self: *@This(), allocator: std.mem.Allocator) void {
        self.style_list.deinit(allocator);
        self.style_list = .empty;
        self.style_map.deinit(allocator);
        self.style_map = .empty;
    }

    pub fn lineCount(self: *const @This()) usize {
        return self.rows +| 1;
    }

    /// Update style for range of the buffer contents.
    pub fn updateStyle(self: *@This(), allocator: std.mem.Allocator, style: Style) Error!void {
        const style_index = blk: {
            for (self.style_list.items, 0..) |s, i| {
                if (std.meta.eql(s, style.style)) {
                    break :blk i;
                }
            }
            try self.style_list.append(allocator, style.style);
            break :blk self.style_list.items.len - 1;
        };
        for (style.begin..style.end) |i| {
            try self.style_map.put(allocator, i, style_index);
        }
    }

    pub fn writer(
        self: *@This(),
        allocator: std.mem.Allocator,
    ) BufferWriter.Writer {
        return .{
            .context = .{
                .allocator = allocator,
                .buffer = self,
            },
        };
    }
};

scroll_view: ScrollView = .{},

pub fn input(self: *@This(), key: vaxis.Key) void {
    self.scroll_view.input(key);
}

pub fn draw(self: *@This(), win: vaxis.Window, buffer: Buffer) void {
    self.scroll_view.draw(win, .{ .cols = buffer.cols, .rows = buffer.lineCount() });
    const Pos = struct { x: usize = 0, y: usize = 0 };
    var pos: Pos = .{};
    var byte_index: usize = 0;
    const bounds = self.scroll_view.bounds(win);
    for (buffer.grapheme.items(.len), buffer.grapheme.items(.offset), 0..) |g_len, g_offset, index| {
        if (bounds.above(pos.y)) {
            break;
        }

        const cluster = buffer.content.items[g_offset..][0..g_len];
        defer byte_index += cluster.len;

        if (isNewlineCluster(cluster)) {
            if (index == buffer.grapheme.len - 1) {
                break;
            }
            pos.y +|= 1;
            pos.x = 0;
            continue;
        } else if (bounds.below(pos.y)) {
            continue;
        }

        const width = win.gwidth(cluster);
        const cell_width = vaxis.gwidth.cellWidth(width);
        defer pos.x +|= width;

        if (!bounds.colInside(pos.x)) {
            continue;
        }
        const remaining_cols = bounds.x2 - pos.x;
        if (@as(usize, cell_width) > remaining_cols) {
            continue;
        }

        const style: vaxis.Style = blk: {
            if (buffer.style_map.get(byte_index)) |style_index| {
                break :blk buffer.style_list.items[style_index];
            }
            break :blk .{};
        };

        self.scroll_view.writeCell(win, pos.x, pos.y, .{
            .char = .{ .grapheme = cluster, .width = cell_width },
            .style = style,
        });
    }
}

fn expectBufferStorageValid(buffer: *const Buffer) !void {
    const content_len = buffer.content.items.len;
    for (buffer.grapheme.items(.len), buffer.grapheme.items(.offset)) |len, offset| {
        const start: usize = offset;
        try std.testing.expect(start <= content_len);
        try std.testing.expect(@as(usize, len) <= content_len - start);
    }
}

fn expectBuffersEqual(expected: *const Buffer, actual: *const Buffer) !void {
    try std.testing.expectEqualSlices(u8, expected.content.items, actual.content.items);
    try std.testing.expectEqualSlices(u16, expected.grapheme.items(.len), actual.grapheme.items(.len));
    try std.testing.expectEqualSlices(u32, expected.grapheme.items(.offset), actual.grapheme.items(.offset));
    try std.testing.expectEqual(expected.rows, actual.rows);
    try std.testing.expectEqual(expected.cols, actual.cols);
    try std.testing.expectEqual(expected.last_cols, actual.last_cols);
    try expectBufferStorageValid(actual);
}

fn expectEmptyBuffer(buffer: *const Buffer) !void {
    try std.testing.expectEqual(@as(usize, 0), buffer.content.items.len);
    try std.testing.expectEqual(@as(usize, 0), buffer.grapheme.len);
    try std.testing.expectEqual(@as(usize, 0), buffer.rows);
    try std.testing.expectEqual(@as(usize, 0), buffer.cols);
    try std.testing.expectEqual(@as(usize, 0), buffer.last_cols);
    try expectBufferStorageValid(buffer);
}

fn checkBufferAppendAllocations(allocator: std.mem.Allocator) !void {
    var buffer: Buffer = .{};
    defer buffer.deinit(allocator);

    buffer.append(allocator, .{ .bytes = "A\xcc\x81\nwide" }) catch |err| {
        try expectEmptyBuffer(&buffer);
        return err;
    };
    try std.testing.expectEqualStrings("A\xcc\x81\nwide", buffer.content.items);
    try expectBufferStorageValid(&buffer);
}

fn checkBufferWriterAllocations(allocator: std.mem.Allocator) !void {
    var buffer: Buffer = .{};
    defer buffer.deinit(allocator);

    var writer = buffer.writer(allocator);
    var parts = [_][]const u8{ "\xc3", "\xa9 e", "\xcc", "\x81" };
    writer.stdWriter().writeVecAll(&parts) catch {
        try std.testing.expectEqual(@as(?BufferWriter.Error, error.OutOfMemory), writer.lastError());
        try expectEmptyBuffer(&buffer);
        return error.OutOfMemory;
    };
    try std.testing.expectEqualStrings("\xc3\xa9 e\xcc\x81", buffer.content.items);
    try expectBufferStorageValid(&buffer);
}

fn checkBufferAliasedAppendAllocations(allocator: std.mem.Allocator) !void {
    var buffer: Buffer = .{};
    defer buffer.deinit(allocator);

    buffer.append(allocator, .{ .bytes = "alias" }) catch |err| {
        try expectEmptyBuffer(&buffer);
        return err;
    };

    const source = buffer.content.items;
    buffer.append(allocator, .{ .bytes = source }) catch |err| {
        try std.testing.expectEqualStrings("alias", buffer.content.items);
        try expectBufferStorageValid(&buffer);
        return err;
    };

    try std.testing.expectEqualStrings("aliasalias", buffer.content.items);
    try expectBufferStorageValid(&buffer);
}

fn checkBufferAliasedUpdateAllocations(allocator: std.mem.Allocator) !void {
    var buffer: Buffer = .{};
    defer buffer.deinit(allocator);

    buffer.append(allocator, .{ .bytes = "replace" }) catch |err| {
        try expectEmptyBuffer(&buffer);
        return err;
    };

    const source = buffer.content.items;
    buffer.update(allocator, .{ .bytes = source }) catch |err| {
        // Failure while staging occurs before clear; a later failure leaves
        // the documented empty replacement state. Both must remain valid.
        if (buffer.content.items.len != 0) {
            try std.testing.expectEqualStrings("replace", buffer.content.items);
        }
        try expectBufferStorageValid(&buffer);
        return err;
    };

    try std.testing.expectEqualStrings("replace", buffer.content.items);
    try expectBufferStorageValid(&buffer);
}

test "Buffer.writer preserves common GenericWriter conveniences" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);

    const writer = buffer.writer(std.testing.allocator);
    try std.testing.expect(writer.context.buffer == &buffer);
    try writer.writeAll("name=");
    try writer.print("{s}:{d}\n", .{ "vaxis", 17 });
    try writer.writeByte(' ');
    try writer.writeByteNTimes('x', 2);
    try writer.writeBytesNTimes("yz", 2);
    try writer.writeInt(u16, 0x3132, .big);
    const Pair = extern struct { first: u8, second: u8 };
    try writer.writeStruct(Pair{ .first = 'A', .second = 'B' }, .big);
    try std.testing.expectEqual(@as(usize, 1), try writer.write("!"));
    try std.testing.expectEqualStrings("name=vaxis:17\n xxyzyz12AB!", buffer.content.items);
}

test "Buffer.writer rejects repeated byte-count overflow" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);

    const writer = buffer.writer(std.testing.allocator);
    try std.testing.expectError(
        error.OutOfMemory,
        writer.writeBytesNTimes("xx", std.math.maxInt(usize)),
    );
    try writer.writeBytesNTimes("", std.math.maxInt(usize));
    try expectEmptyBuffer(&buffer);
}

test "Buffer.writer treats vectors and splats as one text stream" {
    {
        var actual: Buffer = .{};
        defer actual.deinit(std.testing.allocator);
        var expected: Buffer = .{};
        defer expected.deinit(std.testing.allocator);

        var writer = actual.writer(std.testing.allocator);
        var parts = [_][]const u8{ "\xc3", "\xa9 ", "e", "\xcc", "\x81" };
        try writer.stdWriter().writeVecAll(&parts);
        try expected.append(std.testing.allocator, .{ .bytes = "\xc3\xa9 e\xcc\x81" });
        try expectBuffersEqual(&expected, &actual);
    }

    {
        const regional_indicator = "\xf0\x9f\x87\xa6";
        var actual: Buffer = .{};
        defer actual.deinit(std.testing.allocator);
        var expected: Buffer = .{};
        defer expected.deinit(std.testing.allocator);

        var writer = actual.writer(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 8), try writer.stdWriter().writeSplat(&.{regional_indicator}, 2));
        try expected.append(std.testing.allocator, .{ .bytes = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xa6" });
        try expectBuffersEqual(&expected, &actual);
    }

    {
        var buffer: Buffer = .{};
        defer buffer.deinit(std.testing.allocator);
        var writer = buffer.writer(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), try writer.stdWriter().writeSplat(&.{ "x", "" }, 10_000));
        try std.testing.expectEqualStrings("x", buffer.content.items);
    }
}

test "Buffer append and writer preserve malformed utf8 byte spans" {
    const malformed = "\xff\xcc\x81";

    var expected: Buffer = .{};
    defer expected.deinit(std.testing.allocator);
    try expected.append(std.testing.allocator, .{ .bytes = malformed });
    try std.testing.expectEqual(@as(usize, 1), expected.grapheme.len);
    try std.testing.expectEqual(@as(u16, malformed.len), expected.grapheme.items(.len)[0]);
    try std.testing.expectEqual(@as(u32, 0), expected.grapheme.items(.offset)[0]);

    var actual: Buffer = .{};
    defer actual.deinit(std.testing.allocator);
    var writer = actual.writer(std.testing.allocator);
    var parts = [_][]const u8{ "\xff", "\xcc", "\x81" };
    try writer.stdWriter().writeVecAll(&parts);
    try expectBuffersEqual(&expected, &actual);
}

test "Buffer append and writer resegment across call boundaries" {
    var expected: Buffer = .{};
    defer expected.deinit(std.testing.allocator);
    try expected.append(std.testing.allocator, .{ .bytes = "\xc3\xa9 e\xcc\x81" });

    {
        var actual: Buffer = .{};
        defer actual.deinit(std.testing.allocator);
        try actual.append(std.testing.allocator, .{ .bytes = "\xc3" });
        try actual.append(std.testing.allocator, .{ .bytes = "\xa9 e" });
        try actual.append(std.testing.allocator, .{ .bytes = "\xcc" });
        try actual.append(std.testing.allocator, .{ .bytes = "\x81" });
        try expectBuffersEqual(&expected, &actual);
    }

    {
        var actual: Buffer = .{};
        defer actual.deinit(std.testing.allocator);
        var writer = actual.writer(std.testing.allocator);
        try writer.stdWriter().writeAll("\xc3");
        try writer.stdWriter().writeAll("\xa9 e");
        try writer.stdWriter().writeAll("\xcc");
        try writer.stdWriter().writeAll("\x81");
        try expectBuffersEqual(&expected, &actual);
    }
}

test "Buffer treats CRLF graphemes as line breaks" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, .{ .bytes = "aa\r" });
    try buffer.append(std.testing.allocator, .{ .bytes = "\nb" });

    try std.testing.expectEqualStrings("aa\r\nb", buffer.content.items);
    try std.testing.expectEqual(@as(usize, 4), buffer.grapheme.len);
    try std.testing.expectEqual(@as(u16, 2), buffer.grapheme.items(.len)[2]);
    try std.testing.expectEqual(@as(u32, 2), buffer.grapheme.items(.offset)[2]);
    try std.testing.expectEqual(@as(usize, 1), buffer.rows);
    try std.testing.expectEqual(@as(usize, 2), buffer.lineCount());
    try std.testing.expectEqual(@as(usize, 2), buffer.cols);
    try std.testing.expectEqual(@as(usize, 1), buffer.last_cols);
    try expectBufferStorageValid(&buffer);

    try buffer.update(std.testing.allocator, .{ .bytes = "x\r\n" });
    try std.testing.expectEqual(@as(usize, 1), buffer.rows);
    try std.testing.expectEqual(@as(usize, 2), buffer.lineCount());
    try std.testing.expectEqual(@as(usize, 1), buffer.cols);
    try std.testing.expectEqual(@as(usize, 0), buffer.last_cols);
}

test "Buffer append safely stages aliased content" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, .{ .bytes = "self" });
    const source = buffer.content.items;
    try buffer.append(std.testing.allocator, .{ .bytes = source });
    try std.testing.expectEqualStrings("selfself", buffer.content.items);
    try expectBufferStorageValid(&buffer);
}

test "Buffer update safely stages aliased content before clear" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, .{ .bytes = "self" });
    const source = buffer.content.items;
    try buffer.update(std.testing.allocator, .{ .bytes = source });
    try std.testing.expectEqualStrings("self", buffer.content.items);
    try expectBufferStorageValid(&buffer);
}

test "Buffer.clearStyle resets containers for reuse" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.updateStyle(std.testing.allocator, .{ .begin = 0, .end = 1, .style = .{} });
    buffer.clearStyle(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), buffer.style_list.items.len);
    try std.testing.expectEqual(0, buffer.style_map.count());

    try buffer.updateStyle(std.testing.allocator, .{ .begin = 1, .end = 2, .style = .{} });
    try std.testing.expectEqual(@as(usize, 1), buffer.style_list.items.len);
    try std.testing.expectEqual(1, buffer.style_map.count());
}

test "Buffer.append rolls back later allocation failures and remains reusable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    var buffer: Buffer = .{};
    defer buffer.deinit(allocator);

    try std.testing.expectError(error.OutOfMemory, buffer.append(allocator, .{ .bytes = "x" }));
    try std.testing.expect(failing.has_induced_failure);
    try expectEmptyBuffer(&buffer);

    failing.fail_index = std.math.maxInt(usize);
    try buffer.append(allocator, .{ .bytes = "reused" });
    try std.testing.expectEqualStrings("reused", buffer.content.items);
    try expectBufferStorageValid(&buffer);
}

test "Buffer append and writer handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkBufferAppendAllocations, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkBufferWriterAllocations, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkBufferAliasedAppendAllocations, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkBufferAliasedUpdateAllocations, .{});
}

test "Buffer.writer maps standard writer allocation failures" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    var failing_buffer: Buffer = .{};
    defer failing_buffer.deinit(allocator);

    var failing_writer = failing_buffer.writer(allocator);
    try std.testing.expectError(error.WriteFailed, failing_writer.stdWriter().writeAll("x"));
    try std.testing.expectEqual(@as(?BufferWriter.Error, error.OutOfMemory), failing_writer.lastError());
    try expectEmptyBuffer(&failing_buffer);
}

test "draw requires the full cell span and retains zero-width graphemes" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);
    try buffer.append(std.testing.allocator, .{ .bytes = "界" });

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1,
        .cols = 1,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 1,
        .height = 1,
        .screen = &screen,
    };
    var text_view: @This() = .{};
    text_view.scroll_view.vertical_scrollbar = null;

    text_view.draw(win, buffer);
    try std.testing.expectEqualStrings(" ", win.readCell(0, 0).?.char.grapheme);

    screen.clear();
    try buffer.update(std.testing.allocator, .{ .bytes = "\u{200B}" });
    text_view.draw(win, buffer);
    const zero_width_cell = win.readCell(0, 0).?;
    try std.testing.expectEqualStrings("\u{200B}", zero_width_cell.char.grapheme);
    try std.testing.expectEqual(@as(u8, 0), zero_width_cell.char.width);
}
