const std = @import("std");
const provider_registry = @import("src/provider_registry.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize_opt = b.option(std.lang.Optimize, "optimize", "Optimization mode");
    // The primary artifact is an interactive terminal app. Debug mode makes
    // libvaxis walk and compare the full terminal grid with safety checks on
    // every navigation frame, which is visibly sluggish even for modest lists.
    // Keep Debug available explicitly via -Doptimize=debug, but make normal
    // run/install builds use the performance mode users actually experience.
    const optimize = optimize_opt orelse .fast;
    const test_optimize = optimize_opt orelse .debug;
    const all_targets_optimize = optimize_opt orelse .fast;
    const strip_opt = b.option(bool, "strip", "Strip debug symbols from binaries");
    const strip = strip_opt orelse false;
    const all_targets_strip = strip_opt orelse true;
    const single_threaded = b.option(bool, "single-threaded", "Force single-threaded mode");
    const omit_frame_pointer = b.option(bool, "omit-frame-pointer", "Force frame pointer omission mode");
    const error_tracing = b.option(bool, "error-tracing", "Force error tracing mode");
    const pic = b.option(bool, "pic", "Force PIC mode");
    const llvm = b.option(bool, "llvm", "Use LLVM codegen backend") orelse true;
    const enable_tui = b.option(bool, "enable-tui", "Enable TUI support via libvaxis") orelse true;
    const enable_alldriver = b.option(bool, "enable-alldriver", "Enable browser automation support via alldriver") orelse false;
    const enable_unarr = b.option(bool, "enable-unarr", "Enable archive extraction support via unarr") orelse true;
    const live_mode = b.option([]const u8, "live", "Live test mode: off | smoke | named | extensive | all") orelse "off";
    const live_providers = b.option([]const u8, "live-providers", "Comma-separated provider filter for live tests, or '*' for all") orelse "*";
    const live_parallel_on_all = b.option(bool, "live-parallel-on-all", "Run one live subprocess per provider when -Dlive-providers=all/*") orelse true;
    const live_max_jobs = b.option(u32, "live-max-jobs", "Maximum concurrent live provider subprocesses") orelse 4;
    if (live_max_jobs == 0) @panic("live-max-jobs must be positive");
    const live_timeout_seconds = b.option(u32, "live-timeout-seconds", "Hard deadline for each parallel live provider") orelse 60;

    const valid_mode = std.mem.eql(u8, live_mode, "off") or
        std.mem.eql(u8, live_mode, "smoke") or
        std.mem.eql(u8, live_mode, "named") or
        std.mem.eql(u8, live_mode, "extensive") or
        std.mem.eql(u8, live_mode, "all");
    if (!valid_mode) {
        @panic("invalid -Dlive value, expected one of: off, smoke, named, extensive, all");
    }

    const live_tests_enabled = !std.mem.eql(u8, live_mode, "off");
    const live_extensive_suite = live_tests_enabled and
        (std.mem.eql(u8, live_mode, "extensive") or std.mem.eql(u8, live_mode, "all"));
    const live_tui_suite = live_tests_enabled and
        (std.mem.eql(u8, live_mode, "smoke") or std.mem.eql(u8, live_mode, "all"));
    const live_named_tests_enabled = live_tests_enabled and
        (std.mem.eql(u8, live_mode, "named") or std.mem.eql(u8, live_mode, "all"));

    const build_options = b.addOptions();
    build_options.addOption(bool, "live_tests_enabled", live_tests_enabled);
    build_options.addOption(bool, "live_extensive_suite", live_extensive_suite);
    build_options.addOption(bool, "live_tui_suite", live_tui_suite);
    build_options.addOption(bool, "live_named_tests_enabled", live_named_tests_enabled);
    build_options.addOption(bool, "enable_tui", enable_tui);
    build_options.addOption(bool, "enable_alldriver", enable_alldriver);
    build_options.addOption(bool, "enable_unarr", enable_unarr);
    build_options.addOption([]const u8, "live_provider_filter", if (live_tests_enabled) live_providers else "");
    const build_options_mod = build_options.createModule();
    const host_modules = createTargetModuleSet(
        b,
        target,
        optimize,
        strip,
        single_threaded,
        omit_frame_pointer,
        error_tracing,
        pic,
        build_options_mod,
        true,
        enable_tui,
        enable_alldriver,
        enable_unarr,
    );
    _ = b.addModule("subdl", .{
        .root_source_file = b.path("src/scrapers/subdl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "htmlparser", .module = host_modules.htmlparser_compat },
            .{ .name = "alldriver", .module = host_modules.alldriver },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "runtime_alloc", .module = host_modules.runtime_alloc },
            .{ .name = "runtime_io", .module = host_modules.runtime_io },
        },
    });
    const scrapers_mod = host_modules.scrapers;

    const app_exe = b.addExecutable(.{
        .name = "scrapers",
        .use_llvm = llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmd/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
            .imports = &.{
                .{ .name = "scrapers", .module = scrapers_mod },
                .{ .name = "runtime_alloc", .module = host_modules.runtime_alloc },
                .{ .name = "runtime_io", .module = host_modules.runtime_io },
                .{ .name = "tui_backend", .module = host_modules.tui_backend },
            },
        }),
    });

    const cross_targets = [_]struct {
        suffix: []const u8,
        query: std.Target.Query,
        static_libc: bool,
    }{
        .{
            .suffix = "x86_64-linux-gnu",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .static_libc = true,
        },
        .{
            .suffix = "aarch64-linux-gnu",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
            .static_libc = true,
        },
        .{
            .suffix = "x86_64-windows-gnu",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
            .static_libc = false,
        },
        .{
            .suffix = "x86_64-macos-none",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .static_libc = false,
        },
        .{
            .suffix = "aarch64-macos-none",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .static_libc = false,
        },
    };

    b.installArtifact(app_exe);

    const run_step = b.step("run", "Run the app (CLI mode by default)");
    const run_cmd = b.addRunArtifact(app_exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_tui_step = b.step("run-tui", "Run the app in TUI mode");
    const run_tui_cmd = b.addRunArtifact(app_exe);
    run_tui_step.dependOn(&run_tui_cmd.step);
    run_tui_cmd.step.dependOn(b.getInstallStep());
    run_tui_cmd.addArg("--tui");
    run_tui_cmd.addPassthruArgs();

    const all_targets_step = b.step("build-all-targets", "Build scrapers for all configured targets into zig-out/bin");
    for (cross_targets) |cross| {
        const cross_target = b.resolveTargetQuery(cross.query);
        const cross_modules = createTargetModuleSet(
            b,
            cross_target,
            all_targets_optimize,
            all_targets_strip,
            single_threaded,
            omit_frame_pointer,
            error_tracing,
            pic,
            build_options_mod,
            cross.static_libc,
            enable_tui,
            enable_alldriver,
            enable_unarr,
        );

        const cross_exe = b.addExecutable(.{
            .name = b.fmt("scrapers-{s}", .{cross.suffix}),
            .use_llvm = llvm,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/cmd/main.zig"),
                .target = cross_target,
                .optimize = all_targets_optimize,
                .link_libc = true,
                .strip = all_targets_strip,
                .single_threaded = single_threaded,
                .omit_frame_pointer = omit_frame_pointer,
                .error_tracing = error_tracing,
                .pic = pic,
                .imports = &.{
                    .{ .name = "scrapers", .module = cross_modules.scrapers },
                    .{ .name = "runtime_alloc", .module = cross_modules.runtime_alloc },
                    .{ .name = "runtime_io", .module = cross_modules.runtime_io },
                    .{ .name = "tui_backend", .module = cross_modules.tui_backend },
                },
            }),
        });
        const install_cross = b.addInstallArtifact(cross_exe, .{});
        all_targets_step.dependOn(&install_cross.step);
    }

    const test_modules = createTargetModuleSet(
        b,
        target,
        test_optimize,
        false,
        single_threaded,
        omit_frame_pointer,
        error_tracing,
        pic,
        build_options_mod,
        true,
        enable_tui,
        enable_alldriver,
        enable_unarr,
    );
    const test_subdl_mod = b.createModule(.{
        .root_source_file = b.path("src/scrapers/subdl.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "htmlparser", .module = test_modules.htmlparser_compat },
            .{ .name = "alldriver", .module = test_modules.alldriver },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "runtime_alloc", .module = test_modules.runtime_alloc },
            .{ .name = "runtime_io", .module = test_modules.runtime_io },
        },
    });
    const test_app_mod = b.createModule(.{
        .root_source_file = b.path("src/cmd/main.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "scrapers", .module = test_modules.scrapers },
            .{ .name = "runtime_alloc", .module = test_modules.runtime_alloc },
            .{ .name = "runtime_io", .module = test_modules.runtime_io },
            .{ .name = "tui_backend", .module = test_modules.tui_backend },
        },
    });

    const subdl_mod_tests = b.addTest(.{
        .root_module = test_subdl_mod,
        .use_llvm = llvm,
    });
    const run_subdl_mod_tests = b.addRunArtifact(subdl_mod_tests);

    const scrapers_mod_tests = b.addTest(.{
        .root_module = test_modules.scrapers,
        .use_llvm = llvm,
    });
    const run_scrapers_mod_tests = b.addRunArtifact(scrapers_mod_tests);
    const run_scrapers_mod_tests_live = b.addSystemCommand(&.{ "bash", "-lc", "exec \"$1\"", "_" });
    run_scrapers_mod_tests_live.addFileArg(scrapers_mod_tests.getEmittedBin());
    run_scrapers_mod_tests_live.stdio = .inherit;

    const app_tests = b.addTest(.{
        .root_module = test_app_mod,
        .use_llvm = llvm,
    });
    const run_app_tests = b.addRunArtifact(app_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_subdl_mod_tests.step);
    test_step.dependOn(&run_scrapers_mod_tests.step);
    test_step.dependOn(&run_app_tests.step);
    const html_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_modules.htmlparser_compat, .use_llvm = llvm }));
    test_step.dependOn(&html_tests.step);
    b.step("test-html", "Check parser replacement ownership").dependOn(&html_tests.step);
    const backend_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_modules.tui_backend, .use_llvm = llvm }));
    test_step.dependOn(&backend_tests.step);
    if (test_modules.tui_impl) |tui_mod| {
        const tui_tests = b.addTest(.{ .root_module = tui_mod, .use_llvm = llvm });
        const run_tui_tests = b.addRunArtifact(tui_tests);
        test_step.dependOn(&run_tui_tests.step);
        const test_tui_step = b.step("test-tui", "Check terminal navigation, persistence and cancellation");
        test_tui_step.dependOn(&run_tui_tests.step);
    }

    const http_fixture = b.addExecutable(.{
        .name = "http-transport-test",
        .use_llvm = llvm,
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/http_transport_test.zig"), .target = target, .optimize = test_optimize, .imports = &.{ .{ .name = "scrapers", .module = test_modules.scrapers }, .{ .name = "runtime_io", .module = test_modules.runtime_io } } }),
    });
    const http_test = b.addSystemCommand(&.{ "python3", "-B" });
    http_test.addFileArg(b.path("tools/test_http_transport.py"));
    http_test.addFileArg(http_fixture.getEmittedBin());
    const http_step = b.step("test-http", "Native Python 3 loopback transport integration tests");
    if (target.query.isNative()) {
        http_step.dependOn(&http_test.step);
    } else {
        http_step.dependOn(&b.addFail("test-http is a native integration gate; omit -Dtarget").step);
    }
    const pty_step = b.step("test-pty", "Native POSIX Python terminal navigation and shutdown integration");
    if (enable_tui and target.query.isNative() and target.result.os.tag != .windows) {
        for ([_][]const u8{ "normal", "burst" }) |mode| {
            const pty_test = b.addSystemCommand(&.{ "python3", "-B" });
            pty_test.addFileArg(b.path("tools/test_tui_pty.py"));
            pty_test.addFileArg(app_exe.getEmittedBin());
            pty_test.addArg(mode);
            pty_step.dependOn(&pty_test.step);
        }
    } else {
        pty_step.dependOn(&b.addFail("test-pty requires a native POSIX target and enabled TUI").step);
    }
    // Explicit native integration gate: Python directly runs the fixture.
    // Keep ordinary/cross-target unit tests independent of host Python/runners.

    const test_live_single_step = b.step("test-live-single", "Run live tests for the current provider filter");
    test_live_single_step.dependOn(&run_scrapers_mod_tests_live.step);

    const test_live_step = b.step("test-live", "Run live tests using -Dlive and -Dlive-providers");
    if (live_tests_enabled and live_parallel_on_all and
        (isAllLiveProviderSelection(live_providers) or isActiveLiveProviderSelection(live_providers)))
    {
        const script = makeParallelLiveRunScript(
            b,
            live_timeout_seconds,
            live_max_jobs,
            isActiveLiveProviderSelection(live_providers),
        );
        const fanout_cmd = b.addSystemCommand(&.{ "bash", "-lc", script, "_test_bin_" });
        fanout_cmd.setCwd(b.path("."));
        fanout_cmd.addFileArg(scrapers_mod_tests.getEmittedBin());
        test_live_step.dependOn(&fanout_cmd.step);
    } else {
        test_live_step.dependOn(&run_scrapers_mod_tests_live.step);
    }

    const test_live_all_step = b.step("test-live-all", "Run all providers live");
    const live_all_cmd = b.addSystemCommand(&.{
        "zig",
        "build",
        "test-live",
        "-Dlive=all",
        "-Dlive-providers=*",
    });
    live_all_cmd.setCwd(b.path("."));
    test_live_all_step.dependOn(&live_all_cmd.step);

    const test_live_active_step = b.step("test-live-active", "Run all active CLI/TUI providers live");
    const live_active_cmd = b.addSystemCommand(&.{
        "zig",
        "build",
        "test-live",
        "-Dlive=all",
        "-Dlive-providers=active",
    });
    live_active_cmd.setCwd(b.path("."));
    test_live_active_step.dependOn(&live_active_cmd.step);
}

