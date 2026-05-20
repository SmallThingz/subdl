const std = @import("std");

pub fn build(b: *std.Build) void {
  const target = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});

  const onealloc_module = b.addModule("oneserial", .{
    .root_source_file = b.path("src/root.zig"),
    .single_threaded = true,
  });

  const options = b.addOptions();
  onealloc_module.addOptions("build", options);

  const test_step = b.step("test", "Run unit tests");
  for ([_][]const u8{"src/root.zig", "src/test.zig"}) |path| {
    const lib_unit_tests = b.addTest(.{
      .root_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
      }),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    test_step.dependOn(&run_lib_unit_tests.step);
  }
}

