const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const site = "https://www.tvsubtitles.net";

pub const SearchOptions = struct {
    page_start: usize = 1,
    max_pages: usize = 1,
};

pub const SubtitlesOptions = struct {
    include_all_seasons: bool = true,
    max_pages_per_season: usize = 1,
    resolve_download_links: bool = false,
};

pub const SearchItem = struct {
    title: []const u8,
    show_url: []const u8,
};

pub const SubtitleItem = struct {
    language_code: ?[]const u8,
    episode_title: ?[]const u8,
    filename: []const u8,
    season_page_url: []const u8,
    subtitle_page_url: []const u8,
    download_page_url: []const u8,
    direct_zip_url: ?[]const u8,
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
        const page_start = if (options.page_start == 0) 1 else options.page_start;

        const first_response = try submitSearch(self.client, a, query);
        if (first_response.body.len == 0) return .{ .arena = arena, .items = &.{} };

        var page_url: []const u8 = site ++ "/search.php";
        var page_body: []const u8 = first_response.body;
        var page_index: usize = 1;
        var collected_pages: usize = 0;

        while (true) {
            var doc = try common.parseHtmlStable(a, page_body);
            defer doc.deinit();

            if (page_index >= page_start) {
                try collectSearchItems(a, &doc.doc, &out, &seen);
                collected_pages += 1;
                if (collected_pages >= max_pages) break;
            }

            const next_url = try extractNextPageUrl(a, &doc.doc, page_url) orelse break;
            const response = try common.fetchBytes(self.client, a, next_url, .{ .accept = "text/html", .max_attempts = 2, .allow_non_ok = true });
            if (response.body.len == 0) break;
            page_url = next_url;
            page_body = response.body;
            page_index += 1;
        }

        return .{ .arena = arena, .items = try out.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesByShowLink(self: *Scraper, show_url: []const u8) !SubtitlesResponse {
        return self.fetchSubtitlesByShowLinkWithOptions(show_url, .{});
    }

    pub fn fetchSubtitlesByShowLinkWithOptions(self: *Scraper, show_url: []const u8, options: SubtitlesOptions) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const root_response = try common.fetchBytes(self.client, a, show_url, .{ .accept = "text/html", .max_attempts = 2, .allow_non_ok = true });
        if (root_response.body.len == 0) return .{ .arena = arena, .subtitles = &.{} };

        var root_doc = try common.parseHtmlStable(a, root_response.body);
        defer root_doc.deinit();

        var season_urls: std.ArrayListUnmanaged([]const u8) = .empty;
        try season_urls.append(a, show_url);

        if (options.include_all_seasons) {
            var season_links = root_doc.doc.queryAll("p.description a[href*='tvshow-']");
            while (season_links.next()) |anchor| {
                const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                if (std.mem.indexOf(u8, href, "tvshow-") == null) continue;
                const url = try common.resolveUrl(a, site, href);
                try season_urls.append(a, url);
            }
        }

        var seen_season = std.StringHashMapUnmanaged(void).empty;
        var seen_subtitle = std.StringHashMapUnmanaged(void).empty;
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;

        for (season_urls.items) |initial_season_url| {
            if (seen_season.contains(initial_season_url)) continue;
            try seen_season.put(a, initial_season_url, {});

            var page_url: ?[]const u8 = initial_season_url;
            var traversed: usize = 0;
            const max_pages = if (options.max_pages_per_season == 0) 1 else options.max_pages_per_season;

            while (page_url) |url| : (traversed += 1) {
                if (traversed >= max_pages) break;

                const response = try common.fetchBytes(self.client, a, url, .{ .accept = "text/html", .max_attempts = 2, .allow_non_ok = true });
                if (response.body.len == 0) break;

                var doc = try common.parseHtmlStable(a, response.body);
                defer doc.deinit();

                var rows = doc.doc.queryAll("table#table5 tr[align='middle']");
                while (rows.next()) |row| {
                    const episode_title = episodeTitle(row, a) catch null;

                    var anchors = row.queryAll("a[href*='subtitle-']");
                    while (anchors.next()) |anchor| {
                        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                        const subtitle_page_url = try common.resolveUrl(a, site, href);
                        if (seen_subtitle.contains(subtitle_page_url)) continue;
                        try seen_subtitle.put(a, subtitle_page_url, {});

                        const subtitle_id = parseSubtitleId(subtitle_page_url) orelse continue;
                        const download_page_url = try std.fmt.allocPrint(a, "{s}/download-{s}.html", .{ site, subtitle_id });

                        var direct_zip_url: ?[]const u8 = null;
                        if (options.resolve_download_links) {
                            direct_zip_url = self.resolveDownloadUrl(a, download_page_url) catch null;
                        }

                        const lang = languageFromSubtitleAnchor(anchor, href);
                        const filename = buildFilename(a, episode_title, lang) catch "subtitle.zip";

                        try subtitles.append(a, .{
                            .language_code = lang,
                            .episode_title = episode_title,
                            .filename = filename,
                            .season_page_url = url,
                            .subtitle_page_url = subtitle_page_url,
                            .download_page_url = download_page_url,
                            .direct_zip_url = direct_zip_url,
                        });
                    }
                }

                page_url = try extractNextPageUrl(a, &doc.doc, url);
            }
        }

        return .{ .arena = arena, .subtitles = try subtitles.toOwnedSlice(a) };
    }

    pub fn resolveDownloadPageUrl(self: *Scraper, allocator: Allocator, download_page_url: []const u8) ![]const u8 {
        return self.resolveDownloadUrl(allocator, download_page_url);
    }

    fn resolveDownloadUrl(self: *Scraper, allocator: Allocator, download_page_url: []const u8) ![]const u8 {
        const response = try common.fetchBytes(self.client, allocator, download_page_url, .{ .accept = "text/html", .max_attempts = 2, .allow_non_ok = true });
        defer allocator.free(response.body);
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        if (try parseDocumentLocationFromScript(allocator, response.body)) |script_path| {
            defer allocator.free(script_path);
            const escaped = try escapeUrlPath(allocator, script_path);
            defer allocator.free(escaped);
            return try common.resolveUrl(allocator, site, escaped);
        }

        const script_path = parseZipPathFromHtml(response.body) orelse return error.MissingField;
        const escaped = try escapeUrlPath(allocator, script_path);
        defer allocator.free(escaped);
        return try common.resolveUrl(allocator, site, escaped);
    }
};

