const std = @import("std");

/// The package version, single-sourced from build.zig.zon.
const version_string = blk: {
    const zon = @embedFile("build.zig.zon");
    const marker = ".version = \"";
    const start = (std.mem.indexOf(u8, zon, marker) orelse
        @compileError("no version in build.zig.zon")) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, zon, start, '"') orelse
        @compileError("unterminated version in build.zig.zon");
    break :blk zon[start..end];
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "llvm", "Use the LLVM backend for compile steps") orelse true;
    const external_uucode = b.option(bool, "external_uucode", "Use an externally provided uucode module instead of the built-in dependency") orelse false;
    const root_source_file = b.path("src/main.zig");

    // Dependencies
    const zigimg_dep = b.dependency("zigimg", .{
        .optimize = optimize,
        .target = target,
    });
    const uucode_mod = if (!external_uucode) blk: {
        const uucode_dep = b.dependencyLazy("uucode", .{
            .target = target,
            .optimize = optimize,
            .fields = @as([]const []const u8, &.{
                "east_asian_width",
                "grapheme_break",
                "general_category",
                "is_emoji",
                "is_emoji_presentation",
                "is_emoji_vs_base",
            }),
        }) catch |err| switch (err) {
            error.LazyDependencyNeeded => break :blk null,
        };
        break :blk uucode_dep.module("uucode");
    } else null;

    // Module
    const vaxis_mod = b.addModule("vaxis", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    vaxis_mod.addImport("zigimg", zigimg_dep.module("zigimg"));
    if (uucode_mod) |mod| {
        vaxis_mod.addImport("uucode", mod);
    } else if (!external_uucode) {
        // Keep the public module discoverable by a parent package during its
        // cold-cache pass, then propagate Zig 0.17's lazy-fetch signal.
        return error.LazyDependencyNeeded;
    } else {
        // External uucode mode: consumer wires up their own uucode module on
        // the vaxis module. Skip standalone library, test, and docs steps since
        // they all require uucode to be available inside this package.
        return;
    }

    // Exposes the terminal input parser over a C ABI (see include/vaxis.h),
    const c_api_options = b.addOptions();
    c_api_options.addOption([]const u8, "version", version_string);
    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "build_options", .module = c_api_options.createModule() },
        },
    });

    // Compile the C API once as PIC, then use the resulting object for both
    // library formats. Building two libraries directly from c_api_mod would
    // run Zig's frontend and code generator once per linkage.
    const c_api_object = b.addObject(.{
        .name = "vaxis-c-api",
        .root_module = c_api_mod,
        .use_llvm = use_llvm,
    });

    const static_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    static_mod.addObject(c_api_object);
    const static_lib = b.addLibrary(.{
        // the DLL import library is also named vaxis.lib on Windows
        .name = if (target.result.os.tag == .windows) "vaxis-static" else "vaxis",
        .linkage = .static,
        .root_module = static_mod,
        .use_llvm = use_llvm,
    });

    const shared_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shared_mod.addObject(c_api_object);
    const shared_lib = b.addLibrary(.{
        .name = "vaxis",
        .linkage = .dynamic,
        .root_module = shared_mod,
        .use_llvm = use_llvm,
        .version = std.SemanticVersion.parse(version_string) catch unreachable,
    });

    const install_static = b.addInstallArtifact(static_lib, .{});
    const install_shared = b.addInstallArtifact(shared_lib, .{});
    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });
    const install_license = b.addInstallFile(
        b.path("LICENSE"),
        "share/licenses/vaxis/LICENSE",
    );
    const install_third_party_licenses = b.addInstallDirectory(.{
        .source_dir = b.path("THIRD_PARTY_LICENSES"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/vaxis/THIRD_PARTY_LICENSES",
    });
    const lib_static_step = b.step("lib-static", "Build the static C library");
    lib_static_step.dependOn(&install_static.step);
    lib_static_step.dependOn(&install_headers.step);
    lib_static_step.dependOn(&install_license.step);
    lib_static_step.dependOn(&install_third_party_licenses.step);
    const lib_shared_step = b.step("lib-shared", "Build the shared C library");
    lib_shared_step.dependOn(&install_shared.step);
    lib_shared_step.dependOn(&install_headers.step);
    lib_shared_step.dependOn(&install_license.step);
    lib_shared_step.dependOn(&install_third_party_licenses.step);
    const lib_step = b.step("lib", "Build the C library (static and shared)");
    lib_step.dependOn(lib_static_step);
    lib_step.dependOn(lib_shared_step);
    // This vendored package intentionally contains the library, headers and
    // core tests only. Make those libraries the useful standalone default;
    // upstream example and benchmark sources are not part of this subset.
    b.getInstallStep().dependOn(&install_static.step);
    b.getInstallStep().dependOn(&install_shared.step);
    b.getInstallStep().dependOn(&install_headers.step);
    b.getInstallStep().dependOn(&install_license.step);
    b.getInstallStep().dependOn(&install_third_party_licenses.step);

    // Tests
    const tests_step = b.step("test", "Run tests");

    const tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
                .{ .name = "uucode", .module = uucode_mod.? },
            },
        }),
    });

    const tests_run = b.addRunArtifact(tests);
    tests_step.dependOn(&tests_run.step);

    // The C API unit tests import include/vaxis.h, translated to Zig, to check
    // that the vendored header matches the ABI.
    const vaxis_h = b.addTranslateC(.{
        .root_source_file = b.path("include/vaxis.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_api_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "build_options", .module = c_api_options.createModule() },
                .{ .name = "vaxis_h", .module = vaxis_h.createModule() },
            },
        }),
    });
    tests_step.dependOn(&b.addRunArtifact(c_api_tests).step);

    // Docs
    const docs_step = b.step("docs", "Build the vaxis library docs");
    const docs_obj = b.addObject(.{
        .name = "vaxis",
        .use_llvm = use_llvm,
        // Reuse the public module so documentation sees the exact zigimg and
        // uucode imports consumers receive.
        .root_module = vaxis_mod,
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
    docs_step.dependOn(&install_license.step);
    docs_step.dependOn(&install_third_party_licenses.step);
}
