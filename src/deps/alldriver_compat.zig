const build_options = @import("build_options");
pub const enabled = build_options.enable_alldriver;

const impl = if (enabled)
    @import("alldriver_upstream")
else
    struct {
        const StubInstall = struct {};

        const StubCookie = struct {
            domain: []const u8 = "",
            name: []const u8 = "",
            value: []const u8 = "",
        };

        const StubInstallList = struct {
            items: []const StubInstall = &.{},

            pub fn deinit(_: *StubInstallList) void {}
        };

        pub fn discover(_: anytype, _: anytype, _: anytype) !StubInstallList {
            return .{};
        }

        pub const modern = struct {
            pub const ModernSession = struct {
                base: Base = .{},

                pub fn deinit(_: *ModernSession) void {}

                pub fn page(_: *ModernSession) Page {
                    return .{};
                }

                pub fn storage(_: *ModernSession) Storage {
                    return .{};
                }

                pub fn runtime(_: *ModernSession) Runtime {
                    return .{};
                }
            };

            pub fn launch(_: anytype, _: anytype) !ModernSession {
                return error.AllDriverUnavailable;
            }

            pub const Page = struct {
                pub fn navigate(_: *Page, _: []const u8) !void {
                    return error.AllDriverUnavailable;
                }
            };

            pub const Base = struct {
                pub fn waitFor(_: *Base, _: anytype, _: anytype) !void {
                    return error.AllDriverUnavailable;
                }
            };

            pub const Storage = struct {
                pub fn getCookies(_: *Storage, _: anytype) ![]StubCookie {
                    return error.AllDriverUnavailable;
                }

                pub fn freeCookies(_: *Storage, _: anytype, _: []StubCookie) void {}
            };

            pub const Runtime = struct {
                pub fn evaluate(_: *Runtime, _: []const u8) ![]u8 {
                    return error.AllDriverUnavailable;
                }
            };
        };

        pub const BrowserInstall = StubInstall;
        pub const BrowserPreference = struct {};
        pub const DiscoveryOptions = struct {};
        pub const Cookie = StubCookie;
        pub const BrowserInstallList = StubInstallList;
    };

pub const Install = impl.BrowserInstall;
pub const BrowserPreference = impl.BrowserPreference;
pub const DiscoveryOptions = impl.DiscoveryOptions;
pub const Cookie = impl.Cookie;
pub const InstallList = impl.BrowserInstallList;
pub const modern = impl.modern;

pub fn discover(allocator: anytype, options: anytype, overrides: anytype) !InstallList {
    if (!enabled) return impl.discover(allocator, options, overrides);

    const prefs: BrowserPreference = .{
        .kinds = options.kinds,
        .channel = if (@hasField(@TypeOf(options), "channel")) options.channel else null,
        .explicit_path = if (@hasField(@TypeOf(options), "explicit_path")) options.explicit_path else null,
        .allow_managed_download = if (@hasField(@TypeOf(options), "allow_managed_download")) options.allow_managed_download else false,
        .managed_cache_dir = if (@hasField(@TypeOf(options), "managed_cache_dir")) options.managed_cache_dir else null,
    };
    const discovery: DiscoveryOptions = .{
        .include_path_env = if (@hasField(@TypeOf(overrides), "include_path_env")) overrides.include_path_env else true,
        .include_os_probes = if (@hasField(@TypeOf(overrides), "include_os_probes")) overrides.include_os_probes else true,
        .include_known_paths = if (@hasField(@TypeOf(overrides), "include_known_paths")) overrides.include_known_paths else true,
    };
    return impl.discover(allocator, prefs, discovery);
}