fn submitSearch(client: *std.http.Client, allocator: Allocator, query: []const u8) !common.HttpResponse {
    const payload = try std.fmt.allocPrint(allocator, "qs={s}", .{try common.encodeUriComponent(allocator, query)});
    return common.fetchBytes(client, allocator, site ++ "/search.php", .{
        .method = .POST,
        .payload = payload,
        .content_type = "application/x-www-form-urlencoded",
        .accept = "text/html",
        .max_attempts = 2,
        .allow_non_ok = true,
    });
}

fn collectSearchItems(allocator: Allocator, doc: *const html.Document, out: *std.ArrayListUnmanaged(SearchItem), seen: *std.StringHashMapUnmanaged(void)) !void {
    const before_len = out.items.len;
    var anchors = doc.queryAll(".left_articles a[href*='tvshow-']");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (std.mem.indexOf(u8, href, "tvshow-") == null) continue;
        if (std.mem.indexOf(u8, href, ".html") == null) continue;

        const show_url = try common.resolveUrl(allocator, site, href);
        if (seen.contains(show_url)) continue;
        try seen.put(allocator, show_url, {});

        const title = common.trimAscii(try anchor.innerTextWithOptions(allocator, .{ .normalize_whitespace = true }));
        if (title.len == 0) continue;

        try out.append(allocator, .{ .title = title, .show_url = show_url });
    }

    if (out.items.len == before_len) {
        var fallback = doc.queryAll("a[href*='tvshow-']");
        while (fallback.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.mem.indexOf(u8, href, "tvshow-") == null) continue;
            if (std.mem.indexOf(u8, href, ".html") == null) continue;

            const show_url = try common.resolveUrl(allocator, site, href);
            if (seen.contains(show_url)) continue;
            try seen.put(allocator, show_url, {});

            const title = common.trimAscii(try anchor.innerTextWithOptions(allocator, .{ .normalize_whitespace = true }));
            if (title.len == 0) continue;

            try out.append(allocator, .{ .title = title, .show_url = show_url });
        }
    }
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
        if (std.mem.indexOf(u8, href, "page=") == null and std.mem.indexOf(u8, href, "search.php") == null) continue;

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
    if (std.ascii.indexOfIgnoreCase(text, "more") != null) return true;
    return std.mem.eql(u8, text, ">") or std.mem.eql(u8, text, "›") or std.mem.eql(u8, text, "»");
}

