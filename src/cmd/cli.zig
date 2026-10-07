const std = @import("std");
const builtin = @import("builtin");
const scrapers = @import("scrapers");
const runtime_alloc = @import("runtime_alloc");
const runtime_io = @import("runtime_io");

const app = scrapers.providers_app;
const common = scrapers.common;

const Config = struct {
    providers_enabled: [app.providerCount()]bool = app.providerSelectionAll(),
    provider_filter_seen: bool = false,
    query: ?[]const u8 = null,
    search_page: u32 = 1,
    subtitle_page: u32 = 1,
    title_index: usize = 0,
    subtitle_index: ?usize = null,
    out_dir: []const u8 = "downloads",
    extract_archive: bool = false,
    list_providers: bool = false,
    help: bool = false,
};

const SearchHit = struct {
    provider: app.Provider,
    response_index: usize,
    item_index: usize,
};

const SearchTask = struct {
    provider: app.Provider,
    query: []const u8,
    page: u32 = 1,
    result: ?app.SearchResponse = null,
    err: ?anyerror = null,
};

fn searchTaskMain(task: *SearchTask) std.Io.Cancelable!void {
    var client: std.http.Client = .{
        .allocator = std.heap.page_allocator,
        .io = runtime_io.get(),
    };
    defer client.deinit();

    task.result = app.searchPage(std.heap.page_allocator, &client, task.provider, task.query, task.page) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        task.err = err;
        return;
    };
}

fn runOrScheduleGroup(
    comptime run_inline: bool,
    group: *std.Io.Group,
    io: std.Io,
    comptime function: anytype,
    args: anytype,
) !void {
    if (run_inline) return @call(.auto, function, args);
    return group.concurrent(io, function, args);
}

pub fn main(init: std.process.Init) !void {
    return mainWithTuiAvailability(init, false);
}

