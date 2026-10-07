const std = @import("std");
const provider_registry = @import("src/provider_registry.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize_opt = b.option(std.lang.Optimize, "optimize", "Optimization mode");
    const release_optimize: ?std.lang.Optimize = switch (b.graph.release_mode) {
        .off => null,
        .any, .fast => .fast,
        .safe => .safe,
        .small => .small,
    };
    const requested_optimize = optimize_opt orelse release_optimize;
    // The primary artifact is an interactive terminal app. Debug mode makes
    // libvaxis walk and compare the full terminal grid with safety checks on
    // every navigation frame, which is visibly sluggish even for modest lists.
    // Keep Debug available explicitly via -Doptimize=debug, but make normal
    // run/install builds use the performance mode users actually experience.
    const optimize = requested_optimize orelse .fast;
    const test_optimize = requested_optimize orelse .debug;
    const all_targets_optimize = requested_optimize orelse .fast;
    const strip_opt = b.option(bool, "strip", "Strip debug symbols from binaries");
    const strip = strip_opt orelse false;
    const all_targets_strip = strip_opt orelse true;
    const single_threaded = b.option(bool, "single-threaded", "Force single-threaded mode");
    // The shipped executable uses Io.Threaded for concurrent fetch/deadline
    // work. Reject root builds before configuring artifacts, while allowing
    // library consumers to supply their own compatible runtime through the API.
    if ((single_threaded orelse false) and b.dep_prefix.len == 0) {
        std.debug.print("scrapers executable and test targets require threaded I/O for request deadlines; omit -Dsingle-threaded=true\n", .{});
        return error.SingleThreadedExecutableUnsupported;
    }
    const omit_frame_pointer = b.option(bool, "omit-frame-pointer", "Force frame pointer omission mode");
    const error_tracing = b.option(bool, "error-tracing", "Force error tracing mode");
    const pic = b.option(bool, "pic", "Force PIC mode");
    const llvm = b.option(bool, "llvm", "Use LLVM codegen backend") orelse true;
    const enable_tui = b.option(bool, "enable-tui", "Enable TUI support via libvaxis") orelse true;
    const enable_alldriver = b.option(bool, "enable-alldriver", "Enable local Chromium session handoff") orelse false;
    const enable_unarr = b.option(bool, "enable-unarr", "Enable archive extraction support via unarr") orelse true;
    const live_mode = b.option([]const u8, "live", "Live test mode: off | smoke | named | extensive | all") orelse "off";
    const live_providers = b.option([]const u8, "live-providers", "Comma-separated provider filter for live tests, or '*' for all") orelse "*";
    const live_parallel_on_all = b.option(bool, "live-parallel-on-all", "Run one live subprocess per provider when -Dlive-providers=all/*") orelse true;
    const live_max_jobs = b.option(u32, "live-max-jobs", "Maximum concurrent live provider subprocesses") orelse 4;
    if (live_max_jobs == 0) @panic("live-max-jobs must be positive");
    const live_timeout_option = b.option(u32, "live-timeout-seconds", "Hard deadline for a live subprocess (overrides provider defaults)");
    const live_timeout_seconds = live_timeout_option orelse 60;
    if (live_timeout_seconds == 0) @panic("live-timeout-seconds must be positive");
    validateLiveProviderFilter(live_providers);
    // Convenience targets configure their child build explicitly. Their outer
    // build remains in `off` mode and must not be narrowed (or rejected) by an
    // ambient filter intended for direct live-test execution.
    const effective_live_filter = if (std.mem.eql(u8, live_mode, "off"))
        live_providers
    else
        b.graph.environ_map.get("SCRAPERS_LIVE_PROVIDER_FILTER") orelse
            b.graph.environ_map.get("SCRAPERS_LIVE_PROVIDERS") orelse live_providers;
    validateLiveProviderFilter(effective_live_filter);
    const non_fanout_timeout_seconds = if (live_timeout_option != null)
        live_timeout_seconds
    else
        defaultLiveSubprocessTimeout(effective_live_filter, live_timeout_seconds);

    const valid_mode = std.mem.eql(u8, live_mode, "off") or
        std.mem.eql(u8, live_mode, "smoke") or
        std.mem.eql(u8, live_mode, "named") or
        std.mem.eql(u8, live_mode, "extensive") or
        std.mem.eql(u8, live_mode, "all");
    if (!valid_mode) {
        @panic("invalid -Dlive value, expected one of: off, smoke, named, extensive, all");
    }

    const live_tests_enabled = !std.mem.eql(u8, live_mode, "off");
    if (live_tests_enabled and (!target.query.isNative() or target.result.os.tag != .linux)) {
        @panic("live tests require a native Linux target with Bash 4.3+, GNU timeout, mkfifo, and flock");
    }
    const live_probe_stats = liveProbeSelectionStats(effective_live_filter, live_mode);
    if (live_tests_enabled) {
        reportLiveProbeSelection(live_mode, live_probe_stats);
        if (live_probe_stats.runnable == 0) {
            std.debug.panic(
                "live provider selection has no {s} probes; use -Dlive=smoke|all or select a provider with that suite",
                .{live_mode},
            );
        }
    }
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
    build_options.addOption([]const u8, "active_live_provider_filter", activeLiveProviderFilter(b));
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
        enable_unarr,
    );
    _ = b.addModule("subdl", .{
        .root_source_file = b.path("src/subdl_compat.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "scrapers", .module = host_modules.scrapers },
        },
    });
    // Public modules must exist even during a dependency's cold-cache
    // configuration pass. A parent package may call dependency.module()
    // immediately after this build script returns; propagate the lazy-fetch
    // signal only after publishing both supported module names.
    if (host_modules.lazy_dependencies_pending) return error.LazyDependencyNeeded;
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
    }{
        .{
            .suffix = "x86_64-linux-gnu",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        },
        .{
            .suffix = "aarch64-linux-gnu",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        },
        .{
            .suffix = "x86_64-windows-gnu",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
        },
        .{
            .suffix = "x86_64-macos-none",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .macos },
        },
        .{
            .suffix = "aarch64-macos-none",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .macos },
        },
    };

    b.installArtifact(app_exe);
    const install_project_licence = b.addInstallFile(
        b.path("LICENCE"),
        "share/licenses/scrapers/LICENCE",
    );
    const install_project_copying = b.addInstallFile(
        b.path("COPYING"),
        "share/licenses/scrapers/COPYING",
    );
    const install_libvaxis_license = b.addInstallFile(
        b.path("vendor/libvaxis/LICENSE"),
        "share/licenses/scrapers/libvaxis/LICENSE",
    );
    const install_zigimg_license = b.addInstallFile(
        b.path("vendor/zigimg/LICENSE"),
        "share/licenses/scrapers/zigimg/LICENSE",
    );
    const install_retained_notices = b.addInstallDirectory(.{
        .source_dir = b.path("THIRD_PARTY_LICENSES"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/scrapers/third-party",
    });
    const install_uucode_notices = b.addInstallDirectory(.{
        .source_dir = b.path("vendor/libvaxis/THIRD_PARTY_LICENSES/uucode"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/scrapers/third-party/uucode",
    });
    const install_third_party_inventory = b.addInstallFile(
        b.path("THIRD_PARTY_NOTICES.md"),
        "share/doc/scrapers/THIRD_PARTY_NOTICES.md",
    );
    const install_vendor_provenance = b.addInstallFile(
        b.path("vendor/README.md"),
        "share/doc/scrapers/VENDOR_PROVENANCE.md",
    );
    const install_legal_metadata_step = b.step(
        "install-legal-metadata",
        "Install project license texts and third-party notices",
    );
    install_legal_metadata_step.dependOn(&install_project_licence.step);
    install_legal_metadata_step.dependOn(&install_project_copying.step);
    install_legal_metadata_step.dependOn(&install_libvaxis_license.step);
    install_legal_metadata_step.dependOn(&install_zigimg_license.step);
    install_legal_metadata_step.dependOn(&install_retained_notices.step);
    install_legal_metadata_step.dependOn(&install_uucode_notices.step);
    install_legal_metadata_step.dependOn(&install_third_party_inventory.step);
    install_legal_metadata_step.dependOn(&install_vendor_provenance.step);
    b.getInstallStep().dependOn(install_legal_metadata_step);

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
    all_targets_step.dependOn(install_legal_metadata_step);
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
            false,
            enable_tui,
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
        false,
        enable_tui,
        enable_unarr,
    );
    const test_subdl_mod = b.createModule(.{
        // Test the module consumers actually receive. The canonical scraper
        // graph is already covered through test_modules.scrapers; this facade
        // additionally verifies every historical re-export.
        .root_source_file = b.path("src/subdl_compat.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
        .imports = &.{
            .{ .name = "scrapers", .module = test_modules.scrapers },
        },
    });
    const test_app_mod = b.createModule(.{
        .root_source_file = b.path("src/cmd/main.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = true,
        .single_threaded = single_threaded,
        .omit_frame_pointer = omit_frame_pointer,
        .error_tracing = error_tracing,
        .pic = pic,
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
    const browser_smoke_enabled = envFlagEnabled(b, "SUBDL_CHROMIUM_SMOKE") or
        envFlagEnabled(b, "SUBDL_CHROMIUM_HEADED_SMOKE");
    run_subdl_mod_tests.has_side_effects = browser_smoke_enabled;

    const scrapers_mod_tests = b.addTest(.{
        .root_module = test_modules.scrapers,
        .use_llvm = llvm,
    });
    const run_scrapers_mod_tests = b.addRunArtifact(scrapers_mod_tests);
    run_scrapers_mod_tests.has_side_effects = browser_smoke_enabled;
    const run_scrapers_mod_tests_live = b.addSystemCommand(&.{
        "timeout", "--signal=TERM", "--kill-after=5s", b.fmt("{d}s", .{non_fanout_timeout_seconds}),
    });
    run_scrapers_mod_tests_live.addFileArg(scrapers_mod_tests.getEmittedBin());
    run_scrapers_mod_tests_live.stdio = .inherit;

    const app_tests = b.addTest(.{
        .root_module = test_app_mod,
        .use_llvm = llvm,
    });
    const run_app_tests = b.addRunArtifact(app_tests);
    run_app_tests.has_side_effects = browser_smoke_enabled;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_subdl_mod_tests.step);
    test_step.dependOn(&run_scrapers_mod_tests.step);
    test_step.dependOn(&run_app_tests.step);
    // Build-script helpers have ordinary `test` declarations below, but the
    // build runner itself is not compiled in test mode. Compile build.zig once
    // as a host test artifact so these assertions run without invoking a
    // recursive `zig build`.
    const build_logic_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
        }),
        .use_llvm = llvm,
    }));
    test_step.dependOn(&build_logic_tests.step);
    const html_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_modules.htmlparser_compat, .use_llvm = llvm }));
    test_step.dependOn(&html_tests.step);
    b.step("test-html", "Check parser replacement ownership").dependOn(&html_tests.step);
    const backend_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_modules.tui_backend, .use_llvm = llvm }));
    test_step.dependOn(&backend_tests.step);
    if (test_modules.tui_impl) |tui_mod| {
        const tui_tests = b.addTest(.{ .root_module = tui_mod, .use_llvm = llvm });
        const run_tui_tests = b.addRunArtifact(tui_tests);
        run_tui_tests.has_side_effects = browser_smoke_enabled;
        test_step.dependOn(&run_tui_tests.step);
        const test_tui_step = b.step("test-tui", "Check terminal navigation, persistence and cancellation");
        test_tui_step.dependOn(&run_tui_tests.step);
    }

    const http_fixture = b.addExecutable(.{
        .name = "http-transport-test",
        .use_llvm = llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/http_transport_test.zig"),
            .target = target,
            .optimize = test_optimize,
            .single_threaded = single_threaded,
            .omit_frame_pointer = omit_frame_pointer,
            .error_tracing = error_tracing,
            .pic = pic,
            .imports = &.{
                .{ .name = "scrapers", .module = test_modules.scrapers },
                .{ .name = "runtime_io", .module = test_modules.runtime_io },
            },
        }),
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
    // The HTTP integration gate remains explicit: Python directly runs its
    // fixture. Cross-target tests stay independent of host-only runners.

    const live_runner_contract_filter = "subdl.com,opensubtitles.com,sub-scene.com";
    const live_runner_contract_script = makeParallelLiveRunScript(
        b,
        30,
        2,
        live_runner_contract_filter,
        "smoke",
        liveProbeSelectionStats(live_runner_contract_filter, "smoke"),
        false,
    );
    const live_runner_named_contract_filter = "subdl.com,isubtitles.org";
    const live_runner_named_contract_script = makeParallelLiveRunScript(
        b,
        30,
        1,
        live_runner_named_contract_filter,
        "named",
        liveProbeSelectionStats(live_runner_named_contract_filter, "named"),
        false,
    );
    const live_runner_contract_cmd = b.addSystemCommand(&.{"bash"});
    live_runner_contract_cmd.addFileArg(b.path("tools/test_live_runner.sh"));
    live_runner_contract_cmd.addArg(live_runner_contract_script);
    live_runner_contract_cmd.addArg(live_runner_named_contract_script);
    live_runner_contract_cmd.removeEnvironmentVariable("BASH_ENV");
    live_runner_contract_cmd.removeEnvironmentVariable("ENV");
    live_runner_contract_cmd.removeEnvironmentVariable("LIVE_RUNNER_CONTRACT_FIXTURE");
    live_runner_contract_cmd.removeEnvironmentVariable("LIVE_RUNNER_FIXTURE_MODE");
    live_runner_contract_cmd.removeEnvironmentVariable("LIVE_RUNNER_FIXTURE_TARGET");
    live_runner_contract_cmd.removeEnvironmentVariable("LIVE_RUNNER_FIXTURE_MARKER");
    live_runner_contract_cmd.setCwd(b.path("."));
    const live_runner_contract_step = b.step(
        "test-live-runner",
        "Exercise bounded live fanout status/probe markers and cleanup contracts",
    );
    if (target.query.isNative() and target.result.os.tag == .linux) {
        live_runner_contract_step.dependOn(&live_runner_contract_cmd.step);
        test_step.dependOn(&live_runner_contract_cmd.step);
    } else {
        live_runner_contract_step.dependOn(&b.addFail("test-live-runner requires a native Linux target").step);
    }

    const test_live_step = b.step("test-live", "Run live tests using -Dlive and -Dlive-providers");
    if (!live_tests_enabled) {
        test_live_step.dependOn(&b.addFail("test-live requires -Dlive=smoke|named|extensive|all").step);
    } else if (shouldUseLiveRunner(effective_live_filter)) {
        const runner_max_jobs = liveRunnerMaxJobs(effective_live_filter, live_parallel_on_all, live_max_jobs);
        const script = makeParallelLiveRunScript(
            b,
            live_timeout_seconds,
            runner_max_jobs,
            effective_live_filter,
            live_mode,
            live_probe_stats,
            live_timeout_option == null,
        );
        // Materialize the runner instead of passing it to `bash -c`: a smoke/all
        // script can exceed Linux's per-argument MAX_ARG_STRLEN as provider
        // blocks are expanded. A plain non-login shell has no profile-created
        // jobs; drop non-interactive startup hooks so every job remains owned.
        const live_runner_files = b.addWriteFiles();
        const live_runner_file = live_runner_files.add("live-runner.sh", script);
        const fanout_cmd = b.addSystemCommand(&.{"bash"});
        fanout_cmd.addFileArg(live_runner_file);
        fanout_cmd.removeEnvironmentVariable("BASH_ENV");
        fanout_cmd.removeEnvironmentVariable("ENV");
        fanout_cmd.setCwd(b.path("."));
        fanout_cmd.addFileArg(scrapers_mod_tests.getEmittedBin());
        test_live_step.dependOn(&fanout_cmd.step);
    } else {
        test_live_step.dependOn(&run_scrapers_mod_tests_live.step);
    }

    const test_live_single_step = b.step("test-live-single", "Run live tests for the current provider filter");
    if (live_tests_enabled) {
        // Keep the compatibility step on the same marker-validated and
        // signal-supervised path as test-live.
        test_live_single_step.dependOn(test_live_step);
    } else {
        test_live_single_step.dependOn(&b.addFail("test-live-single requires -Dlive=smoke|named|extensive|all").step);
    }

    const test_live_all_step = b.step("test-live-all", "Run one application smoke per supported media path for every provider");
    const live_all_cmd = addLiveConvenienceCommand(b, "*", "smoke");
    live_all_cmd.setCwd(b.path("."));
    test_live_all_step.dependOn(&live_all_cmd.step);

    const test_live_active_step = b.step("test-live-active", "Run one application smoke per supported media path for every active CLI/TUI provider");
    const live_active_cmd = addLiveConvenienceCommand(b, "active", "smoke");
    live_active_cmd.setCwd(b.path("."));
    test_live_active_step.dependOn(&live_active_cmd.step);
}

