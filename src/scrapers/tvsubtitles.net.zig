const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");
const HtmlParseOptions: html.ParseOptions = .{};
const HtmlDocument = HtmlParseOptions.GetDocument();
const HtmlNode = HtmlParseOptions.GetNode();

const Allocator = std.mem.Allocator;
const site = "http://www.tvsubtitles.net";

const ProviderRoute = enum {
    search,
    show,
    subtitle,
    download,
    archive,
};

pub const SearchOptions = struct {};

pub const SubtitlesOptions = struct {
    include_all_seasons: bool = true,
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

pub const SearchResponse = common.PagedSearchResponse(SearchItem);

pub const SubtitlesResponse = common.PagedSubtitlesResponse(SubtitleItem);

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchWithOptions(query, .{});
    }

    pub fn searchWithOptions(self: *Scraper, query: []const u8, _: SearchOptions) !SearchResponse {
        return self.searchWithOptionsUsing(query, fetchSearchPage);
    }

    fn searchWithOptionsUsing(self: *Scraper, query: []const u8, comptime fetch_page: anytype) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var out: std.ArrayListUnmanaged(SearchItem) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const page_url = try buildSearchUrl(a, trimmed);
        const response = try fetch_page(self.client, a, page_url);
        if (common.getenv("SCRAPERS_DEBUG_TVSUB") != null) std.debug.print("[tvsubtitles] search status={d} bytes={d}\n", .{ @backingInt(response.status), response.body.len });
        if (response.body.len > 0) {
            var doc = try common.parseHtmlStable(a, response.body);
            try collectSearchItems(a, &doc.doc, trimmed, &out, &seen);
            if (out.items.len == 0) try collectSearchItemsRaw(a, response.body, trimmed, &out, &seen);
        }

        return common.finishResponse(SearchResponse, &arena, .{
            .arena = arena,
            .items = try out.toOwnedSlice(a),
            .page = 1,
            .has_prev_page = false,
            .has_next_page = false,
        });
    }

    pub fn fetchSubtitlesByShowLinkWithOptions(self: *Scraper, show_url: []const u8, options: SubtitlesOptions) !SubtitlesResponse {
        return self.fetchSubtitlesByShowLinkWithOptionsUsing(show_url, options, fetchTvShowHtml);
    }

    fn fetchSubtitlesByShowLinkWithOptionsUsing(self: *Scraper, show_url: []const u8, options: SubtitlesOptions, comptime fetch_html: anytype) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderUrl(show_url, .show);

        const root_response = try fetch_html(self.client, a, show_url);
        if (root_response.body.len == 0) return .{ .arena = arena, .subtitles = &.{} };

        var root_doc = try common.parseHtmlStable(a, root_response.body);

        var season_urls: std.ArrayListUnmanaged([]const u8) = .empty;
        var queued_seasons = std.StringHashMapUnmanaged(void).empty;
        const root_season_url = try a.dupe(u8, show_url);

        if (options.include_all_seasons) {
            var season_links = root_doc.doc.queryAll("p.description a[href*='tvshow-']");
            while (season_links.next()) |anchor| {
                const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                if (std.mem.indexOf(u8, href, "tvshow-") == null) continue;
                if (queued_seasons.contains(href)) continue;
                try queued_seasons.ensureUnusedCapacity(a, 1);
                try season_urls.ensureUnusedCapacity(a, 1);
                queued_seasons.putAssumeCapacityNoClobber(href, {});
                season_urls.appendAssumeCapacity(href);
            }
        }

        var seen_season = std.StringHashMapUnmanaged(void).empty;
        var seen_subtitle = std.StringHashMapUnmanaged(void).empty;
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;

        try seen_season.put(a, root_season_url, {});
        try self.appendSubtitleRows(a, &root_doc.doc, root_season_url, options, &subtitles, &seen_subtitle);

        for (season_urls.items) |href| {
            const initial_season_url = (try resolveProviderUrlOptional(a, href, .show)) orelse continue;
            if (seen_season.contains(initial_season_url)) continue;
            try seen_season.put(a, initial_season_url, {});

            const response = try fetch_html(self.client, a, initial_season_url);
            if (response.body.len == 0) continue;

            var doc = try common.parseHtmlStable(a, response.body);
            try self.appendSubtitleRows(a, &doc.doc, initial_season_url, options, &subtitles, &seen_subtitle);
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .subtitles = try subtitles.toOwnedSlice(a),
            .page = 1,
            .has_prev_page = false,
            .has_next_page = false,
        });
    }

    fn appendSubtitleRows(
        self: *Scraper,
        allocator: Allocator,
        doc: *const HtmlDocument,
        season_page_url: []const u8,
        options: SubtitlesOptions,
        subtitles: *std.ArrayListUnmanaged(SubtitleItem),
        seen_subtitle: *std.StringHashMapUnmanaged(void),
    ) !void {
        var rows = doc.queryAll("table#table5 tr[align='middle']");
        while (rows.next()) |row| {
            var episode_title_loaded = false;
            var episode_title: ?[]const u8 = null;

            var anchors = row.queryAll("a[href*='subtitle-']");
            while (anchors.next()) |anchor| {
                const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
                const subtitle_id = parseSubtitleId(href) orelse continue;
                if (seen_subtitle.contains(subtitle_id)) continue;
                const subtitle_page_url = (try resolveProviderUrlOptional(allocator, href, .subtitle)) orelse continue;

                try seen_subtitle.ensureUnusedCapacity(allocator, 1);
                try subtitles.ensureUnusedCapacity(allocator, 1);
                if (!episode_title_loaded) {
                    episode_title = try episodeTitle(row, allocator);
                    episode_title_loaded = true;
                }
                const download_page_url = try std.fmt.allocPrint(allocator, "{s}/download-{s}.html", .{ site, subtitle_id });

                var direct_zip_url: ?[]const u8 = null;
                if (options.resolve_download_links) {
                    direct_zip_url = try self.resolveDownloadUrl(allocator, download_page_url);
                }

                const lang = try common.dupOptional(allocator, languageFromSubtitleAnchor(anchor, row, href));
                const filename = try buildFilename(allocator, episode_title, lang);

                seen_subtitle.putAssumeCapacityNoClobber(subtitle_id, {});
                subtitles.appendAssumeCapacity(.{
                    .language_code = lang,
                    .episode_title = episode_title,
                    .filename = filename,
                    .season_page_url = season_page_url,
                    .subtitle_page_url = subtitle_page_url,
                    .download_page_url = download_page_url,
                    .direct_zip_url = direct_zip_url,
                });
            }
        }
    }

    pub fn resolveDownloadPageUrl(self: *Scraper, allocator: Allocator, download_page_url: []const u8) ![]const u8 {
        return self.resolveDownloadUrl(allocator, download_page_url);
    }

    fn resolveDownloadUrl(self: *Scraper, allocator: Allocator, download_page_url: []const u8) ![]const u8 {
        const response = try fetchTvDownloadHtml(self.client, allocator, download_page_url);
        defer allocator.free(response.body);
        if (response.status != .ok) return error.UnexpectedHttpStatus;

        if (try parseDocumentLocationFromScript(allocator, response.body)) |script_path| {
            defer allocator.free(script_path);
            const escaped = try escapeUrlPath(allocator, script_path);
            defer allocator.free(escaped);
            return try resolveProviderUrl(allocator, escaped, .archive);
        }

        const script_path = parseZipPathFromHtml(response.body) orelse return error.MissingField;
        const escaped = try escapeUrlPath(allocator, script_path);
        defer allocator.free(escaped);
        return try resolveProviderUrl(allocator, escaped, .archive);
    }
};

