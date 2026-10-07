const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const impl = if (build_options.enable_tui)
    @import("tui_impl")
else
    struct {
        pub const available = false;

        pub fn main(_: anytype) !void {
            return error.TuiUnavailable;
        }
    };

// Vaxis owns a dedicated terminal-input reader through `Io.concurrent`.
// Zig's single-threaded runtime deliberately rejects that operation, so do not
// advertise a mode which can only fail during startup in that configuration.
pub const available = build_options.enable_tui and !builtin.single_threaded;
pub const panic = if (build_options.enable_tui) impl.panic else std.debug.FullPanic(defaultPanic);

fn defaultPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    std.debug.defaultPanic(msg, ret_addr);
}

pub fn main(init: anytype) !void {
    if (comptime !available) return error.TuiUnavailable;
    return impl.main(init);
}

test {
    if (build_options.enable_tui) std.testing.refAllDecls(impl);
}

test "TUI availability includes its terminal concurrency requirement" {
    if (builtin.single_threaded or !build_options.enable_tui) {
        try std.testing.expect(!available);
    } else {
        try std.testing.expect(available);
    }
}
