const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");
const suite = @import("test_suite.zig");

const Allocator = std.mem.Allocator;

const user_agent = "scrape-subdl.com/0.1 (+https://subdl.com)";
const api_base = "https://api3.subdl.com";
const site = "https://subdl.com";

pub const Error = error{
    UnexpectedHttpStatus,
    InvalidSubtitleLink,
    MissingField,
    InvalidFieldType,
    UnexpectedTitleType,
    MissingSeasonSlug,
    UnsupportedSearchLanguage,
};

pub const SubtitlePath = struct {
    subdl_id: []const u8,
    slug: []const u8,
    season_slug: ?[]const u8,
    lang_slug: ?[]const u8,
};

pub const MediaType = enum {
    movie,
    tv,

    pub fn fromString(value: []const u8) ?MediaType {
        if (std.mem.eql(u8, value, "movie")) return .movie;
        if (std.mem.eql(u8, value, "tv")) return .tv;
        return null;
    }
};

pub const SearchItem = struct {
    media_type: MediaType,
    name: []const u8,
    poster_url: []const u8,
    year: i64,
    link: []const u8,
    original_name: []const u8,
    subtitles_count: i64,
};

pub const SearchLanguage = struct {
    name: []const u8,
    code: []const u8,
};

pub const project_search_languages = [_]SearchLanguage{
    .{ .name = "Arabic", .code = "ar" },
    .{ .name = "Brazillian Portuguese", .code = "pt" },
    .{ .name = "Danish", .code = "da" },
    .{ .name = "Dutch", .code = "nl" },
    .{ .name = "English", .code = "en" },
    .{ .name = "Farsi/Persian", .code = "fa" },
    .{ .name = "Pashto", .code = "ps" },
    .{ .name = "Finnish", .code = "fi" },
    .{ .name = "French", .code = "fr" },
    .{ .name = "Indonesian", .code = "id" },
    .{ .name = "Italian", .code = "it" },
    .{ .name = "Norwegian", .code = "no" },
    .{ .name = "Romanian", .code = "ro" },
    .{ .name = "Spanish", .code = "es" },
    .{ .name = "Swedish", .code = "sv" },
    .{ .name = "Vietnamese", .code = "vi" },
    .{ .name = "Albanian", .code = "sq" },
    .{ .name = "Azerbaijani", .code = "az" },
    .{ .name = "South Azerbaijani", .code = "azb" },
    .{ .name = "Belarusian", .code = "be" },
    .{ .name = "Bengali", .code = "bn" },
    .{ .name = "Big 5 code", .code = "zh-tw" },
    .{ .name = "Bosnian", .code = "bs" },
    .{ .name = "Bulgarian", .code = "bg" },
    .{ .name = "Bulgarian/ English", .code = "bg-en" },
    .{ .name = "Burmese", .code = "my" },
    .{ .name = "Catalan", .code = "ca" },
    .{ .name = "Chinese BG code", .code = "zh-cn" },
    .{ .name = "Croatian", .code = "hr" },
    .{ .name = "Czech", .code = "cs" },
    .{ .name = "Dutch/ English", .code = "nl-en" },
    .{ .name = "English/ German", .code = "en-de" },
    .{ .name = "Esperanto", .code = "eo" },
    .{ .name = "Estonian", .code = "et" },
    .{ .name = "Georgian", .code = "ka" },
    .{ .name = "German", .code = "de" },
    .{ .name = "Greek", .code = "el" },
    .{ .name = "Greenlandic", .code = "kl" },
    .{ .name = "Hebrew", .code = "he" },
    .{ .name = "Hindi", .code = "hi" },
    .{ .name = "Hungarian", .code = "hu" },
    .{ .name = "Hungarian/ English", .code = "hu-en" },
    .{ .name = "Icelandic", .code = "is" },
    .{ .name = "Japanese", .code = "ja" },
    .{ .name = "Korean", .code = "ko" },
    .{ .name = "Kurdish", .code = "ku" },
    .{ .name = "Latvian", .code = "lv" },
    .{ .name = "Lithuanian", .code = "lt" },
    .{ .name = "Macedonian", .code = "mk" },
    .{ .name = "Malay", .code = "ms" },
    .{ .name = "Malayalam", .code = "ml" },
    .{ .name = "Manipuri", .code = "mni" },
    .{ .name = "Polish", .code = "pl" },
    .{ .name = "Portuguese", .code = "pt" },
    .{ .name = "Russian", .code = "ru" },
    .{ .name = "Serbian", .code = "sr" },
    .{ .name = "Sinhala", .code = "si" },
    .{ .name = "Slovak", .code = "sk" },
    .{ .name = "Slovenian", .code = "sl" },
    .{ .name = "Tagalog", .code = "tl" },
    .{ .name = "Tamil", .code = "ta" },
    .{ .name = "Telugu", .code = "te" },
    .{ .name = "Thai", .code = "th" },
    .{ .name = "Turkish", .code = "tr" },
    .{ .name = "Ukranian", .code = "uk" },
    .{ .name = "Urdu", .code = "ur" },
};