pub fn mainWithTuiAvailability(init: std.process.Init, tui_available: bool) !void {
    runtime_io.set(init.io);
    var allocator_state = runtime_alloc.RuntimeAllocator.init();
    defer allocator_state.deinit();
    const allocator = allocator_state.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    const config = parseArgs(&args) catch |err| {
        try stderr.print("argument error: {s}\n\n", .{@errorName(err)});
        try printUsageWithTuiAvailability(stderr, tui_available);
        try stderr.flush();
        std.process.exit(2);
    };

    if (config.help) {
        try printUsageWithTuiAvailability(stdout, tui_available);
        try stdout.flush();
        return;
    }

    if (config.list_providers) {
        try printProviders(stdout);
        try stdout.flush();
        return;
    }

    const query = config.query orelse {
        try printUsageWithTuiAvailability(stderr, tui_available);
        try stderr.flush();
        std.process.exit(2);
    };
    if (common.countTrue(&config.providers_enabled) == 0) {
        try stderr.print("no providers selected\n", .{});
        try stderr.flush();
        std.process.exit(2);
    }

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = init.io,
    };
    defer client.deinit();

    var searches: std.ArrayListUnmanaged(app.SearchResponse) = .empty;
    defer {
        for (searches.items) |*search| search.deinit();
        searches.deinit(allocator);
    }

    var hits: std.ArrayListUnmanaged(SearchHit) = .empty;
    defer hits.deinit(allocator);

    const enabled_provider_count = common.countTrue(&config.providers_enabled);
    const tasks = try allocator.alloc(SearchTask, enabled_provider_count);
    var initialized_count: usize = 0;
    defer {
        for (tasks[0..initialized_count]) |*task| {
            if (task.result) |*result| result.deinit();
        }
        allocator.free(tasks);
    }

    var search_group: std.Io.Group = .init;
    defer search_group.cancel(init.io);
    var task_count: usize = 0;
    for (app.providers()) |provider| {
        const provider_index = app.providerIndex(provider) orelse continue;
        if (!config.providers_enabled[provider_index]) continue;
        tasks[task_count] = .{ .provider = provider, .query = query, .page = config.search_page };
        initialized_count = task_count + 1;
        try runOrScheduleGroup(builtin.single_threaded, &search_group, init.io, searchTaskMain, .{&tasks[task_count]});
        task_count += 1;
    }
    try search_group.await(init.io);

    var failed_count: usize = 0;
    for (tasks[0..task_count]) |*task| {
        if (task.err) |err| {
            failed_count += 1;
            try stderr.print("warning: search failed for {s}: {s}\n", .{ app.providerName(task.provider), @errorName(err) });
            try printBrowserErrorHint(stderr, err);
            continue;
        }
        const search_result = task.result orelse {
            failed_count += 1;
            continue;
        };
        const response_index = searches.items.len;
        try searches.append(allocator, search_result);
        task.result = null;
        for (searches.items[response_index].items, 0..) |_, item_index| {
            try hits.append(allocator, .{
                .provider = task.provider,
                .response_index = response_index,
                .item_index = item_index,
            });
        }
    }

    try stderr.flush();

    if (hits.items.len == 0) {
        if (failed_count > 0) {
            try stderr.print("no search results; {d} provider(s) failed\n", .{failed_count});
        } else {
            try stderr.print("no search results\n", .{});
        }
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.print("Query: {f}\n", .{terminalText(query)});
    try stdout.print("Search Results ({d}), page {d}:\n", .{ hits.items.len, config.search_page });
    for (searches.items) |response| {
        if (response.has_next_page) try stdout.print("  [{s}] more results available on the next search page\n", .{app.providerName(response.provider)});
    }
    for (hits.items, 0..) |hit, idx| {
        const item = searches.items[hit.response_index].items[hit.item_index];
        try stdout.print("  [{d}] [{s}] {f}\n", .{ idx, app.providerName(hit.provider), terminalText(item.label) });
    }

    try stdout.flush();

    if (config.title_index >= hits.items.len) {
        try stderr.print("title-index out of range: {d} (max {d})\n", .{ config.title_index, hits.items.len - 1 });
        try stderr.flush();
        std.process.exit(2);
    }

    const hit = hits.items[config.title_index];
    const selected_title = searches.items[hit.response_index].items[hit.item_index];
    const selected_provider = hit.provider;

    var subtitles = app.fetchSubtitlesPage(allocator, &client, selected_title.ref, config.subtitle_page) catch |err| {
        try stderr.print("subtitle fetch failed: {s}\n", .{@errorName(err)});
        try printBrowserErrorHint(stderr, err);
        try stderr.flush();
        std.process.exit(1);
    };
    defer subtitles.deinit();

    if (subtitles.items.len == 0) {
        try stderr.print("no subtitle rows for selected title\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.print("\nProvider: {s}\n", .{app.providerName(selected_provider)});
    try stdout.print("Title: {f}\n", .{terminalText(subtitles.title)});
    try stdout.print("Subtitle Rows ({d}), page {d}, next={any}:\n", .{ subtitles.items.len, subtitles.page, subtitles.has_next_page });
    for (subtitles.items, 0..) |item, idx| {
        const status = if (item.download_url != null) "downloadable" else "no-direct-url";
        try stdout.print("  [{d}] {f} [{s}]\n", .{ idx, terminalText(item.label), status });
    }

    try stdout.flush();

    const subtitle_index = if (config.subtitle_index) |idx| idx else findFirstDownloadable(subtitles.items) orelse {
        try stderr.print("no downloadable subtitle found for selected title\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    if (subtitle_index >= subtitles.items.len) {
        try stderr.print("subtitle-index out of range: {d} (max {d})\n", .{ subtitle_index, subtitles.items.len - 1 });
        try stderr.flush();
        std.process.exit(2);
    }

    const selected = subtitles.items[subtitle_index];
    if (selected.download_url == null) {
        try stderr.print("selected subtitle has no direct download URL\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var result = app.downloadSubtitleWithOptions(allocator, &client, selected, config.out_dir, .{
        .extract_archive = config.extract_archive,
    }) catch |err| {
        try stderr.print("download failed: {s}\n", .{@errorName(err)});
        try printBrowserErrorHint(stderr, err);
        try stderr.flush();
        std.process.exit(1);
    };
    defer result.deinit(allocator);

    try stdout.print("\nDownloaded:\n", .{});
    try stdout.print("  Provider: {s}\n", .{app.providerName(selected_provider)});
    try stdout.print("  File: {f}\n", .{terminalText(result.file_path)});
    if (result.archive_path) |archive_path| {
        try stdout.print("  Archive: {f}\n", .{terminalText(archive_path)});
    }
    if (result.translation_incomplete) try stdout.print("  Warning: translation is incomplete; some original text was preserved.\n", .{});
    if (result.extraction_unavailable) {
        try stdout.print("  Saved original archive; extract it with an external archive tool.\n", .{});
    }
    if (result.extracted_files.len > 0) {
        try stdout.print("  Extracted subtitle files ({d}):\n", .{result.extracted_files.len});
        for (result.extracted_files) |path| {
            try stdout.print("    - {f}\n", .{terminalText(path)});
        }
    }
    try stdout.print("  Bytes: {d}\n", .{result.bytes_written});
    const source_url_display = try app.downloadTargetForDisplay(allocator, result.source_url);
    defer allocator.free(source_url_display);
    try stdout.print("  URL: {f}\n", .{terminalText(source_url_display)});
    try stdout.flush();
}

fn parseArgs(args: anytype) !Config {
    var cfg: Config = .{};

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--provider")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            try addProviderFilter(&cfg, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--providers") or std.mem.eql(u8, arg, "-p")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            try addProviderFilter(&cfg, value);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--providers=")) {
            try addProviderFilter(&cfg, arg["--providers=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-p=")) {
            try addProviderFilter(&cfg, arg["-p=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-p") and arg.len > 2) {
            try addProviderFilter(&cfg, arg["-p".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--query")) {
            cfg.query = args.next() orelse return error.MissingArgumentValue;
            continue;
        }
        if (std.mem.eql(u8, arg, "--search-page") or std.mem.eql(u8, arg, "--subtitle-page")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            const page = try std.fmt.parseUnsigned(u32, value, 10);
            if (page == 0) return error.InvalidPage;
            if (std.mem.eql(u8, arg, "--search-page")) cfg.search_page = page else cfg.subtitle_page = page;
            continue;
        }
        if (std.mem.eql(u8, arg, "--title-index")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            cfg.title_index = try std.fmt.parseUnsigned(usize, value, 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--subtitle-index")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            cfg.subtitle_index = try std.fmt.parseUnsigned(usize, value, 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--out-dir")) {
            cfg.out_dir = args.next() orelse return error.MissingArgumentValue;
            continue;
        }
        if (std.mem.eql(u8, arg, "--extract")) {
            cfg.extract_archive = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--list-providers")) {
            cfg.list_providers = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cfg.help = true;
            continue;
        }
        return error.UnknownArgument;
    }

    return cfg;
}

fn browserErrorHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.DownloadConsentRequired => "Prijevodi requires download-protection consent on its site and a matching browser session; see DOCUMENTATION.md for SCRAPERS_PRIJEVODI_* setup",
        error.InvalidDownloadSession => "configure all three SCRAPERS_PRIJEVODI_* values from the same consenting browser session; see DOCUMENTATION.md",
        error.BrowserAutomationDisabled => "browser handoff is disabled in this build; rebuild with -Denable-alldriver=true",
        error.BrowserAutomationUnavailable => "secure browser handoff is unavailable on this platform or in this build",
        error.InvalidBrowserExecutable => "SUBDL_CHROMIUM_PATH must be an absolute path to a supported Chromium executable",
        error.CloudflareSessionUnavailable => "no usable Cloudflare session was acquired; install a supported Chromium browser and, if authorized, complete the visible verification prompt manually",
        error.BrowserAutomationFailed => "browser handoff failed; verify the configured Chromium installation and retry",
        else => null,
    };
}

fn printBrowserErrorHint(writer: *std.Io.Writer, err: anyerror) !void {
    if (browserErrorHint(err)) |hint| try writer.print("hint: {s}\n", .{hint});
}

fn addProviderFilter(cfg: *Config, value: []const u8) !void {
    if (!cfg.provider_filter_seen) {
        cfg.providers_enabled = @splat(false);
        cfg.provider_filter_seen = true;
    }

    var it = std.mem.splitScalar(u8, value, ',');
    var added = false;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (isNoneProviderSelector(trimmed)) {
            cfg.providers_enabled = @splat(false);
            added = true;
            continue;
        }
        const provider = app.resolveProvider(trimmed) catch |err| switch (err) {
            error.UnknownProvider => return error.InvalidProvider,
            error.AmbiguousProvider => return error.AmbiguousProvider,
        };
        const provider_index = app.providerIndex(provider) orelse return error.InvalidProvider;
        cfg.providers_enabled[provider_index] = true;
        added = true;
    }
    if (!added) return error.InvalidProvider;
}

fn isNoneProviderSelector(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "none");
}

