const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

const Allocator = std.mem.Allocator;
const site = "https://isubtitles.org";

pub const SearchOptions = struct {
    page_start: usize = 1,
    max_pages: usize = 1,
};

pub const SubtitlesOptions = struct {
    page_start: usize = 1,
    max_pages: usize = 1,
};

pub const SearchItem = struct {
    title: []const u8,
    year: ?[]const u8,
    details_url: []const u8,
};

pub const SubtitleItem = struct {
    language_raw: ?[]const u8,
    language_code: ?[]const u8,
    release: ?[]const u8,
    created_at: ?[]const u8,
    file_count: ?[]const u8,
    size: ?[]const u8,
    comment: ?[]const u8,
    filename: []const u8,
    details_url: []const u8,
    download_page_url: []const u8,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SearchItem,
    page: usize = 1,
    has_prev_page: bool = false,
    has_next_page: bool = false,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    subtitles: []const SubtitleItem,
    page: usize = 1,
    has_prev_page: bool = false,
    has_next_page: bool = false,

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
        return self.searchWithOptions(query, .{});
    }

    pub fn searchWithOptions(self: *Scraper, query: []const u8, options: SearchOptions) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
        var page = if (options.page_start == 0) 1 else options.page_start;
        const page_start = page;
        var next_url: ?[]const u8 = null;
        var traversed: usize = 0;
        var last_page = page_start;
        var has_next_page = false;

        while (traversed < max_pages) : (traversed += 1) {
            last_page = page;
            const page_url = if (next_url) |u| u else try buildSearchUrl(a, query, page);
            const response = try self.fetchHtmlPreferCurl(a, page_url);
            if (response.body.len == 0) break;

            maybeDebugDumpFirstPage(response.status, page_url, response.body, traversed);

            var parsed = try common.parseHtmlStable(a, response.body);
            defer parsed.deinit();

            const before_len = out.items.len;
            try collectSearchItemsFromSelector(a, &parsed.doc, ".movie-list-info h3 a[href*='-subtitles']", &seen, &out);
            if (out.items.len == before_len) {
                try collectSearchItemsFromSelector(a, &parsed.doc, "h3 a[href*='-subtitles']", &seen, &out);
            }
            if (out.items.len == before_len) {
                try collectSearchItemsFromSelector(a, &parsed.doc, "a[href*='-subtitles']", &seen, &out);
            }
            if (out.items.len == before_len) {
                try collectSearchItemsFromRawHtml(a, response.body, &seen, &out);
            }

            const extracted_next = try extractNextPageUrl(a, &parsed.doc, page_url);
            has_next_page = extracted_next != null;

            if (next_url != null) {
                next_url = extracted_next;
            } else {
                next_url = extracted_next;
                page += 1;
            }

            if (next_url == null) {
                if (options.page_start > 1 or options.max_pages == 1) break;
                if (traversed + 1 >= max_pages) break;
                if (page > 128) break;
            }
        }

        return .{
            .arena = arena,
            .items = try out.toOwnedSlice(a),
            .page = last_page,
            .has_prev_page = last_page > 1,
            .has_next_page = has_next_page,
        };
    }

    pub fn fetchSubtitlesByMovieLink(self: *Scraper, details_url: []const u8) !SubtitlesResponse {
        return self.fetchSubtitlesByMovieLinkWithOptions(details_url, .{});
    }

    pub fn fetchSubtitlesByMovieLinkWithOptions(self: *Scraper, details_url: []const u8, options: SubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        var title: []const u8 = "";

        const max_pages = if (options.max_pages == 0) 1 else options.max_pages;
        var page = if (options.page_start == 0) 1 else options.page_start;
        const page_start = page;
        var next_url: ?[]const u8 = if (options.page_start > 1) try addOrReplacePageQuery(a, details_url, page) else null;
        var last_page = page_start;
        var has_next_page = false;

        var traversed: usize = 0;
        while (traversed < max_pages) : (traversed += 1) {
            last_page = page;
            const page_url = if (next_url) |u| u else if (page == 1) details_url else try addOrReplacePageQuery(a, details_url, page);
            const response = try self.fetchHtmlPreferCurl(a, page_url);
            if (response.body.len == 0) break;

            var parsed = try common.parseHtmlStable(a, response.body);
            defer parsed.deinit();

            if (title.len == 0) {
                if (parsed.doc.queryOne("h1")) |h1| {
                    title = try common.innerTextTrimmedOwned(a, h1);
                } else if (parsed.doc.queryOne("title")) |t| {
                    title = try common.innerTextTrimmedOwned(a, t);
                }
            }

            var rows = parsed.doc.queryAll("section table.table tr");
            while (rows.next()) |row| {
                const download_anchor = row.queryOne("td[data-title='Download'] a[href]") orelse continue;
                const href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
                const download_page_url = try common.resolveUrl(a, site, href);
                if (seen.contains(download_page_url)) continue;
                try seen.put(a, download_page_url, {});

                const language_raw = textAt(row, a, "td[data-title='Language'] a") catch null;
                const release = textAt(row, a, "td[data-title='Release / Movie'] a") catch null;
                const created_at = textAt(row, a, "td[data-title='Created']") catch null;
                const file_count = textAt(row, a, "td[data-title='File']") catch null;
                const size = textAt(row, a, "td[data-title='Size']") catch null;
                const comment = textAt(row, a, "td[data-title='Comment']") catch null;

                const filename = if (release) |r| r else if (title.len > 0) title else "subtitle.srt";

                try out.append(a, .{
                    .language_raw = language_raw,
                    .language_code = if (language_raw) |lang| common.normalizeLanguageCode(lang) else null,
                    .release = release,
                    .created_at = created_at,
                    .file_count = file_count,
                    .size = size,
                    .comment = comment,
                    .filename = filename,
                    .details_url = details_url,
                    .download_page_url = download_page_url,
                });
            }

            next_url = try extractNextPageUrl(a, &parsed.doc, page_url);
            has_next_page = next_url != null;
            page += 1;
            if (next_url == null and page > 128) break;
            if (next_url == null and options.page_start > 1) break;
        }

        return .{
            .arena = arena,
            .title = title,
            .subtitles = try out.toOwnedSlice(a),
            .page = last_page,
            .has_prev_page = last_page > 1,
            .has_next_page = has_next_page,
        };
    }

    fn fetchHtmlPreferCurl(self: *Scraper, allocator: Allocator, url: []const u8) !common.HttpResponse {
        if (try fetchHtmlViaCurl(allocator, url)) |curl_response| {
            return curl_response;
        }
        return common.fetchBytes(self.client, allocator, url, .{
            .accept = "text/html",
            .max_attempts = 2,
            .allow_non_ok = true,
        });
    }
};

