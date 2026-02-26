const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libvaxis_dep = b.dependency("libvaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const htmlparser_dep = b.dependency("htmlparser", .{
        .target = target,
        .optimize = optimize,
    });
    const htmlparser_compat_mod = b.createModule(.{
        .root_source_file = b.path("src/deps/htmlparser_compat.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "htmlparser_upstream", .module = htmlparser_dep.module("htmlparser") },
        },
    });
    const alldriver_dep = b.dependency("alldriver", .{
        .target = target,
        .optimize = optimize,
    });
    const subdl_mod = b.addModule("subdl", .{
        .root_source_file = b.path("src/scrapers/subdl.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "htmlparser", .module = htmlparser_compat_mod },
            .{ .name = "alldriver", .module = alldriver_dep.module("alldriver") },
        },
    });
    const scrapers_mod = b.addModule("scrapers", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "htmlparser", .module = htmlparser_compat_mod },
            .{ .name = "alldriver", .module = alldriver_dep.module("alldriver") },
        },
    });

    const cli_exe = b.addExecutable(.{
        .name = "scrapers_cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmd/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scrapers", .module = scrapers_mod },
            },
        }),
    });

    const tui_exe = b.addExecutable(.{
        .name = "scrapers_tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmd/tui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scrapers", .module = scrapers_mod },
                .{ .name = "vaxis", .module = libvaxis_dep.module("vaxis") },
            },
        }),
    });

    b.installArtifact(cli_exe);
    b.installArtifact(tui_exe);

    const run_step = b.step("run", "Run the CLI app");
    const run_cli_cmd = b.addRunArtifact(cli_exe);
    run_step.dependOn(&run_cli_cmd.step);
    run_cli_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli_cmd.addArgs(args);

    const run_tui_step = b.step("run-tui", "Run the Vaxis TUI app");
    const run_tui_cmd = b.addRunArtifact(tui_exe);
    run_tui_step.dependOn(&run_tui_cmd.step);
    run_tui_cmd.step.dependOn(b.getInstallStep());

    const subdl_mod_tests = b.addTest(.{
        .root_module = subdl_mod,
    });
    const run_subdl_mod_tests = b.addRunArtifact(subdl_mod_tests);

    const scrapers_mod_tests = b.addTest(.{
        .root_module = scrapers_mod,
    });
    const run_scrapers_mod_tests = b.addRunArtifact(scrapers_mod_tests);

    const cli_tests = b.addTest(.{
        .root_module = cli_exe.root_module,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const tui_tests = b.addTest(.{
        .root_module = tui_exe.root_module,
    });
    const run_tui_tests = b.addRunArtifact(tui_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_subdl_mod_tests.step);
    test_step.dependOn(&run_scrapers_mod_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_tui_tests.step);
}
