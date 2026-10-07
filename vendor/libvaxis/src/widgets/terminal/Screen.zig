const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("../../main.zig");

const ansi = @import("ansi.zig");

const log = std.log.scoped(.vaxis_terminal);

const Screen = @This();

pub const Cell = struct {
    char: std.ArrayList(u8) = .empty,
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = .empty,
    uri_id: std.ArrayList(u8) = .empty,
    width: u8 = 1,

    wrapped: bool = false,
    dirty: bool = true,

    pub fn erase(self: *Cell, allocator: std.mem.Allocator, bg: vaxis.Color) void {
        self.char.clearRetainingCapacity();
        self.char.append(allocator, ' ') catch unreachable; // we never completely free this list
        self.style = .{};
        self.style.bg = bg;
        self.uri.clearRetainingCapacity();
        self.uri_id.clearRetainingCapacity();
        self.width = 1;
        self.wrapped = false;
        self.dirty = true;
    }

    pub fn copyFrom(self: *Cell, allocator: std.mem.Allocator, src: Cell) !void {
        self.char.clearRetainingCapacity();
        try self.char.appendSlice(allocator, src.char.items);
        self.style = src.style;
        self.uri.clearRetainingCapacity();
        try self.uri.appendSlice(allocator, src.uri.items);
        self.uri_id.clearRetainingCapacity();
        try self.uri_id.appendSlice(allocator, src.uri_id.items);
        self.width = src.width;
        self.wrapped = src.wrapped;

        self.dirty = true;
    }
};

pub const Cursor = struct {
    style: vaxis.Style = .{},
    uri: std.ArrayList(u8) = .empty,
    uri_id: std.ArrayList(u8) = .empty,
    col: u16 = 0,
    row: u16 = 0,
    pending_wrap: bool = false,
    shape: vaxis.Cell.CursorShape = .default,
    visible: bool = true,

    pub fn isOutsideScrollingRegion(self: Cursor, sr: ScrollingRegion) bool {
        return self.row < sr.top or
            self.row > sr.bottom or
            self.col < sr.left or
            self.col > sr.right;
    }

    pub fn isInsideScrollingRegion(self: Cursor, sr: ScrollingRegion) bool {
        return !self.isOutsideScrollingRegion(sr);
    }
};

pub const ScrollingRegion = struct {
    top: u16,
    bottom: u16,
    left: u16,
    right: u16,

    pub fn contains(self: ScrollingRegion, col: usize, row: usize) bool {
        return col >= self.left and
            col <= self.right and
            row >= self.top and
            row <= self.bottom;
    }
};

allocator: std.mem.Allocator,

width: u16 = 0,
height: u16 = 0,

scrolling_region: ScrollingRegion,

buf: []Cell = undefined,

cursor: Cursor = .{},

csi_u_flags: vaxis.Key.KittyFlags = @bitCast(@as(u5, 0)),

/// sets each cell to the default cell
pub fn init(alloc: std.mem.Allocator, w: u16, h: u16) !Screen {
    if (w == 0 or h == 0) return error.InvalidScreenSize;
    var screen = Screen{
        .allocator = alloc,
        .buf = try alloc.alloc(Cell, @as(usize, @intCast(w)) * h),
        .scrolling_region = .{
            .top = 0,
            .bottom = h - 1,
            .left = 0,
            .right = w - 1,
        },
        .width = w,
        .height = h,
    };
    var initialized: usize = 0;
    errdefer {
        for (screen.buf[0..initialized]) |*cell| {
            cell.char.deinit(alloc);
            cell.uri.deinit(alloc);
            cell.uri_id.deinit(alloc);
        }
        alloc.free(screen.buf);
    }
    for (screen.buf, 0..) |_, i| {
        screen.buf[i] = .{
            .char = try .initCapacity(alloc, 1),
        };
        initialized += 1;
        try screen.buf[i].char.append(alloc, ' ');
    }
    return screen;
}

pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    for (self.buf, 0..) |_, i| {
        self.buf[i].char.deinit(alloc);
        self.buf[i].uri.deinit(alloc);
        self.buf[i].uri_id.deinit(alloc);
    }

    alloc.free(self.buf);
}

