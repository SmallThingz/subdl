const std = @import("std");
const common = @import("common.zig");
const cf = @import("opensubtitles_com_cf.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.opensubtitles.com";

pub const SearchItem = struct {
    title: []const u8,
    year: ?[]const u8,
    item_type: ?[]const u8,
    path: []const u8,
    subtitles_count: ?i64,
    subtitles_list_url: []const u8,
};

pub const SubtitleItem = struct {
    language: ?[]const u8,
    filename: ?[]const u8,
    row_summary: ?[]const u8,
    remote_endpoint: []const u8,
    resolved_filename: ?[]const u8,
    verified_download_url: ?[]const u8,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SearchItem,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    subtitles: []const SubtitleItem,

    pub fn deinit(self: *SubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Scraper = struct {
    pub const Options = struct {
        language_code: []const u8 = "en",
    };

    pub const FetchSubtitlesOptions = struct {
        resolve_downloads: bool = false,
        resolve_limit: usize = 8,
    };

    allocator: Allocator,
    client: *std.http.Client,
    options: Options,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client, .options = .{} };
    }

    pub fn initWithOptions(allocator: Allocator, client: *std.http.Client, options: Options) Scraper {
        return .{ .allocator = allocator, .client = client, .options = options };
    }

    pub fn deinit(_: *Scraper) void {}

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var session = try cf.ensureSession(a, .{});
        const encoded = try common.encodeUriComponent(a, query);
        const language = self.options.language_code;
        const url = try std.fmt.allocPrint(a, "{s}/{s}/{s}/search/autocomplete/{s}.json", .{ site, language, language, encoded });

        const body = try fetchWithSession(self.client, a, &session, url, .{ .accept = "application/json" }, true);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const arr = switch (root) {
            .array => |arr| arr,
            else => return error.InvalidFieldType,
        };

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (arr.items) |entry| {
            const obj = switch (entry) {
                .object => |o| o,
                else => continue,
            };

            const title = if (obj.get("title")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;
            const path = if (obj.get("path")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;
            const year = if (obj.get("year")) |v| switch (v) {
                .string => |s| s,
                .number_string => |s| s,
                .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
                else => null,
            } else null;
            const item_type = if (obj.get("type")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null;
            const subtitles_count = if (obj.get("subtitles_count")) |v| switch (v) {
                .integer => |i| i,
                .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => null,
            } else null;

            var replaced = std.ArrayList(u8).empty;
            defer replaced.deinit(a);
            const current_locale = "current_locale";
            var cursor: usize = 0;
            while (std.mem.indexOfPos(u8, path, cursor, current_locale)) |idx| {
                try replaced.appendSlice(a, path[cursor..idx]);
                try replaced.appendSlice(a, language);
                cursor = idx + current_locale.len;
            }
            try replaced.appendSlice(a, path[cursor..]);
            const locale_path = replaced.items;
            const feature_path = try replaceMoviesWithFeatures(a, locale_path);
            const subtitles_list_url = try std.fmt.allocPrint(a, "{s}/{s}/subtitles_list.json", .{ site, feature_path });

            try out.append(a, .{
                .title = title,
                .year = year,
                .item_type = item_type,
                .path = path,
                .subtitles_count = subtitles_count,
                .subtitles_list_url = subtitles_list_url,
            });
        }

        return .{ .arena = arena, .items = try out.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        return self.fetchSubtitlesBySearchItemWithOptions(item, .{});
    }

    pub fn fetchSubtitlesBySearchItemWithOptions(self: *Scraper, item: SearchItem, options: FetchSubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var session = try cf.ensureSession(a, .{});
        const list_body = try fetchWithSession(self.client, a, &session, item.subtitles_list_url, .{ .accept = "application/json" }, true);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, list_body, .{});
        const obj = switch (root) {
            .object => |o| o,
            else => return error.InvalidFieldType,
        };
        const data = obj.get("data") orelse return error.MissingField;
        const rows = switch (data) {
            .array => |arr| arr,
            else => return error.InvalidFieldType,
        };

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var resolved_count: usize = 0;
        for (rows.items) |row| {
            const cols = switch (row) {
                .array => |arr| arr,
                else => continue,
            };
            if (cols.items.len == 0) continue;

            const language = parseLanguageFromCell(a, cols.items, 1) catch null;
            const filename = parseFilenameFromCell(a, cols.items, 2) catch null;
            const row_summary = summarizeRow(a, cols.items) catch null;
            const remote = parseRemoteEndpoint(a, cols.items) catch continue;

            const should_resolve = options.resolve_downloads and
                (options.resolve_limit == 0 or resolved_count < options.resolve_limit);
            const resolved: ResolvedDownload = if (should_resolve)
                self.resolveAndVerifyDownloadWithSession(a, &session, remote) catch |err| switch (err) {
                    error.CloudflareSessionUnavailable, error.UnexpectedHttpStatus => .{ .filename = null, .verified_url = null },
                    else => return err,
                }
            else
                .{ .filename = null, .verified_url = null };
            if (should_resolve) resolved_count += 1;

            try subtitles.append(a, .{
                .language = language,
                .filename = filename,
                .row_summary = row_summary,
                .remote_endpoint = remote,
                .resolved_filename = resolved.filename,
                .verified_download_url = resolved.verified_url,
            });
        }

        return .{ .arena = arena, .subtitles = try subtitles.toOwnedSlice(a) };
    }

    const ResolvedDownload = struct {
        filename: ?[]const u8,
        verified_url: ?[]const u8,
    };

    pub fn resolveVerifiedDownloadUrl(self: *Scraper, allocator: Allocator, remote_endpoint: []const u8) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var session = try cf.ensureSession(a, .{});
        const resolved = try self.resolveAndVerifyDownloadWithSession(a, &session, remote_endpoint);
        if (resolved.verified_url) |url| {
            return try allocator.dupe(u8, url);
        }
        return null;
    }

    pub fn resolveAndVerifyDownload(self: *Scraper, remote_endpoint: []const u8) !ResolvedDownload {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var session = try cf.ensureSession(a, .{});
        const resolved = try self.resolveAndVerifyDownloadWithSession(a, &session, remote_endpoint);
        return .{
            .filename = if (resolved.filename) |name| try self.allocator.dupe(u8, name) else null,
            .verified_url = if (resolved.verified_url) |url| try self.allocator.dupe(u8, url) else null,
        };
    }

    fn resolveAndVerifyDownloadWithSession(self: *Scraper, allocator: Allocator, session: *cf.Session, remote_endpoint: []const u8) !ResolvedDownload {
        const language = self.options.language_code;
        const remote_url = if (std.mem.startsWith(u8, remote_endpoint, "http"))
            remote_endpoint
        else
            try common.resolveUrl(allocator, site, remote_endpoint);

        const csrf_token = session.csrf_token orelse "";
        const headers = [_]std.http.Header{
            .{ .name = "referer", .value = site ++ "/" },
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
            .{ .name = "x-csrf-token", .value = csrf_token },
            .{ .name = "accept", .value = "*/*" },
        };

        const body = try fetchWithSession(self.client, allocator, session, remote_url, .{
            .accept = "*/*",
            .extra_headers = &headers,
            .allow_non_ok = true,
        }, true);

        const parsed = parseFileDownload(body);
        if (parsed.url == null) return .{ .filename = null, .verified_url = null };

        const url = parsed.url orelse return .{ .filename = parsed.filename, .verified_url = null };
        const verify_referer = try std.fmt.allocPrint(allocator, "{s}/{s}/", .{ site, language });
        const verify_headers = [_]std.http.Header{
            .{ .name = "cookie", .value = session.cookie_header },
            .{ .name = "user-agent", .value = session.user_agent },
            .{ .name = "referer", .value = verify_referer },
            .{ .name = "accept", .value = "application/zip,application/octet-stream,*/*" },
        };

        const verify_status = verifyDownloadHeadWithCurlSession(allocator, session.*, url, &verify_headers) catch null;
        if (verify_status) |status| {
            if (status != .ok and status != .found and status != .moved_permanently and status != .see_other and status != .temporary_redirect and status != .permanent_redirect) {
                // Some mirrors/challenge edges reject HEAD while the URL is still valid for GET.
                return .{ .filename = parsed.filename, .verified_url = url };
            }
        }

        return .{ .filename = parsed.filename, .verified_url = url };
    }
};

const SessionFetchOptions = struct {
    accept: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    allow_non_ok: bool = false,
};

fn fetchWithSession(client: *std.http.Client, allocator: Allocator, session: *cf.Session, url: []const u8, options: SessionFetchOptions, refresh_on_403: bool) ![]u8 {
    if (try fetchWithCurlSession(allocator, session.*, url, options)) |curl_response| {
        if (curl_response.status == .forbidden and refresh_on_403) {
            allocator.free(curl_response.body);
            session.* = try cf.ensureSession(allocator, .{ .force_refresh = true });

            if (try fetchWithCurlSession(allocator, session.*, url, options)) |refreshed| {
                if (!options.allow_non_ok and refreshed.status != .ok) {
                    allocator.free(refreshed.body);
                    return error.UnexpectedHttpStatus;
                }
                return refreshed.body;
            }
            // Curl was available for the first attempt but not after refresh.
            // Fall back to std.http below.
        } else {
            if (!options.allow_non_ok and curl_response.status != .ok) {
                allocator.free(curl_response.body);
                return error.UnexpectedHttpStatus;
            }
            return curl_response.body;
        }
    }

    const headers = try joinHeadersWithSession(allocator, session.*, options.extra_headers);
    defer allocator.free(headers);

    var response = try common.fetchBytes(client, allocator, url, .{
        .accept = options.accept,
        .extra_headers = headers,
        .allow_non_ok = true,
        .max_attempts = 2,
    });

    if (response.status == .forbidden and refresh_on_403) {
        allocator.free(response.body);

        // Cloudflare cookies can appear before the challenge flow has fully settled.
        // Retry once with the same session before forcing a fresh browser run.
        std.Thread.sleep(1200 * std.time.ns_per_ms);
        response = try common.fetchBytes(client, allocator, url, .{
            .accept = options.accept,
            .extra_headers = headers,
            .allow_non_ok = true,
            .max_attempts = 1,
        });
        if (response.status != .forbidden) {
            if (!options.allow_non_ok and response.status != .ok) {
                allocator.free(response.body);
                return error.UnexpectedHttpStatus;
            }
            return response.body;
        }

        allocator.free(response.body);
        session.* = try cf.ensureSession(allocator, .{ .force_refresh = true });
        const refreshed_headers = try joinHeadersWithSession(allocator, session.*, options.extra_headers);
        defer allocator.free(refreshed_headers);
        response = try common.fetchBytes(client, allocator, url, .{
            .accept = options.accept,
            .extra_headers = refreshed_headers,
            .allow_non_ok = true,
            .max_attempts = 1,
        });
    }

    if (!options.allow_non_ok and response.status != .ok) {
        allocator.free(response.body);
        return error.UnexpectedHttpStatus;
    }

    return response.body;
}

fn joinHeadersWithSession(allocator: Allocator, session: cf.Session, headers: []const std.http.Header) ![]std.http.Header {
    var out = try allocator.alloc(std.http.Header, headers.len + 2);
    out[0] = .{ .name = "cookie", .value = session.cookie_header };
    out[1] = .{ .name = "user-agent", .value = session.user_agent };
    for (headers, 0..) |h, i| out[i + 2] = h;
    return out;
}

fn fetchWithCurlSession(allocator: Allocator, session: cf.Session, url: []const u8, options: SessionFetchOptions) !?common.HttpResponse {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    var owned_args: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned_args.items) |arg| allocator.free(arg);
        owned_args.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "--location",
        "--max-time",
        "45",
        "--compressed",
        "-X",
        "GET",
        "-A",
        session.user_agent,
    });

    const cookie_header = try std.fmt.allocPrint(allocator, "Cookie: {s}", .{session.cookie_header});
    try owned_args.append(allocator, cookie_header);
    try argv.appendSlice(allocator, &.{ "-H", cookie_header });

    if (options.accept) |accept| {
        const accept_header = try std.fmt.allocPrint(allocator, "Accept: {s}", .{accept});
        try owned_args.append(allocator, accept_header);
        try argv.appendSlice(allocator, &.{ "-H", accept_header });
    }

    for (options.extra_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) continue;
        if (options.accept != null and std.ascii.eqlIgnoreCase(h.name, "accept")) continue;

        const header_line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ h.name, h.value });
        try owned_args.append(allocator, header_line);
        try argv.appendSlice(allocator, &.{ "-H", header_line });
    }

    try argv.appendSlice(allocator, &.{ "-w", "\n%{http_code}", url });

    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 8 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    switch (run_result.term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    const sep = std.mem.lastIndexOfScalar(u8, run_result.stdout, '\n') orelse return null;
    const status_raw = std.mem.trim(u8, run_result.stdout[sep + 1 ..], " \t\r\n");
    const status_code = std.fmt.parseInt(u10, status_raw, 10) catch return null;
    const body = run_result.stdout[0..sep];

    return .{
        .status = @enumFromInt(status_code),
        .body = try allocator.dupe(u8, body),
    };
}

