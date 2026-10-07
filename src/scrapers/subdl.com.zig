const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;

const user_agent = "scrape-subdl.com/0.1 (+https://subdl.com)";
const api_base = "https://api3.subdl.com";
const site = "https://subdl.com";
const download_site = "https://dl.subdl.com";

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
    language_code: []const u8,
};

pub const SearchLanguage = struct {
    name: []const u8,
    code: []const u8,
};

pub const project_search_languages = [_]SearchLanguage{
    .{ .name = "Arabic", .code = "ar" },
    .{ .name = "Brazillian Portuguese", .code = "pt-br" },
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
        const with_prefix = if (std.mem.startsWith(u8, link, marker))
            link[marker.len..]
        else blk: {
            const scheme_end = std.mem.indexOf(u8, link, "://") orelse
                return error.InvalidSubtitleLink;
            const path_start = std.mem.indexOfScalarPos(
                u8,
                link,
                scheme_end + "://".len,
                '/',
            ) orelse return error.InvalidSubtitleLink;
            if (!std.mem.startsWith(u8, link[path_start..], marker))
                return error.InvalidSubtitleLink;
            break :blk link[path_start + marker.len ..];
        };
        if (std.mem.indexOfAny(u8, with_prefix, "?#") != null)
            return error.InvalidSubtitleLink;

        var it = std.mem.splitScalar(u8, with_prefix, '/');
        const subdl_id = it.next() orelse return error.InvalidSubtitleLink;
        const slug = it.next() orelse return error.InvalidSubtitleLink;
        const season_slug = it.next();
        const lang_slug = it.next();
        if (it.next() != null) return error.InvalidSubtitleLink;

        try validateEncodedSubtitleSegment(subdl_id, .id);
        try validateEncodedSubtitleSegment(slug, .generic);
        if (season_slug) |segment| try validateEncodedSubtitleSegment(segment, .generic);
        if (lang_slug) |segment| try validateEncodedSubtitleSegment(segment, .generic);

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

        const language_code = resolveProjectSearchLanguageCode(language) orelse
            return error.UnsupportedSearchLanguage;
        const trimmed_query = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed_query.len == 0) {
            return common.finishResponse(SearchResponse, &arena, .{
                .arena = arena,
                .items = &.{},
            });
        }
        const encoded_query = try common.encodeUriComponent(a, trimmed_query);
        const url = try std.fmt.allocPrint(a, "{s}/search?query={s}", .{ api_base, encoded_query });
        const body = try self.fetchBytes(a, url, "application/json");
        const json_root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const root_object = try asObject(json_root);
        const result_array = try asArray(try getRequiredField(root_object, "results"));

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (result_array.items) |entry| {
            const item = try parseSearchResultEntry(a, entry, language_code);
            if (item) |value| try items.append(a, value);
        }

        return common.finishResponse(SearchResponse, &arena, .{
            .arena = arena,
            .items = try items.toOwnedSlice(a),
        });
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

        var page = try self.fetchSubtitlePage(link, resolved_season_slug);
        errdefer page.arena.deinit();

        if (page.title.media_type != .tv) return error.UnexpectedTitleType;
        const owned_slug = try page.arena.allocator().dupe(u8, resolved_season_slug);

        return .{
            .arena = page.arena,
            .tv = page.title,
            .season_slug = owned_slug,
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
        const language_code = resolveProjectSearchLanguageCode(self.options.search_language) orelse
            return error.UnsupportedSearchLanguage;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const normalized_link = try resolveProviderLink(a, link);
        const parsed = try parseSubtitleLink(normalized_link);

        const path = try buildSubtitlePath(a, parsed, season_slug);
        const canonical_parsed = try parseSubtitleLink(path);
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ site, path });
        const body = try self.fetchBytes(a, url, "text/html");
        var html_page = try common.parseHtmlStable(a, body);

        const seasons = try parseHtmlSeasons(a, &html_page.doc, path);
        const movie_info = try parseHtmlTitleInfo(a, &html_page.doc, body, canonical_parsed, seasons.len);
        const languages = try parseHtmlLanguages(
            a,
            &html_page.doc,
            self.options.include_empty_subtitle_groups,
            language_code,
        );

        return .{
            .arena = arena,
            .title = movie_info,
            .seasons = seasons,
            .languages = languages,
        };
    }

    fn fetchBytes(self: *Scraper, allocator: Allocator, url: []const u8, accept: []const u8) ![]u8 {
        try validateFetchEndpoint(url);
        const headers = [_]std.http.Header{
            .{ .name = "accept", .value = accept },
            .{ .name = "user-agent", .value = user_agent },
        };

        const response = try common.fetchBytes(self.client, allocator, url, .{
            .accept = accept,
            .extra_headers = &headers,
            .max_attempts = 3,
            .retry_initial_backoff_ms = 400,
            .require_public_origin = true,
            .require_https = true,
        });
        if (response.status != .ok) {
            allocator.free(response.body);
            return error.UnexpectedHttpStatus;
        }
        return response.body;
    }
};