fn buildSearchUrl(allocator: Allocator, query: []const u8) ![]const u8 {
    const encoded = try common.encodeUriComponent(allocator, query);
    return std.fmt.allocPrint(allocator, "{s}/search.php?qs={s}", .{ site, encoded });
}

fn collectSearchItemsRaw(allocator: Allocator, body: []const u8, query: []const u8, out: *std.ArrayListUnmanaged(SearchItem), seen: *std.StringHashMapUnmanaged(void)) !void {
    var cursor: usize = 0;
    const needle = "href=\"tvshow-";
    while (std.mem.indexOfPos(u8, body, cursor, needle)) |marker| {
        const href_start = marker + "href=\"".len;
        const href_end = std.mem.indexOfScalarPos(u8, body, href_start, '"') orelse break;
        cursor = href_end + 1;
        const bold_start_marker = std.mem.indexOfPos(u8, body, href_end, "<b>") orelse continue;
        if (bold_start_marker > href_end + 160) continue;
        const title_start = bold_start_marker + 3;
        const title_end = std.mem.indexOfPos(u8, body, title_start, "</b>") orelse continue;
        const title = std.mem.trim(u8, body[title_start..title_end], " \t\r\n");
        if (title.len == 0 or !try titleMatchesQuery(allocator, title, query)) continue;
        const href = body[href_start..href_end];
        if (seen.contains(href)) continue;
        try seen.ensureUnusedCapacity(allocator, 1);
        try out.ensureUnusedCapacity(allocator, 1);
        const show_url = (try resolveProviderUrlOptional(allocator, href, .show)) orelse continue;
        const owned_title = try allocator.dupe(u8, title);
        seen.putAssumeCapacityNoClobber(href, {});
        out.appendAssumeCapacity(.{ .title = owned_title, .show_url = show_url });
    }
}

fn fetchSearchPage(client: *std.http.Client, allocator: Allocator, page_url: []const u8) !common.HttpResponse {
    try validateProviderUrl(page_url, .search);
    return fetchSearchPageWith(client, allocator, page_url, common.fetchBytes);
}

