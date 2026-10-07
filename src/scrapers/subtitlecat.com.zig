const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

const Allocator = std.mem.Allocator;
const site = "https://www.subtitlecat.com";

pub const SearchItem = struct {
    title: []const u8,
    details_url: []const u8,
    source_language: ?[]const u8,
};

pub const TranslateSpec = struct {
    source_url: ?[]const u8,
};

pub const SubtitleItem = struct {
    language_code: ?[]const u8,
    language_label: ?[]const u8,
    filename: []const u8,
    mode: enum { direct_download, translated },
    source_url: ?[]const u8,
    download_url: ?[]const u8,
    translate_spec: ?TranslateSpec,
};

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.SubtitlesResponse(SubtitleItem);

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const trimmed_query = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed_query.len == 0) return .{ .arena = arena, .items = &.{} };
        const encoded = try common.encodeUriComponent(a, trimmed_query);
        const url = try std.fmt.allocPrint(a, "{s}/index.php?search={s}&show=10000", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{
            .accept = "text/html",
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });

        var parsed = try common.parseHtmlStable(a, response.body);

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        var anchors = parsed.doc.queryAll("table.sub-table tbody tr td:first-child a");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const title = try common.innerTextTrimmedOwned(a, anchor);
            if (title.len == 0) continue;
            const details_url = resolveProviderUrl(a, href, .details) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (seen.contains(details_url)) continue;
            try seen.put(a, details_url, {});
            const first_cell = anchor.parentNode() orelse continue;
            const raw = try common.innerTextTrimmedOwned(a, first_cell);
            const source_language = parseTranslatedFrom(raw);

            try items.append(a, .{ .title = title, .details_url = details_url, .source_language = source_language });
        }

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesByDetailsLink(self: *Scraper, details_url: []const u8) !SubtitlesResponse {
        return self.fetchSubtitlesByDetailsLinkUsing(common.fetchBytes, details_url);
    }

    fn fetchSubtitlesByDetailsLinkUsing(self: *Scraper, comptime fetch: anytype, details_url: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        try validateProviderEndpoint(details_url, .details);
        const details_id = providerSubtitleId(details_url) orelse return error.UnsafeHttpTarget;

        const response = try fetch(self.client, a, details_url, .{
            .accept = "text/html",
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
        });
        var parsed = try common.parseHtmlStable(a, response.body);

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var blocks = parsed.doc.queryAll("div.sub-single");
        while (blocks.next()) |block| {
            var spans: [3]?HtmlNode = .{ null, null, null };
            var span_count: usize = 0;
            var children = block.children();
            while (children.next()) |child| {
                if (!std.mem.eql(u8, child.tagName(), "span")) continue;
                if (span_count < spans.len) spans[span_count] = child;
                span_count += 1;
            }

            const language_code = blk: {
                const first_span = spans[0] orelse break :blk null;
                const img = common.findDescendantByTag(first_span, "img") orelse break :blk null;
                const raw = common.getAttributeValueSafe(img, "alt") orelse break :blk null;
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (trimmed.len == 0) break :blk null;
                break :blk try a.dupe(u8, trimmed);
            };

            const language_label = if (spans[1]) |s2|
                try common.innerTextTrimmedOwned(a, s2)
            else
                null;

            if (spans[2]) |action| {
                var appended_direct = false;
                var download_anchors = action.queryAll("a[href]");
                while (download_anchors.next()) |download_anchor| {
                    const href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
                    const url = resolveProviderUrl(a, href, .subtitle) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    const source_id = providerSubtitleId(url) orelse continue;
                    if (!std.mem.eql(u8, details_id, source_id)) continue;
                    const inferred = inferFilenameFromUrl(url);
                    const filename = if (inferred) |value|
                        if (common.isSubtitleFilename(value)) value else "subtitle.srt"
                    else
                        "subtitle.srt";
                    try subtitles.append(a, .{
                        .language_code = language_code,
                        .language_label = language_label,
                        .filename = filename,
                        .mode = .direct_download,
                        .source_url = url,
                        .download_url = url,
                        .translate_spec = null,
                    });
                    appended_direct = true;
                    break;
                }
                if (appended_direct) continue;

                var buttons = action.queryAll("button[onclick]");
                while (buttons.next()) |button| {
                    const onclick = common.getAttributeValueSafe(button, "onclick") orelse continue;
                    const spec = usableTranslateSpec(try parseOptionalTranslateSpec(a, onclick)) orelse continue;
                    const source = spec.source_url.?;
                    const source_id = providerSubtitleId(source) orelse continue;
                    if (!std.mem.eql(u8, details_id, source_id)) continue;
                    const code = if (language_code) |c|
                        c
                    else if (common.getAttributeValueSafe(button, "id")) |id|
                        if (std.mem.trim(u8, id, " \t\r\n").len > 0) try a.dupe(u8, id) else null
                    else
                        null;
                    const filename = try inferTranslatedFilename(a, source, code);
                    try subtitles.append(a, .{
                        .language_code = code,
                        .language_label = language_label,
                        .filename = filename,
                        .mode = .translated,
                        .source_url = source,
                        .download_url = null,
                        .translate_spec = spec,
                    });
                    break;
                }
            }
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{ .arena = arena, .subtitles = try subtitles.toOwnedSlice(a) });
    }
};