pub const SeasonInfo = struct {
    number: []const u8,
    name: []const u8,
    poster: []const u8,
};

pub const TitleInfo = struct {
    media_type: MediaType,
    sd_id: i64,
    slug: []const u8,
    name: []const u8,
    second_name: []const u8,
    poster_url: []const u8,
    year: i64,
    total_seasons: i64,
};

pub const SubtitleItem = struct {
    id: i64,
    language: []const u8,
    quality: []const u8,
    link: []const u8,
    bucket_link: []const u8,
    author: []const u8,
    season: i64,
    episode: i64,
    title: []const u8,
    extra: []const u8,
    enabled: bool,
    n_id: []const u8,
    downloads: i64,
    hearing_impaired: bool,
    releases: []const []const u8,
    rate: ?f64,
    date_ms: i64,
    comment: []const u8,
    slug: ?[]const u8,
};

pub const LanguageSubtitles = struct {
    language: []const u8,
    subtitles: []const SubtitleItem,
};

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const MovieSubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    movie: TitleInfo,
    languages: []const LanguageSubtitles,

    pub fn deinit(self: *MovieSubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const TvSeasonsResponse = struct {
    arena: std.heap.ArenaAllocator,
    tv: TitleInfo,
    seasons: []const SeasonInfo,

    pub fn deinit(self: *TvSeasonsResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const TvSeasonSubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    tv: TitleInfo,
    season_slug: []const u8,
    languages: []const LanguageSubtitles,

    pub fn deinit(self: *TvSeasonSubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Scraper = struct {
    pub const Options = struct {
        include_empty_subtitle_groups: bool = false,
        search_language: []const u8 = "en",
    };

    allocator: Allocator,
    client: *std.http.Client,
    options: Options = .{},

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return initWithOptions(allocator, client, .{});
    }

    pub fn initWithOptions(allocator: Allocator, client: *std.http.Client, options: Options) Scraper {
        return .{
            .allocator = allocator,
            .client = client,
            .options = options,
        };
    }

    pub fn parseSubtitleLink(link: []const u8) Error!SubtitlePath {
        const marker = "/subtitle/";
        const marker_start = std.mem.indexOf(u8, link, marker) orelse return error.InvalidSubtitleLink;

        const with_prefix = link[marker_start + marker.len ..];
        const path_end = std.mem.indexOfAny(u8, with_prefix, "?#") orelse with_prefix.len;
        const path_no_query = with_prefix[0..path_end];

        var it = std.mem.tokenizeScalar(u8, path_no_query, '/');
        const subdl_id = it.next() orelse return error.InvalidSubtitleLink;
        const slug = it.next() orelse return error.InvalidSubtitleLink;

        if (!std.mem.startsWith(u8, subdl_id, "sd")) return error.InvalidSubtitleLink;

        const season_slug = it.next();
        const lang_slug = it.next();

        return .{
            .subdl_id = subdl_id,
            .slug = slug,
            .season_slug = season_slug,
            .lang_slug = lang_slug,
        };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        return self.searchWithLanguage(query, self.options.search_language);
    }

    pub fn searchWithLanguage(self: *Scraper, query: []const u8, language: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        _ = resolveProjectSearchLanguageCode(language) orelse return error.UnsupportedSearchLanguage;
        const encoded_query = try common.encodeUriComponent(a, query);
        const url = try std.fmt.allocPrint(a, "{s}/search?query={s}", .{ api_base, encoded_query });
        const body = try self.fetchBytes(a, url, "application/json");
        const json_root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const root_object = try asObject(json_root);
        const result_array = try asArray(try getRequiredField(root_object, "results"));

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (result_array.items) |entry| {
            const entry_obj = try asObject(entry);
            const media_type_text = try getRequiredString(entry_obj, "type");
            const media_type = MediaType.fromString(media_type_text) orelse continue;
            const link = try getRequiredString(entry_obj, "link");

            try items.append(a, .{
                .media_type = media_type,
                .name = try getRequiredString(entry_obj, "name"),
                .poster_url = try getStringOrDefault(entry_obj, "poster_url", ""),
                .year = try getRequiredInt(entry_obj, "year"),
                .link = link,
                .original_name = try getStringOrDefault(entry_obj, "original_name", try getRequiredString(entry_obj, "name")),
                .subtitles_count = try getIntOrDefault(entry_obj, "subtitles_count", 0),
            });
        }

        return .{
            .arena = arena,
            .items = try items.toOwnedSlice(a),
        };
    }

    pub fn fetchMovieByLink(self: *Scraper, link: []const u8) !MovieSubtitlesResponse {
        const page = try self.fetchSubtitlePage(link, null);
        errdefer page.arena.deinit();

        if (page.title.media_type != .movie) return error.UnexpectedTitleType;

        return .{
            .arena = page.arena,
            .movie = page.title,
            .languages = page.languages,
        };
    }

    pub fn fetchTvSeasonsByLink(self: *Scraper, link: []const u8) !TvSeasonsResponse {
        const page = try self.fetchSubtitlePage(link, null);
        errdefer page.arena.deinit();

        if (page.title.media_type != .tv) return error.UnexpectedTitleType;

        return .{
            .arena = page.arena,
            .tv = page.title,
            .seasons = page.seasons,
        };
    }

    pub fn fetchTvSeasonByLink(self: *Scraper, link: []const u8, season_slug: ?[]const u8) !TvSeasonSubtitlesResponse {
        const parsed = try parseSubtitleLink(link);

        const resolved_season_slug = season_slug orelse parsed.season_slug orelse return error.MissingSeasonSlug;

        const page = try self.fetchSubtitlePage(link, resolved_season_slug);
        errdefer page.arena.deinit();

        if (page.title.media_type != .tv) return error.UnexpectedTitleType;

        return .{
            .arena = page.arena,
            .tv = page.title,
            .season_slug = resolved_season_slug,
            .languages = page.languages,
        };
    }

    const PageParseResult = struct {
        arena: std.heap.ArenaAllocator,
        title: TitleInfo,
        seasons: []const SeasonInfo,
        languages: []const LanguageSubtitles,
    };

    fn fetchSubtitlePage(self: *Scraper, link: []const u8, season_slug: ?[]const u8) !PageParseResult {
        const parsed = try parseSubtitleLink(link);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const path = if (season_slug) |season|
            try std.fmt.allocPrint(a, "/subtitle/{s}/{s}/{s}", .{ parsed.subdl_id, parsed.slug, season })
        else
            try std.fmt.allocPrint(a, "/subtitle/{s}/{s}", .{ parsed.subdl_id, parsed.slug });
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ site, path });
        const body = try self.fetchBytes(a, url, "text/html");
        var html_page = try common.parseHtmlStable(a, body);

        const seasons = try parseHtmlSeasons(a, &html_page.doc, path);
        const movie_info = try parseHtmlTitleInfo(a, &html_page.doc, body, parsed, seasons.len);
        const languages = try parseHtmlLanguages(a, &html_page.doc, self.options.include_empty_subtitle_groups);

        return .{
            .arena = arena,
            .title = movie_info,
            .seasons = seasons,
            .languages = languages,
        };
    }

    fn fetchBytes(self: *Scraper, allocator: Allocator, url: []const u8, accept: []const u8) ![]u8 {
        const headers = [_]std.http.Header{
            .{ .name = "accept", .value = accept },
            .{ .name = "user-agent", .value = user_agent },
        };

        const response = try common.fetchBytes(self.client, allocator, url, .{
            .accept = accept,
            .extra_headers = &headers,
            .max_attempts = 3,
            .retry_initial_backoff_ms = 400,
        });
        if (response.status != .ok) {
            allocator.free(response.body);
            return error.UnexpectedHttpStatus;
        }
        return response.body;
    }
};

pub fn resolveProjectSearchLanguageCode(language_or_code: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, language_or_code, " \t\r\n");
    for (project_search_languages) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.name)) return entry.code;
        if (eqlCode(trimmed, entry.code)) return entry.code;
    }
    return null;
}