fn fetchSearchPageWith(client: *std.http.Client, allocator: Allocator, page_url: []const u8, comptime fetch: anytype) !common.HttpResponse {
    var response = try fetch(client, allocator, page_url, common.FetchOptions{
        .accept = "text/html",
        .cache = false,
        .max_attempts = 2,
        .retry_on_429 = false,
        .allow_non_ok = true,
        .require_public_origin = true,
    });
    if (response.status == .too_many_requests) {
        allocator.free(response.body);
        return error.RateLimited;
    }
    if (common.isAustralianWebsiteBlockPage(response.body)) {
        allocator.free(response.body);
        return error.ProviderAccessBlocked;
    }
    if (response.status != .ok or response.body.len == 0 or std.mem.indexOf(u8, response.body, "tvshow-") == null) {
        allocator.free(response.body);
        response = try fetch(client, allocator, site ++ "/tvshows.html", common.FetchOptions{
            .accept = "text/html",
            .cache = false,
            .max_attempts = 2,
            .retry_on_429 = false,
            .allow_non_ok = true,
            .require_public_origin = true,
        });
    }
    return acceptTvHtmlResponse(allocator, response);
}

fn fetchTvShowHtml(client: *std.http.Client, allocator: Allocator, canonical_url: []const u8) !common.HttpResponse {
    return fetchTvHtml(client, allocator, canonical_url, .show);
}

fn fetchTvDownloadHtml(client: *std.http.Client, allocator: Allocator, canonical_url: []const u8) !common.HttpResponse {
    return fetchTvHtml(client, allocator, canonical_url, .download);
}

fn fetchTvHtml(client: *std.http.Client, allocator: Allocator, canonical_url: []const u8, route: ProviderRoute) !common.HttpResponse {
    try validateProviderUrl(canonical_url, route);
    const response = try common.fetchBytes(client, allocator, canonical_url, .{
        .accept = "text/html",
        .cache = false,
        .max_attempts = 2,
        .retry_on_429 = false,
        .allow_non_ok = true,
        .require_public_origin = true,
    });
    return acceptTvHtmlResponse(allocator, response);
}

fn acceptTvHtmlResponse(allocator: Allocator, response: common.HttpResponse) !common.HttpResponse {
    if (response.status == .too_many_requests) {
        allocator.free(response.body);
        return error.RateLimited;
    }
    if (common.isAustralianWebsiteBlockPage(response.body)) {
        allocator.free(response.body);
        return error.ProviderAccessBlocked;
    }
    if (response.status != .ok) {
        allocator.free(response.body);
        return error.UnexpectedHttpStatus;
    }
    return response;
}

fn collectSearchItems(allocator: Allocator, doc: *const HtmlDocument, query: []const u8, out: *std.ArrayListUnmanaged(SearchItem), seen: *std.StringHashMapUnmanaged(void)) !void {
    const before_len = out.items.len;
    var anchors = doc.queryAll(".left_articles a[href*='tvshow-']");
    while (anchors.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (std.mem.indexOf(u8, href, "tvshow-") == null) continue;
        if (std.mem.indexOf(u8, href, ".html") == null) continue;

        if (seen.contains(href)) continue;
        try seen.ensureUnusedCapacity(allocator, 1);
        try out.ensureUnusedCapacity(allocator, 1);
        const title = try common.innerTextTrimmedOwned(allocator, anchor);
        if (title.len == 0) continue;
        if (!try titleMatchesQuery(allocator, title, query)) continue;
        const show_url = (try resolveProviderUrlOptional(allocator, href, .show)) orelse continue;

        seen.putAssumeCapacityNoClobber(href, {});
        out.appendAssumeCapacity(.{ .title = title, .show_url = show_url });
    }

    if (out.items.len == before_len) {
        var fallback = doc.queryAll("a[href*='tvshow-']");
        while (fallback.next()) |anchor| {
            const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
            if (std.mem.indexOf(u8, href, "tvshow-") == null) continue;
            if (std.mem.indexOf(u8, href, ".html") == null) continue;

            if (seen.contains(href)) continue;
            try seen.ensureUnusedCapacity(allocator, 1);
            try out.ensureUnusedCapacity(allocator, 1);
            const title = try common.innerTextTrimmedOwned(allocator, anchor);
            if (title.len == 0) continue;
            if (!try titleMatchesQuery(allocator, title, query)) continue;
            const show_url = (try resolveProviderUrlOptional(allocator, href, .show)) orelse continue;

            seen.putAssumeCapacityNoClobber(href, {});
            out.appendAssumeCapacity(.{ .title = title, .show_url = show_url });
        }
    }
}

fn titleMatchesQuery(allocator: Allocator, title: []const u8, query: []const u8) !bool {
    const normalized_title = try common.normalizeTitle(allocator, title);
    const normalized_query = try common.normalizeTitle(allocator, query);
    return common.normalizedTitlesRelated(normalized_title, normalized_query);
}