fn envFlagEnabled(b: *std.Build, name: []const u8) bool {
    const value = b.graph.environ_map.get(name) orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn activeLiveProviderFilter(b: *std.Build) []const u8 {
    var filter: std.ArrayListUnmanaged(u8) = .empty;
    for (provider_registry.all) |info| {
        if (!info.active) continue;
        if (filter.items.len != 0) filter.append(b.allocator, ',') catch @panic("oom");
        filter.appendSlice(b.allocator, info.live_name) catch @panic("oom");
    }
    return filter.toOwnedSlice(b.allocator) catch @panic("oom");
}

fn addLiveConvenienceCommand(b: *std.Build, selection: []const u8, mode: []const u8) *std.Build.Step.Run {
    const command = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test-live", b.fmt("-Dlive={s}", .{mode}), b.fmt("-Dlive-providers={s}", .{selection}) });
    // The convenience target defines its provider set even when the parent
    // environment contains an ad-hoc filter. Live artifacts must be native,
    // so target and CPU options deliberately stay on the outer build only.
    command.setEnvironmentVariable("SCRAPERS_LIVE_PROVIDER_FILTER", selection);
    command.removeEnvironmentVariable("SCRAPERS_LIVE_PROVIDERS");
    // --release is a graph option, so it is absent from user_input_options.
    // Forward it separately; an explicit -Doptimize still wins in the child.
    switch (b.graph.release_mode) {
        .off => {},
        .any => command.addArg("--release"),
        .fast => command.addArg("--release=fast"),
        .safe => command.addArg("--release=safe"),
        .small => command.addArg("--release=small"),
    }
    var options = b.user_input_options.iterator();
    while (options.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.eql(u8, name, "live") or
            std.mem.eql(u8, name, "live-providers") or
            std.mem.eql(u8, name, "target") or
            std.mem.eql(u8, name, "cpu")) continue;
        switch (entry.value_ptr.*) {
            .flag => command.addArg(b.fmt("-D{s}", .{name})),
            .scalar => |value| command.addArg(b.fmt("-D{s}={s}", .{ name, value })),
            .list => |values| for (values.items) |value| command.addArg(b.fmt("-D{s}={s}", .{ name, value })),
            else => @panic("unsupported nested live build option"),
        }
    }
    // Zig 0.17 no longer exposes the outer build's job limit to build scripts.
    // Keep the nested convenience build serialized instead of silently
    // oversubscribing a caller that requested `-j1`.
    command.addArg("-j1");
    return command;
}

