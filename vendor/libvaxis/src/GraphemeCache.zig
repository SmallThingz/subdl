const std = @import("std");
const Parser = @import("Parser.zig");

const GraphemeCache = @This();

/// The event queue and this cache share this capacity so their lifetime bounds
/// cannot drift independently.
pub const event_queue_capacity: usize = 512;

/// One slot is retained for the event most recently returned to the consumer,
/// and one for the producer's event cached before a blocking queue push.
pub const retained_entry_count: usize = event_queue_capacity + 2;

/// Key text produced by Parser is never larger than its scratch buffer. Public
/// callers are rejected explicitly if they exceed the same bound.
pub const max_entry_bytes: usize = Parser.max_key_text_bytes;

comptime {
    if (retained_entry_count < event_queue_capacity + 2)
        @compileError("key text cache must retain the queue, delivered event, and pending producer event");
    if (max_entry_bytes < Parser.max_key_text_bytes)
        @compileError("key text cache entries must fit Parser key text");
}

/// Fixed-size slots prevent a short entry from wrapping into storage still
/// referenced by an older queued event.
entries: [retained_entry_count][max_entry_bytes]u8 = undefined,

// The slot used by the next entry.
next_slot: usize = 0,

pub const PutError = error{EntryTooLarge};

/// Copy key text into bounded storage. The returned slice remains valid while
/// it is queued and, once delivered, until the next successful event dequeue.
pub fn put(self: *GraphemeCache, bytes: []const u8) PutError![]u8 {
    if (bytes.len > max_entry_bytes) return error.EntryTooLarge;

    const slot = self.next_slot;
    self.next_slot = if (slot + 1 == retained_entry_count) 0 else slot + 1;
    @memcpy(self.entries[slot][0..bytes.len], bytes);
    return self.entries[slot][0..bytes.len];
}

/// Release the most recent entry when its queue push fails. The input loop has
/// a single cache producer, so no later reservation can interleave here.
pub fn discardLast(self: *GraphemeCache, bytes: []const u8) void {
    const slot = if (self.next_slot == 0) retained_entry_count - 1 else self.next_slot - 1;
    std.debug.assert(bytes.ptr == self.entries[slot][0..].ptr);
    std.debug.assert(bytes.len <= max_entry_bytes);
    self.next_slot = slot;
}

test {
    std.testing.refAllDecls(@This());
}

test "cache retains a full event queue through deterministic wrap" {
    var cache: GraphemeCache = .{};
    const first = try cache.put("aa");

    var value: [2]u8 = undefined;
    for (1..retained_entry_count) |i| {
        value[0] = @truncate(i);
        value[1] = @truncate(i >> 8);
        _ = try cache.put(&value);
    }

    try std.testing.expectEqualStrings("aa", first);
    const wrapped = try cache.put("zz");
    try std.testing.expectEqualStrings("zz", wrapped);
    try std.testing.expectEqualStrings("zz", first);
}

test "cache rejects oversized entries without consuming a slot" {
    var cache: GraphemeCache = .{};
    const live = try cache.put("ok");
    var oversized: [max_entry_bytes + 1]u8 = undefined;

    try std.testing.expectError(error.EntryTooLarge, cache.put(&oversized));
    try std.testing.expectEqual(@as(usize, 1), cache.next_slot);
    try std.testing.expectEqualStrings("ok", live);
}

test "discarded producer entry is reused without advancing the wrap" {
    var cache: GraphemeCache = .{};
    const first = try cache.put("aa");

    var value: [2]u8 = .{ 0, 0 };
    for (1..retained_entry_count - 1) |i| {
        value[0] = @truncate(i);
        value[1] = @truncate(i >> 8);
        _ = try cache.put(&value);
    }

    const discarded = try cache.put("xx");
    cache.discardLast(discarded);
    _ = try cache.put("yy");
    try std.testing.expectEqualStrings("aa", first);
}