fn findFirstDownloadable(items: []const app.SubtitleChoice) ?usize {
    for (items, 0..) |item, idx| {
        if (item.download_url != null) return idx;
    }
    return null;
}

fn printProviders(writer: *std.Io.Writer) !void {
    try writer.print("Available providers:\n", .{});
    for (app.providers()) |provider| {
        const info = app.providerInfo(provider);
        try writer.print(
            "  {s} - {s} ({s}) movies={any} tv={any} search_pages={any} subtitle_pages={any}\n",
            .{
                info.id,
                info.display_name,
                info.site_url,
                info.supports_movies,
                info.supports_tv,
                info.supports_search_pagination,
                info.supports_subtitles_pagination,
            },
        );
    }
}

pub fn printUsage(writer: *std.Io.Writer) !void {
    return printUsageWithTuiAvailability(writer, false);
}

pub fn printUsageWithTuiAvailability(writer: *std.Io.Writer, tui_available: bool) !void {
    if (tui_available) try writer.writeAll("Interactive mode: scrapers --tui\n\n");
    try writer.print(
        \\Usage:
        \\  scrapers --query <text> [--providers a,b] [--provider name] [-p provider] [--search-page N] [--subtitle-page N] [--title-index N] [--subtitle-index N] [--out-dir DIR] [--extract]
        \\  scrapers --list-providers
        \\  scrapers --help
        \\
        \\Examples:
        \\  scrapers --query "The Matrix"
        \\  scrapers --providers subdl_com,subsource_net --query "The Matrix" --title-index 0
        \\  scrapers --providers=none,subdl_com --query "The Matrix"
        \\  scrapers -pnone -p subsource --query "The Matrix"
        \\  scrapers -p subsource --query "The Matrix" --extract
        \\
    ,
        .{},
    );
}