fn episodeTitle(row: HtmlNode, allocator: Allocator) !?[]const u8 {
    if (row.queryOne("td:nth-child(2) a b")) |node| {
        const text = try common.innerTextTrimmedOwned(allocator, node);
        if (text.len > 0) return text;
    }
    if (row.queryOne("td:nth-child(2) a")) |node| {
        const text = try common.innerTextTrimmedOwned(allocator, node);
        if (text.len > 0) return text;
    }
    return null;
}

fn parseSubtitleId(subtitle_page_url: []const u8) ?[]const u8 {
    const path = if (std.mem.startsWith(u8, subtitle_page_url, "http://") or
        std.mem.startsWith(u8, subtitle_page_url, "https://"))
    absolute: {
        const uri = std.Uri.parse(subtitle_page_url) catch return null;
        if (uri.query != null or uri.fragment != null or uri.user != null or uri.password != null) return null;
        break :absolute switch (uri.path) {
            .raw, .percent_encoded => |value| value,
        };
    } else relative: {
        if (std.mem.indexOfAny(u8, subtitle_page_url, "?#") != null) return null;
        break :relative subtitle_page_url;
    };

    const canonical_path = if (std.mem.startsWith(u8, path, "/")) path else else_path: {
        if (std.mem.indexOfScalar(u8, path, '/') != null) return null;
        break :else_path path;
    };
    const prefix = if (std.mem.startsWith(u8, canonical_path, "/")) "/subtitle-" else "subtitle-";
    return parsePositiveRouteId(canonical_path, prefix, ".html");
}

fn languageFromSubtitleAnchor(anchor: HtmlNode, row: HtmlNode, href: []const u8) ?[]const u8 {
    if (anchor.queryOne("img")) |img| {
        if (common.getAttributeValueSafe(img, "alt")) |alt| {
            if (normalizeTvLanguage(alt)) |code| return code;
        }
        if (common.getAttributeValueSafe(img, "src")) |src| {
            if (languageFromFlagSource(src)) |code| return code;
        }
    }

    if (rowHasSingleSubtitleAnchor(row)) {
        var alt_images = row.queryAll("img[alt]");
        while (alt_images.next()) |img| {
            if (common.getAttributeValueSafe(img, "alt")) |alt| {
                if (normalizeTvLanguage(alt)) |code| return code;
            }
        }
        var source_images = row.queryAll("img[src]");
        while (source_images.next()) |img| {
            if (common.getAttributeValueSafe(img, "src")) |src| {
                if (languageFromFlagSource(src)) |code| return code;
            }
        }
    }

    if (std.mem.lastIndexOfScalar(u8, href, '-')) |dash| {
        const tail = href[dash + 1 ..];
        if (tail.len >= 2 and std.ascii.isAlphabetic(tail[0]) and std.ascii.isAlphabetic(tail[1]) and
            (tail.len == 2 or tail[2] == '.' or tail[2] == '-' or tail[2] == '_'))
        {
            return normalizeTvLanguage(tail[0..2]);
        }
    }

    return null;
}

fn rowHasSingleSubtitleAnchor(row: HtmlNode) bool {
    var anchors = row.queryAll("a[href*='subtitle-']");
    if (anchors.next() == null) return false;
    return anchors.next() == null;
}

fn languageFromFlagSource(src: []const u8) ?[]const u8 {
    const path_end = std.mem.indexOfAny(u8, src, "?#") orelse src.len;
    const path = src[0..path_end];
    const basename_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
    const basename = path[basename_start..];
    const extension = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    return normalizeTvLanguage(basename[0..extension]);
}

fn normalizeTvLanguage(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (common.normalizeLanguageCode(trimmed)) |code| return code;
    if (trimmed.len == 2 and std.ascii.isAlphabetic(trimmed[0]) and std.ascii.isAlphabetic(trimmed[1]))
        return mapLanguageCode(trimmed);
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
    if (std.mem.indexOf(u8, html_body, marker) == null) return null;

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

    var location_cursor: usize = 0;
    while (std.mem.indexOfPos(u8, html_body, location_cursor, marker)) |idx| {
        location_cursor = idx + marker.len;
        const after = html_body[location_cursor..];
        const eq_idx = std.mem.indexOfScalar(u8, after, '=') orelse continue;
        const semicolon_idx = std.mem.indexOfScalarPos(u8, after, eq_idx + 1, ';') orelse continue;
        const expr = std.mem.trim(u8, after[eq_idx + 1 .. semicolon_idx], " \t\r\n");
        if (expr.len == 0) continue;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        var expression_valid = true;
        var it = std.mem.tokenizeScalar(u8, expr, '+');
        while (it.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " \t\r\n");
            if (part.len == 0) continue;

            if (part.len >= 2 and ((part[0] == '\'' and part[part.len - 1] == '\'') or (part[0] == '"' and part[part.len - 1] == '"'))) {
                const decoded = try decodeJsString(allocator, part[1 .. part.len - 1]);
                defer allocator.free(decoded);
                try out.appendSlice(allocator, decoded);
                continue;
            }

            if (vars.get(part)) |value| {
                try out.appendSlice(allocator, value);
                continue;
            }

            expression_valid = false;
            break;
        }

        if (!expression_valid or out.items.len == 0) continue;
        const candidate = try out.toOwnedSlice(allocator);
        if (!try isValidScriptArchiveCandidate(allocator, candidate)) {
            allocator.free(candidate);
            continue;
        }
        return candidate;
    }
    return null;
}

