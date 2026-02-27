const std = @import("std");
const common = @import("common.zig");
const suite = @import("test_suite.zig");

const Allocator = std.mem.Allocator;

const user_agent = "scrape-subdl.com/0.1 (+https://subdl.com)";
const build_id_source_url = "https://subdl.com/api-doc";

pub const Error = error{
    UnexpectedHttpStatus,
    BuildIdNotFound,
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

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SearchItem,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

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
    build_id: ?[]u8 = null,
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

    pub fn deinit(self: *Scraper) void {
        if (self.build_id) |build_id| {
            self.allocator.free(build_id);
            self.build_id = null;
        }
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

        const language_code = resolveProjectSearchLanguageCode(language) orelse return error.UnsupportedSearchLanguage;
        const build_id = try self.ensureBuildId();
        const encoded_query = try encodePathSegment(a, query);
        const url = try std.fmt.allocPrint(
            a,
            "https://subdl.com/_next/data/{s}/{s}/search/{s}.json",
            .{ build_id, language_code, encoded_query },
        );

        const body = self.fetchBytes(a, url, "application/json") catch |err| switch (err) {
            error.UnexpectedHttpStatus => blk: {
                self.clearBuildId();
                const refreshed_build_id = try self.ensureBuildId();
                const retry_url = try std.fmt.allocPrint(
                    a,
                    "https://subdl.com/_next/data/{s}/{s}/search/{s}.json",
                    .{ refreshed_build_id, language_code, encoded_query },
                );
                break :blk try self.fetchBytes(a, retry_url, "application/json");
            },
            else => return err,
        };
        const json_root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const root_object = try asObject(json_root);
        const page_props_val = try getRequiredField(root_object, "pageProps");
        const page_props = try asObject(page_props_val);
        const list_value = try getRequiredField(page_props, "list");
        const result_array = try asArray(list_value);

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (result_array.items) |entry| {
            const entry_obj = try asObject(entry);
            const media_type_text = try getRequiredString(entry_obj, "type");
            const media_type = MediaType.fromString(media_type_text) orelse continue;
            const sd_id = try getRequiredString(entry_obj, "sd_id");
            const slug = try getRequiredString(entry_obj, "slug");
            const link = try std.fmt.allocPrint(a, "/subtitle/{s}/{s}", .{ sd_id, slug });

            try items.append(a, .{
                .media_type = media_type,
                .name = try getRequiredString(entry_obj, "name"),
                .poster_url = try getRequiredString(entry_obj, "poster_url"),
                .year = try getRequiredInt(entry_obj, "year"),
                .link = link,
                .original_name = try getRequiredString(entry_obj, "original_name"),
                .subtitles_count = try getRequiredInt(entry_obj, "subtitles_count"),
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

        const build_id = try self.ensureBuildId();

        const url = try buildSubtitleDataUrl(
            a,
            build_id,
            parsed.subdl_id,
            parsed.slug,
            season_slug,
            null,
        );

        const body = self.fetchBytes(a, url, "application/json") catch |err| switch (err) {
            error.UnexpectedHttpStatus => blk: {
                self.clearBuildId();
                const refreshed_build_id = try self.ensureBuildId();
                const retry_url = try buildSubtitleDataUrl(
                    a,
                    refreshed_build_id,
                    parsed.subdl_id,
                    parsed.slug,
                    season_slug,
                    null,
                );
                break :blk try self.fetchBytes(a, retry_url, "application/json");
            },
            else => return err,
        };

        const json_root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const root_obj = try asObject(json_root);
        const page_props_val = try getRequiredField(root_obj, "pageProps");
        const page_props = try asObject(page_props_val);

        const movie_info = try parseTitleInfo(page_props);
        const seasons = try parseSeasons(page_props, a);
        const languages = try parseLanguages(page_props, a, self.options.include_empty_subtitle_groups);

        return .{
            .arena = arena,
            .title = movie_info,
            .seasons = seasons,
            .languages = languages,
        };
    }

    fn ensureBuildId(self: *Scraper) ![]const u8 {
        if (self.build_id) |build_id| return build_id;

        const build_id = try self.fetchBuildId();
        self.build_id = build_id;
        return build_id;
    }

    fn clearBuildId(self: *Scraper) void {
        if (self.build_id) |build_id| {
            self.allocator.free(build_id);
            self.build_id = null;
        }
    }

    fn fetchBuildId(self: *Scraper) ![]u8 {
        const body = try self.fetchBytes(self.allocator, build_id_source_url, "text/html");
        defer self.allocator.free(body);

        const marker = "\"buildId\":\"";
        const marker_start = std.mem.indexOf(u8, body, marker) orelse return error.BuildIdNotFound;

        const start = marker_start + marker.len;
        const tail = body[start..];
        const end_rel = std.mem.indexOfScalar(u8, tail, '"') orelse return error.BuildIdNotFound;

        return try self.allocator.dupe(u8, tail[0..end_rel]);
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

fn buildSubtitleDataUrl(
    allocator: Allocator,
    build_id: []const u8,
    subdl_id: []const u8,
    slug: []const u8,
    season_slug: ?[]const u8,
    lang_slug: ?[]const u8,
) ![]u8 {
    if (season_slug) |season| {
        if (lang_slug) |lang| {
            return std.fmt.allocPrint(
                allocator,
                "https://subdl.com/_next/data/{s}/subtitle/{s}/{s}/{s}/{s}.json",
                .{ build_id, subdl_id, slug, season, lang },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "https://subdl.com/_next/data/{s}/subtitle/{s}/{s}/{s}.json",
            .{ build_id, subdl_id, slug, season },
        );
    }

    if (lang_slug) |lang| {
        return std.fmt.allocPrint(
            allocator,
            "https://subdl.com/_next/data/{s}/subtitle/{s}/{s}/{s}.json",
            .{ build_id, subdl_id, slug, lang },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "https://subdl.com/_next/data/{s}/subtitle/{s}/{s}.json",
        .{ build_id, subdl_id, slug },
    );
}

fn parseTitleInfo(page_props: std.json.ObjectMap) !TitleInfo {
    const movie_info_val = try getRequiredField(page_props, "movieInfo");
    const movie_info = try asObject(movie_info_val);

    const media_type_str = try getRequiredString(movie_info, "type");
    const media_type = MediaType.fromString(media_type_str) orelse return error.UnexpectedTitleType;

    return .{
        .media_type = media_type,
        .sd_id = try getRequiredInt(movie_info, "sd_id"),
        .slug = try getRequiredString(movie_info, "slug"),
        .name = try getRequiredString(movie_info, "name"),
        .second_name = try getRequiredString(movie_info, "secondName"),
        .poster_url = try getRequiredString(movie_info, "poster_url"),
        .year = try getRequiredInt(movie_info, "year"),
        .total_seasons = try getRequiredInt(movie_info, "total_seasons"),
    };
}

fn parseSeasons(page_props: std.json.ObjectMap, allocator: Allocator) ![]const SeasonInfo {
    const movie_info_val = try getRequiredField(page_props, "movieInfo");
    const movie_info = try asObject(movie_info_val);

    const seasons_val = try getRequiredField(movie_info, "seasons");
    const seasons_arr = switch (seasons_val) {
        .array => |arr| arr,
        .null => return &.{},
        else => return error.InvalidFieldType,
    };

    var seasons: std.ArrayListUnmanaged(SeasonInfo) = .empty;
    for (seasons_arr.items) |season_val| {
        const season_obj = try asObject(season_val);
        try seasons.append(allocator, .{
            .number = try getRequiredString(season_obj, "number"),
            .name = try getRequiredString(season_obj, "name"),
            .poster = try getRequiredString(season_obj, "poster"),
        });
    }

    return try seasons.toOwnedSlice(allocator);
}

fn parseLanguages(
    page_props: std.json.ObjectMap,
    allocator: Allocator,
    include_empty_subtitle_groups: bool,
) ![]const LanguageSubtitles {
    const grouped_val = try getRequiredField(page_props, "groupedSubtitles");

    return switch (grouped_val) {
        .null => &.{},
        .array => &.{},
        .object => |grouped| parseGroupedSubtitles(grouped, allocator, include_empty_subtitle_groups),
        else => error.InvalidFieldType,
    };
}

fn parseGroupedSubtitles(
    grouped: std.json.ObjectMap,
    allocator: Allocator,
    include_empty_subtitle_groups: bool,
) ![]const LanguageSubtitles {
    var result: std.ArrayListUnmanaged(LanguageSubtitles) = .empty;

    var it = grouped.iterator();
    while (it.next()) |entry| {
        const language = entry.key_ptr.*;
        const subtitles_array = try asArray(entry.value_ptr.*);

        var subtitle_items: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        for (subtitles_array.items) |subtitle_val| {
            const subtitle_obj = try asObject(subtitle_val);
            try subtitle_items.append(allocator, try parseSubtitle(subtitle_obj, allocator));
        }

        if (!include_empty_subtitle_groups and subtitle_items.items.len == 0) continue;
        const owned_subtitles = try subtitle_items.toOwnedSlice(allocator);
        try result.append(allocator, .{
            .language = language,
            .subtitles = owned_subtitles,
        });
    }

    return try result.toOwnedSlice(allocator);
}

fn parseSubtitle(subtitle_obj: std.json.ObjectMap, allocator: Allocator) !SubtitleItem {
    const releases = switch (subtitle_obj.get("releases") orelse std.json.Value{ .array = std.json.Array.init(allocator) }) {
        .array => |arr| blk: {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr.items) |release_val| {
                if (release_val == .string) {
                    try list.append(allocator, release_val.string);
                }
            }
            break :blk try list.toOwnedSlice(allocator);
        },
        else => &.{},
    };

    const enabled_val = subtitle_obj.get("e") orelse return error.MissingField;
    const hi_val = subtitle_obj.get("hi") orelse return error.MissingField;

    return .{
        .id = try getRequiredInt(subtitle_obj, "id"),
        .language = try getRequiredString(subtitle_obj, "language"),
        .quality = try getRequiredString(subtitle_obj, "quality"),
        .link = try getRequiredString(subtitle_obj, "link"),
        .bucket_link = try getRequiredString(subtitle_obj, "bucketLink"),
        .author = try getRequiredString(subtitle_obj, "author"),
        .season = try getRequiredInt(subtitle_obj, "season"),
        .episode = try getRequiredInt(subtitle_obj, "episode"),
        .title = try getRequiredString(subtitle_obj, "title"),
        .extra = try getRequiredString(subtitle_obj, "extra"),
        .enabled = try asBoolOrInt(enabled_val),
        .n_id = try getRequiredString(subtitle_obj, "n_id"),
        .downloads = try getRequiredInt(subtitle_obj, "downloads"),
        .hearing_impaired = try asBoolOrInt(hi_val),
        .releases = releases,
        .rate = try getOptionalFloat(subtitle_obj, "rate"),
        .date_ms = try getRequiredInt(subtitle_obj, "date"),
        .comment = try getRequiredString(subtitle_obj, "comment"),
        .slug = try getOptionalString(subtitle_obj, "slug"),
    };
}

fn getRequiredField(obj: std.json.ObjectMap, field: []const u8) !std.json.Value {
    return obj.get(field) orelse error.MissingField;
}

fn getRequiredString(obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = try getRequiredField(obj, field);
    return asString(value);
}

fn getOptionalString(obj: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .null => null,
        .string => |s| s,
        else => error.InvalidFieldType,
    };
}

fn getRequiredInt(obj: std.json.ObjectMap, field: []const u8) !i64 {
    const value = try getRequiredField(obj, field);
    return asInt(value);
}

fn getOptionalFloat(obj: std.json.ObjectMap, field: []const u8) !?f64 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .number_string => |s| try std.fmt.parseFloat(f64, s),
        else => error.InvalidFieldType,
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

fn asBoolOrInt(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        .integer => |i| i != 0,
        .number_string => |n| (std.fmt.parseInt(i64, n, 10) catch return error.InvalidFieldType) != 0,
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

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    defer scraper.deinit();

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

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    defer scraper.deinit();

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
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var default_scraper = Scraper.init(std.testing.allocator, &client);
    defer default_scraper.deinit();
    try std.testing.expect(default_scraper.options.include_empty_subtitle_groups == false);

    var include_empty_scraper = Scraper.initWithOptions(std.testing.allocator, &client, .{
        .include_empty_subtitle_groups = true,
    });
    defer include_empty_scraper.deinit();
    try std.testing.expect(include_empty_scraper.options.include_empty_subtitle_groups);
}

test "grouped subtitle parsing excludes empty groups by default and includes with option" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var grouped = std.json.ObjectMap.init(a);
    try grouped.put("english", .{ .array = std.json.Array.init(a) });
    try grouped.put("spanish", .{ .array = std.json.Array.init(a) });

    const filtered = try parseGroupedSubtitles(grouped, a, false);
    try std.testing.expectEqual(@as(usize, 0), filtered.len);

    const included = try parseGroupedSubtitles(grouped, a, true);
    try std.testing.expectEqual(@as(usize, 2), included.len);
    for (included) |lang| {
        try std.testing.expectEqual(@as(usize, 0), lang.subtitles.len);
    }
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
