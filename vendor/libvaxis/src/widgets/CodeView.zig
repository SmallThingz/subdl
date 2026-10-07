const std = @import("std");
const vaxis = @import("../main.zig");
const ScrollView = vaxis.widgets.ScrollView;
const LineNumbers = vaxis.widgets.LineNumbers;
const TextView = vaxis.widgets.TextView;

pub const DrawOptions = struct {
    highlighted_line: u16 = 0,
    draw_line_numbers: bool = true,
    indentation: u16 = 0,
};

pub const Buffer = TextView.Buffer;

scroll_view: ScrollView = .{ .vertical_scrollbar = null },
highlighted_style: vaxis.Style = .{ .bg = .{ .index = 0 } },
indentation_cell: vaxis.Cell = .{
    .char = .{
        .grapheme = "┆",
        .width = 1,
    },
    .style = .{ .dim = true },
},

pub fn input(self: *@This(), key: vaxis.Key) void {
    self.scroll_view.input(key);
}

pub fn draw(self: *@This(), win: vaxis.Window, buffer: Buffer, opts: DrawOptions) void {
    const visible_rows = buffer.lineCount();
    const pad_left: u16 = if (opts.draw_line_numbers) LineNumbers.numDigits(visible_rows) +| 1 else 0;
    self.scroll_view.draw(win, .{
        .cols = buffer.cols + pad_left,
        .rows = visible_rows,
    });
    if (opts.draw_line_numbers) {
        var nl: LineNumbers = .{
            .highlighted_line = opts.highlighted_line,
            .num_lines = visible_rows,
        };
        nl.draw(win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = pad_left,
            .height = win.height,
        }), self.scroll_view.scroll.y);
    }
    self.drawCode(win.child(.{ .x_off = pad_left }), buffer, opts);
}

fn drawCode(self: *@This(), win: vaxis.Window, buffer: Buffer, opts: DrawOptions) void {
    const Pos = struct { x: usize = 0, y: usize = 0 };
    var pos: Pos = .{};
    var byte_index: usize = 0;
    var is_indentation = true;
    const bounds = self.scroll_view.bounds(win);
    if (opts.highlighted_line != 0) {
        const highlighted_row = @as(usize, opts.highlighted_line) - 1;
        if (highlighted_row < buffer.lineCount() and bounds.rowInside(highlighted_row)) {
            // Paint the clipped row independently of its graphemes. Empty
            // lines and lines wholly left of the horizontal viewport still
            // need the same highlight as visible text.
            for (bounds.x1..bounds.x2) |x| {
                self.scroll_view.writeCell(win, x, highlighted_row, .{
                    .style = self.highlighted_style,
                });
            }
        }
    }
    for (buffer.grapheme.items(.len), buffer.grapheme.items(.offset), 0..) |g_len, g_offset, index| {
        if (bounds.above(pos.y)) {
            break;
        }

        const cluster = buffer.content.items[g_offset..][0..g_len];
        defer byte_index += cluster.len;

        if (TextView.isNewlineCluster(cluster)) {
            if (index == buffer.grapheme.len - 1) {
                break;
            }
            pos.y += 1;
            pos.x = 0;
            is_indentation = true;
            continue;
        } else if (bounds.below(pos.y)) {
            continue;
        }

        const highlighted_line = pos.y +| 1 == opts.highlighted_line;
        var style: vaxis.Style = if (highlighted_line) self.highlighted_style else .{};

        if (buffer.style_map.get(byte_index)) |meta| {
            const tmp = style.bg;
            style = buffer.style_list.items[meta];
            style.bg = tmp;
        }

        const width = win.gwidth(cluster);
        const cell_width = vaxis.gwidth.cellWidth(width);
        defer pos.x +|= width;

        if (opts.indentation > 0 and !std.mem.eql(u8, cluster, " ")) {
            is_indentation = false;
        }

        if (!bounds.colInside(pos.x)) {
            continue;
        }
        const remaining_cols = bounds.x2 - pos.x;
        if (@as(usize, cell_width) > remaining_cols) {
            continue;
        }

        if (is_indentation and opts.indentation > 0 and pos.x % opts.indentation == 0) {
            var cell = self.indentation_cell;
            cell.style.bg = style.bg;
            self.scroll_view.writeCell(win, pos.x, pos.y, cell);
        } else {
            self.scroll_view.writeCell(win, pos.x, pos.y, .{
                .char = .{ .grapheme = cluster, .width = cell_width },
                .style = style,
            });
        }
    }
}

test "highlight fills empty and horizontally clipped code rows" {
    const highlighted_style: vaxis.Style = .{ .bg = .{ .index = 3 } };

    {
        var buffer: Buffer = .{};
        defer buffer.deinit(std.testing.allocator);
        try buffer.append(std.testing.allocator, .{ .bytes = "x\n" });

        var screen = try vaxis.Screen.init(std.testing.allocator, .{
            .rows = 2,
            .cols = 4,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        defer screen.deinit(std.testing.allocator);
        const win: vaxis.Window = .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = 4,
            .height = 2,
            .screen = &screen,
        };
        var code_view: @This() = .{ .highlighted_style = highlighted_style };

        code_view.draw(win, buffer, .{
            .highlighted_line = 2,
            .draw_line_numbers = false,
        });

        for (0..win.width) |col| {
            const cell = win.readCell(@intCast(col), 1).?;
            try std.testing.expect(vaxis.Style.eql(cell.style, highlighted_style));
        }
    }

    {
        var buffer: Buffer = .{};
        defer buffer.deinit(std.testing.allocator);
        try buffer.append(std.testing.allocator, .{ .bytes = "x\nabcdef" });

        var screen = try vaxis.Screen.init(std.testing.allocator, .{
            .rows = 2,
            .cols = 3,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        defer screen.deinit(std.testing.allocator);
        const win: vaxis.Window = .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = 3,
            .height = 2,
            .screen = &screen,
        };
        var code_view: @This() = .{ .highlighted_style = highlighted_style };
        code_view.scroll_view.scroll.x = 3;

        code_view.draw(win, buffer, .{
            .highlighted_line = 1,
            .draw_line_numbers = false,
        });

        for (0..win.width) |col| {
            const cell = win.readCell(@intCast(col), 0).?;
            try std.testing.expect(vaxis.Style.eql(cell.style, highlighted_style));
        }
    }
}

test "draw requires the full code-cell span and retains zero-width graphemes" {
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
    var code_view: @This() = .{};

    code_view.draw(win, buffer, .{ .draw_line_numbers = false });
    try std.testing.expectEqualStrings(" ", win.readCell(0, 0).?.char.grapheme);

    screen.clear();
    try buffer.update(std.testing.allocator, .{ .bytes = "\u{200B}" });
    code_view.draw(win, buffer, .{ .draw_line_numbers = false });
    const zero_width_cell = win.readCell(0, 0).?;
    try std.testing.expectEqualStrings("\u{200B}", zero_width_cell.char.grapheme);
    try std.testing.expectEqual(@as(u8, 0), zero_width_cell.char.width);
}

test "widget qualification horizontal clipping preserves indentation state" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);
    try buffer.append(std.testing.allocator, .{ .bytes = "x    y" });
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .rows = 1, .cols = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 3, .height = 1, .screen = &screen };
    var code_view: @This() = .{};
    code_view.scroll_view.scroll.x = 2;
    code_view.draw(win, buffer, .{ .draw_line_numbers = false, .indentation = 2 });
    try std.testing.expectEqualStrings(" ", win.readCell(0, 0).?.char.grapheme);
}