fn isAllLiveProviderSelection(raw_filter: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_filter, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (std.mem.eql(u8, trimmed, "*")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return true;
    return false;
}

fn isActiveLiveProviderSelection(raw_filter: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw_filter, " \t\r\n"), "active");
}

fn makeParallelLiveRunScript(
    b: *std.Build,
    timeout_seconds: u32,
    max_jobs: u32,
    active_only: bool,
) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(b.allocator);
    out.appendSlice(b.allocator,
        \\set -euo pipefail
        \\test_bin="$1"
        \\mkdir -p .tmp
        \\tmpdir="$(mktemp -d .tmp/live-runner.XXXXXX)"
        \\cleanup() { rm -rf "$tmpdir"; }
        \\trap cleanup EXIT
        \\declare -a names=()
        \\declare -a pids=()
        \\
    ) catch @panic("oom");

    out.print(b.allocator, "max_jobs={d}\n", .{max_jobs}) catch @panic("oom");
    for (provider_registry.all) |target_info| {
        if (active_only and !target_info.active) continue;
        if (target_info.live_serial) continue;
        out.appendSlice(b.allocator,
            \\while (( $(jobs -rp | wc -l) >= max_jobs )); do
            \\  wait -n || true
            \\done
            \\
        ) catch @panic("oom");
        const provider_timeout_seconds = target_info.live_timeout_seconds orelse timeout_seconds;
        out.print(b.allocator,
            \\echo "[live][runner] START {s}"
            \\
            \\(
            \\  set -o pipefail
            \\  set +e
            \\  SCRAPERS_LIVE_PROVIDER_FILTER="{s}" timeout --signal=TERM --kill-after=5s {d}s "$test_bin" 2>&1 | sed -u 's/^/[live][{s}] /'
            \\  rc=${{PIPESTATUS[0]}}
            \\  set -e
            \\  echo "$rc" > "$tmpdir/{s}.rc"
            \\  echo "[live][runner] END {s} rc=$rc"
            \\  exit "$rc"
            \\) &
            \\names+=("{s}")
            \\pids+=("$!")
            \\
        , .{
            target_info.live_name,
            target_info.live_name,
            provider_timeout_seconds,
            target_info.live_name,
            target_info.live_name,
            target_info.live_name,
            target_info.live_name,
        }) catch @panic("oom");
    }

    out.appendSlice(b.allocator,
        \\(
        \\  while true; do
        \\    active_names=""
        \\    for i in "${!pids[@]}"; do
        \\      pid="${pids[$i]}"
        \\      name="${names[$i]}"
        \\      if [[ -d "/proc/$pid" ]]; then
        \\        if [[ -z "$active_names" ]]; then
        \\          active_names="$name"
        \\        else
        \\          active_names="$active_names,$name"
        \\        fi
        \\      fi
        \\    done
        \\    if [[ -z "$active_names" ]]; then
        \\      break
        \\    fi
        \\    echo "[live][runner] ACTIVE $active_names"
        \\    sleep 5
        \\  done
        \\) &
        \\monitor_pid=$!
        \\
        \\overall_rc=0
        \\for i in "${!pids[@]}"; do
        \\  name="${names[$i]}"
        \\  pid="${pids[$i]}"
        \\  wait "$pid" || true
        \\  rc_file="$tmpdir/$name.rc"
        \\  if [[ ! -f "$rc_file" ]]; then
        \\    echo "[live][runner] END $name rc=missing"
        \\    overall_rc=1
        \\    continue
        \\  fi
        \\  rc="$(cat "$rc_file")"
        \\  if [[ "$rc" != "0" ]]; then
        \\    overall_rc=1
        \\  fi
        \\done
        \\wait "$monitor_pid" 2>/dev/null || true
        \\
    ) catch @panic("oom");

    for (provider_registry.all) |target_info| {
        if (!target_info.live_serial) continue;
        if (active_only and !target_info.active) continue;
        const provider_timeout_seconds = target_info.live_timeout_seconds orelse timeout_seconds;
        out.print(b.allocator,
            \\echo "[live][runner] START {s} mode=serial"
            \\set +e
            \\SCRAPERS_LIVE_PROVIDER_FILTER="{s}" timeout --signal=TERM --kill-after=5s {d}s "$test_bin" 2>&1 | sed -u 's/^/[live][{s}] /'
            \\rc=${{PIPESTATUS[0]}}
            \\set -e
            \\echo "[live][runner] END {s} rc=$rc mode=serial"
            \\if [[ "$rc" != "0" ]]; then
            \\  overall_rc=1
            \\fi
            \\
        , .{
            target_info.live_name,
            target_info.live_name,
            provider_timeout_seconds,
            target_info.live_name,
            target_info.live_name,
        }) catch @panic("oom");
    }

    out.appendSlice(b.allocator,
        \\echo "[live][runner] SUMMARY rc=$overall_rc"
        \\exit "$overall_rc"
        \\
    ) catch @panic("oom");

    return out.toOwnedSlice(b.allocator) catch @panic("oom");
}