test "CLI usage advertises its help and provider spellings" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try printUsage(&output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "scrapers --help") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "--provider name") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Interactive mode") == null);

    var tui_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer tui_output.deinit();
    try printUsageWithTuiAvailability(&tui_output.writer, true);
    try std.testing.expect(std.mem.startsWith(u8, tui_output.written(), "Interactive mode: scrapers --tui\n\nUsage:\n"));
}

test "CLI retains Windows argument storage for query and output directory" {
    const command = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "scrapers --query \"進撃の巨人\" --out-dir \"字幕 files\" -pnone");
    defer std.testing.allocator.free(command);
    var iterator = try std.process.Args.Iterator.Windows.init(std.testing.allocator, command);
    defer iterator.deinit();
    const config = try parseArgs(&iterator);
    const churn = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(churn);
    @memset(churn, 0xa5);
    try std.testing.expectEqualStrings("進撃の巨人", config.query.?);
    try std.testing.expectEqualStrings("字幕 files", config.out_dir);
    try std.testing.expectEqual(@as(usize, 0), common.countTrue(&config.providers_enabled));
}

test "CLI none provider selector resets earlier choices and allows a later provider" {
    const command = try std.unicode.utf8ToUtf16LeAlloc(
        std.testing.allocator,
        "scrapers -p subdl_com -pnone -p subsource --query title",
    );
    defer std.testing.allocator.free(command);
    var iterator = try std.process.Args.Iterator.Windows.init(std.testing.allocator, command);
    defer iterator.deinit();

    const config = try parseArgs(&iterator);
    try std.testing.expectEqual(@as(usize, 1), common.countTrue(&config.providers_enabled));
    const subsource_index = app.providerIndex(.subsource_net) orelse return error.MissingActiveProviderIndex;
    try std.testing.expect(config.providers_enabled[subsource_index]);
}

