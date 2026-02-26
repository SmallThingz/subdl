const std = @import("std");
const scrapers = @import("scrapers");

const app = scrapers.providers_app;

const Config = struct {
    provider: app.Provider = .subdl_com,
    query: ?[]const u8 = null,
    title_index: usize = 0,
    subtitle_index: ?usize = null,
    out_dir: []const u8 = "downloads",
    list_providers: bool = false,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const config = parseArgs(gpa, stderr) catch |err| {
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

    var client: std.http.Client = .{ .allocator = gpa };
    defer client.deinit();

    var search = app.search(gpa, &client, config.provider, query) catch |err| {
        try stderr.print("search failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    defer search.deinit();

    if (search.items.len == 0) {
        try stderr.print("no search results for provider {s}\n", .{app.providerName(config.provider)});
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.print("Provider: {s}\n", .{app.providerName(config.provider)});
    try stdout.print("Query: {s}\n", .{query});
    try stdout.print("Search Results ({d}):\n", .{search.items.len});
    for (search.items, 0..) |item, idx| {
        try stdout.print("  [{d}] {s}\n", .{ idx, item.label });
    }

    if (config.title_index >= search.items.len) {
        try stderr.print("title-index out of range: {d} (max {d})\n", .{ config.title_index, search.items.len - 1 });
        try stderr.flush();
        std.process.exit(2);
    }

    var subtitles = app.fetchSubtitles(gpa, &client, search.items[config.title_index].ref) catch |err| {
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

    try stdout.print("\nTitle: {s}\n", .{subtitles.title});
    try stdout.print("Subtitle Rows ({d}):\n", .{subtitles.items.len});
    for (subtitles.items, 0..) |item, idx| {
        const status = if (item.download_url != null) "downloadable" else "no-direct-url";
        try stdout.print("  [{d}] {s} [{s}]\n", .{ idx, item.label, status });
    }

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

    var result = app.downloadSubtitle(gpa, &client, selected, config.out_dir) catch |err| {
        try stderr.print("download failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    defer result.deinit(gpa);

    try stdout.print("\nDownloaded:\n", .{});
    try stdout.print("  Provider: {s}\n", .{app.providerName(config.provider)});
    try stdout.print("  File: {s}\n", .{result.file_path});
    if (result.archive_path) |archive_path| {
        try stdout.print("  Archive: {s}\n", .{archive_path});
    }
    if (result.extracted_files.len > 0) {
        try stdout.print("  Extracted subtitle files ({d}):\n", .{result.extracted_files.len});
        for (result.extracted_files) |path| {
            try stdout.print("    - {s}\n", .{path});
        }
    }
    try stdout.print("  Bytes: {d}\n", .{result.bytes_written});
    try stdout.print("  URL: {s}\n", .{result.source_url});
    try stdout.flush();
}

fn parseArgs(allocator: std.mem.Allocator, stderr: *std.Io.Writer) !Config {
    var cfg: Config = .{};

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--provider")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            cfg.provider = app.parseProvider(value) orelse return error.InvalidProvider;
            continue;
        }
        if (std.mem.eql(u8, arg, "--query")) {
            cfg.query = args.next() orelse return error.MissingArgumentValue;
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

fn findFirstDownloadable(items: []const app.SubtitleChoice) ?usize {
    for (items, 0..) |item, idx| {
        if (item.download_url != null) return idx;
    }
    return null;
}

fn printProviders(writer: *std.Io.Writer) !void {
    try writer.print("Available providers:\n", .{});
    for (app.providers()) |provider| {
        try writer.print("  {s}\n", .{app.providerName(provider)});
    }
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage:
        \\  scrapers_cli --provider <name> --query <text> [--title-index N] [--subtitle-index N] [--out-dir DIR]
        \\  scrapers_cli --list-providers
        \\
        \\Examples:
        \\  scrapers_cli --provider subdl_com --query "The Matrix"
        \\  scrapers_cli --provider podnapisi_net --query "The Matrix" --title-index 0 --subtitle-index 1 --out-dir downloads
        \\
    ,
        .{},
    );
}
