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

pub const available = impl.available;

pub fn main(init: anytype) !void {
    return impl.main(init);
}