fn parseTranslatedFrom(raw: []const u8) ?[]const u8 {
    const marker = "(translated from";
    const start = std.ascii.findIgnoreCase(raw, marker) orelse return null;
    const tail = raw[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, tail, ')') orelse tail.len;
    return std.mem.trim(u8, tail[0..end], " \t\r\n");
}

fn parseTranslateSpec(allocator: Allocator, onclick: []const u8) !TranslateSpec {
    const args = try extractQuotedArgs(allocator, onclick);
    defer allocator.free(args);

    if (args.len >= 3 and std.mem.startsWith(u8, onclick, "translate_from_server_folder")) {
        const filename = args[1];
        const folder = args[2];
        const folder_needs_alloc = !std.mem.endsWith(u8, folder, "/");
        const folder_norm = if (folder_needs_alloc)
            try std.fmt.allocPrint(allocator, "{s}/", .{folder})
        else
            folder;
        defer if (folder_needs_alloc) allocator.free(folder_norm);

        const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ folder_norm, filename });
        defer allocator.free(path);
        return .{ .source_url = try resolveProviderUrl(allocator, path, .subtitle) };
    }

    if (args.len >= 2 and std.mem.startsWith(u8, onclick, "translate_from_server")) {
        return .{ .source_url = try resolveProviderUrl(allocator, args[1], .subtitle) };
    }

    // Some deployments rename the translation helper, but unrelated buttons
    // must not be promoted into download rows merely because an argument ends
    // in .srt.
    if (std.ascii.findIgnoreCase(onclick, "translate") == null) return .{ .source_url = null };

    var filename_index: ?usize = null;
    for (args, 0..) |arg, index| {
        if (!std.ascii.endsWithIgnoreCase(arg, ".srt")) continue;
        if (std.mem.startsWith(u8, arg, "/") or
            std.ascii.startsWithIgnoreCase(arg, "http://") or
            std.ascii.startsWithIgnoreCase(arg, "https://"))
        {
            return .{ .source_url = try resolveProviderUrl(allocator, arg, .subtitle) };
        }
        if (filename_index == null) filename_index = index;
    }

    if (filename_index) |file_index| {
        const filename = args[file_index];
        for (args, 0..) |folder, folder_index| {
            if (folder_index == file_index or !std.mem.startsWith(u8, folder, "/")) continue;
            const separator = if (std.mem.endsWith(u8, folder, "/")) "" else "/";
            const path = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ folder, separator, filename });
            defer allocator.free(path);
            return .{ .source_url = try resolveProviderUrl(allocator, path, .subtitle) };
        }
        return .{ .source_url = try resolveProviderUrl(allocator, filename, .subtitle) };
    }

    return .{ .source_url = null };
}