/// Copy one visible viewport into the destination screen. `source_row` is the
/// first source row displayed at destination row zero.
pub fn copyTo(self: *Screen, allocator: std.mem.Allocator, dst: *Screen, source_row: usize) !void {
    if (self.width == 0 or self.height == 0 or dst.width == 0 or dst.height == 0 or
        self.width != dst.width or dst.height > self.height)
        return error.InvalidViewport;
    if (source_row > @as(usize, self.height - dst.height)) return error.InvalidViewport;
    const source_start = source_row * @as(usize, self.width);

    dst.cursor = self.cursor;
    dst.cursor.col = @min(self.cursor.col, dst.width - 1);
    const cursor_row = @as(usize, self.cursor.row);
    const source_row_end = source_row + @as(usize, dst.height);
    if (cursor_row >= source_row and cursor_row < source_row_end) {
        dst.cursor.row = @intCast(cursor_row - source_row);
    } else {
        dst.cursor.row = 0;
        dst.cursor.visible = false;
    }

    for (dst.buf, 0..) |*destination, i| {
        const source = &self.buf[source_start + i];
        try destination.copyFrom(allocator, source.*);
        source.dirty = false;
    }
}

pub fn readCell(self: *Screen, col: usize, row: usize) ?vaxis.Cell {
    if (col >= @as(usize, self.width)) {
        // column out of bounds
        return null;
    }
    if (row >= @as(usize, self.height)) {
        // height out of bounds
        return null;
    }
    const i = (row * @as(usize, self.width)) + col;
    assert(i < self.buf.len);
    const cell = self.buf[i];
    return .{
        .char = .{ .grapheme = cell.char.items, .width = cell.width },
        .style = cell.style,
    };
}

/// returns true if the current cursor position is within the scrolling region
pub fn withinScrollingRegion(self: Screen) bool {
    return self.scrolling_region.contains(self.cursor.col, self.cursor.row);
}

fn hasValidScrollingRegion(self: *const Screen) bool {
    return self.width > 0 and
        self.height > 0 and
        self.scrolling_region.top <= self.scrolling_region.bottom and
        self.scrolling_region.left <= self.scrolling_region.right and
        self.scrolling_region.bottom < self.height and
        self.scrolling_region.right < self.width;
}

/// writes a cell to a location. 0 indexed
pub fn print(
    self: *Screen,
    grapheme: []const u8,
    width: u8,
    wrap: bool,
) !void {
    if (self.cursor.pending_wrap) {
        try self.index();
        self.cursor.col = self.scrolling_region.left;
    }
    if (self.cursor.col >= self.width) return;
    if (self.cursor.row >= self.height) return;
    const col = self.cursor.col;
    const row = self.cursor.row;

    const i = @as(usize, row) * @as(usize, self.width) + @as(usize, col);
    assert(i < self.buf.len);
    self.buf[i].char.clearRetainingCapacity();
    self.buf[i].char.appendSlice(self.allocator, grapheme) catch {
        log.warn("couldn't write grapheme", .{});
    };
    self.buf[i].uri.clearRetainingCapacity();
    self.buf[i].uri.appendSlice(self.allocator, self.cursor.uri.items) catch {
        log.warn("couldn't write uri", .{});
    };
    self.buf[i].uri_id.clearRetainingCapacity();
    self.buf[i].uri_id.appendSlice(self.allocator, self.cursor.uri_id.items) catch {
        log.warn("couldn't write uri_id", .{});
    };
    self.buf[i].style = self.cursor.style;
    self.buf[i].width = width;
    self.buf[i].dirty = true;

    const next_col = @as(usize, self.cursor.col) + @as(usize, width);
    if (next_col >= @as(usize, self.width)) {
        self.cursor.pending_wrap = wrap;
        self.cursor.col = if (wrap) self.width else self.width - 1;
    } else {
        self.cursor.col = @intCast(next_col);
    }
}

/// IND
pub fn index(self: *Screen) !void {
    self.cursor.pending_wrap = false;

    if (self.cursor.row < self.scrolling_region.top or
        self.cursor.row > self.scrolling_region.bottom)
    {
        // Outside, we just move cursor down one
        self.cursor.row = @min(self.height - 1, self.cursor.row +| 1);
        return;
    }
    // We are inside the scrolling region
    if (self.cursor.row == self.scrolling_region.bottom) {
        // Inside scrolling region *and* at bottom of screen, we scroll contents up and insert a
        // blank line
        // TODO: scrollback if scrolling region is entire visible screen
        const cursor_row = self.cursor.row;
        self.cursor.row = self.scrolling_region.top;
        defer self.cursor.row = cursor_row;
        try self.deleteLine(1);
        return;
    }
    self.cursor.row += 1;
}