fn eqlCode(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const ac_norm = if (ac == '_') '-' else std.ascii.toLower(ac);
        const bc_norm = if (bc == '_') '-' else std.ascii.toLower(bc);
        if (ac_norm != bc_norm) return false;
    }
    return true;
}

fn encodePathSegment(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (value) |byte| {
        const is_unreserved = (byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (is_unreserved) {
            try out.append(allocator, byte);
            continue;
        }
        var encoded: [3]u8 = undefined;
        _ = try std.fmt.bufPrint(&encoded, "%{X:0>2}", .{byte});
        try out.appendSlice(allocator, &encoded);
    }

    return try out.toOwnedSlice(allocator);
}

fn parseHtmlTitleInfo(
    allocator: Allocator,
    doc: *const html.Document,
    body: []const u8,
    path: SubtitlePath,
    season_count: usize,
) !TitleInfo {
    const heading = doc.queryOne("h1") orelse return error.MissingField;
    const heading_text = try common.innerTextTrimmedOwned(allocator, heading);
    const parsed_name = splitTitleYear(heading_text);
    const poster = if (doc.queryOne("meta[property='og:image']")) |node|
        common.getAttributeValueSafe(node, "content") orelse ""
    else
        "";

    return .{
        .media_type = if (std.mem.indexOf(u8, body, "\"@type\":\"TVSeries\"") != null) .tv else .movie,
        .sd_id = std.fmt.parseInt(i64, path.subdl_id[2..], 10) catch 0,
        .slug = path.slug,
        .name = parsed_name.name,
        .second_name = parsed_name.name,
        .poster_url = poster,
        .year = parsed_name.year,
        .total_seasons = @intCast(season_count),
    };
}

const ParsedTitle = struct { name: []const u8, year: i64 };

fn splitTitleYear(value: []const u8) ParsedTitle {
    if (value.len >= 6 and value[value.len - 1] == ')') {
        const year_start = value.len - 6;
        if (value[year_start] == '(') {
            const year = std.fmt.parseInt(i64, value[year_start + 1 .. value.len - 1], 10) catch 0;
            if (year != 0) return .{ .name = std.mem.trimEnd(u8, value[0..year_start], " \t"), .year = year };
        }
    }
    return .{ .name = value, .year = 0 };
}

fn parseHtmlSeasons(allocator: Allocator, doc: *const html.Document, base_path: []const u8) ![]const SeasonInfo {
    var result: std.ArrayListUnmanaged(SeasonInfo) = .empty;
    var links = doc.query("a[href^='/subtitle/']");
    defer links.deinit();
    while (links.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (!std.mem.startsWith(u8, href, base_path) or href.len <= base_path.len or href[base_path.len] != '/') continue;
        const season_slug = href[base_path.len + 1 ..];
        if (season_slug.len == 0 or std.mem.indexOfScalar(u8, season_slug, '/') != null) continue;
        if (containsSeason(result.items, season_slug)) continue;
        const heading = anchor.queryOne("h3") orelse continue;
        const name = try common.innerTextTrimmedOwned(allocator, heading);
        if (name.len == 0) continue;
        try result.append(allocator, .{ .number = season_slug, .name = name, .poster = "" });
    }
    return result.toOwnedSlice(allocator);
}

fn containsSeason(seasons: []const SeasonInfo, slug: []const u8) bool {
    for (seasons) |season| if (std.mem.eql(u8, season.number, slug)) return true;
    return false;
}

fn parseHtmlLanguages(
    allocator: Allocator,
    doc: *const html.Document,
    include_empty: bool,
) ![]const LanguageSubtitles {
    var result: std.ArrayListUnmanaged(LanguageSubtitles) = .empty;
    var groups = doc.query("div[data-language]");
    defer groups.deinit();
    while (groups.next()) |group| {
        const language = common.getAttributeValueSafe(group, "data-language-name") orelse
            common.getAttributeValueSafe(group, "data-language") orelse continue;
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var rows = group.query("li[data-row]");
        defer rows.deinit();
        while (rows.next()) |row| {
            const title_node = row.queryOne("h4") orelse continue;
            const title = try common.innerTextTrimmedOwned(allocator, title_node);
            if (title.len == 0) continue;
            const detail_anchor = row.queryOne("a[href^='/s/info/']");
            const detail_path = if (detail_anchor) |node| common.getAttributeValueSafe(node, "href") orelse "" else "";
            const download_anchor = row.queryOne("a[href*='dl.subdl.com/subtitle/']");
            const download_url = if (download_anchor) |node| common.getAttributeValueSafe(node, "href") orelse "" else "";
            const author_anchor = row.queryOne("a[href^='/u/']");
            const author = if (author_anchor) |node| try common.innerTextTrimmedOwned(allocator, node) else "";
            const download_prefix = "https://dl.subdl.com/subtitle/";
            const link = if (std.mem.startsWith(u8, download_url, download_prefix)) download_url[download_prefix.len..] else download_url;
            const releases = try allocator.alloc([]const u8, 1);
            releases[0] = title;
            try subtitles.append(allocator, .{
                .id = common.parseAttrInt(row, "data-id", i64) orelse 0,
                .language = language,
                .quality = findAncestorAttribute(row, "data-quality") orelse "",
                .link = link,
                .bucket_link = download_url,
                .author = author,
                .season = common.parseAttrInt(row, "data-season", i64) orelse 0,
                .episode = common.parseAttrInt(row, "data-episode-from", i64) orelse 0,
                .title = title,
                .extra = if (detail_path.len == 0) "" else try std.fmt.allocPrint(allocator, "{s}{s}", .{ site, detail_path }),
                .enabled = download_url.len != 0,
                .n_id = downloadId(download_url),
                .downloads = 0,
                .hearing_impaired = try hasUseHref(allocator, row, "#sub-i-hi"),
                .releases = releases,
                .rate = null,
                .date_ms = common.parseAttrInt(row, "data-date", i64) orelse 0,
                .comment = "",
                .slug = detailSlug(detail_path),
            });
        }
        if (subtitles.items.len == 0 and !include_empty) continue;
        try result.append(allocator, .{ .language = language, .subtitles = try subtitles.toOwnedSlice(allocator) });
    }
    return result.toOwnedSlice(allocator);
}

fn hasUseHref(allocator: Allocator, node: html.Node, wanted: []const u8) !bool {
    var uses = node.query("use");
    defer uses.deinit();
    while (uses.next()) |use| {
        if (common.getAttributeValueSafe(use, "href")) |href| {
            if (std.mem.eql(u8, href, wanted)) return true;
        }
    }
    // SVG foreign-content nodes are intentionally absent from some selector
    // indexes, but remain available in the lossless subtree serialization.
    var output: std.Io.Writer.Allocating = .init(allocator);
    try node.writeHtml(&output.writer);
    return std.mem.indexOf(u8, output.written(), wanted) != null;
}

fn findAncestorAttribute(node: html.Node, attribute: []const u8) ?[]const u8 {
    var current = node.parentNode();
    while (current) |ancestor| : (current = ancestor.parentNode()) {
        if (common.getAttributeValueSafe(ancestor, attribute)) |value| return value;
    }
    return null;
}

fn downloadId(url: []const u8) []const u8 {
    const prefix = "https://dl.subdl.com/subtitle/";
    const tail = if (std.mem.startsWith(u8, url, prefix)) url[prefix.len..] else url;
    const dash = std.mem.lastIndexOfScalar(u8, tail, '-') orelse return "";
    const extension = std.mem.lastIndexOfScalar(u8, tail, '.') orelse tail.len;
    return if (dash + 1 < extension) tail[dash + 1 .. extension] else "";
}

fn detailSlug(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "/s/info/")) return null;
    const token = path["/s/info/".len..];
    const slash = std.mem.indexOfScalar(u8, token, '/') orelse return token;
    return token[0..slash];
}