test "CLI page selectors are positive bounded integers" {
    const Case = struct { text: []const u8, err: ?anyerror = null, search: u32 = 1, subtitle: u32 = 1 };
    for ([_]Case{
        .{ .text = "scrapers" },
        .{ .text = "scrapers --search-page 2 --subtitle-page 3", .search = 2, .subtitle = 3 },
        .{ .text = "scrapers --search-page 0", .err = error.InvalidPage },
        .{ .text = "scrapers --subtitle-page 0", .err = error.InvalidPage },
        .{ .text = "scrapers --search-page -1", .err = error.InvalidCharacter },
        .{ .text = "scrapers --search-page xyz", .err = error.InvalidCharacter },
        .{ .text = "scrapers --search-page 4294967296", .err = error.Overflow },
        .{ .text = "scrapers --search-page", .err = error.MissingArgumentValue },
    }) |case| {
        const command = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, case.text);
        defer std.testing.allocator.free(command);
        var iterator = try std.process.Args.Iterator.Windows.init(std.testing.allocator, command);
        defer iterator.deinit();
        if (case.err) |err| {
            try std.testing.expectError(err, parseArgs(&iterator));
        } else {
            const config = try parseArgs(&iterator);
            try std.testing.expectEqual(case.search, config.search_page);
            try std.testing.expectEqual(case.subtitle, config.subtitle_page);
        }
    }
}

test "CLI help is order-independent among valid options" {
    for ([_][]const u8{
        "scrapers --help --query title",
        "scrapers --query title --help",
    }) |text| {
        const command = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, text);
        defer std.testing.allocator.free(command);
        var iterator = try std.process.Args.Iterator.Windows.init(std.testing.allocator, command);
        defer iterator.deinit();
        const config = try parseArgs(&iterator);
        try std.testing.expect(config.help);
        try std.testing.expectEqualStrings("title", config.query.?);
    }
}

test "CLI help does not suppress trailing argument errors" {
    const command = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "scrapers --help --bogus");
    defer std.testing.allocator.free(command);
    var iterator = try std.process.Args.Iterator.Windows.init(std.testing.allocator, command);
    defer iterator.deinit();
    try std.testing.expectError(error.UnknownArgument, parseArgs(&iterator));
}