fn verifyDownloadHeadWithCurlSession(
    allocator: Allocator,
    session: cf.Session,
    url: []const u8,
    headers: []const std.http.Header,
) !?std.http.Status {
    var phase = common.LivePhase.init("opensubtitles.com", "verify_download_head");
    phase.start();
    defer phase.finish();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    var owned_args: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned_args.items) |arg| allocator.free(arg);
        owned_args.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "--location",
        "--max-time",
        "45",
        "--compressed",
        "-I",
        "-A",
        session.user_agent,
    });

    const cookie_header = try std.fmt.allocPrint(allocator, "Cookie: {s}", .{session.cookie_header});
    try owned_args.append(allocator, cookie_header);
    try argv.appendSlice(allocator, &.{ "-H", cookie_header });

    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) continue;
        const header_line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ h.name, h.value });
        try owned_args.append(allocator, header_line);
        try argv.appendSlice(allocator, &.{ "-H", header_line });
    }

    try argv.appendSlice(allocator, &.{ "-w", "\n%{http_code}", url });

    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 64 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    switch (run_result.term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    const sep = std.mem.lastIndexOfScalar(u8, run_result.stdout, '\n') orelse return null;
    const status_raw = std.mem.trim(u8, run_result.stdout[sep + 1 ..], " \t\r\n");
    const status_code = std.fmt.parseInt(u10, status_raw, 10) catch return null;
    return @enumFromInt(status_code);
}