fn isValidScriptArchiveCandidate(allocator: Allocator, candidate: []const u8) !bool {
    const escaped = try escapeUrlPath(allocator, candidate);
    defer allocator.free(escaped);
    const resolved = resolveProviderUrl(allocator, escaped, .archive) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    allocator.free(resolved);
    return true;
}

fn parseZipPathFromHtml(html_body: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, html_body, cursor, "files/")) |files_idx| {
        cursor = files_idx + "files/".len;
        if (files_idx > 0) {
            const preceding = html_body[files_idx - 1];
            if (std.ascii.isAlphanumeric(preceding) or preceding == '_' or preceding == '-') continue;
        }
        var end = files_idx;
        while (end < html_body.len and html_body[end] != '\'' and html_body[end] != '"' and
            html_body[end] != '<' and html_body[end] != ' ') : (end += 1)
        {}

        if (end <= files_idx) continue;
        const value = html_body[files_idx..end];
        if (isSafeEncodedArchiveFilename(value["files/".len..])) return value;
    }
    return null;
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

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderUrl(resolved, route);
    return resolved;
}

fn resolveProviderUrlOptional(allocator: Allocator, href: []const u8, route: ProviderRoute) !?[]const u8 {
    return resolveProviderUrl(allocator, href, route) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
}

fn validateProviderUrl(url: []const u8, route: ProviderRoute) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };

    switch (route) {
        .search => {
            if (!std.mem.eql(u8, path, "/search.php")) return error.UnsafeHttpTarget;
            const query_component = uri.query orelse return error.UnsafeHttpTarget;
            const query = switch (query_component) {
                .raw, .percent_encoded => |value| value,
            };
            if (!isCanonicalSearchQuery(query)) return error.UnsafeHttpTarget;
        },
        .show => {
            if (uri.query != null or !isCanonicalShowPath(path)) return error.UnsafeHttpTarget;
        },
        .subtitle => {
            if (uri.query != null or parsePositiveRouteId(path, "/subtitle-", ".html") == null)
                return error.UnsafeHttpTarget;
        },
        .download => {
            if (uri.query != null or parsePositiveRouteId(path, "/download-", ".html") == null)
                return error.UnsafeHttpTarget;
        },
        .archive => {
            const prefix = "/files/";
            if (uri.query != null or !std.mem.startsWith(u8, path, prefix) or
                !isSafeEncodedArchiveFilename(path[prefix.len..])) return error.UnsafeHttpTarget;
        },
    }
}

fn parsePositiveRouteId(path: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    if (path.len <= prefix.len + suffix.len) return null;
    const id = path[prefix.len .. path.len - suffix.len];
    if (!isCanonicalPositiveId(id)) return null;
    return id;
}

fn isCanonicalPositiveId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isCanonicalShowPath(path: []const u8) bool {
    const prefix = "/tvshow-";
    const suffix = ".html";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return false;
    if (path.len <= prefix.len + suffix.len) return false;

    const route_ids = path[prefix.len .. path.len - suffix.len];
    var ids = std.mem.splitScalar(u8, route_ids, '-');
    const show_id = ids.next() orelse return false;
    if (!isCanonicalPositiveId(show_id)) return false;
    if (ids.next()) |season| {
        if (!isCanonicalPositiveId(season)) return false;
    }
    return ids.next() == null;
}

fn isCanonicalSearchQuery(query: []const u8) bool {
    const prefix = "qs=";
    if (!std.mem.startsWith(u8, query, prefix) or query.len == prefix.len or query.len > 2048) return false;

    var index: usize = prefix.len;
    while (index < query.len) {
        const byte = query[index];
        if (byte == '%') {
            if (query.len - index < 3) return false;
            _ = std.fmt.charToDigit(query[index + 1], 16) catch return false;
            _ = std.fmt.charToDigit(query[index + 2], 16) catch return false;
            index += 3;
            continue;
        }
        if (byte < 0x20 or byte > 0x7e or byte == '&' or byte == '=' or byte == '#' or byte == '?') return false;
        index += 1;
    }
    return true;
}

fn isSafeEncodedArchiveFilename(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024 or !std.ascii.endsWithIgnoreCase(value, ".zip")) return false;
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
            index += 1;
        }
        if (byte < 0x20 or byte == 0x7f or byte == '%' or byte == '/' or byte == '\\' or byte == '?' or byte == '#') return false;
    }
    return true;
}

