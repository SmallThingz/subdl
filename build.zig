const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols from binaries") orelse false;
    const single_threaded = parseToggleBool("single-threaded", b.option([]const u8, "single-threaded", "Single-threaded mode: auto | on | off") orelse "auto");
    const omit_frame_pointer = parseToggleBool("omit-frame-pointer", b.option([]const u8, "omit-frame-pointer", "Frame pointer mode: auto | on | off") orelse "auto");
    const error_tracing = parseToggleBool("error-tracing", b.option([]const u8, "error-tracing", "Error tracing mode: auto | on | off") orelse "auto");
    const pic = parseToggleBool("pic", b.option([]const u8, "pic", "PIC mode: auto | on | off") orelse "auto");
    const live_mode = b.option([]const u8, "live", "Live test mode: off | smoke | named | extensive | all (tui is alias of smoke)") orelse "off";
    const live_providers = b.option([]const u8, "live-providers", "Comma-separated provider filter for live tests, or '*' for all") orelse "*";
    const live_include_captcha = b.option(bool, "live-include-captcha", "Include captcha/cloudflare providers in live test runs") orelse false;
    const live_parallel_on_all = b.option(bool, "live-parallel-on-all", "Run one live subprocess per provider when -Dlive-providers=all/*") orelse true;

    const valid_mode = std.mem.eql(u8, live_mode, "off") or
        std.mem.eql(u8, live_mode, "smoke") or
        std.mem.eql(u8, live_mode, "named") or
        std.mem.eql(u8, live_mode, "extensive") or
        std.mem.eql(u8, live_mode, "tui") or
        std.mem.eql(u8, live_mode, "all");
    if (!valid_mode) {
        @panic("invalid -Dlive value, expected one of: off, smoke, named, extensive, tui, all");
    }

    const live_tests_enabled = !std.mem.eql(u8, live_mode, "off");
    const live_extensive_suite = live_tests_enabled and
        (std.mem.eql(u8, live_mode, "extensive") or std.mem.eql(u8, live_mode, "all"));
    const live_tui_suite = live_tests_enabled and
        (std.mem.eql(u8, live_mode, "smoke") or std.mem.eql(u8, live_mode, "tui") or std.mem.eql(u8, live_mode, "all"));
    const live_named_tests_enabled = live_tests_enabled and
        (std.mem.eql(u8, live_mode, "named") or std.mem.eql(u8, live_mode, "all"));

    const build_options = b.addOptions();
    build_options.addOption(bool, "live_tests_enabled", live_tests_enabled);
    build_options.addOption(bool, "live_extensive_suite", live_extensive_suite);
    build_options.addOption(bool, "live_tui_suite", live_tui_suite);
    build_options.addOption(bool, "live_named_tests_enabled", live_named_tests_enabled);
    build_options.addOption(bool, "live_include_captcha", live_include_captcha);
    build_options.addOption([]const u8, "live_provider_filter", if (live_tests_enabled) live_providers else "");
    const build_options_mod = build_options.createModule();

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
        .optimize = optimize,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "htmlparser_upstream", .module = htmlparser_dep.module("htmlparser") },
        },
    });
    const alldriver_dep = b.dependency("alldriver", .{
        .target = target,
        .optimize = optimize,
    });
    const unarr_dep = b.dependency("unarr", .{
        .target = target,
        .optimize = optimize,
        .static_libc = true,
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
    const subdl_mod = b.addModule("subdl", .{
        .root_source_file = b.path("src/scrapers/subdl.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "htmlparser", .module = htmlparser_compat_mod },
            .{ .name = "alldriver", .module = alldriver_dep.module("alldriver") },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "runtime_alloc", .module = runtime_alloc_mod },
        },
    });
    const scrapers_mod = b.addModule("scrapers", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "htmlparser", .module = htmlparser_compat_mod },
            .{ .name = "alldriver", .module = alldriver_dep.module("alldriver") },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "runtime_alloc", .module = runtime_alloc_mod },
            .{ .name = "unarr", .module = unarr_dep.module("unarr") },
        },
    });

    const cli_exe = b.addExecutable(.{
        .name = "scrapers_cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmd/cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
            .imports = &.{
                .{ .name = "scrapers", .module = scrapers_mod },
                .{ .name = "runtime_alloc", .module = runtime_alloc_mod },
            },
        }),
    });

    const tui_exe = b.addExecutable(.{
        .name = "scrapers_tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmd/tui.zig"),
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
                .{ .name = "vaxis", .module = libvaxis_dep.module("vaxis") },
                .{ .name = "runtime_alloc", .module = runtime_alloc_mod },
            },
        }),
    });

    const cross_targets = [_]struct {
        suffix: []const u8,
        query: std.Target.Query,
    }{
        .{
            .suffix = "x86_64-linux-gnu",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        },
        .{
            .suffix = "aarch64-linux-gnu",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        },
    };

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

    const cross_bin_step = b.step("cross-bin", "Build cross-platform scrapers_cli binaries into zig-out/bin");
    for (cross_targets) |cross| {
        const cross_target = b.resolveTargetQuery(cross.query);
        const cross_htmlparser_dep = b.dependency("htmlparser", .{
            .target = cross_target,
            .optimize = optimize,
        });
        const cross_htmlparser_compat_mod = b.createModule(.{
            .root_source_file = b.path("src/deps/htmlparser_compat.zig"),
            .target = cross_target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
            .imports = &.{
                .{ .name = "htmlparser_upstream", .module = cross_htmlparser_dep.module("htmlparser") },
            },
        });
        const cross_alldriver_dep = b.dependency("alldriver", .{
            .target = cross_target,
            .optimize = optimize,
        });
        const cross_unarr_dep = b.dependency("unarr", .{
            .target = cross_target,
            .optimize = optimize,
            .static_libc = true,
        });
        const cross_runtime_alloc_mod = b.createModule(.{
            .root_source_file = b.path("src/alloc/runtime_allocator.zig"),
            .target = cross_target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
        });
        const cross_scrapers_mod = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = cross_target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
            .imports = &.{
                .{ .name = "htmlparser", .module = cross_htmlparser_compat_mod },
                .{ .name = "alldriver", .module = cross_alldriver_dep.module("alldriver") },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "runtime_alloc", .module = cross_runtime_alloc_mod },
                .{ .name = "unarr", .module = cross_unarr_dep.module("unarr") },
            },
        });

        const cross_exe = b.addExecutable(.{
            .name = b.fmt("scrapers_cli-{s}", .{cross.suffix}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/cmd/cli.zig"),
                .target = cross_target,
                .optimize = optimize,
                .strip = strip,
                .single_threaded = single_threaded,
                .omit_frame_pointer = omit_frame_pointer,
                .error_tracing = error_tracing,
                .pic = pic,
                .imports = &.{
                    .{ .name = "scrapers", .module = cross_scrapers_mod },
                    .{ .name = "runtime_alloc", .module = cross_runtime_alloc_mod },
                },
            }),
        });
        const install_cross = b.addInstallArtifact(cross_exe, .{});
        cross_bin_step.dependOn(&install_cross.step);
    }

    const subdl_mod_tests = b.addTest(.{
        .root_module = subdl_mod,
    });
    const run_subdl_mod_tests = b.addRunArtifact(subdl_mod_tests);

    const scrapers_mod_tests = b.addTest(.{
        .root_module = scrapers_mod,
    });
    const run_scrapers_mod_tests = b.addRunArtifact(scrapers_mod_tests);
    const run_scrapers_mod_tests_live = b.addSystemCommand(&.{ "bash", "-lc", "exec \"$1\"", "_" });
    run_scrapers_mod_tests_live.addFileArg(scrapers_mod_tests.getEmittedBin());
    run_scrapers_mod_tests_live.stdio = .inherit;

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

    const test_live_single_step = b.step("test-live-single", "Run live tests for the current provider filter");
    test_live_single_step.dependOn(&run_scrapers_mod_tests_live.step);

    const test_live_step = b.step("test-live", "Run live tests using -Dlive, -Dlive-providers, -Dlive-include-captcha");
    if (live_tests_enabled and live_parallel_on_all and isAllLiveProviderSelection(live_providers)) {
        const include_captcha_arg = if (live_include_captcha) "true" else "false";
        const script = makeParallelLiveRunScript(b, include_captcha_arg);
        const fanout_cmd = b.addSystemCommand(&.{ "bash", "-lc", script, "_test_bin_" });
        fanout_cmd.setCwd(b.path("."));
        fanout_cmd.addFileArg(scrapers_mod_tests.getEmittedBin());
        test_live_step.dependOn(&fanout_cmd.step);
    } else {
        test_live_step.dependOn(&run_scrapers_mod_tests_live.step);
    }

    const test_live_all_step = b.step("test-live-all", "Run all providers live (including captcha providers)");
    const live_all_cmd = b.addSystemCommand(&.{
        "zig",
        "build",
        "test-live",
        "-Dlive=all",
        "-Dlive-providers=*",
        "-Dlive-include-captcha=true",
    });
    live_all_cmd.setCwd(b.path("."));
    test_live_all_step.dependOn(&live_all_cmd.step);
}