fn parseLanguageFromCell(allocator: Allocator, cols: []const std.json.Value, idx: usize) !?[]const u8 {
    if (idx >= cols.len) return null;
    const html = switch (cols[idx]) {
        .string => |s| s,
        else => return null,
    };
    const wrapped = try std.fmt.allocPrint(allocator, "<div>{s}</div>", .{html});
    var parsed = try common.parseHtmlTurbo(allocator, wrapped);
    defer parsed.deinit();
    if (parsed.doc.queryOne("*[title]")) |n| {
        const title = n.getAttributeValue("title") orelse return null;
        return try allocator.dupe(u8, title);
    }
    const node = parsed.doc.queryOne("div") orelse return null;
    return try common.innerTextTrimmedOwned(allocator, node);
}

fn parseFilenameFromCell(allocator: Allocator, cols: []const std.json.Value, idx: usize) !?[]const u8 {
    if (idx >= cols.len) return null;
    const html = switch (cols[idx]) {
        .string => |s| s,
        else => return null,
    };
    const wrapped = try std.fmt.allocPrint(allocator, "<div>{s}</div>", .{html});
    var parsed = try common.parseHtmlTurbo(allocator, wrapped);
    defer parsed.deinit();
    const div = parsed.doc.queryOne("div") orelse return null;
    const txt = try common.innerTextTrimmedOwned(allocator, div);
    if (txt.len == 0) return null;
    return txt;
}

