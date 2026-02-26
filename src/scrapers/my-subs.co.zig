const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const site = "https://my-subs.co";

pub const MediaKind = enum {
    movie,
    tv,
};

pub const SearchOptions = struct {
    page_start: usize = 1,
    max_pages: usize = 1,
};

pub const SubtitlesOptions = struct {
    include_seasons: bool = true,
    max_pages_per_entry: usize = 1,
    resolve_download_links: bool = false,
};

pub const SearchItem = struct {
    title: []const u8,
    details_url: []const u8,
    media_kind: MediaKind,
};

pub const SubtitleItem = struct {
    language_raw: ?[]const u8,
    language_code: ?[]const u8,
    filename: []const u8,
    release_version: ?[]const u8,
    details_url: []const u8,
    download_page_url: []const u8,
    resolved_download_url: ?[]const u8,
    is_archive: ?bool,
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
        var next_url: ?[]const u8 = null;

        var traversed: usize = 0;
        while (traversed < max_pages) : (traversed += 1) {
            const page_url = if (next_url) |u| u else try buildSearchUrl(a, query, page);
            const response = try common.fetchBytes(self.client, a, page_url, .{ .accept = "text/html", .max_attempts = 2, .allow_non_ok = true });
            if (response.body.len == 0) break;

            var parsed = try common.parseHtmlStable(a, response.body);
            defer parsed.deinit();

            var anchors = parsed.doc.queryAll("a[href*='/showlistsubtitles-'], a[href*='/film-versions-']");
            while (anchors.next()) |anchor| {
                const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                const details_url = try common.resolveUrl(a, site, href);
                if (seen.contains(details_url)) continue;
                try seen.put(a, details_url, {});

                const title = blk: {
                    if (common.getAttributeValueSafe(anchor, "title")) |title_attr| {
                        const clean = common.trimAscii(title_attr);
                        if (clean.len > 0) break :blk clean;
                    }
                    const txt = common.trimAscii(try anchor.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
                    if (txt.len > 0) break :blk txt;
                    break :blk query;
                };

                try out.append(a, .{
                    .title = title,
                    .details_url = details_url,
                    .media_kind = if (std.mem.indexOf(u8, href, "/showlistsubtitles-") != null) .tv else .movie,
                });
            }

            next_url = try extractNextPageUrl(a, &parsed.doc, page_url);
            page += 1;
            if (next_url == null and options.page_start > 1) break;
            if (next_url == null and page > 128) break;
        }

        return .{ .arena = arena, .items = try out.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesByDetailsLink(self: *Scraper, details_url: []const u8, media_kind: MediaKind) !SubtitlesResponse {
        return self.fetchSubtitlesByDetailsLinkWithOptions(details_url, media_kind, .{});
    }

    pub fn fetchSubtitlesByDetailsLinkWithOptions(self: *Scraper, details_url: []const u8, media_kind: MediaKind, options: SubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        var page_urls: std.ArrayListUnmanaged([]const u8) = .empty;
        try page_urls.append(a, details_url);

        const root_response = try common.fetchBytes(self.client, a, details_url, .{ .accept = "text/html", .max_attempts = 2, .allow_non_ok = true });
        if (root_response.body.len == 0) return .{ .arena = arena, .subtitles = &.{} };

        var root = try common.parseHtmlStable(a, root_response.body);
        defer root.deinit();

        if (media_kind == .tv and options.include_seasons) {
            var season_links = root.doc.queryAll("#saison a[href*='/versions-'][href*='-subtitles']");
            while (season_links.next()) |anchor| {
                const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                const url = try common.resolveUrl(a, site, href);
                try page_urls.append(a, url);
            }
        }

        var entry_seen = std.StringHashMapUnmanaged(void).empty;

        for (page_urls.items) |entry_url| {
            if (entry_seen.contains(entry_url)) continue;
            try entry_seen.put(a, entry_url, {});

            var cursor_url: ?[]const u8 = entry_url;
            var traversed: usize = 0;
            const max_pages = if (options.max_pages_per_entry == 0) 1 else options.max_pages_per_entry;
            while (cursor_url) |page_url| : (traversed += 1) {
                if (traversed >= max_pages) break;

                const response = try common.fetchBytes(self.client, a, page_url, .{ .accept = "text/html", .max_attempts = 2, .allow_non_ok = true });
                if (response.body.len == 0) break;

                var parsed = try common.parseHtmlStable(a, response.body);
                defer parsed.deinit();

                const page_title = if (parsed.doc.queryOne("h1")) |h1|
                    common.trimAscii(try h1.innerTextWithOptions(a, .{ .normalize_whitespace = true }))
                else
                    "";

                var anchors = parsed.doc.queryAll("a[href*='/downloads/']");
                while (anchors.next()) |anchor| {
                    const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                    const download_page_url = try common.resolveUrl(a, site, href);
                    if (seen.contains(download_page_url)) continue;
                    try seen.put(a, download_page_url, {});

                    const lang_meta = extractLanguage(anchor);
                    const release_version = extractReleaseVersion(anchor, a) catch null;

                    var filename = if (release_version) |rv| rv else page_title;
                    if (filename.len == 0) {
                        filename = common.trimAscii(try anchor.innerTextWithOptions(a, .{ .normalize_whitespace = true }));
                    }
                    if (filename.len == 0) filename = "subtitle.srt";

                    var resolved_download_url: ?[]const u8 = null;
                    var is_archive: ?bool = null;
                    if (options.resolve_download_links) {
                        const resolved = self.resolveDownloadPage(a, download_page_url) catch null;
                        if (resolved) |url| {
                            resolved_download_url = url;
                            is_archive = looksArchive(url);
                        }
                    }

                    try subtitles.append(a, .{
                        .language_raw = lang_meta.raw,
                        .language_code = lang_meta.code,
                        .filename = filename,
                        .release_version = release_version,
                        .details_url = page_url,
                        .download_page_url = download_page_url,
                        .resolved_download_url = resolved_download_url,
                        .is_archive = is_archive,
                    });
                }

                const next = try extractNextPageUrl(a, &parsed.doc, page_url);
                if (next) |next_page| {
                    if (std.mem.eql(u8, next_page, page_url)) break;
                    cursor_url = next_page;
                } else {
                    cursor_url = null;
                }
            }
        }

        return .{ .arena = arena, .subtitles = try subtitles.toOwnedSlice(a) };
    }

    pub fn resolveDownloadPageUrl(self: *Scraper, allocator: Allocator, download_page_url: []const u8) ![]const u8 {
        return self.resolveDownloadPage(allocator, download_page_url);
    }

    fn resolveDownloadPage(self: *Scraper, allocator: Allocator, download_page_url: []const u8) ![]const u8 {
        const response = try common.fetchBytes(self.client, allocator, download_page_url, .{ .accept = "text/html", .max_attempts = 2, .allow_non_ok = true });
        defer allocator.free(response.body);
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        const real_url = (try parseRealUrlFromPage(allocator, response.body)) orelse return error.MissingField;
        defer allocator.free(real_url);
        return try common.resolveUrl(allocator, site, real_url);
    }
};

fn buildSearchUrl(allocator: Allocator, query: []const u8, page: usize) ![]const u8 {
    const encoded = try common.encodeUriComponent(allocator, query);
    if (page <= 1) return std.fmt.allocPrint(allocator, "{s}/search.php?key={s}", .{ site, encoded });
    return std.fmt.allocPrint(allocator, "{s}/search.php?key={s}&page={d}", .{ site, encoded, page });
}

fn extractNextPageUrl(allocator: Allocator, doc: *const html.Document, current_url: []const u8) !?[]const u8 {
    if (doc.queryOne("a[rel='next'][href]")) |a| {
        if (common.getAttributeValueSafe(a, "href")) |href| {
            return try common.resolveUrl(allocator, site, href);
        }
    }

    var anchors = doc.queryAll("a[href]");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (std.mem.indexOf(u8, href, "page=") == null) continue;

        const text = common.trimAscii(try anchor.innerTextWithOptions(allocator, .{ .normalize_whitespace = true }));
        if (!isLikelyNextText(text)) continue;

        const resolved = try common.resolveUrl(allocator, site, href);
        if (std.mem.eql(u8, resolved, current_url)) continue;
        return resolved;
    }

    return null;
}

fn isLikelyNextText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.ascii.indexOfIgnoreCase(text, "next") != null) return true;
    return std.mem.eql(u8, text, ">") or std.mem.eql(u8, text, "›") or std.mem.eql(u8, text, "»");
}