fn getRequiredField(obj: std.json.ObjectMap, field: []const u8) !std.json.Value {
    return obj.get(field) orelse error.MissingField;
}

fn getRequiredString(obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = try getRequiredField(obj, field);
    return asString(value);
}

fn getStringOrDefault(obj: std.json.ObjectMap, field: []const u8, default: []const u8) ![]const u8 {
    const value = obj.get(field) orelse return default;
    return switch (value) {
        .null => default,
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn getRequiredInt(obj: std.json.ObjectMap, field: []const u8) !i64 {
    const value = try getRequiredField(obj, field);
    return asInt(value);
}

fn getIntOrDefault(obj: std.json.ObjectMap, field: []const u8, default: i64) !i64 {
    const value = obj.get(field) orelse return default;
    return switch (value) {
        .null => default,
        else => asInt(value),
    };
}

fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => error.InvalidFieldType,
    };
}

fn asArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |arr| arr,
        else => error.InvalidFieldType,
    };
}

fn asString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidFieldType,
    };
}

fn asInt(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        .number_string => |n| std.fmt.parseInt(i64, n, 10) catch error.InvalidFieldType,
        else => error.InvalidFieldType,
    };
}

test "parse subtitle link" {
    const parsed = try Scraper.parseSubtitleLink("https://subdl.com/subtitle/sd1300002/shadowhunters/first-season/english");
    try std.testing.expectEqualStrings("sd1300002", parsed.subdl_id);
    try std.testing.expectEqualStrings("shadowhunters", parsed.slug);
    try std.testing.expectEqualStrings("first-season", parsed.season_slug.?);
    try std.testing.expectEqualStrings("english", parsed.lang_slug.?);
}

