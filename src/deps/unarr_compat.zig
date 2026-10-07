const build_options = @import("build_options");

pub const enabled = build_options.enable_unarr;

pub const Format = if (enabled)
    @import("unarr_upstream").Format
else
    enum {
        zip,
        rar,
        @"7z",
    };

pub const Entry = if (enabled)
    @import("unarr_upstream").Entry
else
    struct {
        pub fn size(_: Entry) usize {
            return 0;
        }

        pub fn name(_: Entry) ?[]const u8 {
            return null;
        }

        pub fn rawName(_: Entry) ?[]const u8 {
            return null;
        }

        pub fn read(_: Entry, _: []u8) !void {
            return error.UnarrUnavailable;
        }

        pub fn readAlloc(_: Entry, _: anytype, _: usize) ![]u8 {
            return error.UnarrUnavailable;
        }
    };

pub const Archive = if (enabled)
    @import("unarr_upstream").Archive
else
    struct {
        pub fn openMemory(_: Format, _: []const u8, _: anytype) !Archive {
            return error.UnarrUnavailable;
        }

        pub fn deinit(_: *Archive) void {}

        pub fn nextEntry(_: *Archive) !?Entry {
            return error.UnarrUnavailable;
        }
    };