fn summarizeRow(allocator: Allocator, cols: []const std.json.Value) !?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (cols, 0..) |col, i| {
        const html = switch (col) {
            .string => |s| s,
            else => continue,
        };
        const wrapped = try std.fmt.allocPrint(allocator, "<div>{s}</div>", .{html});
        var parsed = try common.parseHtmlTurbo(allocator, wrapped);
        defer parsed.deinit();
        const div = parsed.doc.queryOne("div") orelse continue;
        const txt = try common.innerTextTrimmedOwned(allocator, div);
        if (txt.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(allocator, " | ");
        try out.appendSlice(allocator, txt);
        if (i >= 6 and out.items.len > 240) break;
    }

    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn parseRemoteEndpoint(allocator: Allocator, cols: []const std.json.Value) ![]const u8 {
    const idx = cols.len - 1;
    const html = switch (cols[idx]) {
        .string => |s| s,
        else => return error.MissingField,
    };

    const wrapped = try std.fmt.allocPrint(allocator, "<div>{s}</div>", .{html});
    var parsed = try common.parseHtmlTurbo(allocator, wrapped);
    defer parsed.deinit();

    const anchor = parsed.doc.queryOne("a[data-remote='true']") orelse return error.MissingField;
    const href = anchor.getAttributeValue("href") orelse return error.MissingField;
    return try common.resolveUrl(allocator, site, href);
}

const FileDownload = struct {
    filename: ?[]const u8,
    url: ?[]const u8,
};

fn parseFileDownload(body: []const u8) FileDownload {
    const marker = "file_download('";
    const start = std.mem.indexOf(u8, body, marker) orelse return .{ .filename = null, .url = null };
    const after = body[start + marker.len ..];

    const quote1 = std.mem.indexOfScalar(u8, after, '\'') orelse return .{ .filename = null, .url = null };
    const filename = after[0..quote1];

    const comma_marker = "','";
    const comma_idx = std.mem.indexOfPos(u8, after, quote1, comma_marker) orelse return .{ .filename = filename, .url = null };
    const url_start = comma_idx + comma_marker.len;
    const tail = after[url_start..];
    const url_end = std.mem.indexOfScalar(u8, tail, '\'') orelse return .{ .filename = filename, .url = null };
    const url = tail[0..url_end];

    return .{ .filename = filename, .url = url };
}

fn replaceMoviesWithFeatures(allocator: Allocator, input: []const u8) ![]const u8 {
    const needle = "/movies/";
    const idx = std.mem.indexOf(u8, input, needle) orelse return try allocator.dupe(u8, input);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, input[0..idx]);
    try out.appendSlice(allocator, "/features/");
    try out.appendSlice(allocator, input[idx + needle.len ..]);
    return try out.toOwnedSlice(allocator);
}