pub fn sgr(self: *Screen, seq: ansi.CSI) void {
    // Validate the complete sequence before mutating style. Otherwise a later
    // overflowing parameter would partially apply the preceding attributes.
    if (!seq.parametersValid(u8)) return;
    if (seq.params.len == 0) {
        self.cursor.style = .{};
        return;
    }

    var iter = seq.iterator(u8);
    while (iter.next()) |ps| {
        switch (ps) {
            0 => self.cursor.style = .{},
            1 => self.cursor.style.bold = true,
            2 => self.cursor.style.dim = true,
            3 => self.cursor.style.italic = true,
            4 => {
                const kind: vaxis.Style.Underline = if (iter.next_is_sub)
                    @fromBackingInt(@intCast(iter.next() orelse 1))
                else
                    .single;
                self.cursor.style.ul_style = kind;
            },
            5 => self.cursor.style.blink = true,
            7 => self.cursor.style.reverse = true,
            8 => self.cursor.style.invisible = true,
            9 => self.cursor.style.strikethrough = true,
            21 => self.cursor.style.ul_style = .double,
            22 => {
                self.cursor.style.bold = false;
                self.cursor.style.dim = false;
            },
            23 => self.cursor.style.italic = false,
            24 => self.cursor.style.ul_style = .off,
            25 => self.cursor.style.blink = false,
            27 => self.cursor.style.reverse = false,
            28 => self.cursor.style.invisible = false,
            29 => self.cursor.style.strikethrough = false,
            30...37 => self.cursor.style.fg = .{ .index = ps - 30 },
            38 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            if (iter.is_empty)
                                ps_r = iter.next() orelse return;
                            break :r ps_r;
                        };
                        const g = iter.next() orelse return;
                        const b = iter.next() orelse return;
                        self.cursor.style.fg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => {
                        const idx = iter.next() orelse return;
                        self.cursor.style.fg = .{ .index = idx };
                    }, // index
                    else => return,
                }
            },
            39 => self.cursor.style.fg = .default,
            40...47 => self.cursor.style.bg = .{ .index = ps - 40 },
            48 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            if (iter.is_empty)
                                ps_r = iter.next() orelse return;
                            break :r ps_r;
                        };
                        const g = iter.next() orelse return;
                        const b = iter.next() orelse return;
                        self.cursor.style.bg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => {
                        const idx = iter.next() orelse return;
                        self.cursor.style.bg = .{ .index = idx };
                    }, // index
                    else => return,
                }
            },
            49 => self.cursor.style.bg = .default,
            90...97 => self.cursor.style.fg = .{ .index = ps - 90 + 8 },
            100...107 => self.cursor.style.bg = .{ .index = ps - 100 + 8 },
            else => continue,
        }
    }
}

pub fn cursorUp(self: *Screen, n: u16) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.row = @max(
            self.cursor.row -| n,
            self.scrolling_region.top,
        )
    else
        self.cursor.row -|= n;
}

pub fn cursorLeft(self: *Screen, n: u16) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.col = @max(
            self.cursor.col -| n,
            self.scrolling_region.left,
        )
    else
        self.cursor.col = self.cursor.col -| n;
}

pub fn cursorRight(self: *Screen, n: u16) void {
    self.cursor.pending_wrap = false;
    if (self.withinScrollingRegion())
        self.cursor.col = @min(
            self.cursor.col +| n,
            self.scrolling_region.right,
        )
    else
        self.cursor.col = @min(
            self.cursor.col +| n,
            self.width - 1,
        );
}

pub fn cursorDown(self: *Screen, n: usize) void {
    self.cursor.pending_wrap = false;
    const maximum = if (self.withinScrollingRegion())
        self.scrolling_region.bottom
    else
        self.height -| 1;
    const next = @as(usize, self.cursor.row) +| n;
    self.cursor.row = @intCast(@min(@as(usize, maximum), next));
}