test "tvsub parse subtitle id" {
    try std.testing.expectEqualStrings("321398", parseSubtitleId(site ++ "/subtitle-321398.html").?);
    try std.testing.expectEqualStrings("321398", parseSubtitleId("subtitle-321398.html").?);
    try std.testing.expect(parseSubtitleId("https://x/subtitle-abc.html") == null);
    try std.testing.expect(parseSubtitleId(site ++ "/foo-subtitle-321398.html") == null);
    try std.testing.expect(parseSubtitleId(site ++ "/subtitle-321398evil.html") == null);
    try std.testing.expect(parseSubtitleId(site ++ "/subtitle-0321398.html") == null);
    try std.testing.expect(parseSubtitleId(site ++ "/subtitle-321398.html?next=/admin") == null);
}

test "tvsub empty search does not fetch" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.TestUnexpectedResult;
        }
    };
    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.searchWithOptionsUsing(" \t\r\n", Fixture.fetch);
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "tvsub valid duplicate search result is not shadowed by an invalid one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try common.parseHtmlStable(
        a,
        "<div class='left_articles'><a href='tvshow-7.html'></a><a href='tvshow-7.html'>Wanted Show</a></div>",
    );
    defer parsed.deinit();
    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    try collectSearchItems(a, &parsed.doc, "Wanted", &out, &seen);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("Wanted Show", out.items[0].title);
}

test "tvsub search relevance rejects partial-word and unrelated rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try common.parseHtmlStable(
        a,
        "<div class='left_articles'>" ++
            "<a href='tvshow-1.html'>Preacher</a>" ++
            "<a href='tvshow-2.html'>Jack Reacher</a>" ++
            "<a href='tvshow-3.html'>The Matrix</a></div>",
    );
    defer parsed.deinit();
    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    try collectSearchItems(a, &parsed.doc, "Reacher", &out, &seen);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("Jack Reacher", out.items[0].title);

    var raw_out: std.ArrayListUnmanaged(SearchItem) = .empty;
    var raw_seen = std.StringHashMapUnmanaged(void).empty;
    try collectSearchItemsRaw(
        a,
        "<a href=\"tvshow-1.html\"><b>Preacher</b></a>" ++
            "<a href=\"tvshow-2.html\"><b>Jack Reacher</b></a>",
        "Reacher",
        &raw_out,
        &raw_seen,
    );
    try std.testing.expectEqual(@as(usize, 1), raw_out.items.len);
    try std.testing.expectEqualStrings("Jack Reacher", raw_out.items[0].title);
}

test "tvsub known duplicate search rows allocate nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed = try common.parseHtmlStable(
        arena.allocator(),
        "<div class='left_articles'><a href='tvshow-7.html'>Wanted Show</a></div>",
    );
    defer parsed.deinit();
    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(std.testing.allocator);
    try seen.put(std.testing.allocator, "tvshow-7.html", {});

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try collectSearchItems(failing.allocator(), &parsed.doc, "Wanted", &out, &seen);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "tvsub root page is parsed without fetching it twice" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, a: Allocator, url: []const u8) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            const body = if (std.mem.endsWith(u8, url, "/tvshow-1.html"))
                "<p class='description'><a href='tvshow-1-2.html'>Season 2</a>" ++
                    "<a href='tvshow-1-2.html'>Season 2 duplicate</a></p>" ++
                    "<table id='table5'><tr align='middle'><td>1</td><td><a><b>Pilot</b></a></td>" ++
                    "<td><a href='subtitle-101.html'><img src='images/flags/en.gif'></a>" ++
                    "<a href='subtitle-101.html'>duplicate</a></td></tr></table>"
            else
                "<table id='table5'><tr align='middle'><td>2</td><td><a><b>Return</b></a></td>" ++
                    "<td><a href='subtitle-202.html'><img src='images/flags/gr.gif'></a></td></tr></table>";
            return .{ .status = .ok, .body = try a.dupe(u8, body) };
        }
    };
    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &fixture.client);
    var response = try scraper.fetchSubtitlesByShowLinkWithOptionsUsing(
        site ++ "/tvshow-1.html",
        .{},
        Fixture.fetch,
    );
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(usize, 2), response.subtitles.len);
    try std.testing.expectEqualStrings("en", response.subtitles[0].language_code.?);
    try std.testing.expectEqualStrings("el", response.subtitles[1].language_code.?);
}

test "tvsub malformed and known duplicate subtitle rows allocate nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed = try common.parseHtmlStable(
        arena.allocator(),
        "<table id='table5'><tr align='middle'><td>1</td><td><a><b>Pilot</b></a></td>" ++
            "<td><a href='subtitle-abc.html'>malformed</a>" ++
            "<a href='subtitle-123.html'>duplicate</a></td></tr></table>",
    );
    defer parsed.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(std.testing.allocator);
    try seen.put(std.testing.allocator, "123", {});

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try scraper.appendSubtitleRows(
        failing.allocator(),
        &parsed.doc,
        site ++ "/tvshow-1.html",
        .{},
        &subtitles,
        &seen,
    );
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), subtitles.items.len);
}

