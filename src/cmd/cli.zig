const std = @import("std");
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

pub fn main(init: std.process.Init) !void {
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
    const config = parseArgs(&args, stderr) catch |err| {
        try stderr.print("argument error: {s}\n\n", .{@errorName(err)});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(2);
    };

    if (config.list_providers) {
        try printProviders(stdout);
        try stdout.flush();
        return;
    }

    const query = config.query orelse {
        try printUsage(stderr);
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
        if (!config.providers_enabled[app.providerIndex(provider)]) continue;
        tasks[task_count] = .{ .provider = provider, .query = query, .page = config.search_page };
        initialized_count = task_count + 1;
        try search_group.concurrent(init.io, searchTaskMain, .{&tasks[task_count]});
        task_count += 1;
    }
    try search_group.await(init.io);

    var failed_count: usize = 0;
    for (tasks[0..task_count]) |*task| {
        if (task.err) |err| {
            failed_count += 1;
            try stderr.print("warning: search failed for {s}: {s}\n", .{ app.providerName(task.provider), @errorName(err) });
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
    try stdout.print("  URL: {f}\n", .{terminalText(result.source_url)});
    try stdout.flush();
}

fn parseArgs(args: anytype, stderr: *std.Io.Writer) !Config {
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
            try printUsage(stderr);
            try stderr.flush();
            std.process.exit(0);
        }
        return error.UnknownArgument;
    }

    return cfg;
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
        cfg.providers_enabled[app.providerIndex(provider)] = true;
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
    try writer.print(
        \\Usage:
        \\  scrapers --query <text> [--providers a,b] [-p provider] [--search-page N] [--subtitle-page N] [--title-index N] [--subtitle-index N] [--out-dir DIR] [--extract]
        \\  scrapers --list-providers
        \\
        \\Examples:
        \\  scrapers --query "The Matrix"
        \\  scrapers --providers subdl_com,subsource_net --query "The Matrix" --title-index 0
        \\  scrapers --providers=none --query "The Matrix"
        \\  scrapers -pnone --query "The Matrix"
        \\  scrapers -p subsource --query "The Matrix" --extract
        \\
    ,
        .{},
    );
}

test "CLI retains Windows argument storage for query and output directory" {
    const command = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "scrapers --query \"進撃の巨人\" --out-dir \"字幕 files\" -pnone");
    defer std.testing.allocator.free(command);
    var iterator = try std.process.Args.Iterator.Windows.init(std.testing.allocator, command);
    defer iterator.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    const config = try parseArgs(&iterator, &errors.writer);
    const churn = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(churn);
    @memset(churn, 0xa5);
    try std.testing.expectEqualStrings("進撃の巨人", config.query.?);
    try std.testing.expectEqualStrings("字幕 files", config.out_dir);
    try std.testing.expectEqual(@as(usize, 0), common.countTrue(&config.providers_enabled));
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
        var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer errors.deinit();
        if (case.err) |err| {
            try std.testing.expectError(err, parseArgs(&iterator, &errors.writer));
        } else {
            const config = try parseArgs(&iterator, &errors.writer);
            try std.testing.expectEqual(case.search, config.search_page);
            try std.testing.expectEqual(case.subtitle, config.subtitle_page);
        }
    }
}

const TerminalText = struct {
    bytes: []const u8,
    pub fn format(self: TerminalText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const hex = "0123456789abcdef";
        for (self.bytes) |byte| {
            if (byte < 0x20 or byte == 0x7f) {
                try writer.writeAll(&.{ '\\', 'x', hex[byte >> 4], hex[byte & 15] });
            } else try writer.writeByte(byte);
        }
    }
};
fn terminalText(bytes: []const u8) TerminalText {
    return .{ .bytes = bytes };
}
test "CLI provider text cannot emit terminal control sequences" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{terminalText("字幕\x1b[2J\nnext")});
    try std.testing.expectEqualStrings("字幕\\x1b[2J\\x0anext", output.written());
}