const TargetModuleSet = struct {
    htmlparser_compat: *std.Build.Module,
    alldriver: *std.Build.Module,
    oneserial: *std.Build.Module,
    runtime_alloc: *std.Build.Module,
    runtime_io: *std.Build.Module,
    unarr: *std.Build.Module,
    scrapers: *std.Build.Module,
    tui_backend: *std.Build.Module,
    tui_impl: ?*std.Build.Module,
};

fn createTargetModuleSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    strip: bool,
    single_threaded: ?bool,
    omit_frame_pointer: ?bool,
    error_tracing: ?bool,
    pic: ?bool,
    build_options_mod: *std.Build.Module,
    static_libc: bool,
    enable_tui: bool,
    enable_alldriver: bool,
    enable_unarr: bool,
) TargetModuleSet {
    _ = static_libc;
    const htmlparser_dep = b.dependency("htmlparser", .{
        .target = target,
        .optimize = optimize,
    });
    const oneserial_dep = b.dependency("oneserial", .{
        .target = target,
        .optimize = optimize,
    });
    const oneserial_mod = compatibleOneserial(b, oneserial_dep);
    const htmlparser_compat_mod = b.createModule(.{
        .root_source_file = b.path("src/deps/htmlparser_compat.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "htmlparser_upstream", .module = htmlparser_dep.module("html") },
        },
    });
    const alldriver_mod = if (enable_alldriver) blk: {
        const alldriver_dep = b.lazyDependency("alldriver", .{
            .target = target,
            .optimize = optimize,
        }) orelse @panic("enable-alldriver requested but alldriver dependency is unavailable");
        break :blk b.createModule(.{
            .root_source_file = b.path("src/deps/alldriver_compat.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "alldriver_upstream", .module = alldriver_dep.module("alldriver") },
            },
        });
    } else b.createModule(.{
        .root_source_file = b.path("src/deps/alldriver_compat.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    const unarr_mod = if (enable_unarr) blk: {
        const unarr_dep = b.lazyDependency("unarr", .{
            .target = target,
            .optimize = optimize,
        }) orelse @panic("enable-unarr requested but unarr dependency is unavailable");
        break :blk b.createModule(.{
            .root_source_file = b.path("src/deps/unarr_compat.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "unarr_upstream", .module = unarr_dep.module("unarr") },
            },
        });
    } else b.createModule(.{
        .root_source_file = b.path("src/deps/unarr_compat.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    const runtime_alloc_mod = b.createModule(.{
        .root_source_file = b.path("src/alloc/runtime_allocator.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
    });
    const runtime_io_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime_io.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
    });
    const scrapers_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "htmlparser", .module = htmlparser_compat_mod },
            .{ .name = "alldriver", .module = alldriver_mod },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "runtime_alloc", .module = runtime_alloc_mod },
            .{ .name = "runtime_io", .module = runtime_io_mod },
            .{ .name = "unarr", .module = unarr_mod },
        },
    });
    var tui_impl: ?*std.Build.Module = null;
    const tui_backend_mod = if (enable_tui) blk: {
        const libvaxis_dep = b.lazyDependency("libvaxis", .{
            .target = target,
            .optimize = optimize,
        }) orelse @panic("enable-tui requested but libvaxis dependency is unavailable");
        const tui_impl_mod = b.createModule(.{
            .root_source_file = b.path("src/cmd/tui.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
            .imports = &.{
                .{ .name = "scrapers", .module = scrapers_mod },
                .{ .name = "vaxis", .module = libvaxis_dep.module("vaxis") },
                .{ .name = "runtime_alloc", .module = runtime_alloc_mod },
                .{ .name = "runtime_io", .module = runtime_io_mod },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "oneserial", .module = oneserial_mod },
            },
        });
        tui_impl = tui_impl_mod;
        break :blk b.createModule(.{
            .root_source_file = b.path("src/cmd/tui_backend.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "tui_impl", .module = tui_impl_mod },
            },
        });
    } else b.createModule(.{
        .root_source_file = b.path("src/cmd/tui_backend.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    return .{
        .htmlparser_compat = htmlparser_compat_mod,
        .alldriver = alldriver_mod,
        .oneserial = oneserial_mod,
        .runtime_alloc = runtime_alloc_mod,
        .runtime_io = runtime_io_mod,
        .unarr = unarr_mod,
        .scrapers = scrapers_mod,
        .tui_backend = tui_backend_mod,
        .tui_impl = tui_impl,
    };
}

fn compatibleOneserial(b: *std.Build, dependency: *std.Build.Dependency) *std.Build.Module {
    const module = dependency.module("oneserial");
    if (@typeInfo(@TypeOf(@as(std.builtin.Type.Pointer, undefined).alignment)) != .optional) return module;
    // The pinned serializer predates nullable pointer alignment. Keep its
    // wire format and immutable package intact; patch reflection in build output.
    const generated = b.addWriteFiles();
    _ = generated.addCopyDirectory(dependency.path("src"), "src", .{ .exclude_extensions = &.{ "serialization_functions.zig", "shim_allocation.zig" } });
    const files = [_]struct { name: []const u8, sha: []const u8, count: usize }{
        .{ .name = "serialization_functions.zig", .sha = "4fbe8f15c114f4b6b8168a5656b85af733b9e2db2baab169b1d885e1b749496b", .count = 2 },
        .{ .name = "shim_allocation.zig", .sha = "8688c61f7365884dd2cef85676b5709fc99ff1b65320ea65e4a9ec8fff089891", .count = 1 },
    };
    for (files) |file| {
        const path = b.fmt("src/{s}", .{file.name});
        const source = std.Io.Dir.cwd().readFileAlloc(b.graph.io, dependency.path(path).getPath(b), b.allocator, .limited(1024 * 1024)) catch @panic("cannot read pinned oneserial source");
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), file.sha)) @panic("oneserial compatibility source identity changed");
        const old = "std.mem.Alignment.fromByteUnits(pi.alignment)";
        if (std.mem.count(u8, source, old) != file.count) @panic("oneserial alignment patch mismatch");
        var patched = std.mem.replaceOwned(u8, b.allocator, source, old, "std.mem.Alignment.fromByteUnits(pi.alignment orelse @alignOf(pi.child))") catch @panic("oom");
        if (std.mem.eql(u8, file.name, "serialization_functions.zig")) {
            const sentinel = "if (ti.pointer.alignment == 0) @alignOf(ti.pointer.child) else ti.pointer.alignment";
            if (std.mem.count(u8, patched, sentinel) != 1) @panic("oneserial sentinel patch mismatch");
            patched = std.mem.replaceOwned(u8, b.allocator, patched, sentinel, "ti.pointer.alignment orelse @alignOf(ti.pointer.child)") catch @panic("oom");
        }
        if (std.mem.eql(u8, file.name, "serialization_functions.zig")) {
            const replacements = [_][2][]const u8{
                .{ "std.meta.intToEnum(Tag, raw) catch error.InvalidUnionTag", "std.enums.fromInt(Tag, raw) orelse error.InvalidUnionTag" },
                .{ "std.meta.intToEnum(T, raw) catch return error.InvalidEnumTag", "std.enums.fromInt(T, raw) orelse return error.InvalidEnumTag" },
            };
            for (replacements) |pair| patched = std.mem.replaceOwned(u8, b.allocator, patched, pair[0], pair[1]) catch @panic("oom");
        }
        _ = generated.add(path, patched);
    }
    module.root_source_file = generated.getDirectory().path(b, "src/root.zig");
    return module;
}