pub fn eraseRight(self: *Screen) void {
    self.cursor.pending_wrap = false;
    if (self.width == 0 or self.height == 0) return;
    const width = @as(usize, self.width);
    const row = @as(usize, @min(self.cursor.row, self.height - 1));
    const col = @as(usize, @min(self.cursor.col, self.width - 1));
    const end = (row + 1) * width;
    var i = row * width + col;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseLeft(self: *Screen) void {
    self.cursor.pending_wrap = false;
    if (self.width == 0 or self.height == 0) return;
    const width = @as(usize, self.width);
    const row = @as(usize, @min(self.cursor.row, self.height - 1));
    const col = @as(usize, @min(self.cursor.col, self.width - 1));
    const start = row * width;
    const end = start + col + 1;
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseLine(self: *Screen) void {
    self.cursor.pending_wrap = false;
    if (self.width == 0 or self.height == 0) return;
    const width = @as(usize, self.width);
    const row = @as(usize, @min(self.cursor.row, self.height - 1));
    const start = row * width;
    const end = start + width;
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

/// Delete lines at the cursor, shifting later rows in the scrolling region up.
pub fn deleteLine(self: *Screen, n: usize) !void {
    self.cursor.pending_wrap = false;
    if (!self.hasValidScrollingRegion()) return;
    if (self.cursor.row < self.scrolling_region.top or
        self.cursor.row > self.scrolling_region.bottom)
        return;

    const width = @as(usize, self.width);
    const cursor_row = @as(usize, self.cursor.row);
    const bottom = @as(usize, self.scrolling_region.bottom);
    const right = @as(usize, self.scrolling_region.right);
    const count = @min(@max(n, 1), bottom - cursor_row + 1);
    const blank_start = bottom + 1 - count;

    var row = cursor_row;
    while (row < blank_start) : (row += 1) {
        var col = @as(usize, self.scrolling_region.left);
        while (col <= right) : (col += 1) {
            const destination = row * width + col;
            const source = (row + count) * width + col;
            try self.buf[destination].copyFrom(self.allocator, self.buf[source]);
        }
    }
    row = blank_start;
    while (row <= bottom) : (row += 1) {
        var col = @as(usize, self.scrolling_region.left);
        while (col <= right) : (col += 1) {
            self.buf[row * width + col].erase(self.allocator, self.cursor.style.bg);
        }
    }
}

/// Insert blank lines at the cursor, shifting later rows in the scrolling region down.
pub fn insertLine(self: *Screen, n: usize) !void {
    self.cursor.pending_wrap = false;
    if (!self.hasValidScrollingRegion()) return;
    if (self.cursor.row < self.scrolling_region.top or
        self.cursor.row > self.scrolling_region.bottom)
        return;

    const width = @as(usize, self.width);
    const cursor_row = @as(usize, self.cursor.row);
    const bottom = @as(usize, self.scrolling_region.bottom);
    const right = @as(usize, self.scrolling_region.right);
    const count = @min(@max(n, 1), bottom - cursor_row + 1);
    const shifted_start = cursor_row + count;

    var row = bottom + 1;
    while (row > shifted_start) {
        row -= 1;
        var col = @as(usize, self.scrolling_region.left);
        while (col <= right) : (col += 1) {
            const destination = row * width + col;
            const source = (row - count) * width + col;
            try self.buf[destination].copyFrom(self.allocator, self.buf[source]);
        }
    }
    row = cursor_row;
    while (row < shifted_start) : (row += 1) {
        var col = @as(usize, self.scrolling_region.left);
        while (col <= right) : (col += 1) {
            self.buf[row * width + col].erase(self.allocator, self.cursor.style.bg);
        }
    }
}

pub fn eraseBelow(self: *Screen) void {
    self.eraseRight();
    if (self.width == 0 or self.height == 0) return;
    // start is the first column of the row below us
    const width = @as(usize, self.width);
    const row = @as(usize, @min(self.cursor.row, self.height - 1));
    const start = (row + 1) * width;
    var i = start;
    while (i < self.buf.len) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseAbove(self: *Screen) void {
    self.eraseLeft();
    if (self.width == 0 or self.height == 0) return;
    // start is the first column of the row below us
    const start: usize = 0;
    const row = @as(usize, @min(self.cursor.row, self.height - 1));
    const end = row * @as(usize, self.width);
    var i = start;
    while (i < end) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn eraseAll(self: *Screen) void {
    var i: usize = 0;
    while (i < self.buf.len) : (i += 1) {
        self.buf[i].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn deleteCharacters(self: *Screen, n: usize) !void {
    self.cursor.pending_wrap = false;
    if (!self.hasValidScrollingRegion()) return;
    if (self.cursor.row < self.scrolling_region.top or
        self.cursor.row > self.scrolling_region.bottom or
        self.cursor.col < self.scrolling_region.left or
        self.cursor.col > self.scrolling_region.right)
        return;

    const width = @as(usize, self.width);
    const row_start = @as(usize, self.cursor.row) * width;
    const cursor_col = @as(usize, self.cursor.col);
    const right = @as(usize, self.scrolling_region.right);
    const count = @min(@max(n, 1), right - cursor_col + 1);
    var col = cursor_col;
    while (col <= right) : (col += 1) {
        const destination = row_start + col;
        if (count <= right - col)
            try self.buf[destination].copyFrom(self.allocator, self.buf[destination + count])
        else
            self.buf[destination].erase(self.allocator, self.cursor.style.bg);
    }
}

pub fn reverseIndex(self: *Screen) !void {
    if (self.cursor.row != self.scrolling_region.top or
        self.cursor.col < self.scrolling_region.left or
        self.cursor.col > self.scrolling_region.right)
        self.cursorUp(1)
    else
        try self.scrollDown(1);
}

pub fn scrollDown(self: *Screen, n: usize) !void {
    const cur_row = self.cursor.row;
    const cur_col = self.cursor.col;
    const wrap = self.cursor.pending_wrap;
    defer {
        self.cursor.row = cur_row;
        self.cursor.col = cur_col;
        self.cursor.pending_wrap = wrap;
    }
    self.cursor.col = self.scrolling_region.left;
    self.cursor.row = self.scrolling_region.top;
    try self.insertLine(n);
}

fn testInitAllocationFailures(allocator: std.mem.Allocator) !void {
    var screen = try Screen.init(allocator, 3, 2);
    defer screen.deinit(allocator);
}

test "init cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testInitAllocationFailures,
        .{},
    );
    try std.testing.expectError(error.InvalidScreenSize, Screen.init(std.testing.allocator, 0, 1));
    try std.testing.expectError(error.InvalidScreenSize, Screen.init(std.testing.allocator, 1, 0));
}

test "sgr ignores an overflowing sequence without partial style changes" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 1, 1);
    defer screen.deinit(allocator);
    screen.cursor.style.bold = true;
    const before = screen.cursor.style;

    screen.sgr(.{ .params = "31;999", .final = 'm' });

    try std.testing.expectEqualDeep(before, screen.cursor.style);
}

test "copyTo selects a bounded viewport and translates the cursor" {
    const allocator = std.testing.allocator;
    var source = try Screen.init(allocator, 2, 5);
    defer source.deinit(allocator);
    var destination = try Screen.init(allocator, 2, 2);
    defer destination.deinit(allocator);

    const labels = [_]u8{ '0', '1', '2', '3', '4' };
    const width = @as(usize, source.width);
    for (0..@as(usize, source.height)) |row| {
        for (0..@as(usize, source.width)) |col| {
            const cell = &source.buf[row * width + col];
            cell.char.clearRetainingCapacity();
            try cell.char.append(allocator, labels[row]);
        }
    }
    source.cursor.row = 3;
    source.cursor.col = source.width;

    try source.copyTo(allocator, &destination, 2);

    try std.testing.expectEqualStrings("2", destination.buf[0].char.items);
    try std.testing.expectEqualStrings("2", destination.buf[1].char.items);
    try std.testing.expectEqualStrings("3", destination.buf[2].char.items);
    try std.testing.expectEqualStrings("3", destination.buf[3].char.items);
    try std.testing.expectEqual(@as(u16, 1), destination.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), destination.cursor.col);
    try std.testing.expect(destination.cursor.visible);
    for (source.buf[0..4]) |cell| try std.testing.expect(cell.dirty);
    for (source.buf[4..8]) |cell| try std.testing.expect(!cell.dirty);
    for (source.buf[8..10]) |cell| try std.testing.expect(cell.dirty);

    source.cursor.row = 4;
    try source.copyTo(allocator, &destination, 1);
    try std.testing.expect(!destination.cursor.visible);
    try std.testing.expectEqual(@as(u16, 0), destination.cursor.row);

    try std.testing.expectError(
        error.InvalidViewport,
        source.copyTo(allocator, &destination, 4),
    );
}

test "cursor text state is initialized and readCell rejects boundary indexes" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 2, 2);
    defer screen.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), screen.cursor.uri.items.len);
    try std.testing.expectEqual(@as(usize, 0), screen.cursor.uri_id.items.len);
    try screen.print("x", 1, false);
    try std.testing.expectEqualStrings("x", screen.buf[0].char.items);
    try std.testing.expect(screen.readCell(2, 0) == null);
    try std.testing.expect(screen.readCell(0, 2) == null);

    screen.buf[3].char.clearRetainingCapacity();
    try screen.buf[3].char.append(allocator, 'y');
    screen.cursor.row = screen.height;
    screen.cursor.col = screen.width;
    screen.eraseBelow();
    try std.testing.expectEqualStrings(" ", screen.buf[3].char.items);

    screen.cursor = .{ .col = 0, .row = 0 };
    try screen.print("w", 2, true);
    try std.testing.expect(screen.cursor.pending_wrap);
    try std.testing.expectEqual(screen.width, screen.cursor.col);

    screen.cursor = .{ .col = 0, .row = 1 };
    try screen.print("w", 2, false);
    try std.testing.expect(!screen.cursor.pending_wrap);
    try std.testing.expectEqual(screen.width - 1, screen.cursor.col);
}