test "tvsub language falls back to flag source but not a numeric subtitle id" {
    var parsed = try common.parseHtmlStable(
        std.testing.allocator,
        "<table><tr><td><a href='subtitle-123.html'><img src='/images/flags/gr.gif'></a></td></tr>" ++
            "<tr><td><a href='subtitle-456.html'>Download</a></td></tr></table>",
    );
    defer parsed.deinit();
    var rows = parsed.doc.queryAll("tr");
    const flag_row = rows.next() orelse return error.TestUnexpectedResult;
    const flag_anchor = flag_row.queryOne("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("el", languageFromSubtitleAnchor(flag_anchor, flag_row, "subtitle-123.html").?);
    const numeric_row = rows.next() orelse return error.TestUnexpectedResult;
    const numeric_anchor = numeric_row.queryOne("a") orelse return error.TestUnexpectedResult;
    try std.testing.expect(languageFromSubtitleAnchor(numeric_anchor, numeric_row, "subtitle-456.html") == null);
}

test "tvsub row-wide flag does not leak to a sibling subtitle anchor" {
    var parsed = try common.parseHtmlStable(
        std.testing.allocator,
        "<table><tr><td><a href='subtitle-123.html'><img src='/images/flags/en.gif'></a>" ++
            "<a href='subtitle-456.html'>Download</a></td></tr></table>",
    );
    defer parsed.deinit();
    const row = parsed.doc.queryOne("tr") orelse return error.TestUnexpectedResult;
    var anchors = row.queryAll("a[href*='subtitle-']");
    const english_anchor = anchors.next() orelse return error.TestUnexpectedResult;
    const unflagged_anchor = anchors.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("en", languageFromSubtitleAnchor(english_anchor, row, "subtitle-123.html").?);
    try std.testing.expect(languageFromSubtitleAnchor(unflagged_anchor, row, "subtitle-456.html") == null);
}

test "tvsub optional row fields preserve allocation failures" {
    const source = "<table><tr><td>1</td><td><a><b>Episode Title</b></a></td></tr></table>";
    var parsed = try common.parseHtmlStable(std.testing.allocator, source);
    defer parsed.deinit();
    const row = parsed.doc.queryOne("tr") orelse return error.TestUnexpectedResult;

    var failing_title = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, episodeTitle(row, failing_title.allocator()));
    try std.testing.expect(failing_title.has_induced_failure);

    var failing_filename = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, buildFilename(failing_filename.allocator(), null, null));
    try std.testing.expect(failing_filename.has_induced_failure);
}

test "tvsub rejects unsafe provider urls before fetch" {
    for ([_][]const u8{
        "http://127.0.0.1/tvshow-1.html",
        "http://user@www.tvsubtitles.net/tvshow-1.html",
        "http://www.tvsubtitles.net.attacker.example/tvshow-1.html",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(url, .show));
    }

    try validateProviderUrl(site ++ "/search.php?qs=Chernobyl%202019", .search);
    try validateProviderUrl(site ++ "/tvshow-1.html", .show);
    try validateProviderUrl(site ++ "/tvshow-1-2.html", .show);
    try validateProviderUrl(site ++ "/subtitle-123.html", .subtitle);
    try validateProviderUrl(site ++ "/download-123.html", .download);
    try validateProviderUrl(site ++ "/files/The%20Name.en.zip", .archive);

    const InvalidRoute = struct { url: []const u8, route: ProviderRoute };
    for ([_]InvalidRoute{
        .{ .url = site ++ "/admin", .route = .show },
        .{ .url = site ++ "/foo-tvshow-1.html", .route = .show },
        .{ .url = site ++ "/tvshow-01.html", .route = .show },
        .{ .url = site ++ "/tvshow-1evil.html", .route = .show },
        .{ .url = site ++ "/tvshow-1.html?next=/admin", .route = .show },
        .{ .url = site ++ "/tvshow-1.html#fragment", .route = .show },
        .{ .url = site ++ "/foo-subtitle-123.html", .route = .subtitle },
        .{ .url = site ++ "/subtitle-123evil.html", .route = .subtitle },
        .{ .url = site ++ "/download-123evil.html", .route = .download },
        .{ .url = site ++ "/files/a%2fb.zip", .route = .archive },
        .{ .url = site ++ "/files/a.zip?next=/admin", .route = .archive },
        .{ .url = site ++ "/search.php?next=/admin", .route = .search },
        .{ .url = site ++ "/search.php?qs=Show&next=/admin", .route = .search },
    }) |case| try std.testing.expectError(error.UnsafeHttpTarget, validateProviderUrl(case.url, case.route));
}

test "tvsub parse document.location concat" {
    const allocator = std.testing.allocator;
    const html_snippet =
        "var s1='fil';var s2='es/T';var s3='he';var s4='Name.en.zip';document.location = s1+s2+s3+s4;";
    const parsed = (try parseDocumentLocationFromScript(allocator, html_snippet)).?;
    defer allocator.free(parsed);
    try std.testing.expectEqualStrings("files/TheName.en.zip", parsed);
}