test "CLI group work has an eager single-threaded fallback" {
    const Fixture = struct {
        fn run(calls: *usize) std.Io.Cancelable!void {
            calls.* += 1;
        }
    };
    var group: std.Io.Group = .init;
    var calls: usize = 0;
    try runOrScheduleGroup(true, &group, std.testing.io, Fixture.run, .{&calls});
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "CLI browser failures include actionable hints" {
    const consent_hint = browserErrorHint(error.DownloadConsentRequired).?;
    try std.testing.expect(std.mem.indexOf(u8, consent_hint, "download-protection consent") != null);
    for ([_]anyerror{ error.DownloadConsentRequired, error.InvalidDownloadSession }) |err| {
        const hint = browserErrorHint(err).?;
        try std.testing.expect(std.mem.indexOf(u8, hint, "browser session") != null);
        try std.testing.expect(std.mem.indexOf(u8, hint, "SCRAPERS_PRIJEVODI_*") != null);
        try std.testing.expect(std.mem.indexOf(u8, hint, "DOCUMENTATION.md") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, browserErrorHint(error.BrowserAutomationDisabled).?, "enable-alldriver") != null);
    try std.testing.expect(std.mem.indexOf(u8, browserErrorHint(error.InvalidBrowserExecutable).?, "SUBDL_CHROMIUM_PATH") != null);
    const challenge_hint = browserErrorHint(error.CloudflareSessionUnavailable).?;
    try std.testing.expect(std.mem.indexOf(u8, challenge_hint, "if authorized") != null);
    try std.testing.expect(std.mem.indexOf(u8, challenge_hint, "manually") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), browserErrorHint(error.ConnectionRefused));
}

const TerminalText = struct {
    bytes: []const u8,
    pub fn format(self: TerminalText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < self.bytes.len) {
            const first = self.bytes[i];
            const seq_len_raw = std.unicode.utf8ByteSequenceLength(first) catch {
                try writeEscapedByte(writer, first);
                i += 1;
                continue;
            };
            const seq_len: usize = @intCast(seq_len_raw);
            if (seq_len > self.bytes.len - i) {
                try writeEscapedByte(writer, first);
                i += 1;
                continue;
            }

            const segment = self.bytes[i .. i + seq_len];
            const codepoint = std.unicode.utf8Decode(segment) catch {
                try writeEscapedByte(writer, first);
                i += 1;
                continue;
            };

            if (seq_len == 1 and (first < 0x20 or first == 0x7f)) {
                try writeEscapedByte(writer, first);
            } else if ((codepoint >= 0x80 and codepoint <= 0x9f) or isTerminalFormatControl(codepoint)) {
                try writer.print("\\u{{{x}}}", .{codepoint});
            } else {
                try writer.writeAll(segment);
            }
            i += seq_len;
        }
    }
};

fn writeEscapedByte(writer: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    const hex = "0123456789abcdef";
    try writer.writeAll(&.{ '\\', 'x', hex[byte >> 4], hex[byte & 15] });
}

fn isTerminalFormatControl(codepoint: u21) bool {
    return switch (codepoint) {
        0x00ad,
        0x061c,
        0x180e,
        0x200b,
        0xfeff,
        0xe0001,
        0x17b4...0x17b5,
        0x200e...0x200f,
        0x2028...0x202e,
        0x2060...0x2064,
        0x2066...0x206f,
        0xfff9...0xfffb,
        0xe0020...0xe007f,
        => true,
        else => false,
    };
}

fn terminalText(bytes: []const u8) TerminalText {
    return .{ .bytes = bytes };
}
test "CLI provider text cannot emit terminal control sequences" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{terminalText("字幕\x1b[2J\nnext")});
    try std.testing.expectEqualStrings("字幕\\x1b[2J\\x0anext", output.written());
}

test "CLI provider text escapes C1, bidi, and invisible format controls" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{terminalText("字幕\u{009b}2J\u{202e}abc\u{feff}")});
    try std.testing.expectEqualStrings("字幕\\u{9b}2J\\u{202e}abc\\u{feff}", output.written());
}

test "CLI provider text escapes invalid UTF-8 and preserves ordinary Unicode" {
    const invalid = [_]u8{ 'x', 0x9b, 0xff, 'y' };
    var invalid_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid_output.deinit();
    try invalid_output.writer.print("{f}", .{terminalText(&invalid)});
    try std.testing.expectEqualStrings("x\\x9b\\xffy", invalid_output.written());

    const ordinary = "字幕 \u{1f469}\u{200d}\u{1f4bb}";
    var ordinary_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ordinary_output.deinit();
    try ordinary_output.writer.print("{f}", .{terminalText(ordinary)});
    try std.testing.expectEqualStrings(ordinary, ordinary_output.written());
}
