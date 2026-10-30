const std = @import("std");

const unarr_version = std.SemanticVersion{
    .major = 1,
    .minor = 2,
    .patch = 0,
};

const unarr_version_string = "1.2.0";

const base_sources = [_][]const u8{
    "_7z/_7z.c",
    "common/conv.c",
    "common/crc32.c",
    "common/stream.c",
    "common/unarr.c",
    "lzmasdk/CpuArch.c",
    "lzmasdk/LzmaDec.c",
    "lzmasdk/Ppmd7.c",
    "lzmasdk/Ppmd7Dec.c",
    "lzmasdk/Ppmd7aDec.c",
    "lzmasdk/Ppmd8.c",
    "lzmasdk/Ppmd8Dec.c",
    "rar/filter-rar.c",
    "rar/huffman-rar.c",
    "rar/parse-rar.c",
    "rar/rar.c",
    "rar/rarvm.c",
    "rar/uncompress-rar.c",
    "tar/parse-tar.c",
    "tar/tar.c",
    "zip/inflate.c",
    "zip/parse-zip.c",
    "zip/uncompress-zip.c",
    "zip/zip.c",
};

const seven_zip_sources = [_][]const u8{
    "lzmasdk/7zArcIn.c",
    "lzmasdk/7zBuf.c",
    "lzmasdk/7zDec.c",
    "lzmasdk/7zStream.c",
    "lzmasdk/Bcj2.c",
    "lzmasdk/Bra.c",
    "lzmasdk/Bra86.c",
    "lzmasdk/Delta.c",
    "lzmasdk/Lzma2Dec.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.option(bool, "shared", "Build a shared library") orelse false;
    const enable_7z = b.option(bool, "enable_7z", "Enable 7z decoding") orelse true;
    const upstream = b.dependency("unarr_upstream", .{});
    const header = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("unarr.h.in") },
        .include_path = "unarr.h",
    }, .{
        .unarr_VERSION_MAJOR = @as(i64, unarr_version.major),
        .unarr_VERSION_MINOR = @as(i64, unarr_version.minor),
        .unarr_VERSION_PATCH = @as(i64, unarr_version.patch),
        .unarr_VERSION = unarr_version_string,
    });
    const lib = b.addLibrary(.{
        .name = "unarr",
        .linkage = if (shared) .dynamic else .static,
        .version = unarr_version,
        .use_lld = target.result.ofmt != .macho,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lib.root_module.addIncludePath(upstream.path(""));
    lib.root_module.addConfigHeader(header);
    lib.root_module.addCMacro("_FILE_OFFSET_BITS", "64");
    lib.root_module.addCMacro("UNARR_EXPORT_SYMBOLS", "1");
    if (shared) lib.root_module.addCMacro("UNARR_IS_SHARED_LIBRARY", "1");
    // The bundled LZMA SDK deliberately uses unaligned loads on supported CPUs.
    lib.root_module.addCSourceFiles(.{ .root = upstream.path(""), .files = &base_sources, .flags = &.{ "-std=c99", "-fno-sanitize=alignment" } });
    if (enable_7z) {
        lib.root_module.addCMacro("HAVE_7Z", "1");
        lib.root_module.addCMacro("Z7_PPMD_SUPPORT", "1");
        lib.root_module.addCSourceFiles(.{ .root = upstream.path(""), .files = &seven_zip_sources, .flags = &.{ "-std=c99", "-fno-sanitize=alignment" } });
    }
    lib.installConfigHeader(header);
    b.installArtifact(lib);
    const options = b.addOptions();
    options.addOption(bool, "enable_7z", enable_7z);
    const mod = b.addModule("unarr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
    });
    mod.addConfigHeader(header);
    if (shared) mod.addCMacro("UNARR_IS_SHARED_LIBRARY", "1");
    mod.linkLibrary(lib);
    const headers = b.addWriteFiles();
    const bindings = b.addTranslateC(.{
        .root_source_file = headers.add("unarr_api.h", "#include <unarr.h>\n"),
        .target = target,
        .optimize = optimize,
    });
    bindings.addConfigHeader(header);
    if (shared) bindings.defineCMacro("UNARR_IS_SHARED_LIBRARY", "1");
    mod.addImport("unarr_c", bindings.createModule());
    const tests = b.addTest(.{ .root_module = mod, .use_lld = target.result.ofmt != .macho, .use_llvm = true });
    const run = b.addRunArtifact(tests);
    run.setCwd(b.path(""));
    b.step("test", "Run archive behavior and ownership tests").dependOn(&run.step);
    b.step("test-bin", "Install tests for execution in a target runtime").dependOn(&b.addInstallArtifact(tests, .{}).step);
    const check = b.step("check", "Compile library and tests");
    check.dependOn(&lib.step);
    check.dependOn(&tests.step);
    const example = b.addExecutable(.{
        .name = "unarr-read",
        .use_llvm = true,
        .use_lld = target.result.ofmt != .macho,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/read.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "unarr", .module = mod }},
        }),
    });
    const run_example = b.addRunArtifact(example);
    run_example.setCwd(b.path(""));
    b.step("example", "Read a real compressed ZIP through the Zig API").dependOn(&run_example.step);
    check.dependOn(&example.step);
}