test "tvsub malformed script quote returns no path" {
    try std.testing.expect((try parseDocumentLocationFromScript(std.testing.allocator, "document.location = ';")) == null);
    try std.testing.expect((try parseDocumentLocationFromScript(std.testing.allocator, "document.location = \";")) == null);
}

test "tvsub script resolver skips malformed document.location decoys" {
    const allocator = std.testing.allocator;
    const parsed = (try parseDocumentLocationFromScript(
        allocator,
        "var bad='files/decoy.zip.exe'; document.location=bad;" ++
            "var good='files/TheName.en.zip'; document.location=good;",
    )) orelse return error.TestUnexpectedResult;
    defer allocator.free(parsed);
    try std.testing.expectEqualStrings("files/TheName.en.zip", parsed);
}

test "tvsub zip fallback skips a malformed files decoy" {
    try std.testing.expectEqualStrings(
        "files/TheName.en.zip",
        parseZipPathFromHtml(
            "'profiles/embedded.zip' 'files/not-an-archive' 'files/decoy.zip.exe' 'files/../admin.zip' " ++
                "\"files/TheName.en.zip\"",
        ).?,
    );
}

test "tvsub rejects failed HTTP and access-block pages" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedHttpStatus, acceptTvHtmlResponse(a, .{
        .status = .forbidden,
        .body = try a.dupe(u8, "<html>Forbidden</html>"),
    }));
    try std.testing.expectError(error.ProviderAccessBlocked, acceptTvHtmlResponse(a, .{
        .status = .ok,
        .body = try a.dupe(u8, "Access to Website Disabled Federal Court of Australia"),
    }));
    const accepted = try acceptTvHtmlResponse(a, .{ .status = .ok, .body = try a.dupe(u8, "fixture") });
    defer a.free(accepted.body);
    try std.testing.expectEqualStrings("fixture", accepted.body);
}

test "tvsub failed search falls back to a successful catalog only" {
    const Mock = struct {
        fn fallback(_: *std.http.Client, a: Allocator, url: []const u8, options: common.FetchOptions) !common.HttpResponse {
            try std.testing.expect(!options.cache);
            const catalog = std.mem.endsWith(u8, url, "/tvshows.html");
            return .{
                .status = if (catalog) .ok else .not_found,
                .body = try a.dupe(u8, if (catalog) "<a href='tvshow-1.html'>Show</a>" else "Search unavailable"),
            };
        }
        fn failedCatalog(_: *std.http.Client, a: Allocator, _: []const u8, _: common.FetchOptions) !common.HttpResponse {
            return .{ .status = .service_unavailable, .body = try a.dupe(u8, "Unavailable") };
        }
        fn canceled(_: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            return error.Canceled;
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const a = std.testing.allocator;
    const response = try fetchSearchPageWith(&client, a, site ++ "/search.php?qs=Show", Mock.fallback);
    defer a.free(response.body);
    try std.testing.expectEqualStrings("<a href='tvshow-1.html'>Show</a>", response.body);
    try std.testing.expectError(error.UnexpectedHttpStatus, fetchSearchPageWith(&client, a, site ++ "/search.php", Mock.failedCatalog));
    try std.testing.expectError(error.Canceled, fetchSearchPageWith(&client, a, site ++ "/search.php", Mock.canceled));
}

test "tvsub rate limits stop acquisition before the catalog fallback" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, a: Allocator, _: []const u8, options: common.FetchOptions) !common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(!options.cache);
            return .{
                .status = if (self.calls == 1) .too_many_requests else .ok,
                .body = try a.dupe(u8, "<a href='tvshow-1.html'>Show</a>"),
            };
        }
    };
    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    try std.testing.expectError(error.RateLimited, fetchSearchPageWith(&fixture.client, std.testing.allocator, site ++ "/search.php", Fixture.fetch));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectError(error.RateLimited, acceptTvHtmlResponse(std.testing.allocator, .{
        .status = .too_many_requests,
        .body = try std.testing.allocator.dupe(u8, "Rate limited"),
    }));
}

test "tvsub subtitle response owns the caller show URL" {
    const Mock = struct {
        fn fetch(_: *std.http.Client, a: Allocator, _: []const u8) !common.HttpResponse {
            return .{ .status = .ok, .body = try a.dupe(
                u8,
                "<table id='table5'><tr align='middle'><td>1</td><td><a><b>Pilot</b></a></td>" ++
                    "<td><a href='/subtitle-123.html'><img alt='en'></a></td></tr></table>",
            ) };
        }
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var show_url = (site ++ "/tvshow-1.html").*;
    var response = try scraper.fetchSubtitlesByShowLinkWithOptionsUsing(&show_url, .{ .include_all_seasons = false }, Mock.fetch);
    defer response.deinit();
    @memset(&show_url, 'x');
    try std.testing.expectEqual(@as(usize, 1), response.subtitles.len);
    try std.testing.expectEqualStrings(site ++ "/tvshow-1.html", response.subtitles[0].season_page_url);
}