fn extractLanguage(anchor: html.Node) struct { raw: ?[]const u8, code: ?[]const u8 } {
    if (anchor.queryOne("span[class*='flag-icon-']")) |flag| {
        const class_name = common.getAttributeValueSafe(flag, "class") orelse "";
        const flag_code = parseFlagCodeFromClass(class_name);

        const raw = blk: {
            const title = common.getAttributeValueSafe(flag, "title") orelse break :blk null;
            const clean = common.trimAscii(title);
            if (clean.len == 0) break :blk null;
            break :blk clean;
        };

        return .{ .raw = raw, .code = languageFromFlag(flag_code, raw) };
    }

    return .{ .raw = null, .code = null };
}

fn parseFlagCodeFromClass(class_name: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, class_name, " \t\r\n");
    while (it.next()) |token| {
        if (!std.mem.startsWith(u8, token, "flag-icon-")) continue;
        const code = token["flag-icon-".len..];
        if (code.len == 2) return code;
    }
    return null;
}

fn languageFromFlag(flag_code: ?[]const u8, raw: ?[]const u8) ?[]const u8 {
    if (flag_code) |code| {
        if (std.ascii.eqlIgnoreCase(code, "br")) return "pt-br";
        if (std.ascii.eqlIgnoreCase(code, "gb")) return "en";
        if (std.ascii.eqlIgnoreCase(code, "gr")) return "el";
        if (std.ascii.eqlIgnoreCase(code, "sa")) return "ar";
        if (std.ascii.eqlIgnoreCase(code, "ua")) return "uk";
        if (std.ascii.eqlIgnoreCase(code, "jp")) return "ja";
        if (std.ascii.eqlIgnoreCase(code, "kr")) return "ko";
        if (std.ascii.eqlIgnoreCase(code, "cn")) return "zh";
        if (std.ascii.eqlIgnoreCase(code, "cz")) return "cs";
        if (std.ascii.eqlIgnoreCase(code, "dk")) return "da";
        return common.normalizeLanguageCode(code) orelse code;
    }
    if (raw) |name| return common.normalizeLanguageCode(name);
    return null;
}