fn parseOptionalTranslateSpec(allocator: Allocator, onclick: []const u8) !?TranslateSpec {
    return parseTranslateSpec(allocator, onclick) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
}

fn usableTranslateSpec(spec: ?TranslateSpec) ?TranslateSpec {
    const value = spec orelse return null;
    const source = value.source_url orelse return null;
    const filename = inferFilenameFromUrl(source) orelse return null;
    if (!std.ascii.endsWithIgnoreCase(filename, ".srt")) return null;
    return value;
}

fn extractQuotedArgs(allocator: Allocator, input: []const u8) ![]const []const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer args.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '\'') continue;
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, input, start, '\'') orelse break;
        try args.append(allocator, input[start..end]);
        i = end;
    }

    return try args.toOwnedSlice(allocator);
}

fn inferFilenameFromUrl(url: []const u8) ?[]const u8 {
    const suffix_start = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..suffix_start];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash + 1 >= path.len) return null;
    return path[slash + 1 ..];
}

fn inferTranslatedFilename(allocator: Allocator, source: ?[]const u8, lang_code: ?[]const u8) ![]const u8 {
    const lang = if (lang_code) |code| blk: {
        const trimmed = std.mem.trim(u8, code, " \t\r\n");
        break :blk if (trimmed.len > 0) trimmed else "translated";
    } else "translated";
    if (source) |src| {
        const base = inferFilenameFromUrl(src) orelse return try std.fmt.allocPrint(allocator, "subtitle-{s}.srt", .{lang});
        const extension = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        var stem = if (extension > 0) base[0..extension] else base;
        if (std.ascii.endsWithIgnoreCase(stem, "-orig")) stem = stem[0 .. stem.len - "-orig".len];
        if (stem.len == 0) return try std.fmt.allocPrint(allocator, "subtitle-{s}.srt", .{lang});
        return try std.fmt.allocPrint(allocator, "{s}-{s}.srt", .{ stem, lang });
    }
    return try std.fmt.allocPrint(allocator, "subtitle-{s}.srt", .{lang});
}

const ProviderRoute = enum { details, subtitle };

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderEndpoint(resolved, route);
    return resolved;
}

fn validateProviderEndpoint(url: []const u8, route: ProviderRoute) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len > 4096) return error.UnsafeHttpTarget;

    var segments = std.mem.splitScalar(u8, path, '/');
    if (!std.mem.eql(u8, segments.next() orelse return error.UnsafeHttpTarget, "") or
        !std.mem.eql(u8, segments.next() orelse return error.UnsafeHttpTarget, "subs"))
    {
        return error.UnsafeHttpTarget;
    }
    const id = segments.next() orelse return error.UnsafeHttpTarget;
    const filename = segments.next() orelse return error.UnsafeHttpTarget;
    if (segments.next() != null or !isCanonicalSubtitleId(id) or !isSafeEncodedFilename(filename))
        return error.UnsafeHttpTarget;

    const valid_extension = switch (route) {
        .details => std.ascii.endsWithIgnoreCase(filename, ".html"),
        .subtitle => common.isSubtitleFilename(filename),
    };
    if (!valid_extension) return error.UnsafeHttpTarget;
}

fn providerSubtitleId(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    var segments = std.mem.splitScalar(u8, path, '/');
    if (!std.mem.eql(u8, segments.next() orelse return null, "") or
        !std.mem.eql(u8, segments.next() orelse return null, "subs"))
    {
        return null;
    }
    return segments.next();
}