fn validateLiveProviderFilter(raw_filter: []const u8) void {
    const trimmed = std.mem.trim(u8, raw_filter, " \t\r\n");
    if (trimmed.len == 0 or isAllLiveProviderSelection(trimmed) or isActiveLiveProviderSelection(trimmed)) return;
    var tokens = std.mem.splitScalar(u8, trimmed, ',');
    var count: usize = 0;
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;
        count += 1;
        if (isAllLiveProviderSelection(token)) {
            @panic("'*' or 'all' must be the only live provider filter token");
        }
        if (isActiveLiveProviderSelection(token)) continue;
        var matched_count: usize = 0;
        for (provider_registry.all) |info| {
            if (liveProviderNameContains(info.id, token) or liveProviderNameContains(info.live_name, token)) {
                matched_count += 1;
            }
        }
        if (matched_count == 0) std.debug.panic("unknown live provider filter: {s}", .{token});
        if (matched_count > 1) std.debug.panic("ambiguous live provider filter: {s}; use a full provider name", .{token});
    }
    if (count == 0) @panic("live provider filter contains no provider names");
}

test "live convenience commands retain release mode and isolate provider selection" {
    const cases = [_]struct { mode: std.Build.ReleaseMode, arg: ?[]const u8 }{
        .{ .mode = .off, .arg = null },
        .{ .mode = .any, .arg = "--release" },
        .{ .mode = .fast, .arg = "--release=fast" },
        .{ .mode = .safe, .arg = "--release=safe" },
        .{ .mode = .small, .arg = "--release=small" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var graph: std.Build.Graph = .{
            .io = std.testing.io,
            .arena = allocator,
            .zig_exe = "zig",
            .environ_map = .init(allocator),
            .host = .{ .query = .{}, .result = @import("builtin").target },
            .release_mode = case.mode,
            .generated_files = .empty,
            .wip_configuration = .init(allocator),
        };
        try graph.environ_map.put("SCRAPERS_LIVE_PROVIDER_FILTER", "invalid");
        try graph.environ_map.put("SCRAPERS_LIVE_PROVIDERS", "invalid");
        const b = try std.Build.create(&graph, .cwd(), &.{});
        try b.user_input_options.put(allocator, "optimize", .{ .scalar = "debug" });
        try b.user_input_options.put(allocator, "target", .{ .scalar = "aarch64-linux-gnu" });
        try b.user_input_options.put(allocator, "cpu", .{ .scalar = "baseline" });
        try b.user_input_options.put(allocator, "live", .{ .scalar = "all" });
        try b.user_input_options.put(allocator, "live-providers", .{ .scalar = "subdl.com" });
        const command = addLiveConvenienceCommand(b, "active", "smoke");
        var args: std.ArrayList([]const u8) = .empty;
        for (command.argv.items) |arg| try args.append(allocator, arg.bytes);
        // Inspect the actual generated child command without compiling or
        // executing any provider tests. Explicit optimization still reaches
        // the child so it can override the inherited release preference.
        try std.testing.expectEqual(@as(usize, if (case.arg != null) 8 else 7), args.items.len);
        try std.testing.expectEqualStrings("-Dlive=smoke", args.items[3]);
        try std.testing.expectEqualStrings("-Dlive-providers=active", args.items[4]);
        var saw_optimize = false;
        var saw_release = false;
        for (args.items) |arg| {
            saw_optimize = saw_optimize or std.mem.eql(u8, arg, "-Doptimize=debug");
            if (case.arg) |expected| saw_release = saw_release or std.mem.eql(u8, arg, expected);
        }
        try std.testing.expect(saw_optimize);
        try std.testing.expectEqual(case.arg != null, saw_release);
        try std.testing.expectEqualStrings("-j1", args.items[args.items.len - 1]);
        try std.testing.expectEqualStrings("active", command.getEnvMap().get("SCRAPERS_LIVE_PROVIDER_FILTER").?);
        try std.testing.expect(command.getEnvMap().get("SCRAPERS_LIVE_PROVIDERS") == null);
    }
}

fn liveProviderNameContains(name: []const u8, token: []const u8) bool {
    if (token.len > name.len) return false;
    for (0..name.len - token.len + 1) |start| {
        for (token, name[start..][0..token.len]) |a, c| {
            const normalized_a = if (a == '.' or a == '-') '_' else std.ascii.toLower(a);
            const normalized_c = if (c == '.' or c == '-') '_' else std.ascii.toLower(c);
            if (normalized_a != normalized_c) break;
        } else return true;
    }
    return false;
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

fn liveProviderMatchesSelection(info: provider_registry.Info, raw_filter: []const u8) bool {
    if (isAllLiveProviderSelection(raw_filter)) return true;
    if (isActiveLiveProviderSelection(raw_filter)) return info.active;

    var tokens = std.mem.splitScalar(u8, raw_filter, ',');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;
        if (isActiveLiveProviderSelection(token)) {
            if (info.active) return true;
            continue;
        }
        if (liveProviderNameContains(info.id, token) or liveProviderNameContains(info.live_name, token)) return true;
    }
    return false;
}

fn liveProviderSelectionCount(raw_filter: []const u8) usize {
    var count: usize = 0;
    for (provider_registry.all) |info| {
        if (liveProviderMatchesSelection(info, raw_filter)) count += 1;
    }
    return count;
}

const LiveProbeSelectionStats = struct {
    selected: usize = 0,
    runnable: usize = 0,
    no_probe: usize = 0,
};

fn providerHasLiveProbeInMode(info: provider_registry.Info, live_mode: []const u8) bool {
    if (std.mem.eql(u8, live_mode, "smoke") or std.mem.eql(u8, live_mode, "all")) return true;
    if (std.mem.eql(u8, live_mode, "named")) return info.has_named_live_probe;
    if (std.mem.eql(u8, live_mode, "extensive")) return info.has_extensive_live_probe;
    return false;
}

fn liveProbeSelectionStats(raw_filter: []const u8, live_mode: []const u8) LiveProbeSelectionStats {
    var stats: LiveProbeSelectionStats = .{};
    for (provider_registry.all) |info| {
        if (!liveProviderMatchesSelection(info, raw_filter)) continue;
        stats.selected += 1;
        if (providerHasLiveProbeInMode(info, live_mode)) {
            stats.runnable += 1;
        } else {
            stats.no_probe += 1;
        }
    }
    return stats;
}

fn reportLiveProbeSelection(live_mode: []const u8, stats: LiveProbeSelectionStats) void {
    std.debug.print(
        "[live][runner] PLAN mode={s} selected={d} runnable={d} no_probe={d}\n",
        .{ live_mode, stats.selected, stats.runnable, stats.no_probe },
    );
}

fn shouldUseLiveRunner(raw_filter: []const u8) bool {
    // The generated runner provides the probe-execution contract and signal
    // cleanup even for one-provider and explicitly serialized selections.
    return liveProviderSelectionCount(raw_filter) > 0;
}

fn liveRunnerMaxJobs(raw_filter: []const u8, parallel_on_all: bool, requested_max_jobs: u32) u32 {
    if (isAllLiveProviderSelection(raw_filter) and !parallel_on_all) return 1;
    return requested_max_jobs;
}

fn defaultLiveSubprocessTimeout(raw_filter: []const u8, fallback_seconds: u32) u32 {
    var total: u32 = 0;
    for (provider_registry.all) |info| {
        if (!liveProviderMatchesSelection(info, raw_filter)) continue;
        total = std.math.add(u32, total, info.live_timeout_seconds orelse fallback_seconds) catch return std.math.maxInt(u32);
    }
    return if (total == 0) fallback_seconds else total;
}

test "mixed active live provider filters validate" {
    validateLiveProviderFilter("active,tvsubtitles.net");
    validateLiveProviderFilter("ACTIVE,TVSUBTITLES_NET");
}

test "mixed active live provider timeout expands active exactly once" {
    const fallback: u32 = 60;
    const active_timeout = defaultLiveSubprocessTimeout("active", fallback);
    const inactive_timeout = provider_registry.info(.tvsubtitles_net).live_timeout_seconds orelse fallback;
    const expected_mixed_timeout = std.math.add(u32, active_timeout, inactive_timeout) catch unreachable;

    try std.testing.expectEqual(
        expected_mixed_timeout,
        defaultLiveSubprocessTimeout("active,tvsubtitles.net", fallback),
    );
    try std.testing.expectEqual(
        expected_mixed_timeout,
        defaultLiveSubprocessTimeout("ACTIVE,TVSUBTITLES_NET", fallback),
    );
    try std.testing.expectEqual(
        active_timeout,
        defaultLiveSubprocessTimeout("active,subdl.com", fallback),
    );
}

test "live filters use the validated runner for every distinct registry selection" {
    try std.testing.expectEqual(@as(usize, provider_registry.active_count), liveProviderSelectionCount("active"));
    try std.testing.expectEqual(@as(usize, provider_registry.active_count + 1), liveProviderSelectionCount("active,tvsubtitles.net"));
    try std.testing.expectEqual(@as(usize, provider_registry.active_count), liveProviderSelectionCount("active,subdl.com,subdl_com"));
    try std.testing.expectEqual(@as(usize, 1), liveProviderSelectionCount("tvsubtitles.net,tvsubtitles_net"));
    try std.testing.expect(shouldUseLiveRunner("subdl.com,tvsubtitles.net"));
    try std.testing.expect(shouldUseLiveRunner("tvsubtitles.net,tvsubtitles_net"));
    try std.testing.expect(shouldUseLiveRunner("active,tvsubtitles.net"));
    try std.testing.expect(shouldUseLiveRunner("*"));
    try std.testing.expectEqual(@as(u32, 4), liveRunnerMaxJobs("*", true, 4));
    try std.testing.expectEqual(@as(u32, 1), liveRunnerMaxJobs("*", false, 4));
    try std.testing.expectEqual(@as(u32, 4), liveRunnerMaxJobs("active", false, 4));
}

test "live probe capability accounting keeps aliases and suite sets honest" {
    const active_named = liveProbeSelectionStats("active", "named");
    try std.testing.expectEqual(@as(usize, 46), active_named.selected);
    try std.testing.expectEqual(@as(usize, 43), active_named.runnable);
    try std.testing.expectEqual(@as(usize, 3), active_named.no_probe);

    const all_named = liveProbeSelectionStats("*", "named");
    try std.testing.expectEqual(@as(usize, 53), all_named.selected);
    try std.testing.expectEqual(@as(usize, 48), all_named.runnable);
    try std.testing.expectEqual(@as(usize, 5), all_named.no_probe);

    const inactive_named = liveProbeSelectionStats(
        "opensubtitles.org,moviesubtitlesrt.com,podnapisi.net,my-subs.co,tvsubtitles.net,greek-subtitles.com,animesubtitle.ir",
        "named",
    );
    try std.testing.expectEqual(@as(usize, 7), inactive_named.selected);
    try std.testing.expectEqual(@as(usize, 5), inactive_named.runnable);
    try std.testing.expectEqual(@as(usize, 2), inactive_named.no_probe);

    const extensive = liveProbeSelectionStats(
        "subdl.com,isubtitles.org,moviesubtitles.org,moviesubtitlesrt.com,my-subs.co,podnapisi.net,subtitlecat.com,subsource.net,sub-scene.com,tvsubtitles.net",
        "extensive",
    );
    try std.testing.expectEqual(@as(usize, 10), extensive.selected);
    try std.testing.expectEqual(@as(usize, 10), extensive.runnable);
    try std.testing.expectEqual(@as(usize, 0), extensive.no_probe);

    const mixed_named = liveProbeSelectionStats("subdl.com,isubtitles.org", "named");
    try std.testing.expectEqual(@as(usize, 2), mixed_named.selected);
    try std.testing.expectEqual(@as(usize, 1), mixed_named.runnable);
    try std.testing.expectEqual(@as(usize, 1), mixed_named.no_probe);

    const unsupported_named = liveProbeSelectionStats("isubtitles.org", "named");
    try std.testing.expectEqual(@as(usize, 1), unsupported_named.selected);
    try std.testing.expectEqual(@as(usize, 0), unsupported_named.runnable);
    try std.testing.expectEqual(@as(usize, 1), unsupported_named.no_probe);

    const active_smoke = liveProbeSelectionStats("active", "smoke");
    try std.testing.expectEqual(@as(usize, 46), active_smoke.selected);
    try std.testing.expectEqual(@as(usize, 46), active_smoke.runnable);
    try std.testing.expectEqual(@as(usize, 0), active_smoke.no_probe);
}

const live_timeout_kill_after_seconds: u32 = 5;
const live_shutdown_poll_milliseconds: u32 = 100;
const live_provider_shutdown_grace_ticks: u32 = 60;
const live_monitor_shutdown_grace_ticks: u32 = 10;
const live_runner_shutdown_grace_ticks: u32 = 70;

test "live runner shutdown grace covers nested timeout escalation" {
    const timeout_escalation_milliseconds = live_timeout_kill_after_seconds * 1000;
    const provider_grace_milliseconds = live_provider_shutdown_grace_ticks * live_shutdown_poll_milliseconds;
    const runner_grace_milliseconds = live_runner_shutdown_grace_ticks * live_shutdown_poll_milliseconds;

    try std.testing.expect(provider_grace_milliseconds > timeout_escalation_milliseconds);
    try std.testing.expect(runner_grace_milliseconds > provider_grace_milliseconds);
}

fn liveRunnerProviderTokenIsSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_') continue;
        return false;
    }
    return true;
}