test "deleteCharacters shifts only the cursor row and treats zero as one" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit(allocator);

    screen.buf[0].char.clearRetainingCapacity();
    try screen.buf[0].char.append(allocator, 'z');
    for ("ABCDE", 0..) |value, col| {
        const cell = &screen.buf[5 + col];
        cell.char.clearRetainingCapacity();
        try cell.char.append(allocator, value);
    }
    screen.cursor.row = 1;
    screen.cursor.col = 1;

    try screen.deleteCharacters(0);

    try std.testing.expectEqualStrings("z", screen.buf[0].char.items);
    const expected = [_]u8{ 'A', 'C', 'D', 'E', ' ' };
    for (expected, 0..) |value, col| {
        try std.testing.expectEqual(@as(usize, 1), screen.buf[5 + col].char.items.len);
        try std.testing.expectEqual(value, screen.buf[5 + col].char.items[0]);
    }
}

fn setSingleColumnRows(screen: *Screen, values: []const u8) !void {
    std.debug.assert(screen.width == 1 and values.len == @as(usize, screen.height));
    for (values, 0..) |value, row| {
        screen.buf[row].char.clearRetainingCapacity();
        try screen.buf[row].char.append(screen.allocator, value);
    }
}

fn expectSingleColumnRows(screen: *const Screen, expected: []const u8) !void {
    std.debug.assert(screen.width == 1 and expected.len == @as(usize, screen.height));
    for (expected, 0..) |value, row| {
        try std.testing.expectEqual(@as(usize, 1), screen.buf[row].char.items.len);
        try std.testing.expectEqual(value, screen.buf[row].char.items[0]);
    }
}

test "line insertion and deletion honor cursor and scrolling region" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 1, 5);
    defer screen.deinit(allocator);
    screen.scrolling_region = .{ .top = 1, .bottom = 3, .left = 0, .right = 0 };

    try setSingleColumnRows(&screen, "01234");
    screen.cursor.row = 2;
    try screen.deleteLine(1);
    try expectSingleColumnRows(&screen, "013 4");

    try setSingleColumnRows(&screen, "01234");
    screen.cursor.row = 2;
    try screen.insertLine(1);
    try expectSingleColumnRows(&screen, "01 24");

    try setSingleColumnRows(&screen, "01234");
    screen.cursor.row = 3;
    try screen.insertLine(0);
    try expectSingleColumnRows(&screen, "012 4");

    try setSingleColumnRows(&screen, "01234");
    screen.cursor.row = 3;
    try screen.index();
    try expectSingleColumnRows(&screen, "023 4");
    try std.testing.expectEqual(@as(u16, 3), screen.cursor.row);
}