const SubtitleSegmentKind = enum { id, generic };

fn validateEncodedSubtitleSegment(value: []const u8, kind: SubtitleSegmentKind) Error!void {
    if (value.len == 0) return error.InvalidSubtitleLink;
    var index: usize = 0;
    var decoded_len: usize = 0;
    var first_two: [2]u8 = undefined;
    while (index < value.len) {
        const byte = if (value[index] == '%') blk: {
            if (value.len - index < 3) return error.InvalidSubtitleLink;
            const high = std.fmt.charToDigit(value[index + 1], 16) catch
                return error.InvalidSubtitleLink;
            const low = std.fmt.charToDigit(value[index + 2], 16) catch
                return error.InvalidSubtitleLink;
            index += 3;
            break :blk @as(u8, @intCast(high * 16 + low));
        } else blk: {
            const raw = value[index];
            index += 1;
            break :blk raw;
        };

        if (byte < 0x20 or byte == 0x7f or
            byte == '/' or byte == '\\' or byte == '?' or byte == '#')
        {
            return error.InvalidSubtitleLink;
        }
        if (decoded_len < first_two.len) first_two[decoded_len] = byte;
        if (kind == .id) {
            if (decoded_len == 0 and byte != 's') return error.InvalidSubtitleLink;
            if (decoded_len == 1 and byte != 'd') return error.InvalidSubtitleLink;
            if (decoded_len >= 2 and !std.ascii.isDigit(byte))
                return error.InvalidSubtitleLink;
        }
        decoded_len += 1;
    }
    if (kind == .id and decoded_len < 3) return error.InvalidSubtitleLink;
    if (kind == .generic and
        ((decoded_len == 1 and first_two[0] == '.') or
            (decoded_len == 2 and first_two[0] == '.' and first_two[1] == '.')))
    {
        return error.InvalidSubtitleLink;
    }
}

fn parseSearchResultEntry(
    allocator: Allocator,
    entry: std.json.Value,
    language_code: []const u8,
) !?SearchItem {
    const entry_obj = asObject(entry) catch return null;
    const media_type_text = getRequiredString(entry_obj, "type") catch return null;
    const media_type = MediaType.fromString(media_type_text) orelse return null;
    const name = getRequiredString(entry_obj, "name") catch return null;
    const href = getRequiredString(entry_obj, "link") catch return null;
    const year = getRequiredInt(entry_obj, "year") catch return null;
    const poster_url = getStringOrDefault(entry_obj, "poster_url", "") catch return null;
    const original_name = getStringOrDefault(entry_obj, "original_name", name) catch return null;
    const subtitles_count = getIntOrDefault(entry_obj, "subtitles_count", 0) catch return null;
    const link = resolveProviderLink(allocator, href) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    _ = Scraper.parseSubtitleLink(link) catch return null;

    return .{
        .media_type = media_type,
        .name = name,
        .poster_url = poster_url,
        .year = year,
        .link = link,
        .original_name = original_name,
        .subtitles_count = subtitles_count,
        .language_code = language_code,
    };
}