test "live runner provider tokens are safe for shell literals and filenames" {
    for ([_][]const u8{ "subdl.com", "sub_scene_com", "my-subs.co" }) |value| {
        try std.testing.expect(liveRunnerProviderTokenIsSafe(value));
    }
    for ([_][]const u8{ "", "provider/name", "provider name", "provider'name", "provider\nname", "$provider" }) |value| {
        try std.testing.expect(!liveRunnerProviderTokenIsSafe(value));
    }
}

fn makeParallelLiveRunScript(
    b: *std.Build,
    timeout_seconds: u32,
    max_jobs: u32,
    raw_filter: []const u8,
    live_mode: []const u8,
    probe_stats: LiveProbeSelectionStats,
    use_provider_deadlines: bool,
) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(b.allocator);
    for (provider_registry.all) |target_info| {
        if (!liveProviderMatchesSelection(target_info, raw_filter)) continue;
        if (!liveRunnerProviderTokenIsSafe(target_info.id) or
            !liveRunnerProviderTokenIsSafe(target_info.live_name))
        {
            std.debug.panic("unsafe live runner provider token: {s} / {s}", .{ target_info.id, target_info.live_name });
        }
    }
    out.appendSlice(b.allocator,
        \\set -euo pipefail
        \\test_bin="$1"
        \\tmpdir=""
        \\output_fifo_path=""
        \\output_lock_path=""
        \\output_keepalive_fd=""
        \\output_stream_fd=""
        \\output_mux_pid=""
        \\output_mux_terminal_path=""
        \\# Install a minimal trap before mkdir/mktemp and keep its target empty
        \\# until creation succeeds, so every startup failure is safe to clean.
        \\trap 'rc=$?; trap - EXIT; trap "" INT TERM; if [[ -n "$tmpdir" ]]; then command rm -rf -- "$tmpdir"; fi; exit "$rc"' EXIT
        \\trap 'exit 130' INT
        \\trap 'exit 143' TERM
        \\if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        \\  command echo "live runner requires Bash 4.3 or newer" >&2
        \\  exit 2
        \\fi
        \\for required_command in bash cat flock grep mkdir mkfifo mktemp rm sleep tee timeout; do
        \\  if ! command type -P "$required_command" >/dev/null 2>&1; then
        \\    command echo "live runner requires $required_command" >&2
        \\    exit 2
        \\  fi
        \\done
        \\if ! command timeout --version 2>/dev/null | command grep -F 'GNU coreutils' >/dev/null; then
        \\  command echo "live runner requires GNU coreutils timeout" >&2
        \\  exit 2
        \\fi
        \\command mkdir -p .tmp
        \\tmpdir="$(command mktemp -d .tmp/live-runner.XXXXXX)"
        \\declare -a names=()
        \\declare -a pids=()
        \\declare -a wait_rcs=()
        \\declare -a reaped=()
        \\monitor_pid=""
        \\shutdown_poll_seconds=0.1
        \\emit_record() {
        \\  local record="$1"
        \\  local lock_fd
        \\  local write_rc=0
        \\  exec {lock_fd}> "$output_lock_path" || return $?
        \\  command flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
        \\  if [[ -f "$output_mux_terminal_path" ]]; then
        \\    write_rc=1
        \\  else
        \\    command printf '%s\n' "$record" >&"$output_stream_fd" || write_rc=$?
        \\  fi
        \\  command flock -u "$lock_fd" || { if (( write_rc == 0 )); then write_rc=1; fi; }
        \\  exec {lock_fd}>&-
        \\  return "$write_rc"
        \\}
        \\emit_terminal_record() {
        \\  local record="$1"
        \\  local terminal_path="$2"
        \\  local terminal_value="$3"
        \\  local lock_fd
        \\  local write_rc=0
        \\  exec {lock_fd}> "$output_lock_path" || return $?
        \\  command flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
        \\  # Publish terminal state first under the same lock used by ACTIVE and
        \\  # END. If either output path then fails, keeping the sentinel prevents
        \\  # an ACTIVE record from following a partially or fully written END.
        \\  command printf '%s\n' "$terminal_value" > "$terminal_path" || write_rc=$?
        \\  if (( write_rc == 0 )); then
        \\    if [[ -f "$output_mux_terminal_path" ]]; then
        \\      write_rc=1
        \\    else
        \\      command printf '%s\n' "$record" >&"$output_stream_fd" || write_rc=$?
        \\    fi
        \\  fi
        \\  command flock -u "$lock_fd" || { if (( write_rc == 0 )); then write_rc=1; fi; }
        \\  exec {lock_fd}>&-
        \\  return "$write_rc"
        \\}
        \\emit_active_snapshot() {
        \\  local active_names=""
        \\  local i
        \\  local name
        \\  local lock_fd
        \\  local write_rc=0
        \\  exec {lock_fd}> "$output_lock_path" || return 2
        \\  command flock -x "$lock_fd" || { exec {lock_fd}>&-; return 2; }
        \\  if [[ -f "$output_mux_terminal_path" ]]; then
        \\    command flock -u "$lock_fd" 2>/dev/null || true
        \\    exec {lock_fd}>&-
        \\    return 2
        \\  fi
        \\  for i in "${!pids[@]}"; do
        \\    name="${names[$i]}"
        \\    if [[ ! -f "$tmpdir/$name.done" && ! -f "$tmpdir/$name.failed" ]]; then
        \\      if [[ -z "$active_names" ]]; then
        \\        active_names="$name"
        \\      else
        \\        active_names="$active_names,$name"
        \\      fi
        \\    fi
        \\  done
        \\  if [[ -z "$active_names" ]]; then
        \\    command flock -u "$lock_fd" || write_rc=$?
        \\    exec {lock_fd}>&-
        \\    if (( write_rc != 0 )); then return 2; fi
        \\    return 1
        \\  fi
        \\  command printf '%s\n' "[live][runner] ACTIVE $active_names" >&"$output_stream_fd" || write_rc=$?
        \\  command flock -u "$lock_fd" || { if (( write_rc == 0 )); then write_rc=1; fi; }
        \\  exec {lock_fd}>&-
        \\  if (( write_rc != 0 )); then return 2; fi
        \\  return 0
        \\}
        \\validate_provider_probe() {
        \\  local log_path="$1"
        \\  local live_name="$2"
        \\  local provider_id="$3"
        \\  local accepted_live="[live][probe] provider=$live_name"
        \\  local accepted_id="[live][probe] provider=$provider_id"
        \\  local accepted_count
        \\  local unexpected_probe_lines
        \\  unexpected_probe_lines="$(command grep -F '[live][probe]' "$log_path" | command grep -Fvx -e "$accepted_live" -e "$accepted_id" || true)"
        \\  if [[ -n "$unexpected_probe_lines" ]]; then
        \\    emit_record "[live][runner] UNEXPECTED_PROBE $live_name"
        \\    if [[ "$rc" == "0" ]]; then
        \\      rc=87
        \\    fi
        \\  fi
        \\  # At least one exact accepted marker proves that the selected
        \\  # provider ran. Named and `live=all` tests may emit more than one.
        \\  accepted_count="$(command grep -Fxc -e "$accepted_live" -e "$accepted_id" -- "$log_path" || true)"
        \\  if (( accepted_count == 0 )); then
        \\    emit_record "[live][runner] MISSING_PROBE $live_name"
        \\    if [[ "$rc" == "0" ]]; then
        \\      rc=86
        \\    fi
        \\  fi
        \\}
        \\
    ) catch @panic("oom");
    out.print(b.allocator,
        \\timeout_kill_after_seconds={d}
        \\provider_shutdown_grace_ticks={d}
        \\monitor_shutdown_grace_ticks={d}
        \\runner_shutdown_grace_ticks={d}
        \\
    , .{
        live_timeout_kill_after_seconds,
        live_provider_shutdown_grace_ticks,
        live_monitor_shutdown_grace_ticks,
        live_runner_shutdown_grace_ticks,
    }) catch @panic("oom");
    out.appendSlice(b.allocator,
        \\runner_job_is_live() {
        \\  local wanted_pid="$1"
        \\  local candidate_pid
        \\  while IFS= read -r candidate_pid; do
        \\    if [[ "$candidate_pid" == "$wanted_pid" ]]; then
        \\      return 0
        \\    fi
        \\  done < <(jobs -pr; jobs -ps)
        \\  return 1
        \\}
        \\terminate_one_runner_job() {
        \\  local initial_signal="$1"
        \\  local grace_ticks="$2"
        \\  local owned_pid="${3:-}"
        \\  local attempt
        \\  local -a candidates=()
        \\  if [[ -z "$owned_pid" ]]; then
        \\    # A trap can run after `&` creates the job but before `$!` is
        \\    # copied. Each wrapper creates exactly one background job, so the
        \\    # sole live/stopped job is still an unambiguous ownership handle.
        \\    mapfile -t candidates < <(jobs -pr; jobs -ps)
        \\    if (( ${#candidates[@]} != 1 )); then
        \\      return
        \\    fi
        \\    owned_pid="${candidates[0]}"
        \\  fi
        \\  if runner_job_is_live "$owned_pid"; then
        \\    kill "-$initial_signal" "$owned_pid" 2>/dev/null || true
        \\    kill -CONT "$owned_pid" 2>/dev/null || true
        \\  fi
        \\  for (( attempt = 0; attempt < grace_ticks; attempt++ )); do
        \\    if ! runner_job_is_live "$owned_pid"; then
        \\      break
        \\    fi
        \\    command sleep "$shutdown_poll_seconds"
        \\  done
        \\  if runner_job_is_live "$owned_pid"; then
        \\    kill -KILL "$owned_pid" 2>/dev/null || true
        \\    return
        \\  fi
        \\  # The job table says this child is terminal, so reaping its cached
        \\  # status cannot extend cleanup beyond the bounded poll above.
        \\  wait "$owned_pid" 2>/dev/null || true
        \\}
        \\terminate_all_runner_jobs() {
        \\  local attempt
        \\  local -a owned_pids=()
        \\  local -a remaining_pids=()
        \\  # The caller starts a fresh non-interactive Bash with BASH_ENV/ENV
        \\  # removed. Bash cannot inherit a parent's job table, so every job
        \\  # here is runner-owned.
        \\  mapfile -t owned_pids < <(jobs -pr; jobs -ps)
        \\  if (( ${#owned_pids[@]} == 0 )); then
        \\    return
        \\  fi
        \\  kill -TERM "${owned_pids[@]}" 2>/dev/null || true
        \\  kill -CONT "${owned_pids[@]}" 2>/dev/null || true
        \\  for (( attempt = 0; attempt < runner_shutdown_grace_ticks; attempt++ )); do
        \\    mapfile -t remaining_pids < <(jobs -pr; jobs -ps)
        \\    if (( ${#remaining_pids[@]} == 0 )); then
        \\      break
        \\    fi
        \\    command sleep "$shutdown_poll_seconds"
        \\  done
        \\  mapfile -t remaining_pids < <(jobs -pr; jobs -ps)
        \\  if (( ${#remaining_pids[@]} != 0 )); then
        \\    kill -KILL "${remaining_pids[@]}" 2>/dev/null || true
        \\    return
        \\  fi
        \\  # All owned children are terminal; only reap cached statuses.
        \\  wait "${owned_pids[@]}" 2>/dev/null || true
        \\}
        \\wait_for_provider_slot() {
        \\  local active_jobs
        \\  local i
        \\  local owned_pid
        \\  while :; do
        \\    active_jobs=0
        \\    for i in "${!pids[@]}"; do
        \\      if [[ "${reaped[$i]:-0}" == "1" ]]; then
        \\        continue
        \\      fi
        \\      owned_pid="${pids[$i]}"
        \\      if runner_job_is_live "$owned_pid"; then
        \\        active_jobs=$((active_jobs + 1))
        \\      else
        \\        # Reap before launching another wrapper so this PID cannot be
        \\        # reused and later mistaken for the provider that owned it.
        \\        set +e
        \\        wait "$owned_pid"
        \\        wait_rcs[$i]=$?
        \\        set -e
        \\        reaped[$i]=1
        \\      fi
        \\    done
        \\    if (( active_jobs < max_jobs )); then
        \\      return
        \\    fi
        \\    command sleep "$shutdown_poll_seconds"
        \\  done
        \\}
        \\bounded_wait_rc=0
        \\wait_for_job_bounded() {
        \\  local owned_pid="$1"
        \\  local grace_ticks="$2"
        \\  local attempt
        \\  for (( attempt = 0; attempt < grace_ticks; attempt++ )); do
        \\    if ! runner_job_is_live "$owned_pid"; then
        \\      set +e
        \\      wait "$owned_pid"
        \\      bounded_wait_rc=$?
        \\      set -e
        \\      return 0
        \\    fi
        \\    command sleep "$shutdown_poll_seconds"
        \\  done
        \\  return 1
        \\}
        \\cleanup() {
        \\  rc=$?
        \\  trap - EXIT
        \\  trap '' INT TERM
        \\  terminate_all_runner_jobs
        \\  if [[ -n "$tmpdir" ]]; then
        \\    command rm -rf -- "$tmpdir"
        \\  fi
        \\  exit "$rc"
        \\}
        \\terminate_provider_pipeline() {
        \\  trap '' TERM INT
        \\  # SIGALRM enters GNU timeout's own deadline path, so its configured
        \\  # TERM then KILL escalation still covers the nested process group.
        \\  terminate_one_runner_job ALRM "$provider_shutdown_grace_ticks" "${pipeline_pid:-}"
        \\  pipeline_pid=""
        \\}
        \\terminate_monitor_delay() {
        \\  trap '' TERM INT
        \\  terminate_one_runner_job TERM "$monitor_shutdown_grace_ticks" "${monitor_delay_pid:-}"
        \\  monitor_delay_pid=""
        \\}
        \\trap cleanup EXIT
        \\trap 'exit 130' INT
        \\trap 'exit 143' TERM
        \\output_fifo_path="$tmpdir/output.fifo"
        \\output_lock_path="$tmpdir/output.lock"
        \\output_mux_terminal_path="$tmpdir/output-mux.terminal"
        \\command mkfifo "$output_fifo_path"
        \\# Linux permits opening a FIFO read/write without a peer. This anchor
        \\# makes every later writer acquisition nonblocking; the mux terminal
        \\# sentinel makes producers fail fast instead of filling an orphaned FIFO.
        \\exec {output_keepalive_fd}<> "$output_fifo_path"
        \\(
        \\  exec {output_keepalive_fd}>&-
        \\  set +e
        \\  command cat "$output_fifo_path"
        \\  mux_rc=$?
        \\  command printf '%s\n' "$mux_rc" > "$output_mux_terminal_path"
        \\  terminal_rc=$?
        \\  if (( mux_rc == 0 && terminal_rc != 0 )); then mux_rc=$terminal_rc; fi
        \\  exit "$mux_rc"
        \\) &
        \\output_mux_pid=$!
        \\output_stream_fd="$output_keepalive_fd"
        \\
    ) catch @panic("oom");

    for (provider_registry.all) |target_info| {
        if (!liveProviderMatchesSelection(target_info, raw_filter)) continue;
        if (providerHasLiveProbeInMode(target_info, live_mode)) continue;
        out.print(b.allocator,
            \\emit_record "[live][runner] NO_PROBE {s} mode={s}"
            \\
        , .{ target_info.live_name, live_mode }) catch @panic("oom");
    }
    out.print(b.allocator, "max_jobs={d}\n", .{max_jobs}) catch @panic("oom");
    for (provider_registry.all) |target_info| {
        if (!liveProviderMatchesSelection(target_info, raw_filter)) continue;
        if (!providerHasLiveProbeInMode(target_info, live_mode)) continue;
        if (target_info.live_serial) continue;
        out.appendSlice(b.allocator,
            \\wait_for_provider_slot
            \\
        ) catch @panic("oom");
        const provider_timeout_seconds = if (use_provider_deadlines) target_info.live_timeout_seconds orelse timeout_seconds else timeout_seconds;
        out.print(b.allocator,
            \\emit_record "[live][runner] START {s}"
            \\
            \\(
            \\  set -o pipefail
            \\  child_output_fd=""
            \\  exec {{child_output_fd}}> "$output_fifo_path"
            \\  exec {{output_keepalive_fd}}>&-
            \\  output_stream_fd="$child_output_fd"
            \\  set +e
            \\  pipeline_pid=""
            \\  trap 'terminate_provider_pipeline; exit 143' TERM
            \\  trap 'terminate_provider_pipeline; exit 130' INT
            \\  # Timeout supervises one nested shell, whose pipefail status is
            \\  # the provider status. Its default non-foreground mode owns the
            \\  # complete test/tee/prefix pipeline process group instead of
            \\  # leaving an output stage outside the hard deadline.
            \\  # One FIFO multiplexer owns stdout. Provider chunks are capped,
            \\  # locked records; a 250 ms partial read keeps prompts visible
            \\  # without allowing concurrent byte-level line corruption.
            \\  # The nested leader traps TERM and stays in the group until KILL,
            \\  # even if the direct pipeline exits while a descendant ignores TERM.
            \\  SCRAPERS_LIVE_PROVIDER_FILTER="{s}" command timeout --signal=TERM --kill-after="$timeout_kill_after_seconds"s {d}s bash -o pipefail -c 'pipeline_pid=""; output_prefix="$2"; output_fifo="$4"; output_lock="$5"; output_mux_terminal="$7"; inherited_output_fd="$6"; exec {{inherited_output_fd}}>&-; hold_pipeline_until_kill() {{ trap "" TERM INT; if [[ -n "$pipeline_pid" ]]; then wait "$pipeline_pid" 2>/dev/null || true; fi; while :; do command sleep 3600; done; }}; prefix_output() {{ local chunk read_rc write_rc output_fd lock_fd skip_empty_delimiter=0; exec {{output_fd}}> "$output_fifo" || return $?; exec {{lock_fd}}> "$output_lock" || {{ exec {{output_fd}}>&-; return 1; }}; while :; do chunk=""; IFS= read -r -t 0.25 -n 512 chunk; read_rc=$?; if [[ -z "$chunk" && "$read_rc" == "0" && "$skip_empty_delimiter" == "1" ]]; then skip_empty_delimiter=0; elif [[ -n "$chunk" || "$read_rc" == "0" ]]; then write_rc=0; if [[ -f "$output_mux_terminal" ]]; then exec {{lock_fd}}>&-; exec {{output_fd}}>&-; return 1; fi; command flock -x "$lock_fd" || return $?; if [[ -f "$output_mux_terminal" ]]; then command flock -u "$lock_fd" 2>/dev/null || true; exec {{lock_fd}}>&-; exec {{output_fd}}>&-; return 1; fi; command printf "%s%s\n" "$output_prefix" "$chunk" >&"$output_fd" || write_rc=$?; command flock -u "$lock_fd" || {{ if (( write_rc == 0 )); then write_rc=1; fi; }}; if (( write_rc != 0 )); then return "$write_rc"; fi; if (( read_rc > 128 || ${{#chunk}} == 512 )); then skip_empty_delimiter=1; else skip_empty_delimiter=0; fi; fi; if (( read_rc == 0 || read_rc > 128 )); then continue; fi; break; done; exec {{lock_fd}}>&-; exec {{output_fd}}>&-; }}; trap hold_pipeline_until_kill TERM INT; "$1" 2>&1 | command tee "$3" | prefix_output & pipeline_pid=$!; wait "$pipeline_pid"; rc=$?; trap - TERM INT; exit "$rc"' _ "$test_bin" '[live][{s}] ' "$tmpdir/{s}.log" "$output_fifo_path" "$output_lock_path" "$child_output_fd" "$output_mux_terminal_path" &
            \\  pipeline_pid=$!
            \\  wait "$pipeline_pid"
            \\  rc=$?
            \\  pipeline_pid=""
            \\  trap - TERM INT
            \\  validate_provider_probe "$tmpdir/{s}.log" "{s}" "{s}"
            \\  set -e
            \\  command printf '%s\n' "$rc" > "$tmpdir/{s}.rc"
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
            target_info.id,
            target_info.live_name,
            target_info.live_name,
        }) catch @panic("oom");
    }

    out.appendSlice(b.allocator,
        \\(
        \\  child_output_fd=""
        \\  exec {child_output_fd}> "$output_fifo_path"
        \\  exec {output_keepalive_fd}>&-
        \\  output_stream_fd="$child_output_fd"
        \\  monitor_delay_pid=""
        \\  trap 'terminate_monitor_delay; exit 143' TERM
        \\  trap 'terminate_monitor_delay; exit 130' INT
        \\  while [[ ! -f "$tmpdir/monitor.stop" ]]; do
        \\    if emit_active_snapshot; then
        \\      :
        \\    else
        \\      active_rc=$?
        \\      if (( active_rc == 1 )); then break; fi
        \\      exit "$active_rc"
        \\    fi
        \\    command sleep 5 &
        \\    monitor_delay_pid=$!
        \\    wait "$monitor_delay_pid" 2>/dev/null || true
        \\    monitor_delay_pid=""
        \\  done
        \\) &
        \\monitor_pid=$!
        \\
        \\overall_rc=0
        \\for i in "${!pids[@]}"; do
        \\  name="${names[$i]}"
        \\  pid="${pids[$i]}"
        \\  if [[ "${reaped[$i]:-0}" == "1" ]]; then
        \\    wait_rc="${wait_rcs[$i]}"
        \\  else
        \\    set +e
        \\    wait "$pid"
        \\    wait_rc=$?
        \\    set -e
        \\  fi
        \\  unset 'pids[i]'
        \\  unset 'wait_rcs[i]'
        \\  unset 'reaped[i]'
        \\  rc_file="$tmpdir/$name.rc"
        \\  completion_rc="missing"
        \\  normal_completion=0
        \\  if [[ -f "$rc_file" ]]; then
        \\    rc="$(command cat "$rc_file")"
        \\    if [[ "$rc" =~ ^[0-9]+$ && "$wait_rc" == "$rc" ]]; then
        \\      completion_rc="$rc"
        \\      normal_completion=1
        \\    else
        \\      emit_record "[live][runner] RESULT_MISMATCH $name wait_rc=$wait_rc recorded_rc=$rc"
        \\      completion_rc="mismatch"
        \\    fi
        \\  fi
        \\  if (( normal_completion )); then
        \\    terminal_path="$tmpdir/$name.done"
        \\  else
        \\    terminal_path="$tmpdir/$name.failed"
        \\    overall_rc=1
        \\  fi
        \\  if ! emit_terminal_record "[live][runner] END $name rc=$completion_rc" "$terminal_path" "$completion_rc"; then
        \\    overall_rc=1
        \\  fi
        \\  if [[ "$completion_rc" != "0" ]]; then
        \\    overall_rc=1
        \\  fi
        \\done
        \\: > "$tmpdir/monitor.stop"
        \\if wait_for_job_bounded "$monitor_pid" "$runner_shutdown_grace_ticks"; then
        \\  if (( bounded_wait_rc != 0 )); then
        \\    emit_record "[live][runner] MONITOR_FAILED rc=$bounded_wait_rc"
        \\    overall_rc=1
        \\  fi
        \\else
        \\  emit_record "[live][runner] MONITOR_STUCK"
        \\  overall_rc=1
        \\  terminate_one_runner_job TERM "$monitor_shutdown_grace_ticks" "$monitor_pid"
        \\fi
        \\monitor_pid=""
        \\pids=()
        \\wait_rcs=()
        \\reaped=()
        \\
    ) catch @panic("oom");

    for (provider_registry.all) |target_info| {
        if (!target_info.live_serial) continue;
        if (!liveProviderMatchesSelection(target_info, raw_filter)) continue;
        if (!providerHasLiveProbeInMode(target_info, live_mode)) continue;
        const provider_timeout_seconds = if (use_provider_deadlines) target_info.live_timeout_seconds orelse timeout_seconds else timeout_seconds;
        out.print(b.allocator,
            \\emit_record "[live][runner] START {s} mode=serial"
            \\(
            \\  set -o pipefail
            \\  child_output_fd=""
            \\  exec {{child_output_fd}}> "$output_fifo_path"
            \\  exec {{output_keepalive_fd}}>&-
            \\  output_stream_fd="$child_output_fd"
            \\  set +e
            \\  pipeline_pid=""
            \\  trap 'terminate_provider_pipeline; exit 143' TERM
            \\  trap 'terminate_provider_pipeline; exit 130' INT
            \\  SCRAPERS_LIVE_PROVIDER_FILTER="{s}" command timeout --signal=TERM --kill-after="$timeout_kill_after_seconds"s {d}s bash -o pipefail -c 'pipeline_pid=""; output_prefix="$2"; output_fifo="$4"; output_lock="$5"; output_mux_terminal="$7"; inherited_output_fd="$6"; exec {{inherited_output_fd}}>&-; hold_pipeline_until_kill() {{ trap "" TERM INT; if [[ -n "$pipeline_pid" ]]; then wait "$pipeline_pid" 2>/dev/null || true; fi; while :; do command sleep 3600; done; }}; prefix_output() {{ local chunk read_rc write_rc output_fd lock_fd skip_empty_delimiter=0; exec {{output_fd}}> "$output_fifo" || return $?; exec {{lock_fd}}> "$output_lock" || {{ exec {{output_fd}}>&-; return 1; }}; while :; do chunk=""; IFS= read -r -t 0.25 -n 512 chunk; read_rc=$?; if [[ -z "$chunk" && "$read_rc" == "0" && "$skip_empty_delimiter" == "1" ]]; then skip_empty_delimiter=0; elif [[ -n "$chunk" || "$read_rc" == "0" ]]; then write_rc=0; if [[ -f "$output_mux_terminal" ]]; then exec {{lock_fd}}>&-; exec {{output_fd}}>&-; return 1; fi; command flock -x "$lock_fd" || return $?; if [[ -f "$output_mux_terminal" ]]; then command flock -u "$lock_fd" 2>/dev/null || true; exec {{lock_fd}}>&-; exec {{output_fd}}>&-; return 1; fi; command printf "%s%s\n" "$output_prefix" "$chunk" >&"$output_fd" || write_rc=$?; command flock -u "$lock_fd" || {{ if (( write_rc == 0 )); then write_rc=1; fi; }}; if (( write_rc != 0 )); then return "$write_rc"; fi; if (( read_rc > 128 || ${{#chunk}} == 512 )); then skip_empty_delimiter=1; else skip_empty_delimiter=0; fi; fi; if (( read_rc == 0 || read_rc > 128 )); then continue; fi; break; done; exec {{lock_fd}}>&-; exec {{output_fd}}>&-; }}; trap hold_pipeline_until_kill TERM INT; "$1" 2>&1 | command tee "$3" | prefix_output & pipeline_pid=$!; wait "$pipeline_pid"; rc=$?; trap - TERM INT; exit "$rc"' _ "$test_bin" '[live][{s}] ' "$tmpdir/{s}.log" "$output_fifo_path" "$output_lock_path" "$child_output_fd" "$output_mux_terminal_path" &
            \\  pipeline_pid=$!
            \\  wait "$pipeline_pid"
            \\  rc=$?
            \\  pipeline_pid=""
            \\  trap - TERM INT
            \\  validate_provider_probe "$tmpdir/{s}.log" "{s}" "{s}"
            \\  set -e
            \\  command printf '%s\n' "$rc" > "$tmpdir/{s}.rc"
            \\  exit "$rc"
            \\) &
            \\serial_pid=$!
            \\set +e
            \\wait "$serial_pid"
            \\wait_rc=$?
            \\set -e
            \\serial_pid=""
            \\rc_file="$tmpdir/{s}.rc"
            \\completion_rc="missing"
            \\normal_completion=0
            \\if [[ -f "$rc_file" ]]; then
            \\  rc="$(command cat "$rc_file")"
            \\  if [[ "$rc" =~ ^[0-9]+$ && "$wait_rc" == "$rc" ]]; then
            \\    completion_rc="$rc"
            \\    normal_completion=1
            \\  else
            \\    emit_record "[live][runner] RESULT_MISMATCH {s} wait_rc=$wait_rc recorded_rc=$rc"
            \\    completion_rc="mismatch"
            \\  fi
            \\fi
            \\if (( normal_completion )); then
            \\  terminal_path="$tmpdir/{s}.done"
            \\else
            \\  terminal_path="$tmpdir/{s}.failed"
            \\  overall_rc=1
            \\fi
            \\if ! emit_terminal_record "[live][runner] END {s} rc=$completion_rc mode=serial" "$terminal_path" "$completion_rc"; then
            \\  overall_rc=1
            \\fi
            \\if [[ "$completion_rc" != "0" ]]; then
            \\  overall_rc=1
            \\fi
            \\
        , .{
            target_info.live_name,
            target_info.live_name,
            provider_timeout_seconds,
            target_info.live_name,
            target_info.live_name,
            target_info.live_name,
            target_info.live_name,
            target_info.id,
            target_info.live_name,
            target_info.live_name,
            target_info.live_name,
            target_info.live_name,
            target_info.live_name,
            target_info.live_name,
        }) catch @panic("oom");
    }

    out.print(b.allocator,
        \\emit_record "[live][runner] SUMMARY rc=$overall_rc mode={s} selected={d} started={d} no_probe={d}"
        \\
    , .{
        live_mode,
        probe_stats.selected,
        probe_stats.runnable,
        probe_stats.no_probe,
    }) catch @panic("oom");
    out.appendSlice(b.allocator,
        \\exec {output_keepalive_fd}>&-
        \\output_stream_fd=""
        \\if wait_for_job_bounded "$output_mux_pid" "$runner_shutdown_grace_ticks"; then
        \\  if (( bounded_wait_rc != 0 )); then
        \\    command echo "[live][runner] OUTPUT_MUX_FAILED rc=$bounded_wait_rc" >&2
        \\    overall_rc=1
        \\  fi
        \\  output_mux_pid=""
        \\else
        \\  command echo "[live][runner] OUTPUT_MUX_STUCK" >&2
        \\  overall_rc=1
        \\  terminate_one_runner_job TERM "$monitor_shutdown_grace_ticks" "$output_mux_pid"
        \\fi
        \\exit "$overall_rc"
        \\
    ) catch @panic("oom");

    return out.toOwnedSlice(b.allocator) catch @panic("oom");
}

const TargetModuleSet = struct {
    htmlparser_compat: *std.Build.Module,
    runtime_alloc: *std.Build.Module,
    runtime_io: *std.Build.Module,
    unarr: *std.Build.Module,
    scrapers: *std.Build.Module,
    tui_backend: *std.Build.Module,
    tui_impl: ?*std.Build.Module,
    lazy_dependencies_pending: bool,
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
    expose_scrapers_module: bool,
    enable_tui: bool,
    enable_unarr: bool,
) TargetModuleSet {
    const unarr_dep = if (enable_unarr) b.dependencyLazy("unarr", .{
        .target = target,
        .optimize = optimize,
    }) catch |err| switch (err) {
        error.LazyDependencyNeeded => null,
    } else null;
    // Resolve the local TUI package before the host propagates its lazy-fetch
    // signal so uucode joins the same cold-cache discovery pass.
    const libvaxis_dep = if (enable_tui) b.dependency("libvaxis", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    // Keep constructing this configuration with compatibility modules that do
    // not yet import the missing dependency. No compile step runs during a
    // lazy-fetch pass, and publishing the host modules lets parent packages
    // complete their own configuration before Zig fetches and retries.

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
            .{ .name = "htmlparser_upstream", .module = htmlparser_dep.module("html") },
        },
    });
    const unarr_mod = if (unarr_dep) |dependency|
        b.createModule(.{
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
                .{ .name = "unarr_upstream", .module = dependency.module("unarr") },
            },
        })
    else
        b.createModule(.{
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
    const scrapers_options: std.Build.Module.CreateOptions = .{
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
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "runtime_alloc", .module = runtime_alloc_mod },
            .{ .name = "runtime_io", .module = runtime_io_mod },
            .{ .name = "unarr", .module = unarr_mod },
        },
    };
    const scrapers_mod = if (expose_scrapers_module)
        b.addModule("scrapers", scrapers_options)
    else
        b.createModule(scrapers_options);
    var tui_impl: ?*std.Build.Module = null;
    const tui_backend_mod = if (enable_tui) blk: {
        const libvaxis_dependency = libvaxis_dep orelse unreachable;
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
                .{ .name = "vaxis", .module = libvaxis_dependency.module("vaxis") },
                .{ .name = "runtime_alloc", .module = runtime_alloc_mod },
                .{ .name = "runtime_io", .module = runtime_io_mod },
                .{ .name = "build_options", .module = build_options_mod },
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

    // `dependency()` catches a child package's lazy-fetch signal after that
    // child publishes its modules. Check after all dependency configuration so
    // nested requests such as libvaxis's uucode propagate with our direct
    // lazies on the same retry.
    const lazy_dependencies_pending = b.graph.needed_lazy_dependencies.count() != 0;
    return .{
        .htmlparser_compat = htmlparser_compat_mod,
        .runtime_alloc = runtime_alloc_mod,
        .runtime_io = runtime_io_mod,
        .unarr = unarr_mod,
        .scrapers = scrapers_mod,
        .tui_backend = tui_backend_mod,
        .tui_impl = tui_impl,
        .lazy_dependencies_pending = lazy_dependencies_pending,
    };
}
