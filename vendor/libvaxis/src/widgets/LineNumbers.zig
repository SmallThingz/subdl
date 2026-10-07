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
        if (highlighted) {
            const fill_start = @min(drawn_digits + 1, width);
            for (fill_start..width) |i| {
                win.writeCell(@intCast(i), @intCast(row), .{
                    .style = if (highlighted) self.highlighted_style else self.style,
                });
            }
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