const LiveProviderTarget = struct {
    name: []const u8,
    captcha: bool = false,
};

const live_provider_targets = [_]LiveProviderTarget{
    .{ .name = "subdl.com" },
    .{ .name = "isubtitles.org" },
    .{ .name = "moviesubtitles.org" },
    .{ .name = "moviesubtitlesrt.com" },
    .{ .name = "my-subs.co" },
    .{ .name = "podnapisi.net" },
    .{ .name = "subtitlecat.com" },
    .{ .name = "subsource.net" },
    .{ .name = "tvsubtitles.net" },
    .{ .name = "opensubtitles.org", .captcha = true },
    .{ .name = "opensubtitles.com", .captcha = true },
    .{ .name = "yifysubtitles.ch", .captcha = true },
};

fn isAllLiveProviderSelection(raw_filter: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_filter, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (std.mem.eql(u8, trimmed, "*")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return true;
    return false;
}

fn makeParallelLiveRunScript(
    b: *std.Build,
    include_captcha_arg: []const u8,
) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(b.allocator);
    const w = out.writer(b.allocator);

    w.writeAll(
        \\set -euo pipefail
        \\test_bin="$1"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() { rm -rf "$tmpdir"; }
        \\trap cleanup EXIT
        \\declare -a names=()
        \\declare -a pids=()
        \\
    ) catch @panic("oom");

    for (live_provider_targets) |target_info| {
        if (target_info.captcha and !std.mem.eql(u8, include_captcha_arg, "true")) continue;
        w.print(
            \\echo "[live][runner] START {s}"
            \\
            \\(
            \\  set -o pipefail
            \\  SCRAPERS_LIVE_PROVIDER_FILTER="{s}" SCRAPERS_LIVE_INCLUDE_CAPTCHA="{s}" "$test_bin" 2>&1 | sed -u 's/^/[live][{s}] /'
            \\  rc=${{PIPESTATUS[0]}}
            \\  echo "$rc" > "$tmpdir/{s}.rc"
            \\  echo "[live][runner] END {s} rc=$rc"
            \\  exit "$rc"
            \\) &
            \\names+=("{s}")
            \\pids+=("$!")
            \\
        , .{
            target_info.name,
            target_info.name,
            include_captcha_arg,
            target_info.name,
            target_info.name,
            target_info.name,
            target_info.name,
        }) catch @panic("oom");
    }

    w.writeAll(
        \\(
        \\  while true; do
        \\    active_names=""
        \\    for i in "${!pids[@]}"; do
        \\      pid="${pids[$i]}"
        \\      name="${names[$i]}"
        \\      if kill -0 "$pid" 2>/dev/null; then
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
        \\  if ! wait "$pid"; then
        \\    overall_rc=1
        \\  fi
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
        \\if kill -0 "$monitor_pid" 2>/dev/null; then
        \\  kill "$monitor_pid" 2>/dev/null || true
        \\fi
        \\wait "$monitor_pid" 2>/dev/null || true
        \\exit "$overall_rc"
        \\
    ) catch @panic("oom");

    return out.toOwnedSlice(b.allocator) catch @panic("oom");
}

fn parseToggleBool(option_name: []const u8, raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "auto")) return null;
    if (std.ascii.eqlIgnoreCase(raw, "on") or std.ascii.eqlIgnoreCase(raw, "true")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "off") or std.ascii.eqlIgnoreCase(raw, "false")) return false;
    std.debug.panic("invalid -D{s} value '{s}', expected: auto|on|off", .{ option_name, raw });
}