fn episodeTitle(row: html.Node, allocator: Allocator) !?[]const u8 {
    if (row.queryOne("td:nth-child(2) a b")) |node| {
        const text = common.trimAscii(try node.innerTextWithOptions(allocator, .{ .normalize_whitespace = true }));
        if (text.len > 0) return text;
    }
    if (row.queryOne("td:nth-child(2) a")) |node| {
        const text = common.trimAscii(try node.innerTextWithOptions(allocator, .{ .normalize_whitespace = true }));
        if (text.len > 0) return text;
    }
    return null;
}

fn parseSubtitleId(subtitle_page_url: []const u8) ?[]const u8 {
    const marker = "subtitle-";
    const idx = std.mem.lastIndexOf(u8, subtitle_page_url, marker) orelse return null;
    const tail = subtitle_page_url[idx + marker.len ..];
    var end: usize = 0;
    while (end < tail.len and tail[end] >= '0' and tail[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return tail[0..end];
}

fn languageFromSubtitleAnchor(anchor: html.Node, href: []const u8) ?[]const u8 {
    if (anchor.queryOne("img")) |img| {
        if (common.getAttributeValueSafe(img, "alt")) |alt| {
            const code = common.trimAscii(alt);
            if (code.len == 2) return mapLanguageCode(code);
        }
    }

    if (std.mem.lastIndexOfScalar(u8, href, '-')) |dash| {
        const tail = href[dash + 1 ..];
        if (tail.len >= 2) return mapLanguageCode(tail[0..2]);
    }

    return null;
}

fn mapLanguageCode(raw: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "br")) return "pt-br";
    if (std.ascii.eqlIgnoreCase(raw, "gr")) return "el";
    if (std.ascii.eqlIgnoreCase(raw, "ua")) return "uk";
    if (std.ascii.eqlIgnoreCase(raw, "jp")) return "ja";
    if (std.ascii.eqlIgnoreCase(raw, "ko")) return "ko";
    if (std.ascii.eqlIgnoreCase(raw, "cz")) return "cs";
    if (std.ascii.eqlIgnoreCase(raw, "cn")) return "zh";
    if (std.ascii.eqlIgnoreCase(raw, "en")) return "en";
    if (std.ascii.eqlIgnoreCase(raw, "fr")) return "fr";
    if (std.ascii.eqlIgnoreCase(raw, "es")) return "es";
    if (std.ascii.eqlIgnoreCase(raw, "de")) return "de";
    return raw;
}

fn buildFilename(allocator: Allocator, episode_title: ?[]const u8, language_code: ?[]const u8) ![]const u8 {
    const ep = episode_title orelse "subtitle";
    const lang = language_code orelse "unknown";
    return try std.fmt.allocPrint(allocator, "{s}-{s}.zip", .{ ep, lang });
}