fn resolveProviderLink(allocator: Allocator, href: []const u8) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderEndpoint(resolved);
    return resolved;
}

fn validateProviderEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;
}

fn validateFetchEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (try common.sameOrigin(site, url)) return;
    if (try common.sameOrigin(api_base, url)) return;
    return error.UnsafeHttpTarget;
}

fn validateDownloadEndpoint(url: []const u8) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(download_site, url))) return error.UnsafeHttpTarget;
    const prefix = download_site ++ "/subtitle/";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidSubtitleLink;
    const filename = url[prefix.len..];
    if (filename.len == 0 or std.mem.indexOfAny(u8, filename, "/?#") != null)
        return error.InvalidSubtitleLink;
    try validateEncodedSubtitleSegment(filename, .generic);
}

pub fn resolveProjectSearchLanguageCode(language_or_code: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, language_or_code, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "Brazilian Portuguese")) return "pt-br";
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

    const is_dot_segment = std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..");

    for (value) |byte| {
        const is_unreserved = (byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '_' or (byte == '.' and !is_dot_segment) or byte == '~';
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

fn decodePathSegment(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < value.len) {
        if (value[index] != '%') {
            try out.append(allocator, value[index]);
            index += 1;
            continue;
        }
        if (value.len - index < 3) return error.InvalidSubtitleLink;
        const high = std.fmt.charToDigit(value[index + 1], 16) catch return error.InvalidSubtitleLink;
        const low = std.fmt.charToDigit(value[index + 2], 16) catch return error.InvalidSubtitleLink;
        try out.append(allocator, @intCast(high * 16 + low));
        index += 3;
    }

    return try out.toOwnedSlice(allocator);
}

fn canonicalizeSubtitleSegment(
    allocator: Allocator,
    value: []const u8,
    kind: SubtitleSegmentKind,
) ![]u8 {
    try validateEncodedSubtitleSegment(value, kind);
    const decoded = try decodePathSegment(allocator, value);
    defer allocator.free(decoded);
    return encodePathSegment(allocator, decoded);
}

fn buildSubtitlePath(allocator: Allocator, parsed: SubtitlePath, season_slug: ?[]const u8) ![]u8 {
    const encoded_id = try canonicalizeSubtitleSegment(allocator, parsed.subdl_id, .id);
    defer allocator.free(encoded_id);
    const encoded_slug = try canonicalizeSubtitleSegment(allocator, parsed.slug, .generic);
    defer allocator.free(encoded_slug);

    if (season_slug) |season| {
        if (season.len == 0) return error.MissingSeasonSlug;
        const encoded_season = try canonicalizeSubtitleSegment(allocator, season, .generic);
        defer allocator.free(encoded_season);
        return std.fmt.allocPrint(
            allocator,
            "/subtitle/{s}/{s}/{s}",
            .{ encoded_id, encoded_slug, encoded_season },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "/subtitle/{s}/{s}",
        .{ encoded_id, encoded_slug },
    );
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
        .slug = try allocator.dupe(u8, path.slug),
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
    const base = Scraper.parseSubtitleLink(base_path) catch return error.InvalidSubtitleLink;
    var result: std.ArrayListUnmanaged(SeasonInfo) = .empty;
    var links = doc.query("a[href^='/subtitle/']");
    defer links.deinit();
    while (links.next()) |anchor| {
        const href = common.getAttributeValueSafe(anchor, "href") orelse continue;
        const candidate = Scraper.parseSubtitleLink(href) catch continue;
        if (base.season_slug != null or candidate.season_slug == null or
            candidate.lang_slug != null or
            !std.mem.eql(u8, candidate.subdl_id, base.subdl_id) or
            !std.mem.eql(u8, candidate.slug, base.slug))
        {
            continue;
        }
        const raw_season_slug = candidate.season_slug.?;
        // Reject malformed and duplicate rows before allocating either field.
        // Providers sometimes spell an unreserved byte as `%XX`, so compare
        // decoded segment bytes rather than only the raw representation.
        try validateEncodedSubtitleSegment(raw_season_slug, .generic);
        if (try containsSeasonEncoded(result.items, raw_season_slug)) continue;
        const heading = anchor.queryOne("h3") orelse continue;
        const name = try common.innerTextTrimmedOwned(allocator, heading);
        if (name.len == 0) continue;
        const season_slug = try canonicalizeSubtitleSegment(
            allocator,
            raw_season_slug,
            .generic,
        );
        try result.append(allocator, .{ .number = season_slug, .name = name, .poster = "" });
    }
    return result.toOwnedSlice(allocator);
}

fn containsSeasonEncoded(seasons: []const SeasonInfo, encoded_slug: []const u8) Error!bool {
    for (seasons) |season| {
        if (try encodedSubtitleSegmentsEqual(season.number, encoded_slug)) return true;
    }
    return false;
}

fn encodedSubtitleSegmentsEqual(left: []const u8, right: []const u8) Error!bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (true) {
        const left_byte = try nextDecodedSubtitleSegmentByte(left, &left_index);
        const right_byte = try nextDecodedSubtitleSegmentByte(right, &right_index);
        if (left_byte == null or right_byte == null) return left_byte == right_byte;
        if (left_byte.? != right_byte.?) return false;
    }
}

fn nextDecodedSubtitleSegmentByte(value: []const u8, index: *usize) Error!?u8 {
    if (index.* == value.len) return null;
    if (index.* > value.len) return error.InvalidSubtitleLink;
    if (value[index.*] != '%') {
        const byte = value[index.*];
        index.* += 1;
        return byte;
    }
    if (value.len - index.* < 3) return error.InvalidSubtitleLink;
    const high = std.fmt.charToDigit(value[index.* + 1], 16) catch
        return error.InvalidSubtitleLink;
    const low = std.fmt.charToDigit(value[index.* + 2], 16) catch
        return error.InvalidSubtitleLink;
    index.* += 3;
    return @as(u8, @intCast(high * 16 + low));
}

fn parseHtmlLanguages(
    allocator: Allocator,
    doc: *const html.Document,
    include_empty: bool,
    selected_language_code: []const u8,
) ![]const LanguageSubtitles {
    var result: std.ArrayListUnmanaged(LanguageSubtitles) = .empty;
    var groups = doc.query("div[data-language]");
    defer groups.deinit();
    while (groups.next()) |group| {
        const language_slug = common.getAttributeValueSafe(group, "data-language") orelse continue;
        const language = common.getAttributeValueSafe(group, "data-language-name") orelse
            language_slug;
        if (!languageGroupMatches(language, language_slug, selected_language_code)) continue;
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var rows = group.query("li[data-row]");
        defer rows.deinit();
        while (rows.next()) |row| {
            const subtitle = parseHtmlSubtitleRow(allocator, row, language) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
            if (subtitle) |item| try subtitles.append(allocator, item);
        }
        if (subtitles.items.len == 0 and !include_empty) continue;
        try result.append(allocator, .{ .language = language, .subtitles = try subtitles.toOwnedSlice(allocator) });
    }
    return result.toOwnedSlice(allocator);
}

fn languageGroupMatches(name: []const u8, slug: []const u8, selected_code: []const u8) bool {
    for ([_][]const u8{ name, slug }) |value| {
        const code = resolveProjectSearchLanguageCode(value) orelse continue;
        if (std.ascii.eqlIgnoreCase(code, selected_code)) return true;
    }
    return false;
}

fn parseHtmlSubtitleRow(
    allocator: Allocator,
    row: html.Node,
    language: []const u8,
) !?SubtitleItem {
    const title_node = row.queryOne("h4") orelse return null;
    const title = try common.innerTextTrimmedOwned(allocator, title_node);
    if (title.len == 0) return null;
    const detail = try firstValidDetailLink(allocator, row);
    const detail_path = if (detail) |candidate| candidate.path else "";
    const extra = if (detail) |candidate| candidate.url else "";
    const download_url = try firstValidDownloadLink(row);
    const author_anchor = row.queryOne("a[href^='/u/']");
    const author = if (author_anchor) |node|
        try common.innerTextTrimmedOwned(allocator, node)
    else
        "";
    const download_prefix = "https://dl.subdl.com/subtitle/";
    const link = if (std.mem.startsWith(u8, download_url, download_prefix))
        download_url[download_prefix.len..]
    else
        download_url;
    const releases = try allocator.alloc([]const u8, 1);
    releases[0] = title;
    return .{
        .id = common.parseAttrInt(row, "data-id", i64) orelse 0,
        .language = language,
        .quality = findAncestorAttribute(row, "data-quality") orelse "",
        .link = link,
        .bucket_link = download_url,
        .author = author,
        .season = common.parseAttrInt(row, "data-season", i64) orelse 0,
        .episode = common.parseAttrInt(row, "data-episode-from", i64) orelse 0,
        .title = title,
        .extra = extra,
        .enabled = download_url.len != 0,
        .n_id = downloadId(download_url),
        .downloads = 0,
        .hearing_impaired = try hasUseHref(allocator, row, "#sub-i-hi"),
        .releases = releases,
        .rate = null,
        .date_ms = common.parseAttrInt(row, "data-date", i64) orelse 0,
        .comment = "",
        .slug = detailSlug(detail_path),
    };
}

const DetailLink = struct {
    path: []const u8,
    url: []const u8,
};

fn firstValidDetailLink(allocator: Allocator, row: html.Node) !?DetailLink {
    var anchors = row.query("a[href^='/s/info/']");
    defer anchors.deinit();
    var saw_candidate = false;
    while (anchors.next()) |anchor| {
        saw_candidate = true;
        const path = common.getAttributeValueSafe(anchor, "href") orelse continue;
        if (detailSlug(path) == null) continue;
        const url = resolveProviderLink(allocator, path) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        return .{ .path = path, .url = url };
    }
    if (saw_candidate) return error.InvalidSubtitleLink;
    return null;
}

fn firstValidDownloadLink(row: html.Node) ![]const u8 {
    var anchors = row.query("a[href*='dl.subdl.com/subtitle/']");
    defer anchors.deinit();
    var saw_candidate = false;
    while (anchors.next()) |anchor| {
        saw_candidate = true;
        const url = common.getAttributeValueSafe(anchor, "href") orelse continue;
        validateDownloadEndpoint(url) catch continue;
        return url;
    }
    if (saw_candidate) return error.InvalidSubtitleLink;
    return "";
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
    defer output.deinit();
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
    const tail = path["/s/info/".len..];
    const slash = std.mem.indexOfScalar(u8, tail, '/');
    const token = if (slash) |index| tail[0..index] else tail;
    validateEncodedSubtitleSegment(token, .generic) catch return null;
    if (slash) |index| {
        const title_slug = tail[index + 1 ..];
        if (std.mem.indexOfScalar(u8, title_slug, '/') != null) return null;
        validateEncodedSubtitleSegment(title_slug, .generic) catch return null;
    }
    return token;
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
        .float => |f| common.jsonInt(.{ .float = f }) orelse error.InvalidFieldType,
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

test "subdl subtitle routes require exact canonical segments" {
    for ([_][]const u8{
        "/subtitle/sd/the-matrix",
        "/subtitle/sdabc/the-matrix",
        "/subtitle/SD21581/the-matrix",
        "/subtitle/sd21581",
        "/subtitle/sd21581/the-matrix/",
        "/subtitle/sd21581//first-season",
        "/subtitle/sd21581/the-matrix/first-season/english/extra",
        "/subtitle/sd21581/the-matrix?lang=en",
        "/subtitle/sd21581/the-matrix#english",
        "/foo/subtitle/sd21581/the-matrix",
        "/subtitle/sd21581/%2e%2e",
        "/subtitle/sd21581/the%2fmatrix",
        "/subtitle/sd21581/the%5cmatrix",
        "/subtitle/sd21581/the%3fmatrix",
        "/subtitle/sd21581/the%23matrix",
        "/subtitle/sd21581/the%2",
    }) |invalid| {
        try std.testing.expectError(
            error.InvalidSubtitleLink,
            Scraper.parseSubtitleLink(invalid),
        );
    }

    const encoded = try Scraper.parseSubtitleLink(
        "/subtitle/%73%641300002/shadow%20hunters/first%20season",
    );
    const canonical = try buildSubtitlePath(
        std.testing.allocator,
        encoded,
        encoded.season_slug,
    );
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "/subtitle/sd1300002/shadow%20hunters/first%20season",
        canonical,
    );
}

test "subdl rejects unsafe provider, API, and download endpoints" {
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderLink(std.testing.allocator, "http://127.0.0.1/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderLink(std.testing.allocator, "https://user:pass@subdl.com/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderLink(std.testing.allocator, "https://subdl.com.evil.com/private"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateFetchEndpoint("https://api3.subdl.com.evil.com/search"));
    try std.testing.expectError(error.UnsafeHttpTarget, validateDownloadEndpoint("https://dl.subdl.com.evil.com/subtitle/1.zip"));
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

    var invalid_language_scraper = Scraper.initWithOptions(std.testing.allocator, &client, .{
        .search_language = "klingon",
    });
    try std.testing.expectError(
        error.UnsupportedSearchLanguage,
        invalid_language_scraper.fetchMovieByLink("https://fixture.invalid"),
    );
}

test "subdl whitespace search returns before network" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var response = try scraper.searchWithLanguage(" \t\r\n", "en");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
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
        \\<li data-row data-id="1"><a href="/s/info/bad/row"><h4>Malformed sibling</h4></a>
        \\<a href="https://evil.test/?next=dl.subdl.com/subtitle/bad.zip">Download</a></li>
        \\<li data-row data-id="560930" data-date="1589763900000" data-episode-from="2">
        \\<a href="/s/info/?next=shadow">bad detail</a>
        \\<a href="/s/info/DHDOatxKmT/the-matrix"><h4>The.Matrix.1999.2160p.BluRay</h4></a>
        \\<a href="/u/Kosire">Kosire</a><svg><use href="#sub-i-hi"></use></svg>
        \\<a href="https://evil.test/?next=dl.subdl.com/subtitle/shadow.zip">bad download</a>
        \\<a href="https://dl.subdl.com/subtitle/560930-2216904.zip">Download</a></li>
        \\</ul></div></div></body></html>
    ;
    var page = try common.parseHtmlStable(a, fixture);
    defer page.deinit();
    const parsed_path = try Scraper.parseSubtitleLink("/subtitle/sd21581/the-matrix");
    const seasons = try parseHtmlSeasons(a, &page.doc, "/subtitle/sd21581/the-matrix");
    const title = try parseHtmlTitleInfo(a, &page.doc, fixture, parsed_path, seasons.len);
    const languages = try parseHtmlLanguages(a, &page.doc, false, "en");

    try std.testing.expectEqual(MediaType.tv, title.media_type);
    try std.testing.expectEqualStrings("The Matrix", title.name);
    try std.testing.expectEqual(@as(i64, 1999), title.year);
    try std.testing.expectEqualStrings("first-season", seasons[0].number);
    try std.testing.expectEqualStrings("English", languages[0].language);
    try std.testing.expectEqual(@as(usize, 1), languages[0].subtitles.len);
    const subtitle = languages[0].subtitles[0];
    try std.testing.expectEqualStrings("bluray", subtitle.quality);
    try std.testing.expectEqualStrings("Kosire", subtitle.author);
    try std.testing.expect(subtitle.hearing_impaired);
    try std.testing.expectEqualStrings("560930-2216904.zip", subtitle.link);
    try std.testing.expectEqualStrings("2216904", subtitle.n_id);
    try std.testing.expectEqualStrings("https://subdl.com/s/info/DHDOatxKmT/the-matrix", subtitle.extra);
}

test "subdl subtitle parsing keeps only the selected search language" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture =
        \\<div data-language="english" data-language-name="English"><ul>
        \\<li data-row data-id="1"><h4>English release</h4><a href="https://dl.subdl.com/subtitle/english-1.zip">Download</a></li>
        \\</ul></div>
        \\<div data-language="french" data-language-name="French"><ul>
        \\<li data-row data-id="2"><h4>French release</h4><a href="https://dl.subdl.com/subtitle/french-2.zip">Download</a></li>
        \\</ul></div>
    ;
    var page = try common.parseHtmlStable(arena.allocator(), fixture);
    defer page.deinit();

    const english = try parseHtmlLanguages(arena.allocator(), &page.doc, false, "en");
    try std.testing.expectEqual(@as(usize, 1), english.len);
    try std.testing.expectEqualStrings("English", english[0].language);
    try std.testing.expectEqual(@as(usize, 1), english[0].subtitles.len);
    try std.testing.expectEqualStrings("English release", english[0].subtitles[0].title);

    const french = try parseHtmlLanguages(arena.allocator(), &page.doc, false, "fr");
    try std.testing.expectEqual(@as(usize, 1), french.len);
    try std.testing.expectEqualStrings("French", french[0].language);
    try std.testing.expectEqual(@as(usize, 1), french[0].subtitles.len);
    try std.testing.expectEqualStrings("French release", french[0].subtitles[0].title);
}