fn expectNonEmptySubtitles(languages: []const LanguageSubtitles) !void {
    try std.testing.expect(languages.len > 0);

    var any_subtitles = false;
    for (languages) |lang| {
        if (lang.subtitles.len > 0) {
            any_subtitles = true;
            break;
        }
    }
    try std.testing.expect(any_subtitles);
}

fn findSeasonSlug(seasons: []const SeasonInfo, wanted: []const u8) ?[]const u8 {
    for (seasons) |season| {
        if (std.mem.eql(u8, season.number, wanted)) return season.number;
    }
    return null;
}

test "movie scraping works for The Thing" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "SUBDL_COM")) return error.SkipZigTest;
    if (suite.shouldRunExtensiveLiveSuite(std.testing.allocator)) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);

    var result = try scraper.fetchMovieByLink("https://subdl.com/subtitle/sd32997/the-thing");
    defer result.deinit();

    try std.testing.expectEqual(MediaType.movie, result.movie.media_type);
    try std.testing.expectEqualStrings("the-thing", result.movie.slug);
    try expectNonEmptySubtitles(result.languages);
}

test "tv scraping works for Shadowhunters seasons and season subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "SUBDL_COM")) return error.SkipZigTest;
    if (suite.shouldRunExtensiveLiveSuite(std.testing.allocator)) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);

    var seasons = try scraper.fetchTvSeasonsByLink("https://subdl.com/subtitle/sd1300002/shadowhunters");
    defer seasons.deinit();

    try std.testing.expectEqual(MediaType.tv, seasons.tv.media_type);
    try std.testing.expectEqualStrings("shadowhunters", seasons.tv.slug);
    try std.testing.expect(seasons.seasons.len > 0);

    const season_slug = findSeasonSlug(seasons.seasons, "first-season") orelse seasons.seasons[0].number;

    var season_data = try scraper.fetchTvSeasonByLink("https://subdl.com/subtitle/sd1300002/shadowhunters", season_slug);
    defer season_data.deinit();

    try std.testing.expectEqual(MediaType.tv, season_data.tv.media_type);
    try std.testing.expectEqualStrings(season_slug, season_data.season_slug);
    try expectNonEmptySubtitles(season_data.languages);
}

