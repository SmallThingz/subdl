const std = @import("std");
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

pub const available = build_options.enable_tui;
pub const panic = if (build_options.enable_tui) impl.panic else std.debug.FullPanic(defaultPanic);

fn defaultPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    std.debug.defaultPanic(msg, ret_addr);
}

pub fn main(init: anytype) !void {
    return impl.main(init);
}

test {
    if (build_options.enable_tui) std.testing.refAllDecls(impl);
}