test "subdl title slug survives changes to the caller link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = "<html><body><h1>The Matrix (1999)</h1></body></html>";
    var page = try common.parseHtmlStable(a, fixture);
    defer page.deinit();
    var caller_link = "/subtitle/sd21581/the-matrix".*;
    const path = try Scraper.parseSubtitleLink(&caller_link);
    const title = try parseHtmlTitleInfo(a, &page.doc, fixture, path, 0);
    @memset(&caller_link, 'x');
    try std.testing.expectEqualStrings("the-matrix", title.slug);
}

test "resolve project search language code accepts names and codes" {
    try std.testing.expectEqualStrings("en", resolveProjectSearchLanguageCode("English").?);
    try std.testing.expectEqualStrings("fa", resolveProjectSearchLanguageCode("fa").?);
    try std.testing.expectEqualStrings("pt-br", resolveProjectSearchLanguageCode("Brazillian Portuguese").?);
    try std.testing.expectEqualStrings("pt-br", resolveProjectSearchLanguageCode("Brazilian Portuguese").?);
    try std.testing.expectEqualStrings("pt-br", resolveProjectSearchLanguageCode("pt-BR").?);
    try std.testing.expectEqualStrings("pt", resolveProjectSearchLanguageCode("Portuguese").?);
    try std.testing.expectEqualStrings("zh-tw", resolveProjectSearchLanguageCode("Big 5 code").?);
    try std.testing.expectEqualStrings("zh-tw", resolveProjectSearchLanguageCode("zh_TW").?);
    try std.testing.expect(languageGroupMatches("Brazillian Portuguese", "pt", "pt-br"));
    try std.testing.expect(!languageGroupMatches("Portuguese", "pt", "pt-br"));
    try std.testing.expectEqualStrings("uk", resolveProjectSearchLanguageCode("uk").?);
    try std.testing.expect(resolveProjectSearchLanguageCode("klingon") == null);
}