test "scraper options default and opt-in include-empty-subtitle-groups" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    const default_scraper = Scraper.init(std.testing.allocator, &client);
    try std.testing.expect(default_scraper.options.include_empty_subtitle_groups == false);

    const include_empty_scraper = Scraper.initWithOptions(std.testing.allocator, &client, .{
        .include_empty_subtitle_groups = true,
    });
    try std.testing.expect(include_empty_scraper.options.include_empty_subtitle_groups);
}

test "current html page parsing extracts title seasons and rich subtitle rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture =
        \\<html><head><meta property="og:image" content="https://poster.test/matrix.jpg"></head><body>
        \\<script type="application/ld+json">{"@type":"TVSeries"}</script><h1>The Matrix (1999)</h1>
        \\<a href="/subtitle/sd21581/the-matrix/first-season"><h3>Season 1</h3></a>
        \\<div data-language="english" data-language-name="English"><div data-quality-group data-quality="bluray"><ul>
        \\<li data-row data-id="560930" data-date="1589763900000" data-episode-from="2">
        \\<a href="/s/info/DHDOatxKmT/the-matrix"><h4>The.Matrix.1999.2160p.BluRay</h4></a>
        \\<a href="/u/Kosire">Kosire</a><svg><use href="#sub-i-hi"></use></svg>
        \\<a href="https://dl.subdl.com/subtitle/560930-2216904.zip">Download</a></li>
        \\</ul></div></div></body></html>
    ;
    var page = try common.parseHtmlStable(a, fixture);
    defer page.deinit();
    const parsed_path = try Scraper.parseSubtitleLink("/subtitle/sd21581/the-matrix");
    const seasons = try parseHtmlSeasons(a, &page.doc, "/subtitle/sd21581/the-matrix");
    const title = try parseHtmlTitleInfo(a, &page.doc, fixture, parsed_path, seasons.len);
    const languages = try parseHtmlLanguages(a, &page.doc, false);

    try std.testing.expectEqual(MediaType.tv, title.media_type);
    try std.testing.expectEqualStrings("The Matrix", title.name);
    try std.testing.expectEqual(@as(i64, 1999), title.year);
    try std.testing.expectEqualStrings("first-season", seasons[0].number);
    try std.testing.expectEqualStrings("English", languages[0].language);
    const subtitle = languages[0].subtitles[0];
    try std.testing.expectEqualStrings("bluray", subtitle.quality);
    try std.testing.expectEqualStrings("Kosire", subtitle.author);
    try std.testing.expect(subtitle.hearing_impaired);
    try std.testing.expectEqualStrings("560930-2216904.zip", subtitle.link);
    try std.testing.expectEqualStrings("2216904", subtitle.n_id);
}

test "resolve project search language code accepts names and codes" {
    try std.testing.expectEqualStrings("en", resolveProjectSearchLanguageCode("English").?);
    try std.testing.expectEqualStrings("fa", resolveProjectSearchLanguageCode("fa").?);
    try std.testing.expectEqualStrings("pt", resolveProjectSearchLanguageCode("Brazillian Portuguese").?);
    try std.testing.expectEqualStrings("uk", resolveProjectSearchLanguageCode("uk").?);
    try std.testing.expect(resolveProjectSearchLanguageCode("klingon") == null);
}

test "encode path segment escapes reserved characters" {
    const encoded = try encodePathSegment(std.testing.allocator, "the thing?/v2");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("the%20thing%3F%2Fv2", encoded);
}
