const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();
const suite = @import("test_suite.zig");

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
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn deinit(_: *Scraper) void {}

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const encoded = try common.encodeUriComponent(a, query);
        const url = try std.fmt.allocPrint(a, "{s}/index.php?search={s}&show=10000", .{ site, encoded });
        const response = try common.fetchBytes(self.client, a, url, .{ .accept = "text/html", .max_attempts = 2 });

        var parsed = try common.parseHtmlStable(a, response.body);
        defer parsed.deinit();

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var anchors = parsed.doc.queryAll("table.sub-table tbody tr td:first-child a");
        while (anchors.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            const title = try common.innerTextTrimmedOwned(a, anchor);
            const details_url = try common.resolveUrl(a, site, href);
            const first_cell = anchor.parentNode() orelse continue;
            const raw = try common.innerTextTrimmedOwned(a, first_cell);
            const source_language = parseTranslatedFrom(raw);

            try items.append(a, .{ .title = title, .details_url = details_url, .source_language = source_language });
        }

        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesByDetailsLink(self: *Scraper, details_url: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, details_url, .{ .accept = "text/html", .max_attempts = 2 });
        var parsed = try common.parseHtmlStable(a, response.body);
        defer parsed.deinit();

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var blocks = parsed.doc.queryAll("div.sub-single");
        while (blocks.next()) |block| {
            var spans: [3]?HtmlNode = .{ null, null, null };
            var span_count: usize = 0;
            for (block.children()) |child_idx| {
                const child = block.doc.nodeAt(child_idx) orelse continue;
                if (!std.mem.eql(u8, child.tagName(), "span")) continue;
                if (span_count < spans.len) spans[span_count] = child;
                span_count += 1;
            }

            const language_code = blk: {
                const first_span = spans[0] orelse break :blk null;
                const img = findDescendantByTag(first_span, "img") orelse break :blk null;
                const raw = common.getAttributeValueSafe(img, "alt") orelse break :blk null;
                break :blk try a.dupe(u8, raw);
            };

            const language_label = if (spans[1]) |s2|
                try common.innerTextTrimmedOwned(a, s2)
            else
                null;

            if (spans[2]) |action| {
                if (findDescendantByTagWithAttr(action, "a", "href")) |download_anchor| {
                    const href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
                    const url = try common.resolveUrl(a, site, href);
                    const filename = inferFilenameFromUrl(url) orelse "subtitle.srt";
                    try subtitles.append(a, .{
                        .language_code = language_code,
                        .language_label = language_label,
                        .filename = filename,
                        .mode = .direct_download,
                        .source_url = url,
                        .download_url = url,
                        .translate_spec = null,
                    });
                    continue;
                }

                if (findDescendantByTagWithAttr(action, "button", "onclick")) |button| {
                    const onclick = common.getAttributeValueSafe(button, "onclick") orelse continue;
                    const spec = parseTranslateSpec(a, onclick) catch null;
                    const source = if (spec) |s| s.source_url else null;
                    const code = if (language_code) |c|
                        c
                    else if (common.getAttributeValueSafe(button, "id")) |id|
                        try a.dupe(u8, id)
                    else
                        null;
                    const filename = inferTranslatedFilename(a, source, code) catch "translated.srt";
                    try subtitles.append(a, .{
                        .language_code = code,
                        .language_label = language_label,
                        .filename = filename,
                        .mode = .translated,
                        .source_url = source,
                        .download_url = null,
                        .translate_spec = if (spec) |s| s else null,
                    });
                }
            }
        }

        return .{ .arena = arena, .subtitles = try subtitles.toOwnedSlice(a) };
    }
};

fn parseTranslatedFrom(raw: []const u8) ?[]const u8 {
    const marker = "(translated from";
    const start = std.ascii.indexOfIgnoreCase(raw, marker) orelse return null;
    const tail = raw[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, tail, ')') orelse tail.len;
    return common.trimAscii(tail[0..end]);
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
        return .{ .source_url = try common.resolveUrl(allocator, site, path) };
    }

    if (args.len >= 2 and std.mem.startsWith(u8, onclick, "translate_from_server")) {
        return .{ .source_url = try common.resolveUrl(allocator, site, args[1]) };
    }

    var filename: ?[]const u8 = null;
    var folder: ?[]const u8 = null;
    for (args) |arg| {
        if (filename == null and asciiEndsWithIgnoreCase(arg, ".srt")) filename = arg;
        if (folder == null and std.mem.startsWith(u8, arg, "/")) folder = arg;
    }

    if (filename) |filename_value| {
        if (folder) |folder_value| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ folder_value, filename_value });
            defer allocator.free(path);
            return .{ .source_url = try common.resolveUrl(allocator, site, path) };
        }
    }

    if (filename) |f| return .{ .source_url = try common.resolveUrl(allocator, site, f) };

    return .{ .source_url = null };
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
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
    if (slash + 1 >= url.len) return null;
    return url[slash + 1 ..];
}

fn inferTranslatedFilename(allocator: Allocator, source: ?[]const u8, lang_code: ?[]const u8) ![]const u8 {
    const lang = lang_code orelse "translated";
    if (source) |src| {
        const base = inferFilenameFromUrl(src) orelse return try std.fmt.allocPrint(allocator, "subtitle-{s}.srt", .{lang});
        if (std.mem.endsWith(u8, base, "-orig.srt")) {
            return try std.fmt.allocPrint(allocator, "{s}-{s}.srt", .{ base[0 .. base.len - "-orig.srt".len], lang });
        }
        return try std.fmt.allocPrint(allocator, "{s}-{s}.srt", .{ base, lang });
    }
    return try std.fmt.allocPrint(allocator, "subtitle-{s}.srt", .{lang});
}

fn asciiEndsWithIgnoreCase(input: []const u8, suffix: []const u8) bool {
    if (suffix.len > input.len) return false;
    const tail = input[input.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn findDescendantByTag(node: HtmlNode, tag_name: []const u8) ?HtmlNode {
    for (node.children()) |child_idx| {
        const child = node.doc.nodeAt(child_idx) orelse continue;
        if (std.mem.eql(u8, child.tagName(), tag_name)) return child;
        if (findDescendantByTag(child, tag_name)) |nested| return nested;
    }
    return null;
}

fn findDescendantByTagWithAttr(node: HtmlNode, tag_name: []const u8, attr_name: []const u8) ?HtmlNode {
    for (node.children()) |child_idx| {
        const child = node.doc.nodeAt(child_idx) orelse continue;
        if (std.mem.eql(u8, child.tagName(), tag_name) and common.getAttributeValueSafe(child, attr_name) != null) return child;
        if (findDescendantByTagWithAttr(child, tag_name, attr_name)) |nested| return nested;
    }
    return null;
}

test "subtitlecat translate spec parser" {
    const allocator = std.testing.allocator;
    const spec = try parseTranslateSpec(allocator, "translate_from_server_folder('id','file.srt','/folder/path')");
    defer if (spec.source_url) |s| allocator.free(s);
    try std.testing.expect(spec.source_url != null);
}

test "live subtitlecat search and subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "SUBTITLECAT")) return error.SkipZigTest;
    if (suite.shouldRunExtensiveLiveSuite(std.testing.allocator)) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
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
