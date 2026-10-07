const std = @import("std");
const uucode = @import("uucode");

// Old API-compatible Grapheme value
pub const Grapheme = struct {
    start: usize,
    len: usize,

    pub fn bytes(self: Grapheme, str: []const u8) []const u8 {
        return str[self.start .. self.start + self.len];
    }
};

// Old API-compatible iterator that yields Grapheme with .len and .bytes()
pub const GraphemeIterator = struct {
    str: []const u8,
    inner: uucode.grapheme.Iterator(uucode.utf8.Iterator),
    // Retained for source compatibility with the previous wrapper. After a
    // successful `next`, `start` points at the next grapheme and
    // `prev_break` remains true, matching the old observable state.
    start: usize = 0,
    prev_break: bool = true,

    pub fn init(str: []const u8) GraphemeIterator {
        return .{
            .str = str,
            .inner = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str)),
        };
    }

    pub fn next(self: *GraphemeIterator) ?Grapheme {
        const grapheme = self.inner.nextGrapheme() orelse return null;
        self.start = grapheme.end;
        self.prev_break = true;
        return .{
            .start = grapheme.start,
            .len = grapheme.end - grapheme.start,
        };
    }
};

/// creates a grapheme iterator based on str
pub fn graphemeIterator(str: []const u8) GraphemeIterator {
    return GraphemeIterator.init(str);
}

test "grapheme iterator preserves malformed utf8 byte spans" {
    const malformed = "\xff\xcc\x81";
    var iter = graphemeIterator(malformed);

    const grapheme = iter.next().?;
    try std.testing.expectEqual(@as(usize, 0), grapheme.start);
    try std.testing.expectEqual(@as(usize, malformed.len), grapheme.len);
    try std.testing.expectEqualStrings(malformed, grapheme.bytes(malformed));
    try std.testing.expectEqual(null, iter.next());
}

test "grapheme iterator preserves public compatibility state" {
    const text = "a\xcc\x81b";
    var iter = graphemeIterator(text);
    try std.testing.expectEqual(@as(usize, 0), iter.start);
    try std.testing.expect(iter.prev_break);
    try std.testing.expectEqual(@as(usize, 0), iter.inner.i);

    const first = iter.next().?;
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqual(@as(usize, 3), iter.start);
    try std.testing.expect(iter.prev_break);
    try std.testing.expectEqual(iter.start, iter.inner.i);

    const second = iter.next().?;
    try std.testing.expectEqual(@as(usize, 3), second.start);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(text.len, iter.start);
    try std.testing.expect(iter.prev_break);
    try std.testing.expectEqual(iter.start, iter.inner.i);

    try std.testing.expectEqual(null, iter.next());
    try std.testing.expectEqual(text.len, iter.start);
    try std.testing.expect(iter.prev_break);
}

test {
    std.testing.refAllDecls(@This());
}