fn isCanonicalSubtitleId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isSafeEncodedFilename(value: []const u8) bool {
    if (value.len == 0 or value.len > 3072) return false;
    var decoded_len: usize = 0;
    var decoded_all_dots = true;
    var index: usize = 0;
    while (index < value.len) {
        var byte = value[index];
        if (byte == '%') {
            if (value.len - index < 3) return false;
            const high = std.fmt.charToDigit(value[index + 1], 16) catch return false;
            const low = std.fmt.charToDigit(value[index + 2], 16) catch return false;
            byte = @intCast(high * 16 + low);
            index += 3;
        } else {
            if (byte == '/' or byte == '\\' or byte == '?' or byte == '#') return false;
            index += 1;
        }
        if (byte < 0x20 or byte == 0x7f or byte == '%' or byte == '/' or byte == '\\' or byte == '?' or byte == '#') return false;
        decoded_len += 1;
        if (byte != '.') decoded_all_dots = false;
    }
    return !(decoded_all_dots and (decoded_len == 1 or decoded_len == 2));
}

test "subtitlecat rejects unsafe provider links" {
    try validateProviderEndpoint(site ++ "/subs/1687/The.Matrix.html", .details);
    try validateProviderEndpoint(site ++ "/subs/1687/The.Matrix-en.srt", .subtitle);
    for ([_]struct { url: []const u8, route: ProviderRoute }{
        .{ .url = "http://127.0.0.1/subs/1/file.html", .route = .details },
        .{ .url = "https://user:pass@www.subtitlecat.com/subs/1/file.html", .route = .details },
        .{ .url = "https://www.subtitlecat.com.evil.com/subs/1/file.html", .route = .details },
        .{ .url = site ++ "/index.php", .route = .details },
        .{ .url = site ++ "/subs/1687/file.srt", .route = .details },
        .{ .url = site ++ "/subs/1687/file.html", .route = .subtitle },
        .{ .url = site ++ "/subs/1687/a%2fb.srt", .route = .subtitle },
        .{ .url = site ++ "/subs/1687/a%252fb.srt", .route = .subtitle },
        .{ .url = site ++ "/subs/1687/file.srt?next=/admin", .route = .subtitle },
    }) |case| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(case.url, case.route));
    }
}

test "subtitlecat binds sources to details id and scans all action candidates" {
    const Fixture = struct {
        fn fetch(_: *std.http.Client, allocator: Allocator, url: []const u8, _: common.FetchOptions) !common.HttpResponse {
            try std.testing.expectEqualStrings(site ++ "/subs/1687/The.Matrix.html", url);
            return .{
                .status = .ok,
                .body = try allocator.dupe(
                    u8,
                    "<div class='sub-single'>" ++
                        "<span><img alt='en'></span><span>English</span><span>" ++
                        "<a href='/admin'>Malformed</a>" ++
                        "<a href='/subs/999/wrong.srt'>Wrong detail</a>" ++
                        "<a href='/subs/1687/good.srt'>Download</a>" ++
                        "</span></div>" ++
                        "<div class='sub-single'>" ++
                        "<span><img alt='fr'></span><span>French</span><span>" ++
                        "<button onclick=\"translate_sometime_later('id')\">Malformed</button>" ++
                        "<button onclick=\"translate_from_server('id','/subs/999/wrong-orig.srt')\">Wrong detail</button>" ++
                        "<button onclick=\"translate_from_server('id','/subs/1687/good-orig.srt')\">Translate</button>" ++
                        "</span></div>",
                ),
            };
        }
    };

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.fetchSubtitlesByDetailsLinkUsing(
        Fixture.fetch,
        site ++ "/subs/1687/The.Matrix.html",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.subtitles.len);
    try std.testing.expectEqualStrings(site ++ "/subs/1687/good.srt", response.subtitles[0].download_url.?);
    try std.testing.expectEqualStrings(site ++ "/subs/1687/good-orig.srt", response.subtitles[1].source_url.?);
}

