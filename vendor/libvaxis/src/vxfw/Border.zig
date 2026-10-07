const std = @import("std");
const vaxis = @import("../main.zig");

const Allocator = std.mem.Allocator;

const vxfw = @import("vxfw.zig");

pub const BorderLabel = struct {
    text: []const u8,
    alignment: enum {
        top_left,
        top_center,
        top_right,
        bottom_left,
        bottom_center,
        bottom_right,
    },
};

const Border = @This();

child: vxfw.Widget,
style: vaxis.Style = .{},
labels: []const BorderLabel = &[_]BorderLabel{},

pub fn widget(self: *const Border) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const Border = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

/// If Border has a bounded maximum size, it will shrink the maximum size to account for the border
/// before drawing the child. If the size is unbounded, border will draw the child and then itself
/// around the child's size
pub fn draw(self: *const Border, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const min_width: u16 = ctx.min.width -| 2;
    const min_height: u16 = ctx.min.height -| 2;
    const max_width: ?u16 = if (ctx.max.width) |width| width -| 2 else null;
    const max_height: ?u16 = if (ctx.max.height) |height| height -| 2 else null;

    const child_ctx = ctx.withConstraints(
        .{ .width = min_width, .height = min_height },
        .{ .width = max_width, .height = max_height },
    );
    const child = try self.child.draw(child_ctx);

    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{
        .origin = .{ .col = 1, .row = 1 },
        .z_index = 0,
        .surface = child,
    };

    const size: vxfw.Size = .{
        .width = @min(child.size.width +| 2, ctx.max.width orelse std.math.maxInt(u16)),
        .height = @min(child.size.height +| 2, ctx.max.height orelse std.math.maxInt(u16)),
    };

    var surf = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), size, children);

    // Draw the border
    const right_edge = size.width -| 1;
    const bottom_edge = size.height -| 1;
    surf.writeCell(0, 0, .{ .char = .{ .grapheme = "╭", .width = 1 }, .style = self.style });
    surf.writeCell(right_edge, 0, .{ .char = .{ .grapheme = "╮", .width = 1 }, .style = self.style });
    surf.writeCell(right_edge, bottom_edge, .{ .char = .{ .grapheme = "╯", .width = 1 }, .style = self.style });
    surf.writeCell(0, bottom_edge, .{ .char = .{ .grapheme = "╰", .width = 1 }, .style = self.style });

    var col: u16 = 1;
    while (col < right_edge) : (col += 1) {
        surf.writeCell(col, 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.style });
        surf.writeCell(col, bottom_edge, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.style });
    }

    var row: u16 = 1;
    while (row < bottom_edge) : (row += 1) {
        surf.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = self.style });
        surf.writeCell(right_edge, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = self.style });
    }

    // Add border labels
    for (self.labels) |label| {
        const text_len: u16 = @intCast(ctx.stringWidth(label.text));
        if (text_len == 0) continue;

        const text_row: u16 = switch (label.alignment) {
            .top_left, .top_center, .top_right => 0,
            .bottom_left, .bottom_center, .bottom_right => bottom_edge,
        };

        var text_col: u16 = switch (label.alignment) {
            .top_left, .bottom_left => 1,
            .top_center, .bottom_center => @max((size.width -| text_len) / 2, 1),
            .top_right, .bottom_right => @max(size.width -| 1 -| text_len, 1),
        };

        var iter = ctx.graphemeIterator(label.text);
        while (iter.next()) |grapheme| {
            const text = grapheme.bytes(label.text);
            const width: u16 = @intCast(ctx.stringWidth(text));
            if (text_col >= right_edge or width > right_edge - text_col) break;
            surf.writeCell(text_col, text_row, .{
                .char = .{ .grapheme = text, .width = vaxis.gwidth.cellWidth(width) },
                .style = self.style,
            });
            text_col += width;
        }
    }

    return surf;
}

test Border {
    const Text = @import("Text.zig");
    // Will be height=1, width=3
    const text: Text = .{ .text = "abc" };

    const border: Border = .{ .child = text.widget() };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);

    // Border will draw itself tightly around the child
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 10, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try border.draw(ctx);
    // Border should be the size of Text + 2
    try std.testing.expectEqual(5, surface.size.width);
    try std.testing.expectEqual(3, surface.size.height);
    // Border has 1 child
    try std.testing.expectEqual(1, surface.children.len);
    const child = surface.children[0];
    // The child is 1x3
    try std.testing.expectEqual(3, child.surface.size.width);
    try std.testing.expectEqual(1, child.surface.size.height);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}

test "widget qualification border clips long Unicode labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 5, .height = 3 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const child: @import("Text.zig") = .{ .text = "abc" };
    for ([_]BorderLabel{ .{ .text = "界界界", .alignment = .top_center }, .{ .text = "界界界", .alignment = .top_right } }) |label| {
        const border: Border = .{ .child = child.widget(), .labels = &.{label} };
        const surface = try border.draw(ctx);
        try std.testing.expectEqualStrings("╭", surface.readCell(0, 0).char.grapheme);
        try std.testing.expectEqualStrings("界", surface.readCell(1, 0).char.grapheme);
        try std.testing.expectEqualStrings("╮", surface.readCell(4, 0).char.grapheme);
    }
}

test "widget qualification border respects zero and one column constraints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);
    const text: @import("Text.zig") = .{ .text = "界" };
    const border: Border = .{ .child = text.widget() };
    for ([_]u16{ 0, 1 }) |width| {
        const surface = try border.draw(.{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = width, .height = 1 },
            .cell_size = .{ .width = 10, .height = 20 },
        });
        try std.testing.expect(surface.size.width <= width);
        try std.testing.expect(surface.size.height <= 1);
    }
}