test "encode path segment escapes reserved characters" {
    const encoded = try encodePathSegment(std.testing.allocator, "the thing?/v2");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("the%20thing%3F%2Fv2", encoded);
}

test "subdl season slug is encoded as one path segment" {
    const allocator = std.testing.allocator;
    const parsed = try Scraper.parseSubtitleLink("https://subdl.com/subtitle/sd1300002/shadowhunters");
    const path = try buildSubtitlePath(allocator, parsed, "first season & other");
    defer allocator.free(path);
    try std.testing.expectEqualStrings(
        "/subtitle/sd1300002/shadowhunters/first%20season%20%26%20other",
        path,
    );
    try std.testing.expectError(
        error.InvalidSubtitleLink,
        buildSubtitlePath(allocator, parsed, "first%3fseason"),
    );
    try std.testing.expectError(
        error.InvalidSubtitleLink,
        buildSubtitlePath(allocator, parsed, "first/season"),
    );
}

test "subdl encoded season slug is canonicalized without double encoding" {
    const allocator = std.testing.allocator;
    const parsed = try Scraper.parseSubtitleLink("https://subdl.com/subtitle/sd1300002/shadowhunters/first%20season");
    const path = try buildSubtitlePath(allocator, parsed, parsed.season_slug);
    defer allocator.free(path);
    try std.testing.expectEqualStrings(
        "/subtitle/sd1300002/shadowhunters/first%20season",
        path,
    );
    try std.testing.expectError(error.MissingSeasonSlug, buildSubtitlePath(allocator, parsed, ""));
    try std.testing.expectError(error.InvalidSubtitleLink, buildSubtitlePath(allocator, parsed, "first%2"));
}