test "subtitlecat translate spec parser" {
    const allocator = std.testing.allocator;
    const spec = try parseTranslateSpec(allocator, "translate_from_server_folder('id','file.srt','/subs/123')");
    defer if (spec.source_url) |s| allocator.free(s);
    try std.testing.expect(spec.source_url != null);

    const renamed = try parseTranslateSpec(allocator, "renamed_translate('id','/subs/123/file.srt')");
    defer if (renamed.source_url) |source| allocator.free(source);
    try std.testing.expectEqualStrings(site ++ "/subs/123/file.srt", renamed.source_url.?);
    try std.testing.expect(usableTranslateSpec(renamed) != null);

    const renamed_folder = try parseTranslateSpec(allocator, "renamed_translate('id','file.srt','/subs/123/')");
    defer if (renamed_folder.source_url) |source| allocator.free(source);
    try std.testing.expectEqualStrings(site ++ "/subs/123/file.srt", renamed_folder.source_url.?);
}

test "subtitlecat omits phantom translations without an srt source" {
    const allocator = std.testing.allocator;
    const missing = try parseOptionalTranslateSpec(allocator, "translate_sometime_later('id')");
    try std.testing.expect(usableTranslateSpec(missing) == null);

    const non_subtitle = try parseOptionalTranslateSpec(allocator, "translate_from_server('id','/subs/123/page')");
    defer if (non_subtitle) |spec| if (spec.source_url) |source| allocator.free(source);
    try std.testing.expect(usableTranslateSpec(non_subtitle) == null);

    const unrelated = try parseTranslateSpec(allocator, "preview_file('id','/subs/123/file.srt')");
    defer if (unrelated.source_url) |source| allocator.free(source);
    try std.testing.expect(usableTranslateSpec(unrelated) == null);
}

test "subtitlecat strips URL suffixes and replaces source extensions" {
    try std.testing.expectEqualStrings(
        "movie-orig.srt",
        inferFilenameFromUrl("https://www.subtitlecat.com/subs/movie-orig.srt?token=one#fragment").?,
    );
    const translated = try inferTranslatedFilename(
        std.testing.allocator,
        "https://www.subtitlecat.com/subs/movie-orig.srt?token=one#fragment",
        "fr",
    );
    defer std.testing.allocator.free(translated);
    try std.testing.expectEqualStrings("movie-fr.srt", translated);

    const regular = try inferTranslatedFilename(std.testing.allocator, "https://www.subtitlecat.com/subs/movie.ass", "en");
    defer std.testing.allocator.free(regular);
    try std.testing.expectEqualStrings("movie-en.srt", regular);
}

test "subtitlecat empty search does not acquire the provider" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.search(" \t\r\n");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "subtitlecat optional translation parsing preserves allocation errors" {
    var failing_spec = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        parseOptionalTranslateSpec(failing_spec.allocator(), "translate_from_server_folder('id','file.srt','/subs/123')"),
    );

    var failing_filename = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, inferTranslatedFilename(failing_filename.allocator(), null, "en"));
}

test "live subtitlecat search and subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "SUBTITLECAT")) return error.SkipZigTest;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][subtitlecat.com][search][{d}]\n", .{idx});
        try common.livePrintField(std.testing.allocator, "title", item.title);
        try common.livePrintField(std.testing.allocator, "details_url", item.details_url);
        try common.livePrintOptionalField(std.testing.allocator, "source_language", item.source_language);
    }

    var subtitles = try scraper.fetchSubtitlesByDetailsLink(search.items[0].details_url);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    for (subtitles.subtitles, 0..) |sub, idx| {
        std.debug.print("[live][subtitlecat.com][subtitle][{d}]\n", .{idx});
        try common.livePrintOptionalField(std.testing.allocator, "language_code", sub.language_code);
        try common.livePrintOptionalField(std.testing.allocator, "language_label", sub.language_label);
        try common.livePrintField(std.testing.allocator, "filename", sub.filename);
        std.debug.print("[live] mode={s}\n", .{@tagName(sub.mode)});
        try common.livePrintOptionalField(std.testing.allocator, "source_url", sub.source_url);
        try common.livePrintOptionalField(std.testing.allocator, "download_url", sub.download_url);
        if (sub.translate_spec) |spec| {
            try common.livePrintOptionalField(std.testing.allocator, "translate_spec.source_url", spec.source_url);
        } else {
            std.debug.print("[live] translate_spec=<null>\n", .{});
        }
    }
}
