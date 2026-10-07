const Build = @import("std").Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigimg_module = b.addModule("zigimg", .{
        .root_source_file = b.path("zigimg.zig"),
        .target = target,
        .optimize = optimize,
    });

    zigimg_module.addImport("zigimg", zigimg_module);

    const install_license = b.addInstallFile(
        b.path("LICENSE"),
        "share/licenses/zigimg/LICENSE",
    );
    const install_third_party_licenses = b.addInstallDirectory(.{
        .source_dir = b.path("THIRD_PARTY_LICENSES"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/zigimg/THIRD_PARTY_LICENSES",
    });
    b.getInstallStep().dependOn(&install_license.step);
    b.getInstallStep().dependOn(&install_third_party_licenses.step);

    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    const zigimg_build_test = b.addTest(.{
        .name = "zigimgtest",
        .root_module = zigimg_module,
        .filters = test_filters,
        .use_llvm = true,
    });

    const run_test_cmd = b.addRunArtifact(zigimg_build_test);
    // Force running of the test command even if you don't have changes
    run_test_cmd.has_side_effects = true;

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_test_cmd.step);

    const build_only_test_step = b.step("test_build_only", "Build the tests but does not run it");
    build_only_test_step.dependOn(&zigimg_build_test.step);

    const install_test = b.addInstallArtifact(zigimg_build_test, .{});
    const test_bin_step = b.step("test-bin", "Install the test binary for execution in a target runtime");
    test_bin_step.dependOn(&install_test.step);
    test_bin_step.dependOn(&install_license.step);
    test_bin_step.dependOn(&install_third_party_licenses.step);
}
