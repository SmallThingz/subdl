const std = @import("std");
const vaxis = @import("../main.zig");

const digits = "0123456789";

num_lines: usize = std.math.maxInt(usize),
highlighted_line: usize = 0,
style: vaxis.Style = .{ .dim = true },
highlighted_style: vaxis.Style = .{ .dim = true, .bg = .{ .index = 0 } },

pub fn extractDigit(v: usize, n: usize) usize {
    var remaining = v;
    var i: usize = 0;
    while (i < n and remaining != 0) : (i += 1) {
        remaining /= 10;
    }
    return remaining % 10;
}

pub fn numDigits(v: usize) u8 {
    var remaining = v;
    var count: u8 = 1;
    while (remaining >= 10) {
        remaining /= 10;
        count += 1;
    }
    return count;
}

const VisibleLineRange = struct {
    start: usize,
    count: usize,
};

fn visibleLineRange(num_lines: usize, y_scroll: usize, height: usize) VisibleLineRange {
    const start = std.math.add(usize, y_scroll, 1) catch return .{
        .start = std.math.maxInt(usize),
        .count = 0,
    };
    if (height == 0 or start > num_lines) return .{ .start = start, .count = 0 };

    // `start` is at least one, so this inclusive count cannot overflow even
    // when `num_lines` is maxInt(usize).
    const remaining = num_lines - start + 1;
    return .{ .start = start, .count = @min(remaining, height) };
}

pub fn draw(self: @This(), win: vaxis.Window, y_scroll: usize) void {
    const range = visibleLineRange(self.num_lines, y_scroll, win.height);
    const width: usize = win.width;
    for (0..range.count) |row| {
        const line = range.start + row;
        const highlighted = line == self.highlighted_line;
        if (highlighted) {
            // Paint the gutter first so its padding receives the highlight
            // without blank cells overwriting the right-aligned digits.
            for (0..width) |col| {
                win.writeCell(@intCast(col), @intCast(row), .{
                    .style = self.highlighted_style,
                });
            }
        }
        const num_digits = numDigits(line);
        const drawn_digits = @min(@as(usize, num_digits), width -| 1);
        for (0..drawn_digits) |i| {
            const digit = extractDigit(line, i);
            win.writeCell(@intCast(width -| (i + 2)), @intCast(row), .{
                .char = .{
                    .width = 1,
                    .grapheme = digits[digit .. digit + 1],
                },
                .style = if (highlighted) self.highlighted_style else self.style,
            });
        }
    }
}

test "numDigits handles the full usize range" {
    try std.testing.expectEqual(@as(u8, 1), numDigits(0));
    try std.testing.expectEqual(@as(u8, 1), numDigits(9));
    try std.testing.expectEqual(@as(u8, 2), numDigits(10));
    try std.testing.expectEqual(@as(u8, 9), numDigits(100_000_000));

    const max_digits = numDigits(std.math.maxInt(usize));
    try std.testing.expect(max_digits > 8);
    try std.testing.expect(extractDigit(std.math.maxInt(usize), max_digits - 1) != 0);
    try std.testing.expectEqual(@as(usize, 0), extractDigit(1, std.math.maxInt(usize)));
}

test "visibleLineRange includes one line and respects scrolling" {
    try std.testing.expectEqualDeep(
        VisibleLineRange{ .start = 1, .count = 1 },
        visibleLineRange(1, 0, 24),
    );
    try std.testing.expectEqualDeep(
        VisibleLineRange{ .start = 1, .count = 3 },
        visibleLineRange(5, 0, 3),
    );
    try std.testing.expectEqualDeep(
        VisibleLineRange{ .start = 3, .count = 2 },
        visibleLineRange(5, 2, 2),
    );
    try std.testing.expectEqualDeep(
        VisibleLineRange{ .start = 6, .count = 0 },
        visibleLineRange(5, 5, 2),
    );
}

test "visibleLineRange is overflow safe" {
    const max = std.math.maxInt(usize);
    try std.testing.expectEqualDeep(
        VisibleLineRange{ .start = max, .count = 1 },
        visibleLineRange(max, max - 1, 2),
    );
    try std.testing.expectEqualDeep(
        VisibleLineRange{ .start = max, .count = 0 },
        visibleLineRange(max, max, 2),
    );
}

test "highlighting preserves shorter right-aligned numbers and styles padding" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1,
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
        .height = 1,
        .screen = &screen,
    };
    const line_numbers: @This() = .{
        .num_lines = 100,
        .highlighted_line = 1,
        .highlighted_style = .{ .bg = .{ .index = 3 } },
    };

    line_numbers.draw(win, 0);

    for (0..win.width) |col| {
        const cell = win.readCell(@intCast(col), 0).?;
        try std.testing.expect(vaxis.Style.eql(cell.style, line_numbers.highlighted_style));
    }
    try std.testing.expectEqualStrings("1", win.readCell(2, 0).?.char.grapheme);
}

test "widget qualification line numbers tolerate zero and one column" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .rows = 2, .cols = 1, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 1, .height = 2, .screen = &screen };
    const numbers: @This() = .{ .num_lines = 2, .highlighted_line = 1, .highlighted_style = .{ .bg = .{ .index = 3 } } };
    win.width = 0;
    numbers.draw(win, 0);
    win.width = 1;
    numbers.draw(win, 0);
    try std.testing.expect(vaxis.Style.eql(win.readCell(0, 0).?.style, numbers.highlighted_style));
    try std.testing.expectEqualStrings(" ", win.readCell(0, 0).?.char.grapheme);
    numbers.draw(win, std.math.maxInt(usize));
}