test "subdl raw and encoded dot season slugs are rejected" {
    const allocator = std.testing.allocator;
    const parsed = try Scraper.parseSubtitleLink("https://subdl.com/subtitle/sd1300002/shadowhunters");
    try std.testing.expectError(error.InvalidSubtitleLink, buildSubtitlePath(allocator, parsed, "."));
    try std.testing.expectError(error.InvalidSubtitleLink, buildSubtitlePath(allocator, parsed, ".."));
    try std.testing.expectError(error.InvalidSubtitleLink, buildSubtitlePath(allocator, parsed, "%2e"));
    try std.testing.expectError(error.InvalidSubtitleLink, buildSubtitlePath(allocator, parsed, "%2e%2e"));
}

test "subdl season duplicate comparison is allocation-free and encoding agnostic" {
    try std.testing.expect(try encodedSubtitleSegmentsEqual("first-season", "%66irst-season"));
    try std.testing.expect(try encodedSubtitleSegmentsEqual("first%20season", "first%20season"));
    try std.testing.expect(!(try encodedSubtitleSegmentsEqual("first-season", "second-season")));
    try std.testing.expectError(
        error.InvalidSubtitleLink,
        encodedSubtitleSegmentsEqual("first-season", "first%2"),
    );
}

test "subdl search skips malformed siblings and preserves allocation failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"results\":[42,{\"type\":\"movie\",\"name\":\"bad\"},{\"type\":\"movie\",\"name\":\"bad\",\"year\":1999,\"link\":\"https://evil.test/subtitle/sd1/bad\"},{\"type\":\"movie\",\"name\":\"The Matrix\",\"year\":1999,\"link\":\"/subtitle/sd21581/the-matrix\"}]}",
        .{},
    );
    const object = switch (root) {
        .object => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const values = switch (object.get("results") orelse return error.TestUnexpectedResult) {
        .array => |value| value.items,
        else => return error.TestUnexpectedResult,
    };

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    for (values) |value| {
        const item = try parseSearchResultEntry(arena.allocator(), value, "fr");
        if (item) |valid| try items.append(arena.allocator(), valid);
    }
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("The Matrix", items.items[0].name);
    try std.testing.expectEqualStrings("fr", items.items[0].language_code);

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        parseSearchResultEntry(failing.allocator(), values[3], "fr"),
    );
}

test "subdl malformed HTML rows do not hide allocation failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var page = try common.parseHtmlStable(
        arena.allocator(),
        "<ul><li data-row><h4>Valid row</h4></li></ul>",
    );
    defer page.deinit();
    const row = page.doc.queryOne("li[data-row]") orelse
        return error.TestUnexpectedResult;

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        parseHtmlSubtitleRow(failing.allocator(), row, "English"),
    );
}