test "parse opensubtitles.com file_download" {
    const parsed = parseFileDownload("x file_download('name.zip','https://a/b.zip') y");
    try std.testing.expectEqualStrings("name.zip", parsed.filename.?);
    try std.testing.expectEqualStrings("https://a/b.zip", parsed.url.?);
}

test "live opensubtitles.com search and resolve" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "OPENSUBTITLES_COM")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    const item = search.items[0];
    std.debug.print("[live][opensubtitles.com][search][0]\n", .{});
    try common.livePrintField(std.testing.allocator, "title", item.title);
    try common.livePrintOptionalField(std.testing.allocator, "year", item.year);
    try common.livePrintOptionalField(std.testing.allocator, "item_type", item.item_type);
    try common.livePrintField(std.testing.allocator, "path", item.path);
    if (item.subtitles_count) |count| {
        std.debug.print("[live] subtitles_count={d}\n", .{count});
    } else {
        std.debug.print("[live] subtitles_count=<null>\n", .{});
    }
    try common.livePrintField(std.testing.allocator, "subtitles_list_url", item.subtitles_list_url);

    var subtitles = try scraper.fetchSubtitlesBySearchItemWithOptions(item, .{
        .resolve_downloads = false,
    });
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    const sub = subtitles.subtitles[0];
    std.debug.print("[live][opensubtitles.com][subtitle][0]\n", .{});
    try common.livePrintOptionalField(std.testing.allocator, "language", sub.language);
    try common.livePrintOptionalField(std.testing.allocator, "filename", sub.filename);
    try common.livePrintOptionalField(std.testing.allocator, "row_summary", sub.row_summary);
    try common.livePrintField(std.testing.allocator, "remote_endpoint", sub.remote_endpoint);
    try common.livePrintOptionalField(std.testing.allocator, "resolved_filename", sub.resolved_filename);
    try common.livePrintOptionalField(std.testing.allocator, "verified_download_url", sub.verified_download_url);
}
