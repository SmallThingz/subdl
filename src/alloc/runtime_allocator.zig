const std = @import("std");
const builtin = @import("builtin");

pub const RuntimeAllocator = if (builtin.mode == .Debug)
    struct {
        gpa: std.heap.GeneralPurposeAllocator(.{}) = .{},

        pub fn init() @This() {
            return .{};
        }

        pub fn allocator(self: *@This()) std.mem.Allocator {
            return self.gpa.allocator();
        }

        pub fn deinit(self: *@This()) void {
            _ = self.gpa.deinit();
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