fn collectSearchItemsFromSelector(
    allocator: Allocator,
    doc: *const HtmlDocument,
    comptime selector: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(SearchItem),
) !void {
    var anchors = doc.queryAll(selector);
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const details_url = try common.resolveUrl(allocator, site, href);
        if (seen.contains(details_url)) continue;
        try seen.put(allocator, details_url, {});

        const raw_title = try common.innerTextTrimmedOwned(allocator, anchor);
        const split = splitTitleAndYear(raw_title);
        try out.append(allocator, .{
            .title = split.title,
            .year = split.year,
            .details_url = details_url,
        });
    }
}

fn collectSearchItemsFromRawHtml(
    allocator: Allocator,
    body: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(SearchItem),
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, "href=\"")) |href_marker| {
        const href_start = href_marker + "href=\"".len;
        const href_end = std.mem.indexOfScalarPos(u8, body, href_start, '"') orelse break;
        cursor = href_end + 1;

        const href = body[href_start..href_end];
        if (!std.mem.startsWith(u8, href, "/")) continue;
        if (!std.mem.endsWith(u8, href, "-subtitles")) continue;
        if (std.mem.indexOf(u8, href, "/gender/") != null) continue;
        if (std.mem.indexOf(u8, href, "/country/") != null) continue;
        if (std.mem.indexOf(u8, href, "/search") != null) continue;

        const tag_end = std.mem.indexOfScalarPos(u8, body, href_end, '>') orelse continue;
        const text_end = std.mem.indexOfPos(u8, body, tag_end + 1, "</a>") orelse continue;
        const raw_title = common.trimAscii(body[tag_end + 1 .. text_end]);
        if (raw_title.len == 0) continue;

        const details_url = try common.resolveUrl(allocator, site, href);
        if (seen.contains(details_url)) continue;
        try seen.put(allocator, details_url, {});

        const split = splitTitleAndYear(raw_title);
        try out.append(allocator, .{
            .title = split.title,
            .year = split.year,
            .details_url = details_url,
        });
    }
}

fn textAt(node: HtmlNode, allocator: Allocator, comptime selector: []const u8) !?[]const u8 {
    const found = node.queryOne(selector) orelse return null;
    const text = try common.innerTextTrimmedOwned(allocator, found);
    if (text.len == 0) return null;
    return text;
}