fn extractReleaseVersion(anchor: html.Node, allocator: Allocator) !?[]const u8 {
    if (anchor.queryOne("strong")) |strong| {
        const text = common.trimAscii(try strong.innerTextWithOptions(allocator, .{ .normalize_whitespace = true }));
        if (text.len > 0) return text;
    }

    if (anchor.parentNode()) |p1| {
        if (p1.parentNode()) |p2| {
            if (p2.queryOne("small")) |small| {
                const text = common.trimAscii(try small.innerTextWithOptions(allocator, .{ .normalize_whitespace = true }));
                if (text.len > 0) return text;
            }
        }
    }

    return null;
}

fn parseRealUrlFromPage(allocator: Allocator, body: []const u8) !?[]const u8 {
    const marker = "REAL_URL";
    const marker_idx = std.mem.indexOf(u8, body, marker) orelse return null;
    const after_marker = body[marker_idx + marker.len ..];

    const eq_idx = std.mem.indexOfScalar(u8, after_marker, '=') orelse return null;
    var cursor: usize = eq_idx + 1;
    while (cursor < after_marker.len and std.ascii.isWhitespace(after_marker[cursor])) : (cursor += 1) {}
    if (cursor >= after_marker.len) return null;

    const quote = after_marker[cursor];
    if (quote != '\'' and quote != '"') return null;
    cursor += 1;

    const start = cursor;
    while (cursor < after_marker.len) : (cursor += 1) {
        if (after_marker[cursor] == quote and after_marker[cursor - 1] != '\\') {
            const raw = after_marker[start..cursor];
            return try decodeJsStringLiteral(allocator, raw);
        }
    }

    return null;
}

fn decodeJsStringLiteral(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const esc = input[i + 1];
            i += 1;
            try out.append(allocator, switch (esc) {
                '/' => '/',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\'' => '\'',
                '\\' => '\\',
                else => esc,
            });
            continue;
        }
        try out.append(allocator, input[i]);
    }

    return try out.toOwnedSlice(allocator);
}

fn looksArchive(url: []const u8) bool {
    return std.mem.endsWith(u8, url, ".zip") or
        std.mem.endsWith(u8, url, ".rar") or
        std.mem.indexOf(u8, url, ".zip?") != null or
        std.mem.indexOf(u8, url, ".rar?") != null;
}

test "my-subs parse REAL_URL" {
    const body = "var REAL_URL='\\/files\\/The.Matrix.1999.en.zip';";
    const parsed = (try parseRealUrlFromPage(std.testing.allocator, body)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(parsed);
    try std.testing.expect(std.mem.indexOf(u8, parsed, "files/") != null);
}

test "my-subs flag language map" {
    try std.testing.expectEqualStrings("pt-br", languageFromFlag("br", null).?);
    try std.testing.expectEqualStrings("en", languageFromFlag("gb", null).?);
    try std.testing.expectEqualStrings("el", languageFromFlag("gr", null).?);
}