fn parseDocumentLocationFromScript(allocator: Allocator, html_body: []const u8) !?[]const u8 {
    const marker = "document.location";
    const idx = std.mem.indexOf(u8, html_body, marker) orelse return null;

    var vars = std.StringHashMapUnmanaged([]const u8).empty;
    defer {
        var it = vars.valueIterator();
        while (it.next()) |value_ptr| allocator.free(value_ptr.*);
        vars.deinit(allocator);
    }

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, html_body, pos, "var ")) |var_idx| {
        pos = var_idx + 4;

        var name_start = pos;
        while (name_start < html_body.len and std.ascii.isWhitespace(html_body[name_start])) : (name_start += 1) {}
        var name_end = name_start;
        while (name_end < html_body.len and isJsIdentChar(html_body[name_end])) : (name_end += 1) {}
        if (name_end == name_start) continue;

        var cursor = name_end;
        while (cursor < html_body.len and std.ascii.isWhitespace(html_body[cursor])) : (cursor += 1) {}
        if (cursor >= html_body.len or html_body[cursor] != '=') continue;
        cursor += 1;
        while (cursor < html_body.len and std.ascii.isWhitespace(html_body[cursor])) : (cursor += 1) {}
        if (cursor >= html_body.len) continue;

        const quote = html_body[cursor];
        if (quote != '\'' and quote != '"') continue;
        cursor += 1;

        const value_start = cursor;
        while (cursor < html_body.len) : (cursor += 1) {
            if (html_body[cursor] == quote and html_body[cursor - 1] != '\\') {
                const name = html_body[name_start..name_end];
                const decoded = try decodeJsString(allocator, html_body[value_start..cursor]);
                const gop = try vars.getOrPut(allocator, name);
                if (gop.found_existing) allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = decoded;
                break;
            }
        }
    }

    const after = html_body[idx + marker.len ..];
    const eq_idx = std.mem.indexOfScalar(u8, after, '=') orelse return null;
    const semicolon_idx = std.mem.indexOfScalarPos(u8, after, eq_idx + 1, ';') orelse return null;
    const expr = common.trimAscii(after[eq_idx + 1 .. semicolon_idx]);
    if (expr.len == 0) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, expr, '+');
    while (it.next()) |part_raw| {
        const part = common.trimAscii(part_raw);
        if (part.len == 0) continue;

        if ((part[0] == '\'' and part[part.len - 1] == '\'') or (part[0] == '"' and part[part.len - 1] == '"')) {
            const decoded = try decodeJsString(allocator, part[1 .. part.len - 1]);
            defer allocator.free(decoded);
            try out.appendSlice(allocator, decoded);
            continue;
        }

        if (vars.get(part)) |value| {
            try out.appendSlice(allocator, value);
            continue;
        }

        return null;
    }

    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn parseZipPathFromHtml(html_body: []const u8) ?[]const u8 {
    const files_idx = std.mem.indexOf(u8, html_body, "files/") orelse return null;

    var start = files_idx;
    while (start > 0 and html_body[start - 1] != '\'' and html_body[start - 1] != '"') : (start -= 1) {}

    var end = files_idx;
    while (end < html_body.len and html_body[end] != '\'' and html_body[end] != '"' and html_body[end] != '<' and html_body[end] != ' ') : (end += 1) {}

    if (end <= files_idx) return null;
    const value = html_body[files_idx..end];
    if (std.mem.indexOf(u8, value, ".zip") == null) return null;
    return value;
}

fn decodeJsString(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const esc = input[i + 1];
            i += 1;
            try out.append(allocator, switch (esc) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '\'' => '\'',
                '"' => '"',
                else => esc,
            });
            continue;
        }
        try out.append(allocator, input[i]);
    }

    return try out.toOwnedSlice(allocator);
}

fn isJsIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '$';
}

fn escapeUrlPath(allocator: Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (path) |c| {
        if (c == ' ') {
            try out.appendSlice(allocator, "%20");
            continue;
        }
        try out.append(allocator, c);
    }

    return try out.toOwnedSlice(allocator);
}

test "tvsub parse subtitle id" {
    try std.testing.expectEqualStrings("321398", parseSubtitleId("https://www.tvsubtitles.net/subtitle-321398.html").?);
    try std.testing.expect(parseSubtitleId("https://x/subtitle-abc.html") == null);
}

test "tvsub parse document.location concat" {
    const allocator = std.testing.allocator;
    const html_snippet =
        "var s1='fil';var s2='es/T';var s3='he';var s4='Name.en.zip';document.location = s1+s2+s3+s4;";
    const parsed = (try parseDocumentLocationFromScript(allocator, html_snippet)).?;
    defer allocator.free(parsed);
    try std.testing.expectEqualStrings("files/TheName.en.zip", parsed);
}