fn buildSearchUrl(allocator: Allocator, query: []const u8, page: usize) ![]const u8 {
    const encoded = try common.encodeUriComponent(allocator, query);
    if (page <= 1) return std.fmt.allocPrint(allocator, "{s}/search?kwd={s}", .{ site, encoded });
    return std.fmt.allocPrint(allocator, "{s}/search?kwd={s}&page={d}", .{ site, encoded, page });
}

fn addOrReplacePageQuery(allocator: Allocator, base_url: []const u8, page: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (std.mem.indexOf(u8, base_url, "page=")) |idx| {
        const pre = base_url[0..idx];
        const rest = base_url[idx..];
        const amp = std.mem.indexOfScalar(u8, rest, '&');

        try out.appendSlice(allocator, pre);
        try out.writer(allocator).print("page={d}", .{page});
        if (amp) |amp_idx| {
            try out.appendSlice(allocator, rest[amp_idx..]);
        }
        return try out.toOwnedSlice(allocator);
    }

    try out.appendSlice(allocator, base_url);
    try out.append(allocator, if (std.mem.indexOfScalar(u8, base_url, '?') == null) '?' else '&');
    try out.writer(allocator).print("page={d}", .{page});
    return try out.toOwnedSlice(allocator);
}

fn extractNextPageUrl(allocator: Allocator, doc: *const HtmlDocument, current_url: []const u8) !?[]const u8 {
    if (doc.queryOne("a[rel='next'][href]")) |a| {
        if (common.getAttributeValueSafe(a, "href")) |href| {
            return try common.resolveUrl(allocator, site, href);
        }
    }

    var anchors = doc.queryAll("a[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (std.mem.indexOf(u8, href, "page=") == null) continue;

        const text = try common.innerTextTrimmedOwned(allocator, anchor);
        if (!isLikelyNextText(text)) continue;

        const resolved = try common.resolveUrl(allocator, site, href);
        if (std.mem.eql(u8, resolved, current_url)) continue;
        return resolved;
    }

    return null;
}

fn maybeDebugDumpFirstPage(status: std.http.Status, page_url: []const u8, body: []const u8, traversed: usize) void {
    if (traversed != 0) return;
    if (std.posix.getenv("SCRAPERS_DEBUG_ISUB") == null) return;

    std.debug.print("[isubtitles] status={d} body_len={d} url={s}\n", .{ @intFromEnum(status), body.len, page_url });
    std.fs.cwd().writeFile(.{ .sub_path = "/tmp/isubtitles_response_debug.html", .data = body }) catch {};
}

fn fetchHtmlViaCurl(allocator: Allocator, url: []const u8) !?common.HttpResponse {
    const argv = [_][]const u8{
        "curl",
        "-sS",
        "--location",
        "--max-time",
        "45",
        "--compressed",
        "-A",
        common.default_user_agent,
        "-H",
        "Accept: text/html",
        "-w",
        "\n%{http_code}",
        url,
    };

    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
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

fn isLikelyNextText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.ascii.indexOfIgnoreCase(text, "next") != null) return true;
    return std.mem.eql(u8, text, ">") or std.mem.eql(u8, text, "›") or std.mem.eql(u8, text, "»");
}

fn splitTitleAndYear(raw_title: []const u8) struct { title: []const u8, year: ?[]const u8 } {
    const trimmed = common.trimAscii(raw_title);
    if (trimmed.len < 7) return .{ .title = trimmed, .year = null };

    if (trimmed[trimmed.len - 1] != ')') return .{ .title = trimmed, .year = null };
    const open_idx = std.mem.lastIndexOfScalar(u8, trimmed, '(') orelse return .{ .title = trimmed, .year = null };
    if (open_idx + 5 != trimmed.len - 1) return .{ .title = trimmed, .year = null };

    const year = trimmed[open_idx + 1 .. trimmed.len - 1];
    for (year) |c| {
        if (c < '0' or c > '9') return .{ .title = trimmed, .year = null };
    }

    var title = common.trimAscii(trimmed[0..open_idx]);
    if (std.mem.endsWith(u8, title, "-")) {
        title = common.trimAscii(title[0 .. title.len - 1]);
    }

    return .{ .title = title, .year = year };
}

test "isubtitles split title/year" {
    const a = splitTitleAndYear("The Matrix  - (1999)");
    try std.testing.expectEqualStrings("The Matrix", a.title);
    try std.testing.expectEqualStrings("1999", a.year.?);

    const b = splitTitleAndYear("No Year Title");
    try std.testing.expectEqualStrings("No Year Title", b.title);
    try std.testing.expect(b.year == null);
}

test "isubtitles next-link text" {
    try std.testing.expect(isLikelyNextText("Next"));
    try std.testing.expect(isLikelyNextText(">"));
    try std.testing.expect(!isLikelyNextText("2"));
}
