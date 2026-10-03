const std = @import("std");
const builtin = @import("builtin");

pub const RuntimeAllocator = if (builtin.mode == .debug)
    struct {
        gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{}),

        pub fn init() @This() {
            return .{};
        }

        pub fn allocator(self: *@This()) std.mem.Allocator {
            return self.gpa.allocator();
        }

        pub fn deinit(self: *@This()) void {
            std.debug.assert(self.gpa.deinit() == 0);
        }
    }
else
    struct {
        pub fn init() @This() {
            return .{};
        }

        pub fn allocator(self: *@This()) std.mem.Allocator {
            _ = self;
            return std.heap.smp_allocator;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
