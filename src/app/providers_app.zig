const std = @import("std");
const subdl = @import("../scrapers/subdl.zig");
const runtime_alloc = @import("runtime_alloc");
const runtime_io = @import("runtime_io");
const unarr = @import("unarr");
const provider_registry = @import("../provider_registry.zig");

const Allocator = std.mem.Allocator;
const common = subdl.common;
const cf = subdl.opensubtitles_com_cf;
const opensubtitles_remote_prefix = "oscom-remote:";
const subsource_remote_prefix = "subsource-remote:";
const subtitlecat_translate_prefix = "subtitlecat-translate:";

pub const DownloadPhase = enum(u8) {
    idle,
    resolving_url,
    fetching_source,
    downloading_file,
    translating,
    translating_fallback,
    writing_output,
    extracting_archive,
};

pub const DownloadProgress = struct {
    user_data: ?*anyopaque = null,
    on_phase: ?*const fn (user_data: ?*anyopaque, phase: DownloadPhase) void = null,
    on_units: ?*const fn (user_data: ?*anyopaque, done: usize, total: usize) void = null,
};

pub const DownloadOptions = struct {
    extract_archive: bool = false,
};

pub const Provider = provider_registry.Provider;
const provider_values = provider_registry.active_providers;

pub fn providers() []const Provider {
    return &provider_values;
}

pub fn providerCount() usize {
    return provider_values.len;
}

pub fn providerIndex(provider: Provider) usize {
    for (provider_values, 0..) |value, idx| {
        if (value == provider) return idx;
    }
    unreachable;
}

pub fn providerName(provider: Provider) []const u8 {
    return provider_registry.info(provider).id;
}

pub const ProviderInfo = provider_registry.Info;

pub fn providerInfo(provider: Provider) ProviderInfo {
    return provider_registry.info(provider);
}

pub fn providerDisplayName(provider: Provider) []const u8 {
    return providerInfo(provider).display_name;
}

pub fn providerSupportsTv(provider: Provider) bool {
    return providerInfo(provider).supports_tv;
}

pub fn providerSupportsSearchPagination(provider: Provider) bool {
    return providerInfo(provider).supports_search_pagination;
}

pub fn providerSupportsSubtitlesPagination(provider: Provider) bool {
    return providerInfo(provider).supports_subtitles_pagination;
}

pub fn parseProvider(value: []const u8) ?Provider {
    return resolveProvider(value) catch null;
}

pub const ResolveProviderError = error{
    UnknownProvider,
    AmbiguousProvider,
};

pub fn resolveProvider(value: []const u8) ResolveProviderError!Provider {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return error.UnknownProvider;

    var candidate: ?Provider = null;
    for (provider_values) |provider| {
        const name = providerName(provider);
        if (!matchesProviderPrefix(trimmed, name)) continue;
        if (matchesProvider(trimmed, name)) return provider;
        if (candidate != null) return error.AmbiguousProvider;
        candidate = provider;
    }

    return candidate orelse error.UnknownProvider;
}

fn matchesProviderPrefix(input: []const u8, canonical: []const u8) bool {
    if (input.len == 0 or input.len > canonical.len) return false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (common.normalizeProviderChar(input[i]) != common.normalizeProviderChar(canonical[i])) return false;
    }
    return true;
}

fn matchesProvider(input: []const u8, canonical: []const u8) bool {
    if (input.len != canonical.len) return false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (common.normalizeProviderChar(input[i]) != common.normalizeProviderChar(canonical[i])) return false;
    }
    return true;
}

pub fn providerSelectionAll() [provider_values.len]bool {
    return @splat(true);
}

/// SearchRef is the durable provider-specific handle returned by search and
/// consumed by subtitle fetch. It intentionally keeps only fields needed for the
/// follow-up request plus a title fallback for empty/error pages.
pub const SearchRef = union(Provider) {
    subdl_com: struct {
        title: []const u8,
        media_type: subdl.MediaType,
        link: []const u8,
    },
    opensubtitles_com: struct {
        title: []const u8,
        year: ?[]const u8,
        item_type: ?[]const u8,
        path: []const u8,
        subtitles_count: ?i64,
        subtitles_list_url: []const u8,
    },
    opensubtitles_org: common.SearchLink,
    moviesubtitles_org: struct {
        title: []const u8,
        link: []const u8,
    },
    moviesubtitlesrt_com: common.SearchLink,
    podnapisi_net: struct {
        title: []const u8,
        subtitles_page_url: []const u8,
    },
    yifysubtitles_ch: struct {
        title: []const u8,
        movie_page_url: []const u8,
    },
    subtitlecat_com: struct {
        title: []const u8,
        details_url: []const u8,
    },
    isubtitles_org: struct {
        title: []const u8,
        details_url: []const u8,
    },
    my_subs_co: struct {
        title: []const u8,
        details_url: []const u8,
        media_kind: subdl.my_subs_co.MediaKind,
    },
    subsource_net: struct {
        title: []const u8,
        link: []const u8,
        media_type: []const u8,
        seasons: []const subdl.subsource_net.SeasonItem,
    },
    sub_scene_com: common.SearchLink,
    tvsubtitles_net: struct {
        title: []const u8,
        show_url: []const u8,
    },
    gestdown_info: struct {
        title: []const u8,
        id: []const u8,
        seasons: []const i64,
    },
    greeksubtitles_com: struct {
        title: []const u8,
        language_code: ?[]const u8,
        page_url: []const u8,
        download_url: []const u8,
    },
    subsunacs_net: struct {
        title: []const u8,
        year: ?i64,
        page_url: []const u8,
        download_page_url: []const u8,
    },
    subtitles_ajatt_top: struct {
        title: []const u8,
        media_kind: subdl.subtitles_ajatt_top.MediaKind,
        page_url: []const u8,
    },
    subtis_io: struct {
        title: []const u8,
        year: ?i64,
        slug: []const u8,
        page_url: []const u8,
    },
    greeksubs_net: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.greeksubs_net.MediaKind,
        page_url: []const u8,
    },
    indexsubtitle_cc: common.SearchLink,
    sous_titres_eu: common.MediaSearchLink,
    cc_edatribe_com: common.MediaSearchLink,
    subtitrari_noi_ro: struct {
        title: []const u8,
        year: ?i64,
        page_url: []const u8,
        download_url: []const u8,
    },
    subclub_eu: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.subclub_eu.MediaKind,
        season: ?i64,
        episode: ?i64,
        archive_id: []const u8,
        page_url: []const u8,
    },
    subs_ro: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.subs_ro.MediaKind,
        language_code: []const u8,
        release: []const u8,
        page_url: []const u8,
        download_url: []const u8,
    },
    subs4free_info: struct {
        title: []const u8,
        year: ?i64,
        language_code: []const u8,
        release: []const u8,
        page_url: []const u8,
    },
    tsukihime_org: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.tsukihime_org.MediaKind,
        torrent_id: i64,
        season: ?u16,
        episode: ?u16,
        release: []const u8,
        page_url: []const u8,
    },
    subtitri_nekur_net: struct {
        title: []const u8,
        year: ?i64,
        imdb_id: ?[]const u8,
        fps: ?[]const u8,
        page_url: []const u8,
        download_url: []const u8,
    },
    subsynchro_com: struct {
        title: []const u8,
        year: ?i64,
        page_url: []const u8,
    },
    titrari_ro: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.titrari_ro.MediaKind,
        language_code: []const u8,
        subtitle_id: []const u8,
        page_url: []const u8,
        download_url: []const u8,
    },
    subs_sab_bz: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.subs_sab_bz.MediaKind,
        language_code: []const u8,
        attach_id: []const u8,
        page_url: []const u8,
        download_url: []const u8,
    },
    subtitri_do_am: common.SearchLink,
    prijevodi_online_org: struct {
        title: []const u8,
        series_id: i64,
        slug: []const u8,
        page_url: []const u8,
    },
    animekalesi_com: common.SearchLink,
    subcentral_de: struct {
        title: []const u8,
        season: i64,
        board_url: []const u8,
        thread_url: []const u8,
    },
    subtitulamos_tv: struct {
        title: []const u8,
        show_id: i64,
        season: i64,
        episode: i64,
        page_url: []const u8,
    },
    feliratok_eu: struct {
        title: []const u8,
        year: ?i64,
        language_code: []const u8,
        filename: []const u8,
        page_url: []const u8,
        download_url: []const u8,
    },
    animesub_info: struct {
        title: []const u8,
        media_kind: subdl.animesub_info.MediaKind,
        season: ?i64,
        episode: ?i64,
        subtitle_id: []const u8,
        download_hash: []const u8,
        session_cookie: []const u8,
        search_query: []const u8,
        title_type: []const u8,
        page_url: []const u8,
    },
    animetosho_xyz: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.animetosho_xyz.MediaKind,
        season: ?u16,
        episode: ?u16,
        release_id: i64,
        release: []const u8,
        page_url: []const u8,
    },
    kitsunekko_net: struct {
        title: []const u8,
        language_code: []const u8,
        season: ?u16,
        episode: ?u16,
        page_url: []const u8,
    },
    thesubtitledb_org: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.thesubtitledb_org.MediaKind,
        imdb_id: []const u8,
        season: ?u16,
        episode: ?u16,
        language_code: []const u8,
        page_url: []const u8,
    },
    napisy24_pl: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.napisy24_pl.MediaKind,
        imdb_id: []const u8,
        season: ?u16,
        episode: ?u16,
        search_query: []const u8,
        language_code: []const u8,
        page_url: []const u8,
    },
    nyasub_cz: struct {
        title: []const u8,
        release_label: []const u8,
        media_kind: subdl.nyasub_cz.MediaKind,
        season: ?u16,
        episode: ?u16,
        page_url: []const u8,
    },
    subhd_tv: struct {
        title: []const u8,
        release_info: []const u8,
        media_kind: subdl.subhd_tv.MediaKind,
        season: ?i64,
        episode: ?i64,
        language_code: []const u8,
        subtitle_id: []const u8,
        filename: []const u8,
        detail_url: []const u8,
    },
    fansubs_ru: struct {
        title: []const u8,
        media_id: []const u8,
        page_url: []const u8,
    },
    legendei_net: struct {
        title: []const u8,
        post_id: i64,
        media_kind: subdl.legendei_net.MediaKind,
        season: ?i64,
        episode: ?i64,
        language_code: []const u8,
        page_url: []const u8,
    },
    zoom_lk: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.zoom_lk.MediaKind,
        season: ?i64,
        page_url: []const u8,
    },
    justsubtitles_com: struct {
        title: []const u8,
        year: ?i64,
        movie_id: i64,
        page_url: []const u8,
    },
    wizdom_xyz: struct {
        title: []const u8,
        year: ?i64,
        media_kind: subdl.wizdom_xyz.MediaKind,
        imdb_id: []const u8,
        season: ?i64,
        episode: ?i64,
        page_url: []const u8,
    },
    miraianime_net: struct {
        title: []const u8,
        english_title: ?[]const u8,
        anime_id: i64,
        media_kind: subdl.miraianime_net.MediaKind,
        episodes: ?i64,
        page_url: []const u8,
        subtitle_page_url: []const u8,
    },
    animesubtitle_ir: struct {
        title: []const u8,
        post_id: i64,
        media_kind: subdl.animesubtitle_ir.MediaKind,
        page_url: []const u8,
    },
    grupahatak_pl: common.SearchLink,
    jimaku_cc: struct {
        title: []const u8,
        english_name: ?[]const u8,
        japanese_name: ?[]const u8,
        media_kind: subdl.jimaku_cc.MediaKind,
        entry_id: i64,
        page_url: []const u8,
    },
};

pub const SearchChoice = struct {
    /// Human-readable row text. The canonical title is available through
    /// titleFromRef(ref), so this field can include extra context such as year
    /// or media type without duplicating durable data.
    label: []const u8,
    ref: SearchRef,
};

pub const SearchResponse = struct {
    /// All strings and items in the response live in this arena. Call deinit()
    /// once after consumers are done borrowing response slices.
    arena: std.heap.ArenaAllocator,
    provider: Provider,
    items: []const SearchChoice,
    page: usize = 1,
    has_prev_page: bool = false,
    has_next_page: bool = false,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitleChoice = struct {
    label: []const u8,
    language: ?[]const u8,
    filename: ?[]const u8,
    download_url: ?[]const u8,
};

fn appendBasicSubtitleChoices(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SubtitleChoice),
    subtitles: anytype,
) !void {
    for (subtitles) |subtitle| {
        try out.append(allocator, .{
            .label = try subtitleLabel(allocator, subtitle.language_code, subtitle.filename, subtitle.download_url),
            .language = try allocator.dupe(u8, subtitle.language_code),
            .filename = try allocator.dupe(u8, subtitle.filename),
            .download_url = try allocator.dupe(u8, subtitle.download_url),
        });
    }
}

fn appendEpisodeSubtitleChoices(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SubtitleChoice),
    subtitles: anytype,
) !void {
    for (subtitles) |subtitle| {
        try out.append(allocator, .{
            .label = try std.fmt.allocPrint(
                allocator,
                "S{d:0>2}E{d:0>2} • {s} • {s}",
                .{ subtitle.season, subtitle.episode, subtitle.language_code, subtitle.filename },
            ),
            .language = try allocator.dupe(u8, subtitle.language_code),
            .filename = try allocator.dupe(u8, subtitle.filename),
            .download_url = try allocator.dupe(u8, subtitle.download_url),
        });
    }
}

fn appendOptionalLanguageSubtitleChoices(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SubtitleChoice),
    subtitles: anytype,
) !void {
    for (subtitles) |subtitle| {
        try out.append(allocator, .{
            .label = try subtitleLabel(allocator, subtitle.language_code, subtitle.filename, subtitle.download_url),
            .language = try common.dupOptional(allocator, subtitle.language_code),
            .filename = try allocator.dupe(u8, subtitle.filename),
            .download_url = try allocator.dupe(u8, subtitle.download_url),
        });
    }
}

fn appendFixedLanguageSubtitleChoices(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SubtitleChoice),
    subtitles: anytype,
    language: []const u8,
) !void {
    for (subtitles) |subtitle| {
        try out.append(allocator, .{
            .label = try subtitleLabel(allocator, language, subtitle.filename, subtitle.download_url),
            .language = try allocator.dupe(u8, language),
            .filename = try allocator.dupe(u8, subtitle.filename),
            .download_url = try allocator.dupe(u8, subtitle.download_url),
        });
    }
}

pub const SubtitlesResponse = struct {
    /// Mirrors SearchResponse ownership: subtitle rows borrow from this arena.
    arena: std.heap.ArenaAllocator,
    provider: Provider,
    title: []const u8,
    items: []const SubtitleChoice,
    page: usize = 1,
    has_prev_page: bool = false,
    has_next_page: bool = false,

    pub fn deinit(self: *SubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const DownloadResult = struct {
    file_path: []const u8,
    archive_path: ?[]const u8 = null,
    extracted_files: []const []const u8 = &.{},
    extraction_unavailable: bool = false,
    translation_incomplete: bool = false,
    bytes_written: usize,
    source_url: []const u8,

    pub fn deinit(self: *DownloadResult, allocator: Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.source_url);
        if (self.archive_path) |p| allocator.free(p);
        if (self.extracted_files.len > 0) {
            for (self.extracted_files) |p| allocator.free(p);
            allocator.free(self.extracted_files);
        }
        self.* = undefined;
    }
};

pub const SearchOptions = struct {
    language_code: ?[]const u8 = null,
};

pub fn search(allocator: Allocator, client: *std.http.Client, provider: Provider, query: []const u8) !SearchResponse {
    return searchWithOptions(allocator, client, provider, query, .{});
}

fn searchLinkProvider(
    comptime provider: Provider,
    comptime Scraper: type,
    allocator: Allocator,
    client: *std.http.Client,
    query: []const u8,
    arena_allocator: Allocator,
    out: *std.ArrayListUnmanaged(SearchChoice),
    comptime label_prefix: []const u8,
    comptime label_suffix: []const u8,
) !void {
    var scraper = Scraper.init(allocator, client);
    var response = try scraper.search(query);
    defer response.deinit();

    for (response.items) |item| {
        const ref_item: common.SearchLink = .{
            .title = try arena_allocator.dupe(u8, item.title),
            .page_url = try arena_allocator.dupe(u8, item.page_url),
        };
        const label = if (label_prefix.len == 0 and label_suffix.len == 0)
            try arena_allocator.dupe(u8, ref_item.title)
        else
            try std.fmt.allocPrint(arena_allocator, "{s}{s}{s}", .{ label_prefix, ref_item.title, label_suffix });
        try out.append(arena_allocator, .{
            .label = label,
            .ref = @unionInit(SearchRef, @tagName(provider), ref_item),
        });
    }
}

fn searchMediaLinkProvider(
    comptime provider: Provider,
    comptime Scraper: type,
    allocator: Allocator,
    client: *std.http.Client,
    query: []const u8,
    arena_allocator: Allocator,
    out: *std.ArrayListUnmanaged(SearchChoice),
) !void {
    var scraper = Scraper.init(allocator, client);
    var response = try scraper.search(query);
    defer response.deinit();

    for (response.items) |item| {
        const ref_item: common.MediaSearchLink = .{
            .title = try arena_allocator.dupe(u8, item.title),
            .media_kind = item.media_kind,
            .page_url = try arena_allocator.dupe(u8, item.page_url),
        };
        try out.append(arena_allocator, .{
            .label = try std.fmt.allocPrint(arena_allocator, "[{s}] {s}", .{ @tagName(ref_item.media_kind), ref_item.title }),
            .ref = @unionInit(SearchRef, @tagName(provider), ref_item),
        });
    }
}

pub fn searchWithOptions(allocator: Allocator, client: *std.http.Client, provider: Provider, query: []const u8, options: SearchOptions) !SearchResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SearchChoice) = .empty;

    switch (provider) {
        .subdl_com => {
            var scraper = if (options.language_code) |language_code|
                subdl.subdl_com.Scraper.initWithOptions(allocator, client, .{ .search_language = language_code })
            else
                subdl.subdl_com.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.name);
                const link = try toAbsoluteSubdlLink(a, item.link);
                const label = try std.fmt.allocPrint(a, "[{s}] {s} ({d})", .{ @tagName(item.media_type), title, item.year });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subdl_com = .{
                        .title = title,
                        .media_type = item.media_type,
                        .link = link,
                    } },
                });
            }
        },
        .opensubtitles_com => {
            var scraper = if (options.language_code) |language_code|
                subdl.opensubtitles_com.Scraper.initWithOptions(allocator, client, .{ .language_code = language_code })
            else
                subdl.opensubtitles_com.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const year = try common.dupOptional(a, item.year);
                const item_type = try common.dupOptional(a, item.item_type);
                const path = try a.dupe(u8, item.path);
                const list_url = try a.dupe(u8, item.subtitles_list_url);
                const label = if (year) |y|
                    try std.fmt.allocPrint(a, "{s} ({s})", .{ title, y })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .label = label,
                    .ref = .{ .opensubtitles_com = .{
                        .title = title,
                        .year = year,
                        .item_type = item_type,
                        .path = path,
                        .subtitles_count = item.subtitles_count,
                        .subtitles_list_url = list_url,
                    } },
                });
            }
        },
        .opensubtitles_org => {
            var scraper = if (options.language_code) |language_code|
                subdl.opensubtitles_org.Scraper.initWithOptions(allocator, client, .{ .language_code = language_code })
            else
                subdl.opensubtitles_org.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const page_url = try a.dupe(u8, item.page_url);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .opensubtitles_org = .{
                        .title = title,
                        .page_url = page_url,
                    } },
                });
            }
        },
        .moviesubtitles_org => {
            var scraper = subdl.moviesubtitles_org.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const link = try a.dupe(u8, item.link);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .moviesubtitles_org = .{
                        .title = title,
                        .link = link,
                    } },
                });
            }
        },
        .moviesubtitlesrt_com => {
            try searchLinkProvider(.moviesubtitlesrt_com, subdl.moviesubtitlesrt_com.Scraper, allocator, client, query, a, &out, "", "");
        },
        .podnapisi_net => {
            var scraper = subdl.podnapisi_net.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const subtitles_page_url = try a.dupe(u8, item.subtitles_page_url);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d})", .{ title, year })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .label = label,
                    .ref = .{ .podnapisi_net = .{
                        .title = title,
                        .subtitles_page_url = subtitles_page_url,
                    } },
                });
            }
        },
        .yifysubtitles_ch => {
            var scraper = subdl.yifysubtitles_ch.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.movie);
                const movie_page_url = try a.dupe(u8, item.movie_page_url);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .yifysubtitles_ch = .{
                        .title = title,
                        .movie_page_url = movie_page_url,
                    } },
                });
            }
        },
        .subtitlecat_com => {
            var scraper = subdl.subtitlecat_com.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const details_url = try a.dupe(u8, item.details_url);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .subtitlecat_com = .{
                        .title = title,
                        .details_url = details_url,
                    } },
                });
            }
        },
        .isubtitles_org => {
            var scraper = subdl.isubtitles_org.Scraper.init(allocator, client);
            var response = try scraper.searchWithOptions(query, .{ .max_pages = 3 });
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const details_url = try a.dupe(u8, item.details_url);
                const label = if (item.year) |y|
                    try std.fmt.allocPrint(a, "{s} ({s})", .{ title, y })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .label = label,
                    .ref = .{ .isubtitles_org = .{
                        .title = title,
                        .details_url = details_url,
                    } },
                });
            }
        },
        .my_subs_co => {
            var scraper = subdl.my_subs_co.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const details_url = try a.dupe(u8, item.details_url);
                const label = try std.fmt.allocPrint(a, "[{s}] {s}", .{ @tagName(item.media_kind), title });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .my_subs_co = .{
                        .title = title,
                        .details_url = details_url,
                        .media_kind = item.media_kind,
                    } },
                });
            }
        },
        .subsource_net => {
            var scraper = subdl.subsource_net.Scraper.init(allocator, client);
            var response = try scraper.searchWithOptions(query, .{
                .max_pages = 3,
                .auto_cloudflare_session = true,
            });
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const link = try a.dupe(u8, item.link);
                const media_type = try a.dupe(u8, item.media_type);
                var seasons: std.ArrayListUnmanaged(subdl.subsource_net.SeasonItem) = .empty;
                for (item.seasons) |season| {
                    try seasons.append(a, .{
                        .season = season.season,
                        .link = try a.dupe(u8, season.link),
                    });
                }
                const label = if (item.release_year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d})", .{ title, year })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subsource_net = .{
                        .title = title,
                        .link = link,
                        .media_type = media_type,
                        .seasons = try seasons.toOwnedSlice(a),
                    } },
                });
            }
        },
        .sub_scene_com => {
            try searchLinkProvider(.sub_scene_com, subdl.sub_scene_com.Scraper, allocator, client, query, a, &out, "", "");
        },
        .tvsubtitles_net => {
            var scraper = subdl.tvsubtitles_net.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const show_url = try a.dupe(u8, item.show_url);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .tvsubtitles_net = .{
                        .title = title,
                        .show_url = show_url,
                    } },
                });
            }
        },
        .gestdown_info => {
            var scraper = subdl.gestdown_info.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                var seasons: std.ArrayListUnmanaged(i64) = .empty;
                try seasons.appendSlice(a, item.seasons);
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .gestdown_info = .{
                        .title = title,
                        .id = try a.dupe(u8, item.id),
                        .seasons = try seasons.toOwnedSlice(a),
                    } },
                });
            }
        },
        .greeksubtitles_com => {
            var scraper = subdl.greeksubtitles_com.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const language_code = try common.dupOptional(a, item.language_code);
                const label = if (language_code) |language|
                    try std.fmt.allocPrint(a, "[{s}] {s}", .{ language, title })
                else
                    try a.dupe(u8, title);
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .greeksubtitles_com = .{
                        .title = title,
                        .language_code = language_code,
                        .page_url = try a.dupe(u8, item.page_url),
                        .download_url = try a.dupe(u8, item.download_url),
                    } },
                });
            }
        },
        .subsunacs_net => {
            var scraper = subdl.subsunacs_net.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d})", .{ title, year })
                else
                    try a.dupe(u8, title);
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subsunacs_net = .{
                        .title = title,
                        .year = item.year,
                        .page_url = try a.dupe(u8, item.page_url),
                        .download_page_url = try a.dupe(u8, item.download_page_url),
                    } },
                });
            }
        },
        .subtitles_ajatt_top => {
            var scraper = subdl.subtitles_ajatt_top.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.english_name orelse item.title);
                try out.append(a, .{
                    .label = try std.fmt.allocPrint(a, "[{s}] {s}", .{ @tagName(item.media_kind), title }),
                    .ref = .{ .subtitles_ajatt_top = .{
                        .title = title,
                        .media_kind = item.media_kind,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .subtis_io => {
            var scraper = subdl.subtis_io.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d})", .{ title, year })
                else
                    try a.dupe(u8, title);
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subtis_io = .{
                        .title = title,
                        .year = item.year,
                        .slug = try a.dupe(u8, item.slug),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .greeksubs_net => {
            var scraper = subdl.greeksubs_net.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "[{s}] {s} ({d})", .{ @tagName(item.media_kind), title, year })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s}", .{ @tagName(item.media_kind), title });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .greeksubs_net = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .indexsubtitle_cc => {
            try searchLinkProvider(.indexsubtitle_cc, subdl.indexsubtitle_cc.Scraper, allocator, client, query, a, &out, "", "");
        },
        .sous_titres_eu => {
            try searchMediaLinkProvider(.sous_titres_eu, subdl.sous_titres_eu.Scraper, allocator, client, query, a, &out);
        },
        .cc_edatribe_com => {
            try searchMediaLinkProvider(.cc_edatribe_com, subdl.cc_edatribe_com.Scraper, allocator, client, query, a, &out);
        },
        .subtitrari_noi_ro => {
            var scraper = subdl.subtitrari_noi_ro.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d})", .{ title, year })
                else
                    try a.dupe(u8, title);
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subtitrari_noi_ro = .{
                        .title = title,
                        .year = item.year,
                        .page_url = try a.dupe(u8, item.page_url),
                        .download_url = try a.dupe(u8, item.download_url),
                    } },
                });
            }
        },
        .subclub_eu => {
            var scraper = subdl.subclub_eu.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.season) |season|
                    if (item.episode) |episode|
                        try std.fmt.allocPrint(a, "[tv] {s} S{d}E{d} [et]", .{ title, season, episode })
                    else
                        try std.fmt.allocPrint(a, "[tv] {s} S{d} [et]", .{ title, season })
                else if (item.year) |year|
                    try std.fmt.allocPrint(a, "[movie] {s} ({d}) [et]", .{ title, year })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s} [et]", .{ @tagName(item.media_kind), title });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subclub_eu = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .season = item.season,
                        .episode = item.episode,
                        .archive_id = try a.dupe(u8, item.archive_id),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .subs_ro => {
            var scraper = subdl.subs_ro.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "[{s}] {s} ({d}) [{s}] {s}", .{ @tagName(item.media_kind), title, year, item.language_code, item.release })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s} [{s}] {s}", .{ @tagName(item.media_kind), title, item.language_code, item.release });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subs_ro = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .language_code = try a.dupe(u8, item.language_code),
                        .release = try a.dupe(u8, item.release),
                        .page_url = try a.dupe(u8, item.page_url),
                        .download_url = try a.dupe(u8, item.download_url),
                    } },
                });
            }
        },
        .subs4free_info => {
            var scraper = subdl.subs4free_info.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d}) [{s}] {s}", .{ title, year, item.language_code, item.release })
                else
                    try std.fmt.allocPrint(a, "{s} [{s}] {s}", .{ title, item.language_code, item.release });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subs4free_info = .{
                        .title = title,
                        .year = item.year,
                        .language_code = try a.dupe(u8, item.language_code),
                        .release = try a.dupe(u8, item.release),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .tsukihime_org => {
            var scraper = subdl.tsukihime_org.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.episode) |episode|
                    try std.fmt.allocPrint(a, "[{s}] {s} • E{d:0>2} • {s}", .{ @tagName(item.media_kind), title, episode, item.release })
                else if (item.year) |year|
                    try std.fmt.allocPrint(a, "[{s}] {s} ({d}) • {s}", .{ @tagName(item.media_kind), title, year, item.release })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s} • {s}", .{ @tagName(item.media_kind), title, item.release });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .tsukihime_org = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .torrent_id = item.torrent_id,
                        .season = item.season,
                        .episode = item.episode,
                        .release = try a.dupe(u8, item.release),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .subtitri_nekur_net => {
            var scraper = subdl.subtitri_nekur_net.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d}) [lv]", .{ title, year })
                else
                    try std.fmt.allocPrint(a, "{s} [lv]", .{title});
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subtitri_nekur_net = .{
                        .title = title,
                        .year = item.year,
                        .imdb_id = try common.dupOptional(a, item.imdb_id),
                        .fps = try common.dupOptional(a, item.fps),
                        .page_url = try a.dupe(u8, item.page_url),
                        .download_url = try a.dupe(u8, item.download_url),
                    } },
                });
            }
        },
        .subsynchro_com => {
            var scraper = subdl.subsynchro_com.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d}) [fr]", .{ title, year })
                else
                    try std.fmt.allocPrint(a, "{s} [fr]", .{title});
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subsynchro_com = .{
                        .title = title,
                        .year = item.year,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .titrari_ro => {
            var scraper = subdl.titrari_ro.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "[{s}] {s} ({d}) [{s}]", .{ @tagName(item.media_kind), title, year, item.language_code })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s} [{s}]", .{ @tagName(item.media_kind), title, item.language_code });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .titrari_ro = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .language_code = try a.dupe(u8, item.language_code),
                        .subtitle_id = try a.dupe(u8, item.subtitle_id),
                        .page_url = try a.dupe(u8, item.page_url),
                        .download_url = try a.dupe(u8, item.download_url),
                    } },
                });
            }
        },
        .subs_sab_bz => {
            var scraper = subdl.subs_sab_bz.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "[{s}] {s} ({d}) [{s}]", .{ @tagName(item.media_kind), title, year, item.language_code })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s} [{s}]", .{ @tagName(item.media_kind), title, item.language_code });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subs_sab_bz = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .language_code = try a.dupe(u8, item.language_code),
                        .attach_id = try a.dupe(u8, item.attach_id),
                        .page_url = try a.dupe(u8, item.page_url),
                        .download_url = try a.dupe(u8, item.download_url),
                    } },
                });
            }
        },
        .subtitri_do_am => {
            try searchLinkProvider(.subtitri_do_am, subdl.subtitri_do_am.Scraper, allocator, client, query, a, &out, "", "");
        },
        .prijevodi_online_org => {
            var scraper = subdl.prijevodi_online_org.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try std.fmt.allocPrint(a, "[tv] {s}", .{title}),
                    .ref = .{ .prijevodi_online_org = .{
                        .title = title,
                        .series_id = item.series_id,
                        .slug = try a.dupe(u8, item.slug),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .animekalesi_com => {
            try searchLinkProvider(.animekalesi_com, subdl.animekalesi_com.Scraper, allocator, client, query, a, &out, "[tv] ", "");
        },
        .subcentral_de => {
            var scraper = subdl.subcentral_de.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try std.fmt.allocPrint(a, "[tv] {s} • S{d}", .{ title, item.season }),
                    .ref = .{ .subcentral_de = .{
                        .title = title,
                        .season = item.season,
                        .board_url = try a.dupe(u8, item.board_url),
                        .thread_url = try a.dupe(u8, item.thread_url),
                    } },
                });
            }
        },
        .subtitulamos_tv => {
            var scraper = subdl.subtitulamos_tv.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try std.fmt.allocPrint(a, "[tv] {s} • S{d:0>2}E{d:0>2}", .{ title, item.season, item.episode }),
                    .ref = .{ .subtitulamos_tv = .{
                        .title = title,
                        .show_id = item.show_id,
                        .season = item.season,
                        .episode = item.episode,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .feliratok_eu => {
            var scraper = subdl.feliratok_eu.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d}) [{s}]", .{ title, year, item.language_code })
                else
                    try std.fmt.allocPrint(a, "{s} [{s}]", .{ title, item.language_code });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .feliratok_eu = .{
                        .title = title,
                        .year = item.year,
                        .language_code = try a.dupe(u8, item.language_code),
                        .filename = try a.dupe(u8, item.filename),
                        .page_url = try a.dupe(u8, item.page_url),
                        .download_url = try a.dupe(u8, item.download_url),
                    } },
                });
            }
        },
        .animesub_info => {
            var scraper = subdl.animesub_info.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.media_kind == .tv and item.episode != null)
                    try std.fmt.allocPrint(
                        a,
                        "[tv] {s} • S{d:0>2}E{d:0>2}",
                        .{ title, item.season orelse 1, item.episode.? },
                    )
                else
                    try std.fmt.allocPrint(a, "[movie] {s}", .{title});
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .animesub_info = .{
                        .title = title,
                        .media_kind = item.media_kind,
                        .season = item.season,
                        .episode = item.episode,
                        .subtitle_id = try a.dupe(u8, item.subtitle_id),
                        .download_hash = try a.dupe(u8, item.download_hash),
                        .session_cookie = try a.dupe(u8, item.session_cookie),
                        .search_query = try a.dupe(u8, item.search_query),
                        .title_type = try a.dupe(u8, item.title_type),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .animetosho_xyz => {
            var scraper = subdl.animetosho_xyz.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const release = try a.dupe(u8, item.release);
                const label = if (item.episode) |episode|
                    try std.fmt.allocPrint(a, "[tv] {s} S{d}E{d} • {s}", .{ title, item.season orelse 1, episode, release })
                else if (item.year) |year|
                    try std.fmt.allocPrint(a, "[{s}] {s} ({d}) • {s}", .{ @tagName(item.media_kind), title, year, release })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s} • {s}", .{ @tagName(item.media_kind), title, release });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .animetosho_xyz = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .season = item.season,
                        .episode = item.episode,
                        .release_id = item.release_id,
                        .release = release,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .kitsunekko_net => {
            var scraper = subdl.kitsunekko_net.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.episode) |episode|
                    try std.fmt.allocPrint(a, "[{s}] {s} S{d}E{d}", .{ item.language_code, title, item.season orelse 1, episode })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s}", .{ item.language_code, title });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .kitsunekko_net = .{
                        .title = title,
                        .language_code = try a.dupe(u8, item.language_code),
                        .season = item.season,
                        .episode = item.episode,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .thesubtitledb_org => {
            var scraper = subdl.thesubtitledb_org.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();
            const requested_language = subdl.thesubtitledb_org.providerLanguageCode(options.language_code orelse "en") orelse "en";

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.episode) |episode|
                    if (item.year) |year|
                        try std.fmt.allocPrint(a, "[tv] {s} S{d:0>2}E{d:0>2} ({d})", .{ title, item.season orelse 1, episode, year })
                    else
                        try std.fmt.allocPrint(a, "[tv] {s} S{d:0>2}E{d:0>2}", .{ title, item.season orelse 1, episode })
                else if (item.year) |year|
                    try std.fmt.allocPrint(a, "[{s}] {s} ({d})", .{ @tagName(item.media_kind), title, year })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s}", .{ @tagName(item.media_kind), title });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .thesubtitledb_org = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .imdb_id = try a.dupe(u8, item.imdb_id),
                        .season = item.season,
                        .episode = item.episode,
                        .language_code = try a.dupe(u8, requested_language),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .napisy24_pl => {
            const requested_language = subdl.napisy24_pl.providerLanguageCode(options.language_code orelse "en") orelse "en";
            var scraper = subdl.napisy24_pl.Scraper.initWithLanguage(allocator, client, requested_language);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.episode) |episode|
                    if (item.year) |year|
                        try std.fmt.allocPrint(a, "[tv] {s} S{d:0>2}E{d:0>2} ({d})", .{ title, item.season orelse 1, episode, year })
                    else
                        try std.fmt.allocPrint(a, "[tv] {s} S{d:0>2}E{d:0>2}", .{ title, item.season orelse 1, episode })
                else if (item.year) |year|
                    try std.fmt.allocPrint(a, "[movie] {s} ({d})", .{ title, year })
                else
                    try std.fmt.allocPrint(a, "[movie] {s}", .{title});
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .napisy24_pl = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .imdb_id = try a.dupe(u8, item.imdb_id),
                        .season = item.season,
                        .episode = item.episode,
                        .search_query = try a.dupe(u8, item.search_query),
                        .language_code = try a.dupe(u8, requested_language),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .nyasub_cz => {
            var scraper = subdl.nyasub_cz.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const release_label = try a.dupe(u8, item.release_label);
                const label = if (item.episode) |episode|
                    try std.fmt.allocPrint(a, "[tv] {s} S{d:0>2}E{d:0>2} • {s}", .{ title, item.season orelse 1, episode, release_label })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s} • {s}", .{ @tagName(item.media_kind), title, release_label });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .nyasub_cz = .{
                        .title = title,
                        .release_label = release_label,
                        .media_kind = item.media_kind,
                        .season = item.season,
                        .episode = item.episode,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .subhd_tv => {
            var scraper = subdl.subhd_tv.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.media_kind == .tv and item.episode != null)
                    try std.fmt.allocPrint(
                        a,
                        "[tv] {s} • S{d:0>2}E{d:0>2} • {s} • {s}",
                        .{ title, item.season orelse 1, item.episode.?, item.language_code, item.release_info },
                    )
                else
                    try std.fmt.allocPrint(a, "[movie] {s} • {s} • {s}", .{ title, item.language_code, item.release_info });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .subhd_tv = .{
                        .title = title,
                        .release_info = try a.dupe(u8, item.release_info),
                        .media_kind = item.media_kind,
                        .season = item.season,
                        .episode = item.episode,
                        .language_code = try a.dupe(u8, item.language_code),
                        .subtitle_id = try a.dupe(u8, item.subtitle_id),
                        .filename = try a.dupe(u8, item.filename),
                        .detail_url = try a.dupe(u8, item.detail_url),
                    } },
                });
            }
        },
        .fansubs_ru => {
            var scraper = subdl.fansubs_ru.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = title,
                    .ref = .{ .fansubs_ru = .{
                        .title = title,
                        .media_id = try a.dupe(u8, item.media_id),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .legendei_net => {
            var scraper = subdl.legendei_net.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.media_kind == .tv and item.episode != null)
                    try std.fmt.allocPrint(a, "[tv] {s} • S{d:0>2}E{d:0>2} • {s}", .{ title, item.season orelse 1, item.episode.?, item.language_code })
                else
                    try std.fmt.allocPrint(a, "[movie] {s} • {s}", .{ title, item.language_code });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .legendei_net = .{
                        .title = title,
                        .post_id = item.post_id,
                        .media_kind = item.media_kind,
                        .season = item.season,
                        .episode = item.episode,
                        .language_code = try a.dupe(u8, item.language_code),
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .zoom_lk => {
            var scraper = subdl.zoom_lk.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.media_kind == .tv and item.season != null)
                    try std.fmt.allocPrint(a, "[tv] {s} • S{d:0>2} • si", .{ title, item.season.? })
                else if (item.year) |year|
                    try std.fmt.allocPrint(a, "[movie] {s} ({d}) • si", .{ title, year })
                else
                    try std.fmt.allocPrint(a, "[movie] {s} • si", .{title});
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .zoom_lk = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .season = item.season,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .justsubtitles_com => {
            var scraper = subdl.justsubtitles_com.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d})", .{ title, year })
                else
                    try a.dupe(u8, title);
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .justsubtitles_com = .{
                        .title = title,
                        .year = item.year,
                        .movie_id = item.movie_id,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .wizdom_xyz => {
            var scraper = subdl.wizdom_xyz.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "[{s}] {s} ({d})", .{ @tagName(item.media_kind), title, year })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s}", .{ @tagName(item.media_kind), title });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .wizdom_xyz = .{
                        .title = title,
                        .year = item.year,
                        .media_kind = item.media_kind,
                        .imdb_id = try a.dupe(u8, item.imdb_id),
                        .season = item.season,
                        .episode = item.episode,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .miraianime_net => {
            var scraper = subdl.miraianime_net.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const label = if (item.english_title) |english|
                    try std.fmt.allocPrint(a, "[{s}] {s} / {s} • ar", .{ @tagName(item.media_kind), title, english })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s} • ar", .{ @tagName(item.media_kind), title });
                try out.append(a, .{
                    .label = label,
                    .ref = .{ .miraianime_net = .{
                        .title = title,
                        .english_title = if (item.english_title) |value| try a.dupe(u8, value) else null,
                        .anime_id = item.anime_id,
                        .media_kind = item.media_kind,
                        .episodes = item.episodes,
                        .page_url = try a.dupe(u8, item.page_url),
                        .subtitle_page_url = try a.dupe(u8, item.subtitle_page_url),
                    } },
                });
            }
        },
        .animesubtitle_ir => {
            var scraper = subdl.animesubtitle_ir.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try std.fmt.allocPrint(a, "[{s}] {s} • fa", .{ @tagName(item.media_kind), title }),
                    .ref = .{ .animesubtitle_ir = .{
                        .title = title,
                        .post_id = item.post_id,
                        .media_kind = item.media_kind,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .grupahatak_pl => {
            try searchLinkProvider(.grupahatak_pl, subdl.grupahatak_pl.Scraper, allocator, client, query, a, &out, "[tv] ", " • pl");
        },
        .jimaku_cc => {
            var scraper = subdl.jimaku_cc.Scraper.init(allocator, client);
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const display = if (item.english_name) |english|
                    try std.fmt.allocPrint(a, "[{s}] {s} / {s} • ja", .{ @tagName(item.media_kind), title, english })
                else
                    try std.fmt.allocPrint(a, "[{s}] {s} • ja", .{ @tagName(item.media_kind), title });
                try out.append(a, .{
                    .label = display,
                    .ref = .{ .jimaku_cc = .{
                        .title = title,
                        .english_name = if (item.english_name) |value| try a.dupe(u8, value) else null,
                        .japanese_name = if (item.japanese_name) |value| try a.dupe(u8, value) else null,
                        .media_kind = item.media_kind,
                        .entry_id = item.entry_id,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
    }

    return common.finishResponse(SearchResponse, &arena, .{
        .arena = arena,
        .provider = provider,
        .items = try out.toOwnedSlice(a),
    });
}

/// Page-aware search wrapper. Providers without real pagination expose page 1
/// as normal data and every later page as an empty, non-network response so the
/// UI never invents fake pagination for those providers.
pub fn searchPage(allocator: Allocator, client: *std.http.Client, provider: Provider, query: []const u8, page: usize) !SearchResponse {
    return searchPageWithOptions(allocator, client, provider, query, page, .{});
}

pub fn searchPageWithOptions(allocator: Allocator, client: *std.http.Client, provider: Provider, query: []const u8, page: usize, options: SearchOptions) !SearchResponse {
    const requested_page = if (page == 0) 1 else page;
    if (!providerSupportsSearchPagination(provider)) {
        if (requested_page == 1) {
            var first = try searchWithOptions(allocator, client, provider, query, options);
            first.page = 1;
            first.has_prev_page = false;
            first.has_next_page = false;
            return first;
        }
        return emptySearchPage(allocator, provider, requested_page);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SearchChoice) = .empty;
    var has_next_page = false;

    switch (provider) {
        .opensubtitles_org => {
            var scraper = if (options.language_code) |language_code|
                subdl.opensubtitles_org.Scraper.initWithOptions(allocator, client, .{ .language_code = language_code })
            else
                subdl.opensubtitles_org.Scraper.init(allocator, client);
            var response = try scraper.searchWithOptions(query, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer response.deinit();
            has_next_page = response.has_next_page;

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const page_url = try a.dupe(u8, item.page_url);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .opensubtitles_org = .{
                        .title = title,
                        .page_url = page_url,
                    } },
                });
            }
        },
        .moviesubtitlesrt_com => {
            var scraper = subdl.moviesubtitlesrt_com.Scraper.init(allocator, client);
            var response = try scraper.searchWithOptions(query, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer response.deinit();
            has_next_page = response.has_next_page;

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const page_url = try a.dupe(u8, item.page_url);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .moviesubtitlesrt_com = .{
                        .title = title,
                        .page_url = page_url,
                    } },
                });
            }
        },
        .podnapisi_net => {
            var scraper = subdl.podnapisi_net.Scraper.init(allocator, client);
            var response = try scraper.searchWithOptions(query, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer response.deinit();
            has_next_page = response.has_next_page;

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const subtitles_page_url = try a.dupe(u8, item.subtitles_page_url);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d})", .{ title, year })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .label = label,
                    .ref = .{ .podnapisi_net = .{
                        .title = title,
                        .subtitles_page_url = subtitles_page_url,
                    } },
                });
            }
        },
        .isubtitles_org => {
            var scraper = subdl.isubtitles_org.Scraper.init(allocator, client);
            var response = try scraper.searchWithOptions(query, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer response.deinit();
            has_next_page = response.has_next_page;

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const details_url = try a.dupe(u8, item.details_url);
                const label = if (item.year) |y|
                    try std.fmt.allocPrint(a, "{s} ({s})", .{ title, y })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .label = label,
                    .ref = .{ .isubtitles_org = .{
                        .title = title,
                        .details_url = details_url,
                    } },
                });
            }
        },
        else => return error.UnsupportedProvider,
    }

    return common.finishResponse(SearchResponse, &arena, .{
        .arena = arena,
        .provider = provider,
        .items = try out.toOwnedSlice(a),
        .page = requested_page,
        .has_prev_page = requested_page > 1,
        .has_next_page = has_next_page,
    });
}

pub fn fetchSubtitles(allocator: Allocator, client: *std.http.Client, ref: SearchRef) !SubtitlesResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SubtitleChoice) = .empty;
    var title: []const u8 = "";

    switch (ref) {
        .subdl_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subdl_com.Scraper.init(allocator, client);

            switch (item.media_type) {
                .movie => {
                    var movie = try scraper.fetchMovieByLink(item.link);
                    defer movie.deinit();
                    title = try a.dupe(u8, movie.movie.name);

                    for (movie.languages) |group| {
                        for (group.subtitles) |subtitle| {
                            const download_url = try std.fmt.allocPrint(a, "https://dl.subdl.com/subtitle/{s}", .{subtitle.link});
                            const label = try std.fmt.allocPrint(a, "{s} • {s}", .{ group.language, subtitle.title });
                            try out.append(a, .{
                                .label = label,
                                .language = try a.dupe(u8, group.language),
                                .filename = try a.dupe(u8, subtitle.title),
                                .download_url = download_url,
                            });
                        }
                    }
                },
                .tv => {
                    var seasons = try scraper.fetchTvSeasonsByLink(item.link);
                    defer seasons.deinit();
                    title = try a.dupe(u8, seasons.tv.name);

                    for (seasons.seasons) |season| {
                        var season_data = scraper.fetchTvSeasonByLink(item.link, season.number) catch |err| {
                            if (common.mustPropagateOptionalFailure(err)) return err;
                            continue;
                        };
                        defer season_data.deinit();

                        for (season_data.languages) |group| {
                            for (group.subtitles) |subtitle| {
                                const download_url = try std.fmt.allocPrint(a, "https://dl.subdl.com/subtitle/{s}", .{subtitle.link});
                                const label = try std.fmt.allocPrint(a, "{s} • {s} • {s}", .{ season.name, group.language, subtitle.title });
                                try out.append(a, .{
                                    .label = label,
                                    .language = try a.dupe(u8, group.language),
                                    .filename = try a.dupe(u8, subtitle.title),
                                    .download_url = download_url,
                                });
                            }
                        }
                    }
                },
            }
        },
        .opensubtitles_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.opensubtitles_com.Scraper.init(allocator, client);

            const query_item: subdl.opensubtitles_com.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .item_type = item.item_type,
                .path = item.path,
                .subtitles_count = item.subtitles_count,
                .subtitles_list_url = item.subtitles_list_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItemWithOptions(query_item, .{
                .resolve_downloads = false,
            });
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const download_url = if (subtitle.verified_download_url) |resolved|
                    resolved
                else
                    try makeOpenSubtitlesRemoteToken(a, subtitle.remote_endpoint);
                const label = try subtitleLabel(a, subtitle.language, subtitle.filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language),
                    .filename = try common.dupOptional(a, subtitle.filename),
                    .download_url = try a.dupe(u8, download_url),
                });
            }
        },
        .opensubtitles_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.opensubtitles_org.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesByMoviePage(item.page_url);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const download_url = if (subtitle.direct_zip_url.len > 0) subtitle.direct_zip_url else null;
                const filename = subtitle.filename orelse subtitle.release;
                const label = try subtitleLabel(a, subtitle.language_code, filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language_code),
                    .filename = try common.dupOptional(a, filename),
                    .download_url = try common.dupOptional(a, download_url),
                });
            }
        },
        .moviesubtitles_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.moviesubtitles_org.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesByMovieLink(item.link);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            try appendOptionalLanguageSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .moviesubtitlesrt_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.moviesubtitlesrt_com.Scraper.init(allocator, client);
            var subtitle = try scraper.fetchSubtitleByLink(item.page_url);
            defer subtitle.deinit();
            title = try a.dupe(u8, subtitle.subtitle.title);

            const label = try subtitleLabel(a, subtitle.subtitle.language_code, subtitle.subtitle.title, subtitle.subtitle.download_url);
            try out.append(a, .{
                .label = label,
                .language = try common.dupOptional(a, subtitle.subtitle.language_code),
                .filename = try a.dupe(u8, subtitle.subtitle.title),
                .download_url = try a.dupe(u8, subtitle.subtitle.download_url),
            });
        },
        .podnapisi_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.podnapisi_net.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesBySearchLink(item.subtitles_page_url);
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language, subtitle.release, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language),
                    .filename = try common.dupOptional(a, subtitle.release),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .yifysubtitles_ch => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.yifysubtitles_ch.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesByMovieLink(item.movie_page_url);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language, subtitle.release_text, subtitle.zip_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language),
                    .filename = try a.dupe(u8, subtitle.release_text),
                    .download_url = try a.dupe(u8, subtitle.zip_url),
                });
            }
        },
        .subtitlecat_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitlecat_com.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesByDetailsLink(item.details_url);
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                var resolved_download_url: ?[]const u8 = try common.dupOptional(a, subtitle.download_url);
                if (resolved_download_url == null and subtitle.mode == .translated) {
                    const source_url = subtitle.source_url orelse if (subtitle.translate_spec) |spec|
                        spec.source_url
                    else
                        null;
                    if (source_url) |source| {
                        const target_lang = subtitle.language_code orelse subtitle.language_label orelse "en";
                        resolved_download_url = try makeSubtitlecatTranslateToken(a, source, target_lang, subtitle.filename);
                    }
                }

                var label = try subtitleLabel(a, subtitle.language_code orelse subtitle.language_label, subtitle.filename, resolved_download_url);
                if (subtitle.mode == .translated and resolved_download_url != null) {
                    label = try std.fmt.allocPrint(a, "{s} [translate]", .{label});
                }
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language_code orelse subtitle.language_label),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = resolved_download_url,
                });
            }
        },
        .isubtitles_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.isubtitles_org.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesByMovieLinkWithOptions(item.details_url, .{ .max_pages = 3 });
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_page_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_page_url),
                });
            }
        },
        .my_subs_co => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.my_subs_co.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesByDetailsLinkWithOptions(item.details_url, item.media_kind, .{
                .resolve_download_links = false,
                .include_seasons = true,
            });
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const download_url = subtitle.download_page_url;
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, download_url),
                });
            }
        },
        .subsource_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subsource_net.Scraper.init(allocator, client);

            const fake_item: subdl.subsource_net.SearchItem = .{
                .id = 0,
                .title = item.title,
                .media_type = item.media_type,
                .link = item.link,
                .release_year = null,
                .subtitle_count = null,
                .seasons = item.seasons,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItemWithOptions(fake_item, .{
                .include_seasons = true,
                .max_pages = 1,
                .resolve_download_tokens = false,
                .auto_cloudflare_session = true,
            });
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const filename = subtitle.release_info orelse subtitle.release_type;
                const download_url = try makeSubsourceRemoteToken(a, subtitle.details_path);
                const label = try subtitleLabel(a, subtitle.language_code, filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language_code),
                    .filename = try common.dupOptional(a, filename),
                    .download_url = download_url,
                });
            }
        },
        .sub_scene_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.sub_scene_com.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitles(item.page_url);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const filename = subtitle.release orelse "Without release";
                const label = try subtitleLabel(a, subtitle.language_code orelse subtitle.language, filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language_code orelse subtitle.language),
                    .filename = try a.dupe(u8, filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .tvsubtitles_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.tvsubtitles_net.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesByShowLinkWithOptions(item.show_url, .{
                .include_all_seasons = true,
                .resolve_download_links = false,
            });
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const download_url = subtitle.download_page_url;
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, download_url),
                });
            }
        },
        .gestdown_info => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.gestdown_info.Scraper.init(allocator, client);
            const query_item: subdl.gestdown_info.SearchItem = .{
                .id = item.id,
                .title = item.title,
                .seasons = item.seasons,
                .tvdb_id = null,
                .tmdb_id = null,
                .slug = "",
            };
            var subtitles = try scraper.fetchSubtitles(query_item);
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const language = if (subtitle.hearing_impaired)
                    try std.fmt.allocPrint(a, "{s} HI", .{subtitle.language})
                else
                    try a.dupe(u8, subtitle.language);
                const label = try subtitleLabel(a, language, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = language,
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .greeksubtitles_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.greeksubtitles_com.Scraper.init(allocator, client);
            const query_item: subdl.greeksubtitles_com.SearchItem = .{
                .title = item.title,
                .language_code = item.language_code,
                .page_url = item.page_url,
                .download_url = item.download_url,
                .downloads = null,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendOptionalLanguageSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subsunacs_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subsunacs_net.Scraper.init(allocator, client);
            const query_item: subdl.subsunacs_net.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .page_url = item.page_url,
                .download_page_url = item.download_page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendFixedLanguageSubtitleChoices(a, &out, subtitles.subtitles, "en");
        },
        .subtitles_ajatt_top => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitles_ajatt_top.Scraper.init(allocator, client);
            const query_item: subdl.subtitles_ajatt_top.SearchItem = .{
                .title = item.title,
                .english_name = null,
                .japanese_name = null,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendFixedLanguageSubtitleChoices(a, &out, subtitles.subtitles, "ja");
        },
        .subtis_io => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtis_io.Scraper.init(allocator, client);
            const query_item: subdl.subtis_io.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .slug = item.slug,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendFixedLanguageSubtitleChoices(a, &out, subtitles.subtitles, "es");
        },
        .greeksubs_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.greeksubs_net.Scraper.init(allocator, client);
            const query_item: subdl.greeksubs_net.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendOptionalLanguageSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .indexsubtitle_cc => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.indexsubtitle_cc.Scraper.init(allocator, client);
            const query_item: subdl.indexsubtitle_cc.SearchItem = .{
                .title = item.title,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language, subtitle.title, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language),
                    .filename = try a.dupe(u8, subtitle.title),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .sous_titres_eu => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.sous_titres_eu.Scraper.init(allocator, client);
            const query_item: subdl.sous_titres_eu.SearchItem = .{
                .title = item.title,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendOptionalLanguageSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .cc_edatribe_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.cc_edatribe_com.Scraper.init(allocator, client);
            const query_item: subdl.cc_edatribe_com.SearchItem = .{
                .title = item.title,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subtitrari_noi_ro => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitrari_noi_ro.Scraper.init(allocator, client);
            const query_item: subdl.subtitrari_noi_ro.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .page_url = item.page_url,
                .download_url = item.download_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subclub_eu => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subclub_eu.Scraper.init(allocator, client);
            const query_item: subdl.subclub_eu.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .season = item.season,
                .episode = item.episode,
                .archive_id = item.archive_id,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subs_ro => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subs_ro.Scraper.init(allocator, client);
            const query_item: subdl.subs_ro.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .language_code = item.language_code,
                .release = item.release,
                .page_url = item.page_url,
                .download_url = item.download_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subs4free_info => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subs4free_info.Scraper.init(allocator, client);
            const query_item: subdl.subs4free_info.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .language_code = item.language_code,
                .release = item.release,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .tsukihime_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.tsukihime_org.Scraper.init(allocator, client);
            const query_item: subdl.tsukihime_org.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .torrent_id = item.torrent_id,
                .season = item.season,
                .episode = item.episode,
                .release = item.release,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subtitri_nekur_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitri_nekur_net.Scraper.init(allocator, client);
            const query_item: subdl.subtitri_nekur_net.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .imdb_id = item.imdb_id,
                .fps = item.fps,
                .page_url = item.page_url,
                .download_url = item.download_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subsynchro_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subsynchro_com.Scraper.init(allocator, client);
            const query_item: subdl.subsynchro_com.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .titrari_ro => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.titrari_ro.Scraper.init(allocator, client);
            const query_item: subdl.titrari_ro.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .language_code = item.language_code,
                .subtitle_id = item.subtitle_id,
                .page_url = item.page_url,
                .download_url = item.download_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subs_sab_bz => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subs_sab_bz.Scraper.init(allocator, client);
            const query_item: subdl.subs_sab_bz.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .language_code = item.language_code,
                .attach_id = item.attach_id,
                .page_url = item.page_url,
                .download_url = item.download_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subtitri_do_am => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitri_do_am.Scraper.init(allocator, client);
            const query_item: subdl.subtitri_do_am.SearchItem = .{
                .title = item.title,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .prijevodi_online_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.prijevodi_online_org.Scraper.init(allocator, client);
            const query_item: subdl.prijevodi_online_org.SearchItem = .{
                .title = item.title,
                .series_id = item.series_id,
                .slug = item.slug,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendEpisodeSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .animekalesi_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.animekalesi_com.Scraper.init(allocator, client);
            const query_item: subdl.animekalesi_com.SearchItem = .{
                .title = item.title,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendEpisodeSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subcentral_de => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subcentral_de.Scraper.init(allocator, client);
            const query_item: subdl.subcentral_de.SearchItem = .{
                .title = item.title,
                .season = item.season,
                .board_url = item.board_url,
                .thread_url = item.thread_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try std.fmt.allocPrint(
                    a,
                    "S{d:0>2}E{d:0>2} • {s} • {s}",
                    .{ item.season, subtitle.episode, subtitle.language_code, subtitle.filename },
                );
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subtitulamos_tv => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitulamos_tv.Scraper.init(allocator, client);
            const query_item: subdl.subtitulamos_tv.SearchItem = .{
                .title = item.title,
                .show_id = item.show_id,
                .season = item.season,
                .episode = item.episode,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try std.fmt.allocPrint(
                    a,
                    "S{d:0>2}E{d:0>2} • {s} • {s}",
                    .{ item.season, item.episode, subtitle.language_code, subtitle.filename },
                );
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .feliratok_eu => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.feliratok_eu.Scraper.init(allocator, client);
            const query_item: subdl.feliratok_eu.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .language_code = item.language_code,
                .filename = item.filename,
                .page_url = item.page_url,
                .download_url = item.download_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .animesub_info => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.animesub_info.Scraper.init(allocator, client);
            const query_item: subdl.animesub_info.SearchItem = .{
                .title = item.title,
                .media_kind = item.media_kind,
                .season = item.season,
                .episode = item.episode,
                .subtitle_id = item.subtitle_id,
                .download_hash = item.download_hash,
                .session_cookie = item.session_cookie,
                .search_query = item.search_query,
                .title_type = item.title_type,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .animetosho_xyz => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.animetosho_xyz.Scraper.init(allocator, client);
            const query_item: subdl.animetosho_xyz.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .season = item.season,
                .episode = item.episode,
                .release_id = item.release_id,
                .release = item.release,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .kitsunekko_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.kitsunekko_net.Scraper.init(allocator, client);
            const query_item: subdl.kitsunekko_net.SearchItem = .{
                .title = item.title,
                .language_code = item.language_code,
                .season = item.season,
                .episode = item.episode,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .thesubtitledb_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.thesubtitledb_org.Scraper.init(allocator, client);
            const query_item: subdl.thesubtitledb_org.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .imdb_id = item.imdb_id,
                .season = item.season,
                .episode = item.episode,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item, item.language_code);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const display_name = if (subtitle.hearing_impaired)
                    try std.fmt.allocPrint(a, "{s} [HI]", .{subtitle.release_name})
                else
                    subtitle.release_name;
                const label = try subtitleLabel(a, subtitle.language_code, display_name, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .napisy24_pl => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.napisy24_pl.Scraper.initWithLanguage(allocator, client, item.language_code);
            const query_item: subdl.napisy24_pl.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .imdb_id = item.imdb_id,
                .season = item.season,
                .episode = item.episode,
                .search_query = item.search_query,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item, item.language_code);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.release_name, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .nyasub_cz => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.nyasub_cz.Scraper.init(allocator, client);
            const query_item: subdl.nyasub_cz.SearchItem = .{
                .title = item.title,
                .release_label = item.release_label,
                .media_kind = item.media_kind,
                .season = item.season,
                .episode = item.episode,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .subhd_tv => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subhd_tv.Scraper.init(allocator, client);
            const query_item: subdl.subhd_tv.SearchItem = .{
                .title = item.title,
                .release_info = item.release_info,
                .media_kind = item.media_kind,
                .season = item.season,
                .episode = item.episode,
                .language_code = item.language_code,
                .subtitle_id = item.subtitle_id,
                .filename = item.filename,
                .detail_url = item.detail_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .fansubs_ru => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.fansubs_ru.Scraper.init(allocator, client);
            const query_item: subdl.fansubs_ru.SearchItem = .{
                .title = item.title,
                .media_id = item.media_id,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .legendei_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.legendei_net.Scraper.init(allocator, client);
            const query_item: subdl.legendei_net.SearchItem = .{
                .title = item.title,
                .post_id = item.post_id,
                .media_kind = item.media_kind,
                .season = item.season,
                .episode = item.episode,
                .language_code = item.language_code,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .zoom_lk => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.zoom_lk.Scraper.init(allocator, client);
            const query_item: subdl.zoom_lk.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .season = item.season,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .justsubtitles_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.justsubtitles_com.Scraper.init(allocator, client);
            const query_item: subdl.justsubtitles_com.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .movie_id = item.movie_id,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.release_name, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .wizdom_xyz => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.wizdom_xyz.Scraper.init(allocator, client);
            const query_item: subdl.wizdom_xyz.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .imdb_id = item.imdb_id,
                .season = item.season,
                .episode = item.episode,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const prefix = if (subtitle.season != null and subtitle.episode != null)
                    try std.fmt.allocPrint(a, "S{d:0>2}E{d:0>2} • ", .{ subtitle.season.?, subtitle.episode.? })
                else
                    try a.dupe(u8, "");
                const label = try std.fmt.allocPrint(a, "{s}{s} • {s}", .{ prefix, subtitle.language_code, subtitle.release_info });
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .miraianime_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.miraianime_net.Scraper.init(allocator, client);
            const query_item: subdl.miraianime_net.SearchItem = .{
                .title = item.title,
                .english_title = item.english_title,
                .anime_id = item.anime_id,
                .media_kind = item.media_kind,
                .episodes = item.episodes,
                .page_url = item.page_url,
                .subtitle_page_url = item.subtitle_page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .animesubtitle_ir => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.animesubtitle_ir.Scraper.init(allocator, client);
            const query_item: subdl.animesubtitle_ir.SearchItem = .{
                .title = item.title,
                .post_id = item.post_id,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .grupahatak_pl => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.grupahatak_pl.Scraper.init(allocator, client);
            const query_item: subdl.grupahatak_pl.SearchItem = .{
                .title = item.title,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendEpisodeSubtitleChoices(a, &out, subtitles.subtitles);
        },
        .jimaku_cc => |item| {
            title = try a.dupe(u8, item.english_name orelse item.title);
            var scraper = subdl.jimaku_cc.Scraper.init(allocator, client);
            const query_item: subdl.jimaku_cc.SearchItem = .{
                .title = item.title,
                .english_name = item.english_name,
                .japanese_name = item.japanese_name,
                .media_kind = item.media_kind,
                .entry_id = item.entry_id,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            try appendBasicSubtitleChoices(a, &out, subtitles.subtitles);
        },
    }

    return common.finishResponse(SubtitlesResponse, &arena, .{
        .arena = arena,
        .provider = std.meta.activeTag(ref),
        .title = title,
        .items = try out.toOwnedSlice(a),
    });
}

/// Same pagination contract as searchPage: unsupported providers return an
/// empty page after page 1. This keeps scraper modules simple and moves TUI
/// pagination policy into the app layer.
pub fn fetchSubtitlesPage(allocator: Allocator, client: *std.http.Client, ref: SearchRef, page: usize) !SubtitlesResponse {
    const requested_page = if (page == 0) 1 else page;
    const provider = std.meta.activeTag(ref);
    if (!providerSupportsSubtitlesPagination(provider)) {
        if (requested_page == 1) {
            var first = try fetchSubtitles(allocator, client, ref);
            first.page = 1;
            first.has_prev_page = false;
            first.has_next_page = false;
            return first;
        }
        return emptySubtitlesPage(allocator, ref, requested_page);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SubtitleChoice) = .empty;
    var title: []const u8 = try a.dupe(u8, titleFromRef(ref));
    var has_next_page = false;

    switch (ref) {
        .opensubtitles_org => |item| {
            var scraper = subdl.opensubtitles_org.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesByMoviePageWithOptions(item.page_url, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer subtitles.deinit();
            has_next_page = subtitles.has_next_page;
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const download_url = if (subtitle.direct_zip_url.len > 0) subtitle.direct_zip_url else null;
                const filename = subtitle.filename orelse subtitle.release;
                const label = try subtitleLabel(a, subtitle.language_code, filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language_code),
                    .filename = try common.dupOptional(a, filename),
                    .download_url = try common.dupOptional(a, download_url),
                });
            }
        },
        .isubtitles_org => |item| {
            var scraper = subdl.isubtitles_org.Scraper.init(allocator, client);
            var subtitles = try scraper.fetchSubtitlesByMovieLinkWithOptions(item.details_url, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer subtitles.deinit();
            has_next_page = subtitles.has_next_page;
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_page_url);
                try out.append(a, .{
                    .label = label,
                    .language = try common.dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_page_url),
                });
            }
        },
        else => return error.UnsupportedProvider,
    }

    return common.finishResponse(SubtitlesResponse, &arena, .{
        .arena = arena,
        .provider = provider,
        .title = title,
        .items = try out.toOwnedSlice(a),
        .page = requested_page,
        .has_prev_page = requested_page > 1,
        .has_next_page = has_next_page,
    });
}

fn emptySearchPage(allocator: Allocator, provider: Provider, page: usize) !SearchResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    return .{
        .arena = arena,
        .provider = provider,
        .items = &.{},
        .page = if (page == 0) 1 else page,
        .has_prev_page = page > 1,
        .has_next_page = false,
    };
}

fn emptySubtitlesPage(allocator: Allocator, ref: SearchRef, page: usize) !SubtitlesResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const p = if (page == 0) 1 else page;
    const title = try arena.allocator().dupe(u8, titleFromRef(ref));
    return .{
        .arena = arena,
        .provider = std.meta.activeTag(ref),
        .title = title,
        .items = &.{},
        .page = p,
        .has_prev_page = p > 1,
        .has_next_page = false,
    };
}

pub fn titleFromRef(ref: SearchRef) []const u8 {
    return switch (ref) {
        .subdl_com => |item| item.title,
        .opensubtitles_com => |item| item.title,
        .opensubtitles_org => |item| item.title,
        .moviesubtitles_org => |item| item.title,
        .moviesubtitlesrt_com => |item| item.title,
        .podnapisi_net => |item| item.title,
        .yifysubtitles_ch => |item| item.title,
        .subtitlecat_com => |item| item.title,
        .isubtitles_org => |item| item.title,
        .my_subs_co => |item| item.title,
        .subsource_net => |item| item.title,
        .sub_scene_com => |item| item.title,
        .tvsubtitles_net => |item| item.title,
        .gestdown_info => |item| item.title,
        .greeksubtitles_com => |item| item.title,
        .subsunacs_net => |item| item.title,
        .subtitles_ajatt_top => |item| item.title,
        .subtis_io => |item| item.title,
        .greeksubs_net => |item| item.title,
        .indexsubtitle_cc => |item| item.title,
        .sous_titres_eu => |item| item.title,
        .cc_edatribe_com => |item| item.title,
        .subtitrari_noi_ro => |item| item.title,
        .subclub_eu => |item| item.title,
        .subs_ro => |item| item.title,
        .subs4free_info => |item| item.title,
        .tsukihime_org => |item| item.title,
        .subtitri_nekur_net => |item| item.title,
        .subsynchro_com => |item| item.title,
        .titrari_ro => |item| item.title,
        .subs_sab_bz => |item| item.title,
        .subtitri_do_am => |item| item.title,
        .prijevodi_online_org => |item| item.title,
        .animekalesi_com => |item| item.title,
        .subcentral_de => |item| item.title,
        .subtitulamos_tv => |item| item.title,
        .feliratok_eu => |item| item.title,
        .animesub_info => |item| item.title,
        .animetosho_xyz => |item| item.title,
        .kitsunekko_net => |item| item.title,
        .thesubtitledb_org => |item| item.title,
        .napisy24_pl => |item| item.title,
        .nyasub_cz => |item| item.title,
        .subhd_tv => |item| item.title,
        .fansubs_ru => |item| item.title,
        .legendei_net => |item| item.title,
        .zoom_lk => |item| item.title,
        .justsubtitles_com => |item| item.title,
        .wizdom_xyz => |item| item.title,
        .miraianime_net => |item| item.title,
        .animesubtitle_ir => |item| item.title,
        .grupahatak_pl => |item| item.title,
        .jimaku_cc => |item| item.english_name orelse item.title,
    };
}

pub fn downloadSubtitleWithOptions(
    allocator: Allocator,
    client: *std.http.Client,
    subtitle: SubtitleChoice,
    out_dir: []const u8,
    options: DownloadOptions,
) !DownloadResult {
    return downloadSubtitleWithProgressAndOptions(allocator, client, subtitle, out_dir, null, options);
}

pub fn downloadSubtitleWithProgressAndOptions(
    allocator: Allocator,
    client: *std.http.Client,
    subtitle: SubtitleChoice,
    out_dir: []const u8,
    progress: ?*const DownloadProgress,
    options: DownloadOptions,
) !DownloadResult {
    const source_url = subtitle.download_url orelse return error.MissingField;

    if (try parseSubtitlecatTranslateToken(allocator, source_url)) |token| {
        defer token.deinit(allocator);
        return downloadSubtitlecatTranslated(allocator, client, subtitle, out_dir, source_url, token, progress);
    }

    const owned_source = try allocator.dupe(u8, source_url);
    errdefer allocator.free(owned_source);
    emitDownloadPhase(progress, .resolving_url);
    const greeksubs_download = subdl.greeksubs_net.parseDownloadToken(source_url) != null;
    const indexsubtitle_download = subdl.indexsubtitle_cc.parseDownloadToken(source_url) != null;
    const titrari_download = subdl.titrari_ro.parseDownloadToken(source_url) != null;
    const subs_sab_download = subdl.subs_sab_bz.parseDownloadToken(source_url) != null;
    const animekalesi_download = subdl.animekalesi_com.parseDownloadToken(source_url) != null;
    const animesub_download = subdl.animesub_info.parseDownloadToken(source_url) != null;
    const animetosho_download = subdl.animetosho_xyz.parseDownloadToken(source_url) != null;
    const subhd_download = subdl.subhd_tv.parseDownloadToken(source_url) != null;
    const fansubs_download = subdl.fansubs_ru.parseDownloadToken(source_url) != null;
    const grupahatak_download = subdl.grupahatak_pl.parseDownloadToken(source_url) != null;
    const subs4free_download = subdl.subs4free_info.parseDownloadToken(source_url) != null;
    const tsukihime_download = subdl.tsukihime_org.parseDownloadToken(source_url) != null;
    const subsource_details_path = parseSubsourceRemoteToken(source_url);
    const url = if (greeksubs_download or indexsubtitle_download or titrari_download or subs_sab_download or animekalesi_download or animesub_download or animetosho_download or subhd_download or fansubs_download or grupahatak_download or subs4free_download or tsukihime_download or subsource_details_path != null)
        try allocator.dupe(u8, source_url)
    else
        try resolveDownloadUrlIfNeeded(allocator, client, source_url);
    defer allocator.free(url);

    emitDownloadPhase(progress, .downloading_file);
    const response = if (greeksubs_download) blk: {
        var scraper = subdl.greeksubs_net.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (indexsubtitle_download) blk: {
        var scraper = subdl.indexsubtitle_cc.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (titrari_download) blk: {
        var scraper = subdl.titrari_ro.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (subs_sab_download) blk: {
        var scraper = subdl.subs_sab_bz.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (animekalesi_download) blk: {
        var scraper = subdl.animekalesi_com.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (animesub_download) blk: {
        var scraper = subdl.animesub_info.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (animetosho_download) blk: {
        var scraper = subdl.animetosho_xyz.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (subhd_download) blk: {
        var scraper = subdl.subhd_tv.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (fansubs_download) blk: {
        var scraper = subdl.fansubs_ru.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (grupahatak_download) blk: {
        var scraper = subdl.grupahatak_pl.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (subs4free_download) blk: {
        var scraper = subdl.subs4free_info.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (tsukihime_download) blk: {
        var scraper = subdl.tsukihime_org.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (subsource_details_path) |details_path| blk: {
        var scraper = subdl.subsource_net.Scraper.init(allocator, client);
        break :blk try scraper.fetchDownloadByDetailsPathWithOptions(allocator, details_path, .{
            .auto_cloudflare_session = true,
        });
    } else try fetchDownloadBytes(client, allocator, url);
    defer allocator.free(response.body);
    if (response.status != .ok) return error.UnexpectedHttpStatus;
    const body = response.body;
    try validateSubtitleDownloadBody(allocator, body);
    const bytes_written = body.len;

    const preferred_name = try preferredSubtitleDownloadName(allocator, subtitle, url);
    defer allocator.free(preferred_name);
    const archive_kind = detectArchiveKind(preferred_name, url, body);
    const raw_name = try ensureFilenameExtension(allocator, preferred_name, url, archive_kind, ".srt");
    defer allocator.free(raw_name);

    emitDownloadPhase(progress, .writing_output);
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), out_dir);
    const safe_name = try sanitizeFilename(allocator, raw_name);
    defer allocator.free(safe_name);

    const output_path = try publishUniqueFile(allocator, out_dir, safe_name, body);
    errdefer allocator.free(output_path);

    if (archive_kind == .none) {
        return .{
            .file_path = output_path,
            .bytes_written = bytes_written,
            .source_url = owned_source,
        };
    }

    const archive_copy = try allocator.dupe(u8, output_path);
    errdefer allocator.free(archive_copy);

    if (!options.extract_archive or archive_kind == .seven_z or !unarr.enabled) {
        return .{
            .file_path = output_path,
            .archive_path = archive_copy,
            .extraction_unavailable = options.extract_archive,
            .bytes_written = bytes_written,
            .source_url = owned_source,
        };
    }

    emitDownloadPhase(progress, .extracting_archive);
    const extracted_files = try extractArchiveFiles(allocator, body, archive_kind, out_dir, output_path);
    errdefer {
        for (extracted_files) |path| allocator.free(path);
        allocator.free(extracted_files);
    }

    return .{
        .file_path = output_path,
        .archive_path = archive_copy,
        .extracted_files = extracted_files,
        .bytes_written = bytes_written,
        .source_url = owned_source,
    };
}

fn emitDownloadPhase(progress: ?*const DownloadProgress, phase: DownloadPhase) void {
    const p = progress orelse return;
    if (p.on_phase) |f| f(p.user_data, phase);
}

fn emitDownloadUnits(progress: ?*const DownloadProgress, done: usize, total: usize) void {
    const p = progress orelse return;
    if (p.on_units) |f| f(p.user_data, done, total);
}

const SubtitlecatTranslateToken = struct {
    source_url: []u8,
    target_lang: []u8,
    filename: []u8,

    fn deinit(self: SubtitlecatTranslateToken, allocator: Allocator) void {
        allocator.free(self.source_url);
        allocator.free(self.target_lang);
        allocator.free(self.filename);
    }
};

/// Subtitlecat can expose translated subtitles without a direct file URL. The
/// token is an internal pseudo-URL that carries enough data for the download
/// step to fetch the source subtitle and translate it before writing a file.
fn makeSubtitlecatTranslateToken(
    allocator: Allocator,
    source_url: []const u8,
    target_lang: []const u8,
    filename: []const u8,
) ![]const u8 {
    const source_encoded = try common.encodeUriComponent(allocator, source_url);
    defer allocator.free(source_encoded);
    const target_encoded = try common.encodeUriComponent(allocator, target_lang);
    defer allocator.free(target_encoded);
    const name_encoded = try common.encodeUriComponent(allocator, filename);
    defer allocator.free(name_encoded);

    return try std.fmt.allocPrint(
        allocator,
        "{s}source={s}&tl={s}&name={s}",
        .{ subtitlecat_translate_prefix, source_encoded, target_encoded, name_encoded },
    );
}

fn parseSubtitlecatTranslateToken(allocator: Allocator, download_url: []const u8) !?SubtitlecatTranslateToken {
    if (!std.mem.startsWith(u8, download_url, subtitlecat_translate_prefix)) return null;

    const payload = download_url[subtitlecat_translate_prefix.len..];
    if (payload.len == 0) return error.InvalidDownloadUrl;

    var source_url: ?[]u8 = null;
    errdefer if (source_url) |v| allocator.free(v);
    var target_lang: ?[]u8 = null;
    errdefer if (target_lang) |v| allocator.free(v);
    var filename: ?[]u8 = null;
    errdefer if (filename) |v| allocator.free(v);

    var it = std.mem.splitScalar(u8, payload, '&');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        const value = entry[eq + 1 ..];
        const decoded = try decodeUriComponent(allocator, value);
        errdefer allocator.free(decoded);

        if (std.mem.eql(u8, key, "source")) {
            if (source_url) |old| allocator.free(old);
            source_url = decoded;
        } else if (std.mem.eql(u8, key, "tl")) {
            if (target_lang) |old| allocator.free(old);
            target_lang = decoded;
        } else if (std.mem.eql(u8, key, "name")) {
            if (filename) |old| allocator.free(old);
            filename = decoded;
        } else {
            allocator.free(decoded);
        }
    }

    if (source_url == null) return error.InvalidDownloadUrl;
    if (target_lang == null) target_lang = try allocator.dupe(u8, "");
    if (filename == null) filename = try allocator.dupe(u8, "translated.srt");

    return .{
        .source_url = source_url.?,
        .target_lang = target_lang.?,
        .filename = filename.?,
    };
}

fn decodeUriComponent(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        if (ch == '+') {
            try out.append(allocator, ' ');
            continue;
        }
        if (ch == '%') {
            if (i + 2 >= value.len) return error.InvalidField;
            const hi = try fromHexDigit(value[i + 1]);
            const lo = try fromHexDigit(value[i + 2]);
            try out.append(allocator, @as(u8, (hi << 4) | lo));
            i += 2;
            continue;
        }
        try out.append(allocator, ch);
    }

    return try out.toOwnedSlice(allocator);
}

fn fromHexDigit(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => 10 + ch - 'a',
        'A'...'F' => 10 + ch - 'A',
        else => error.InvalidField,
    };
}

const SubtitlecatBatch = struct {
    text: []u8,
    indices: []usize,
};

const subtitlecat_batch_separator = "\n__SUBDL_LINE_BREAK_9F3A__\n";

fn downloadSubtitlecatTranslated(
    allocator: Allocator,
    client: *std.http.Client,
    subtitle: SubtitleChoice,
    out_dir: []const u8,
    source_token: []const u8,
    token: SubtitlecatTranslateToken,
    progress: ?*const DownloadProgress,
) !DownloadResult {
    const owned_source = try allocator.dupe(u8, source_token);
    errdefer allocator.free(owned_source);
    emitDownloadPhase(progress, .fetching_source);
    const source_response = try common.fetchBytes(client, allocator, token.source_url, .{
        .accept = "text/plain,*/*",
        .allow_non_ok = true,
        .max_attempts = 2,
        .retry_on_429 = false,
        .cache = false,
        .require_public_origin = true,
    });
    defer allocator.free(source_response.body);
    try requireSubtitlecatSourceStatus(source_response.status);
    try validateSubtitleDownloadBody(allocator, source_response.body);

    const target_lang = languageToGoogleCode(token.target_lang) orelse "";

    var translation_incomplete = target_lang.len == 0;
    emitDownloadPhase(progress, .translating);
    const translated_text = if (target_lang.len > 0)
        translateSubtitlecatSrt(allocator, client, source_response.body, target_lang, progress, &translation_incomplete) catch |err| blk: {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            translation_incomplete = true;
            break :blk try allocator.dupe(u8, source_response.body);
        }
    else
        try allocator.dupe(u8, source_response.body);
    defer allocator.free(translated_text);

    emitDownloadPhase(progress, .writing_output);
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), out_dir);
    const preferred_name = try preferredSubtitleDownloadName(allocator, subtitle, token.source_url);
    defer allocator.free(preferred_name);
    const raw_name = try ensureFilenameExtension(allocator, preferred_name, token.source_url, .none, ".srt");
    defer allocator.free(raw_name);
    const safe_name = try sanitizeFilename(allocator, raw_name);
    defer allocator.free(safe_name);

    const output_path = try publishUniqueFile(allocator, out_dir, safe_name, translated_text);
    errdefer allocator.free(output_path);

    return .{
        .file_path = output_path,
        .bytes_written = translated_text.len,
        .translation_incomplete = translation_incomplete,
        .source_url = owned_source,
    };
}

fn requireSubtitlecatSourceStatus(status: std.http.Status) !void {
    if (status == .too_many_requests) return error.RateLimited;
    if (status != .ok) return error.UnexpectedHttpStatus;
}

fn languageToGoogleCode(input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (common.normalizeLanguageCode(trimmed)) |normalized| {
        if (std.mem.eql(u8, normalized, "pt-br")) return "pt";
        if (std.mem.eql(u8, normalized, "zh-tw")) return "zh-TW";
        return normalized;
    }

    var valid = true;
    for (trimmed) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            ch == '-' or
            ch == '_';
        if (!ok) {
            valid = false;
            break;
        }
    }
    if (valid and trimmed.len <= 16) return trimmed;
    return null;
}

fn translateSubtitlecatSrt(
    allocator: Allocator,
    client: *std.http.Client,
    source: []const u8,
    target_lang: []const u8,
    progress: ?*const DownloadProgress,
    incomplete: *bool,
) ![]u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, source, '\n');
    while (line_it.next()) |line| {
        try lines.append(allocator, line);
    }

    var translated: std.ArrayListUnmanaged(?[]u8) = .empty;
    defer {
        for (translated.items) |entry| {
            if (entry) |line| allocator.free(line);
        }
        translated.deinit(allocator);
    }
    try translated.resize(allocator, lines.items.len);
    @memset(translated.items, null);

    const total_units = countTranslatableLines(lines.items);
    emitDownloadUnits(progress, 0, total_units);
    var done_units: usize = 0;

    var batch_text: std.ArrayListUnmanaged(u8) = .empty;
    defer batch_text.deinit(allocator);
    var batch_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer batch_indices.deinit(allocator);
    // Keep requests below common URL limits while avoiding hundreds of tiny
    // requests for a feature-length subtitle file.
    const batch_limit: usize = 4000;

    for (lines.items, 0..) |line, idx| {
        if (!shouldTranslateSubtitleLine(line)) {
            translated.items[idx] = try allocator.dupe(u8, line);
            continue;
        }

        const sanitized = try sanitizeSubtitlecatTranslateLine(allocator, line);
        defer allocator.free(sanitized);

        const extra_len = sanitized.len + @as(usize, if (batch_indices.items.len > 0) subtitlecat_batch_separator.len else 0);
        if (batch_indices.items.len > 0 and batch_text.items.len + extra_len > batch_limit) {
            const owned_text = try batch_text.toOwnedSlice(allocator);
            defer allocator.free(owned_text);
            const owned_indices = try batch_indices.toOwnedSlice(allocator);
            defer allocator.free(owned_indices);
            const batch = SubtitlecatBatch{ .text = owned_text, .indices = owned_indices };
            batch_text.clearRetainingCapacity();
            batch_indices.clearRetainingCapacity();
            try applySubtitlecatBatch(allocator, client, lines.items, translated.items, batch, target_lang, progress, &done_units, total_units, incomplete);
        }

        if (batch_indices.items.len > 0) try batch_text.appendSlice(allocator, subtitlecat_batch_separator);
        try batch_text.appendSlice(allocator, sanitized);
        try batch_indices.append(allocator, idx);
    }

    if (batch_indices.items.len > 0) {
        const owned_text = try batch_text.toOwnedSlice(allocator);
        defer allocator.free(owned_text);
        const owned_indices = try batch_indices.toOwnedSlice(allocator);
        defer allocator.free(owned_indices);
        const batch = SubtitlecatBatch{ .text = owned_text, .indices = owned_indices };
        try applySubtitlecatBatch(allocator, client, lines.items, translated.items, batch, target_lang, progress, &done_units, total_units, incomplete);
    }

    emitDownloadUnits(progress, total_units, total_units);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    for (translated.items, 0..) |entry, idx| {
        const text = if (entry) |line| line else lines.items[idx];
        try output.appendSlice(allocator, text);
        if (idx + 1 < translated.items.len) try output.append(allocator, '\n');
    }

    return try output.toOwnedSlice(allocator);
}

fn applySubtitlecatBatch(
    allocator: Allocator,
    client: *std.http.Client,
    source_lines: []const []const u8,
    translated_lines: []?[]u8,
    batch: SubtitlecatBatch,
    target_lang: []const u8,
    progress: ?*const DownloadProgress,
    done_units: *usize,
    total_units: usize,
    incomplete: *bool,
) !void {
    const translated_batch = translateViaGoogle(allocator, client, batch.text, target_lang) catch |err| blk: {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        break :blk null;
    };
    if (translated_batch) |batch_text| {
        defer allocator.free(batch_text);
        var out_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer out_lines.deinit(allocator);

        var line_it = std.mem.splitSequence(u8, batch_text, subtitlecat_batch_separator);
        while (line_it.next()) |line| try out_lines.append(allocator, line);

        if (out_lines.items.len == batch.indices.len) {
            try applyTranslatedLines(allocator, source_lines, translated_lines, batch.indices, out_lines.items, incomplete);
            done_units.* += batch.indices.len;
            emitDownloadUnits(progress, done_units.*, total_units);
            return;
        }
    }

    // A provider response can normalize separators. Do not turn that into one
    // network request per subtitle line; preserve the source batch instead.
    incomplete.* = true;
    emitDownloadPhase(progress, .translating_fallback);
    for (batch.indices) |line_idx| {
        const source_line = source_lines[line_idx];
        translated_lines[line_idx] = try allocator.dupe(u8, source_line);
        done_units.* += 1;
        emitDownloadUnits(progress, done_units.*, total_units);
    }
    emitDownloadPhase(progress, .translating);
}

fn countTranslatableLines(lines: []const []const u8) usize {
    var count: usize = 0;
    for (lines) |line| {
        if (shouldTranslateSubtitleLine(line)) count += 1;
    }
    return count;
}

fn shouldTranslateSubtitleLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;

    var numeric = true;
    for (trimmed) |ch| {
        if (ch < '0' or ch > '9') {
            numeric = false;
            break;
        }
    }
    if (numeric) return false;

    if (std.mem.indexOf(u8, trimmed, "-->") != null) return false;
    if (std.mem.eql(u8, trimmed, "WEBVTT")) return false;
    return true;
}

fn sanitizeSubtitlecatTranslateLine(allocator: Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        if (std.ascii.startsWithIgnoreCase(line[i..], "<font")) {
            if (std.mem.indexOfScalarPos(u8, line, i, '>')) |end_idx| {
                i = end_idx + 1;
                continue;
            }
        }
        if (std.ascii.startsWithIgnoreCase(line[i..], "</font>")) {
            i += "</font>".len;
            continue;
        }
        if (line[i] == '&') {
            try out.appendSlice(allocator, "and");
        } else {
            try out.append(allocator, line[i]);
        }
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn translateViaGoogle(
    allocator: Allocator,
    client: *std.http.Client,
    text: []const u8,
    target_lang: []const u8,
) ![]u8 {
    const encoded_q = try common.encodeUriComponent(allocator, text);
    defer allocator.free(encoded_q);
    const encoded_tl = try common.encodeUriComponent(allocator, target_lang);
    defer allocator.free(encoded_tl);

    const payload = try std.fmt.allocPrint(
        allocator,
        "client=gtx&sl=auto&tl={s}&dt=t&q={s}",
        .{ encoded_tl, encoded_q },
    );
    defer allocator.free(payload);

    const response = try common.fetchBytes(client, allocator, "https://translate.googleapis.com/translate_a/single", .{
        .method = .POST,
        .payload = payload,
        .content_type = "application/x-www-form-urlencoded",
        .accept = "application/json,text/plain,*/*",
        .allow_non_ok = true,
        .max_attempts = 2,
    });
    defer allocator.free(response.body);
    if (response.status != .ok) return error.UnexpectedHttpStatus;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    return googleTranslateResultToString(allocator, parsed.value);
}

fn googleTranslateResultToString(allocator: Allocator, value: std.json.Value) ![]u8 {
    if (value != .array) return error.InvalidFieldType;
    const root_items = value.array.items;
    if (root_items.len == 0) return error.InvalidField;
    if (root_items[0] != .array) return error.InvalidFieldType;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (root_items[0].array.items) |part| {
        if (part != .array) return error.InvalidFieldType;
        if (part.array.items.len == 0) return error.InvalidField;
        if (part.array.items[0] != .string) return error.InvalidFieldType;
        if (std.mem.trim(u8, part.array.items[0].string, " \t\r\n").len == 0) {
            if (part.array.items.len < 2 or part.array.items[1] != .string or
                std.mem.trim(u8, part.array.items[1].string, " \t\r\n").len != 0) return error.InvalidField;
        }
        try out.appendSlice(allocator, part.array.items[0].string);
    }

    if (std.mem.trim(u8, out.items, " \t\r\n").len == 0) return error.InvalidField;
    return try out.toOwnedSlice(allocator);
}

/// Some providers publish an intermediate download page instead of the final
/// archive URL. Resolve only the known cases here; all other URLs are treated
/// as already-downloadable.
fn resolveDownloadUrlIfNeeded(allocator: Allocator, client: *std.http.Client, download_url: []const u8) ![]const u8 {
    if (parseOpenSubtitlesRemoteToken(download_url)) |remote_endpoint| {
        var scraper = subdl.opensubtitles_com.Scraper.init(allocator, client);
        if (try scraper.resolveVerifiedDownloadUrl(allocator, remote_endpoint)) |resolved| return resolved;
        return error.InvalidDownloadUrl;
    }

    if (std.mem.indexOf(u8, download_url, "my-subs.co/downloads/") != null) {
        var scraper = subdl.my_subs_co.Scraper.init(allocator, client);
        return scraper.resolveDownloadPageUrl(allocator, download_url);
    }

    if (std.mem.indexOf(u8, download_url, "tvsubtitles.net/download-") != null) {
        var scraper = subdl.tvsubtitles_net.Scraper.init(allocator, client);
        return scraper.resolveDownloadPageUrl(allocator, download_url);
    }

    return allocator.dupe(u8, download_url);
}

/// Download fetch has provider-specific recovery hooks because several sites
/// accept normal search requests but protect binary/archive endpoints.
fn fetchDownloadBytes(client: *std.http.Client, allocator: Allocator, url: []const u8) !common.HttpResponse {
    const download_referer = downloadRefererForUrl(url);
    const max_attempts: usize = if (std.mem.indexOf(u8, url, "://subsunacs.net/") != null) 4 else 2;
    const provider_headers = if (download_referer) |referer|
        &[_]std.http.Header{.{ .name = "referer", .value = referer }}
    else
        &[_]std.http.Header{};

    const primary = try common.fetchBytes(client, allocator, url, .{
        .accept = "*/*",
        .extra_headers = provider_headers,
        .cache = false,
        .allow_non_ok = true,
        .max_attempts = max_attempts,
        .retry_on_429 = false,
        .require_public_origin = true,
    });

    const target = cloudflareTargetForUrl(url);
    const was_challenge = cf.isChallengeBody(primary.body);
    const was_rate_limited = primary.status == .too_many_requests;
    if (primary.status == .ok and !was_challenge) return primary;
    allocator.free(primary.body);

    if (was_rate_limited) return error.RateLimited;
    if (was_challenge) {
        if (target) |cf_target| {
            const with_cf = try fetchBytesWithCloudflareSession(client, allocator, url, cf_target.domain, cf_target.challenge_url, "*/*", download_referer);
            const still_challenged = isOpenSubtitlesChallengeResponse(with_cf.status, with_cf.body);
            if (with_cf.status == .ok and !still_challenged) return with_cf;
            const retry_rate_limited = with_cf.status == .too_many_requests;
            allocator.free(with_cf.body);
            if (retry_rate_limited) return error.RateLimited;
            if (still_challenged) return error.CloudflareChallenge;
            if (with_cf.status == .forbidden) return error.ProviderAccessBlocked;
            return error.UnexpectedHttpStatus;
        }
        return error.CloudflareChallenge;
    }

    if (primary.status == .forbidden) return error.ProviderAccessBlocked;
    return error.UnexpectedHttpStatus;
}

fn downloadRefererForUrl(url: []const u8) ?[]const u8 {
    if (yifyRefererForUrl(url)) |referer| return referer;
    if (std.mem.indexOf(u8, url, "://napisy24.pl/run/pages/download.php") != null) {
        return "https://napisy24.pl/";
    }
    return null;
}

const CloudflareTarget = struct {
    domain: []const u8,
    challenge_url: []const u8,
};

const opensubtitles_session_root = "https://www.opensubtitles.com/";

fn cloudflareTargetForUrl(url: []const u8) ?CloudflareTarget {
    if (isOpenSubtitlesSessionUrl(url)) {
        return .{
            .domain = "www.opensubtitles.com",
            .challenge_url = url,
        };
    }

    return null;
}

fn isOpenSubtitlesChallengeResponse(_: std.http.Status, body: []const u8) bool {
    return cf.isChallengeBody(body);
}

fn isOpenSubtitlesSessionUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    if (uri.user != null or uri.password != null) return false;
    if (uri.port) |port| if (port != 443) return false;
    const host = uri.host orelse return false;
    const host_bytes = switch (host) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    return std.ascii.eqlIgnoreCase(host_bytes, "www.opensubtitles.com");
}

fn yifyRefererForUrl(url: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, url, "://yifysubtitles.ch/") != null) {
        return "https://yifysubtitles.ch/";
    }
    return null;
}

fn fetchBytesWithCloudflareSession(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    domain: []const u8,
    challenge_url: []const u8,
    accept: []const u8,
    referer: ?[]const u8,
) !common.HttpResponse {
    if (!isOpenSubtitlesSessionUrl(url) or !std.ascii.eqlIgnoreCase(domain, "www.opensubtitles.com") or !isOpenSubtitlesSessionUrl(challenge_url)) return error.InvalidDownloadUrl;
    var session = try cf.ensureDomainSession(allocator, .{
        .domain = domain,
        .challenge_url = challenge_url,
    });
    defer session.deinit(allocator);

    const first = try fetchBytesUsingSession(client, allocator, url, accept, referer, session);
    if (first.status == .too_many_requests or !isOpenSubtitlesChallengeResponse(first.status, first.body)) return first;
    allocator.free(first.body);

    var refreshed = try cf.ensureDomainSession(allocator, .{
        .domain = domain,
        .challenge_url = challenge_url,
        .force_refresh = true,
        .rejected_generation = session.generation,
    });
    defer refreshed.deinit(allocator);
    return fetchBytesUsingSession(client, allocator, url, accept, referer, refreshed);
}

fn fetchBytesUsingSession(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    accept: []const u8,
    referer: ?[]const u8,
    session: cf.Session,
) !common.HttpResponse {
    return fetchBytesUsingSessionWith(common.fetchBytes, client, allocator, url, accept, referer, session);
}

fn fetchBytesUsingSessionWith(
    comptime fetch: anytype,
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    accept: []const u8,
    referer: ?[]const u8,
    session: cf.Session,
) !common.HttpResponse {
    // Recheck the destination at the boundary that attaches private cookies.
    if (!isOpenSubtitlesSessionUrl(url)) return error.InvalidDownloadUrl;
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    // Redirects on the same origin reuse this static header, so select only
    // cookies that are valid for every path on the OpenSubtitles origin.
    const cookie_header = (try session.cookieHeaderForUrl(allocator, opensubtitles_session_root)) orelse
        return error.CloudflareSessionUnavailable;
    defer allocator.free(cookie_header);
    const clearance = cookieHeaderValue(cookie_header, "cf_clearance") orelse
        return error.CloudflareSessionUnavailable;
    if (session.cf_clearance.len == 0 or !std.mem.eql(u8, clearance, session.cf_clearance))
        return error.CloudflareSessionUnavailable;
    try headers.append(allocator, .{ .name = "cookie", .value = cookie_header });
    try headers.append(allocator, .{ .name = "user-agent", .value = session.user_agent });
    if (referer) |value| {
        try headers.append(allocator, .{ .name = "referer", .value = value });
    }

    return fetch(client, allocator, url, .{
        .accept = accept,
        .extra_headers = headers.items,
        .allow_non_ok = true,
        .max_attempts = 2,
        .retry_on_429 = false,
        .cache = false,
        .require_public_origin = true,
        .require_https = true,
    });
}

fn cookieHeaderValue(header: []const u8, wanted_name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, header, ';');
    while (pairs.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t");
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = std.mem.trim(u8, pair[0..equals], " \t");
        if (!std.mem.eql(u8, name, wanted_name)) continue;
        return std.mem.trim(u8, pair[equals + 1 ..], " \t");
    }
    return null;
}

const ArchiveKind = enum {
    none,
    zip,
    rar,
    seven_z,
};

fn validateSubtitleDownloadBody(allocator: Allocator, body: []const u8) !void {
    if (cf.isChallengeBody(body)) return error.CloudflareChallenge;
    if (body.len >= 2 and (std.mem.eql(u8, body[0..2], "\xFF\xFE") or std.mem.eql(u8, body[0..2], "\xFE\xFF"))) {
        if (body.len % 2 != 0) return error.InvalidDownloadPayload;
        // Only ASCII structural markers are needed for the UTF-16 probe. Its
        // allocation is bounded by the HTTP body limit; original bytes are saved.
        const probe = try allocator.alloc(u8, (body.len - 2) / 2);
        defer allocator.free(probe);
        const little_endian = body[0] == 0xFF;
        for (probe, 0..) |*byte, i| {
            const pair = body[2 + i * 2 ..][0..2];
            const low = pair[if (little_endian) 0 else 1];
            const high = pair[if (little_endian) 1 else 0];
            byte.* = if (high == 0 and low < 128) low else '?';
        }
        return validateSubtitleDownloadBody(allocator, probe);
    }
    var text = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = std.mem.trim(u8, text[3..], " \t\r\n");
    if (text.len == 0) return error.InvalidDownloadPayload;
    if (detectArchiveKind("", "", body) != .none) return;
    // Binary subtitle formats supported by the file picker.
    if (body.len >= 13 and std.mem.eql(u8, body[0..2], "PG")) return;
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "\x00\x00\x01\xBA")) return;
    if (common.isAustralianWebsiteBlockPage(text)) return error.ProviderAccessBlocked;
    var head = text[0..@min(text.len, 4096)];
    while (std.mem.startsWith(u8, head, "<!--")) {
        const end = std.mem.indexOf(u8, head, "-->") orelse return error.InvalidDownloadPayload;
        head = std.mem.trimStart(u8, head[end + 3 ..], " \t\r\n");
    }
    if (head.len == 0) return error.InvalidDownloadPayload;
    const sami = std.ascii.indexOfIgnoreCase(head, "<sami") != null and
        std.ascii.indexOfIgnoreCase(text, "<sync") != null;
    const ttml = std.ascii.indexOfIgnoreCase(head, "<tt") != null and
        std.ascii.indexOfIgnoreCase(text, "<p") != null and
        std.ascii.indexOfIgnoreCase(text, "begin=") != null;
    const vobsub_index = std.ascii.indexOfIgnoreCase(head, "vobsub index file") != null and
        std.ascii.indexOfIgnoreCase(text, "timestamp:") != null and
        std.ascii.indexOfIgnoreCase(text, "filepos:") != null;
    if (sami or ttml or vobsub_index) return;
    for ([_][]const u8{ "<!doctype html", "<html", "<head", "<body", "<title", "<script", "<form", "<div", "<meta" }) |tag| {
        if (std.ascii.startsWithIgnoreCase(head, tag)) return error.InvalidDownloadPayload;
    }
    // JSON objects and object/string arrays are API responses, not subtitles.
    // Keep bracketed ASS sections and frame-based SUB cues valid.
    if (text[0] == '{' or text[0] == '[') {
        const following = std.mem.trimStart(u8, text[1..], " \t\r\n");
        if (following.len > 0 and (following[0] == '"' or following[0] == '}' or following[0] == ']' or (text[0] == '[' and following[0] == '{'))) return error.InvalidDownloadPayload;
    }
    if (tmPlayerSubtitleBody(text)) return;
    var ass_events = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.ascii.eqlIgnoreCase(line, "[Events]")) ass_events = true;
        if (ass_events and std.ascii.startsWithIgnoreCase(line, "Dialogue:") and std.mem.count(u8, line, ",") >= 8) {
            var fields = std.mem.splitScalar(u8, line["Dialogue:".len..], ',');
            _ = fields.next() orelse continue;
            const start = std.mem.trim(u8, fields.next() orelse continue, " \t");
            const end = std.mem.trim(u8, fields.next() orelse continue, " \t");
            if (subtitleTimestamp(start) and subtitleTimestamp(end)) return;
        }
        if (subtitleTimingLine(line, "-->")) return;
        if (subtitleTimingLine(line, ",")) return;
        if (subtitleFrameLine(line, '{', '}') or subtitleFrameLine(line, '[', ']')) return;
    }
    return error.InvalidDownloadPayload;
}

fn tmPlayerSubtitleBody(text: []const u8) bool {
    const max_body_bytes = 1024 * 1024;
    const max_body_lines = 20_000;
    if (text.len > max_body_bytes) return false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var cue_count: usize = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (cue_count == max_body_lines) return false;
        if (!tmPlayerCueLine(line)) return false;
        cue_count += 1;
    }
    return cue_count != 0;
}

fn tmPlayerCueLine(line: []const u8) bool {
    if (line.len <= 9 or line[2] != ':' or line[5] != ':' or line[8] != ':') return false;
    if (!subtitleDigits(line[0..2]) or !subtitleDigits(line[3..5]) or !subtitleDigits(line[6..8])) return false;
    const minutes = std.fmt.parseUnsigned(u8, line[3..5], 10) catch return false;
    const seconds = std.fmt.parseUnsigned(u8, line[6..8], 10) catch return false;
    if (minutes >= 60 or seconds >= 60) return false;
    return std.mem.trim(u8, line[9..], " \t\r").len != 0;
}

fn subtitleDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn subtitleTimestamp(text: []const u8) bool {
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var split = std.mem.splitScalar(u8, text, ':');
    while (split.next()) |part| {
        if (count == parts.len) return false;
        parts[count] = part;
        count += 1;
    }
    if (count < 2 or !subtitleDigits(parts[0])) return false;
    if (count == 3 and (parts[1].len != 2 or !subtitleDigits(parts[1]) or (std.fmt.parseUnsigned(u8, parts[1], 10) catch return false) >= 60)) return false;
    const seconds = parts[count - 1];
    const decimal = std.mem.indexOfAny(u8, seconds, ".,") orelse return false;
    if (decimal != 2 or !subtitleDigits(seconds[0..decimal]) or (std.fmt.parseUnsigned(u8, seconds[0..decimal], 10) catch return false) >= 60) return false;
    return subtitleDigits(seconds[decimal + 1 ..]);
}

fn subtitleTimingLine(line: []const u8, separator: []const u8) bool {
    const divider = std.mem.indexOf(u8, line, separator) orelse return false;
    const left = std.mem.trim(u8, line[0..divider], " \t");
    const remaining = std.mem.trimStart(u8, line[divider + separator.len ..], " \t");
    const right = remaining[0 .. std.mem.indexOfAny(u8, remaining, " \t") orelse remaining.len];
    return subtitleTimestamp(left) and subtitleTimestamp(right);
}

fn subtitleFrameLine(line: []const u8, open: u8, close: u8) bool {
    var remaining = line;
    for (0..2) |_| {
        if (remaining.len == 0 or remaining[0] != open) return false;
        const end = std.mem.indexOfScalar(u8, remaining, close) orelse return false;
        if (!subtitleDigits(remaining[1..end])) return false;
        remaining = remaining[end + 1 ..];
    }
    return std.mem.trim(u8, remaining, " \t\r").len != 0;
}

/// Prefer bytes over provider labels; many download endpoints have no extension.
fn detectArchiveKind(file_name: []const u8, url: []const u8, body: []const u8) ArchiveKind {
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "PK\x03\x04")) return .zip;
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "PK\x05\x06")) return .zip;
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "PK\x07\x08")) return .zip;
    if (body.len >= 7 and std.mem.eql(u8, body[0..7], "Rar!\x1A\x07\x00")) return .rar;
    if (body.len >= 8 and std.mem.eql(u8, body[0..8], "Rar!\x1A\x07\x01\x00")) return .rar;
    if (body.len >= 6 and std.mem.eql(u8, body[0..6], "\x37\x7A\xBC\xAF\x27\x1C")) return .seven_z;
    if (std.ascii.endsWithIgnoreCase(file_name, ".zip") or std.ascii.endsWithIgnoreCase(url, ".zip")) return .zip;
    if (std.ascii.endsWithIgnoreCase(file_name, ".rar") or std.ascii.endsWithIgnoreCase(url, ".rar")) return .rar;
    if (std.ascii.endsWithIgnoreCase(file_name, ".7z") or std.ascii.endsWithIgnoreCase(url, ".7z")) return .seven_z;
    return .none;
}

const max_archive_entry_size_bytes: usize = 64 * 1024 * 1024;
const max_archive_entries: usize = 256;

const max_archive_total_size_bytes: usize = 128 * 1024 * 1024;
fn safeArchiveName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/' or name[0] == '\\' or (name.len >= 2 and name[1] == ':')) return false;
    var parts = std.mem.splitAny(u8, name, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}
fn createUniqueDirectory(allocator: Allocator, out_dir: []const u8, base_name: []const u8) ![]u8 {
    for (0..10000) |attempt| {
        const name = if (attempt == 0) try allocator.dupe(u8, base_name) else try appendNumericSuffix(allocator, base_name, attempt);
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ out_dir, name });
        std.Io.Dir.cwd().createDir(runtime_io.get(), path, .default_dir) catch |err| {
            allocator.free(path);
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        return path;
    }
    return error.TooManyOutputCollisions;
}
fn validateZipExtras(bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        if (bytes.len - at < 4) return error.ArchiveExtractionFailed;
        const tag = std.mem.readInt(u16, bytes[at..][0..2], .little);
        const size = std.mem.readInt(u16, bytes[at + 2 ..][0..2], .little);
        if (size > bytes.len - at - 4) return error.ArchiveExtractionFailed;
        if (tag == 1) return error.ArchiveMetadataUnsupported;
        at += 4 + @as(usize, size);
    }
}
fn canonicalZipBody(body: []const u8) ![]const u8 {
    // Some download endpoints append harmless template whitespace after EOCD.
    // Pass the same exact validated archive boundary to the native decoder.
    if (body.len < 22) return error.ArchiveExtractionFailed;
    var footer = body.len - 22;
    while (true) {
        if (std.mem.eql(u8, body[footer..][0..4], "PK\x05\x06")) {
            const end = footer + 22 + @as(usize, std.mem.readInt(u16, body[footer + 20 ..][0..2], .little));
            if (end <= body.len and body.len - end <= 4096 and std.mem.trim(u8, body[end..], " \t\r\n").len == 0) return body[0..end];
        }
        if (footer == 0 or body.len - footer > 65557 + 4096) return error.ArchiveExtractionFailed;
        footer -= 1;
    }
}
fn preflightZip(body: []const u8) !void {
    if (body.len < 22) return error.ArchiveExtractionFailed;
    var footer: usize = body.len - 22;
    while (true) {
        if (std.mem.eql(u8, body[footer..][0..4], "PK\x05\x06") and std.mem.readInt(u16, body[footer + 20 ..][0..2], .little) == body.len - footer - 22) break;
        if (footer == 0 or body.len - footer > 65557) return error.ArchiveExtractionFailed;
        footer -= 1;
    }
    if (std.mem.indexOf(u8, body[footer + 4 .. body.len - 18], "PK\x05\x06") != null) return error.ArchiveMetadataUnsupported;
    const end = body[footer..];
    if (std.mem.readInt(u16, end[4..6], .little) != 0 or std.mem.readInt(u16, end[6..8], .little) != 0) return error.ArchiveMetadataUnsupported;
    const count = std.mem.readInt(u16, end[10..12], .little);
    if (count > max_archive_entries) return error.ArchiveEntryLimit;
    if (std.mem.readInt(u16, end[8..10], .little) != count) return error.ArchiveExtractionFailed;
    const size = std.mem.readInt(u32, end[12..16], .little);
    var offset: usize = std.mem.readInt(u32, end[16..20], .little);
    if (offset > footer or size != footer - offset) return error.ArchiveExtractionFailed;
    const central_start = offset;
    var total: u64 = 0;
    for (0..count) |_| {
        if (offset > footer or footer - offset < 46 or !std.mem.eql(u8, body[offset..][0..4], "PK\x01\x02")) return error.ArchiveExtractionFailed;
        const record = body[offset..];
        const unpacked = std.mem.readInt(u32, record[24..28], .little);
        const compressed_size = std.mem.readInt(u32, record[20..24], .little);
        const flags = std.mem.readInt(u16, record[8..10], .little);
        const method = std.mem.readInt(u16, record[10..12], .little);
        if (compressed_size == std.math.maxInt(u32) or unpacked == std.math.maxInt(u32) or std.mem.readInt(u16, record[34..36], .little) != 0) return error.ArchiveMetadataUnsupported;
        if (flags & 1 != 0) return error.ArchiveEncrypted;
        if (method != 0 and method != 8) return error.ArchiveMetadataUnsupported;
        if (method == 0 and compressed_size != unpacked) return error.ArchiveExtractionFailed;

        if (unpacked > max_archive_entry_size_bytes) return error.ArchiveEntryTooLarge;
        total += unpacked;
        if (total > max_archive_total_size_bytes) return error.ArchiveTooLarge;
        const name_len = std.mem.readInt(u16, record[28..30], .little);
        const record_len: usize = 46 + @as(usize, name_len) + std.mem.readInt(u16, record[30..32], .little) + std.mem.readInt(u16, record[32..34], .little);
        if (record_len > footer - offset) return error.ArchiveExtractionFailed;
        const name = record[46..][0..name_len];
        try validateZipExtras(record[46 + @as(usize, name_len) ..][0..std.mem.readInt(u16, record[30..32], .little)]);
        if (!safeArchiveName(name) or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidArchivePath;
        const local_offset: usize = std.mem.readInt(u32, record[42..46], .little);
        if (local_offset > offset or offset - local_offset < 30 or !std.mem.eql(u8, body[local_offset..][0..4], "PK\x03\x04")) return error.ArchiveExtractionFailed;
        const local = body[local_offset..];
        const local_name_len = std.mem.readInt(u16, local[26..28], .little);
        const local_extra_len = std.mem.readInt(u16, local[28..30], .little);
        const local_len: usize = 30 + @as(usize, local_name_len) + local_extra_len;
        if (local_offset > central_start or local_len > central_start - local_offset or compressed_size > central_start - local_offset - local_len) return error.ArchiveExtractionFailed;
        if (!std.mem.eql(u8, name, local[30..][0..local_name_len]) or std.mem.readInt(u16, local[8..10], .little) != method or std.mem.readInt(u16, local[6..8], .little) != flags) return error.ArchiveExtractionFailed;
        try validateZipExtras(local[30 + @as(usize, local_name_len) ..][0..local_extra_len]);
        if (flags & 8 == 0 and (std.mem.readInt(u32, local[14..18], .little) != std.mem.readInt(u32, record[16..20], .little) or std.mem.readInt(u32, local[18..22], .little) != compressed_size or std.mem.readInt(u32, local[22..26], .little) != unpacked)) return error.ArchiveExtractionFailed;
        offset += record_len;
    }
    if (offset != footer) return error.ArchiveExtractionFailed;
}
fn publishExtractedDirectory(allocator: Allocator, out_dir: []const u8, base_name: []const u8, staging: []const u8, paths: []const []const u8) ![]const []const u8 {
    for (0..10000) |attempt| {
        const name = if (attempt == 0) try allocator.dupe(u8, base_name) else try appendNumericSuffix(allocator, base_name, attempt);
        defer allocator.free(name);
        const target = try std.fs.path.join(allocator, &.{ out_dir, name });
        defer allocator.free(target);
        const mapped = try allocator.alloc([]const u8, paths.len);
        var initialized: usize = 0;
        var transferred = false;
        defer if (!transferred) {
            for (mapped[0..initialized]) |path| allocator.free(path);
            allocator.free(mapped);
        };
        for (paths, 0..) |path, i| {
            mapped[i] = try std.fs.path.join(allocator, &.{ target, common.pathBaseName(path) });
            initialized += 1;
        }
        try runtime_io.get().checkCancel();
        std.Io.Dir.cwd().renamePreserve(staging, .cwd(), target, runtime_io.get()) catch |err| {
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        transferred = true;
        return mapped;
    }
    return error.TooManyOutputCollisions;
}

fn extractArchiveFiles(allocator: Allocator, archive_body: []const u8, archive_kind: ArchiveKind, out_dir: []const u8, archive_path: []const u8) ![]const []const u8 {
    if (comptime !unarr.enabled) return error.ArchiveExtractionUnavailable;
    const bounded_body = if (archive_kind == .zip) try canonicalZipBody(archive_body) else archive_body;
    if (archive_kind == .zip) try preflightZip(bounded_body);
    // The native 7z decoder allocates encoded headers before exposing entries.
    // Keep the downloaded archive, but do not run that unbounded decoder here.
    if (archive_kind == .seven_z) return error.ArchiveFormatNeedsExternalExtraction;
    const format: unarr.Format = switch (archive_kind) {
        .zip => .zip,
        .rar => .rar,
        .seven_z => .@"7z",
        .none => return error.ArchiveExtractionFailed,
    };
    // Preflight the entire declared inventory before native decompression, disk
    // publication or allocation of any entry buffer.
    var inventory = unarr.Archive.openMemory(format, bounded_body, .{}) catch return error.ArchiveExtractionFailed;
    var inventory_open = true;
    defer if (inventory_open) inventory.deinit();
    var entry_count: usize = 0;
    var total: usize = 0;
    while (inventory.nextEntry() catch return error.ArchiveExtractionFailed) |entry| {
        try runtime_io.get().checkCancel();
        entry_count += 1;
        if (entry_count > max_archive_entries) return error.ArchiveEntryLimit;
        const name = entry.name() orelse entry.rawName() orelse return error.InvalidArchivePath;
        if (!safeArchiveName(name)) return error.InvalidArchivePath;
        if (entry.size() > max_archive_entry_size_bytes) return error.ArchiveEntryTooLarge;
        total = std.math.add(usize, total, entry.size()) catch return error.ArchiveTooLarge;
        if (total > max_archive_total_size_bytes) return error.ArchiveTooLarge;
    }
    if (total == 0) return error.ArchiveExtractionFailed;
    inventory.deinit();
    inventory_open = false;
    var archive = unarr.Archive.openMemory(format, bounded_body, .{}) catch return error.ArchiveExtractionFailed;
    defer archive.deinit();
    const directory_name = try extractionDirBaseName(allocator, archive_path);
    defer allocator.free(directory_name);
    const directory = try createUniqueDirectory(allocator, out_dir, ".scrapers-extract-staging");
    defer allocator.free(directory);
    var staging_owned = true;
    defer if (staging_owned) {
        const protection = runtime_io.get().swapCancelProtection(.blocked);
        defer _ = runtime_io.get().swapCancelProtection(protection);
        std.Io.Dir.cwd().deleteTree(runtime_io.get(), directory) catch {};
    };
    var extracted: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (extracted.items) |path| allocator.free(path);
        extracted.deinit(allocator);
    }
    var index: usize = 0;
    while (archive.nextEntry() catch return error.ArchiveExtractionFailed) |entry| {
        try runtime_io.get().checkCancel();
        index += 1;
        if (index > entry_count) return error.ArchiveExtractionFailed;
        const name = entry.name() orelse entry.rawName() orelse return error.InvalidArchivePath;
        if (entry.size() == 0 or std.mem.endsWith(u8, name, "/") or std.mem.endsWith(u8, name, "\\")) continue;
        const filename = try archiveEntryOutputName(allocator, name, index);
        defer allocator.free(filename);
        const bytes = entry.readAlloc(allocator, max_archive_entry_size_bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.ArchiveExtractionFailed,
        };
        defer allocator.free(bytes);
        try runtime_io.get().checkCancel();
        const path = try publishUniqueFile(allocator, directory, filename, bytes);
        errdefer allocator.free(path);
        try extracted.append(allocator, path);
    }
    if (index != entry_count or extracted.items.len == 0) return error.ArchiveExtractionFailed;
    const published = try publishExtractedDirectory(allocator, out_dir, directory_name, directory, extracted.items);
    staging_owned = false;
    return published;
}

fn extractionDirBaseName(allocator: Allocator, archive_path: []const u8) ![]u8 {
    const base = common.pathBaseName(archive_path);
    const sanitized = try sanitizeFilename(allocator, base);
    defer allocator.free(sanitized);
    const raw_stem = if (std.mem.lastIndexOfScalar(u8, sanitized, '.')) |dot| sanitized[0..dot] else sanitized;
    const stem = std.mem.trim(u8, raw_stem, " .");
    const chosen = if (stem.len == 0) "archive" else stem;
    return try std.fmt.allocPrint(allocator, "{s}.extracted", .{chosen});
}

fn archiveExtractedNameNeedsSanitizing(name: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(name)) return true;

    var i: usize = 0;
    while (i < name.len) {
        const seq_len_raw = std.unicode.utf8ByteSequenceLength(name[i]) catch return true;
        const seq_len: usize = @intCast(seq_len_raw);
        if (i + seq_len > name.len) return true;
        const cp = std.unicode.utf8Decode(name[i .. i + seq_len]) catch return true;
        if (cp == 0xFFFD) return true;
        i += seq_len;
    }
    return false;
}

fn archiveEntryOutputName(allocator: Allocator, entry_name: []const u8, entry_num: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, entry_name, " \t\r\n");
    const leaf = archiveEntryLeafName(trimmed);
    const fallback = if (leaf.len == 0)
        try std.fmt.allocPrint(allocator, "entry-{d}.bin", .{entry_num})
    else
        try allocator.dupe(u8, leaf);
    defer allocator.free(fallback);
    return sanitizeFilename(allocator, fallback);
}

fn archiveEntryLeafName(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    const sep = std.mem.lastIndexOfAny(u8, path, "/\\");
    if (sep) |idx| {
        if (idx + 1 >= path.len) return "";
        return path[idx + 1 ..];
    }
    return path;
}

fn toAbsoluteSubdlLink(allocator: Allocator, link: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://")) {
        return try allocator.dupe(u8, link);
    }
    return try std.fmt.allocPrint(allocator, "https://subdl.com{s}", .{link});
}

fn subtitleLabel(allocator: Allocator, language: ?[]const u8, filename: ?[]const u8, download_url: ?[]const u8) ![]const u8 {
    const language_trimmed = nonEmptyTrimmed(language);
    const filename_trimmed = nonEmptyTrimmed(filename) orelse "Without release";
    if (download_url == null) {
        if (language_trimmed) |lang| {
            return try std.fmt.allocPrint(allocator, "{s} • {s} [no direct download]", .{ lang, filename_trimmed });
        }
        return try std.fmt.allocPrint(allocator, "{s} [no direct download]", .{filename_trimmed});
    }

    if (language_trimmed) |lang| {
        return try std.fmt.allocPrint(allocator, "{s} • {s}", .{ lang, filename_trimmed });
    }
    return try allocator.dupe(u8, filename_trimmed);
}

fn nonEmptyTrimmed(value: ?[]const u8) ?[]const u8 {
    if (value) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn makeOpenSubtitlesRemoteToken(allocator: Allocator, remote_endpoint: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ opensubtitles_remote_prefix, remote_endpoint });
}

fn makeSubsourceRemoteToken(allocator: Allocator, details_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ subsource_remote_prefix, details_path });
}

fn parseSubsourceRemoteToken(download_url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, download_url, subsource_remote_prefix)) return null;
    const path = download_url[subsource_remote_prefix.len..];
    return if (path.len > 0) path else null;
}

fn parseOpenSubtitlesRemoteToken(download_url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, download_url, opensubtitles_remote_prefix)) return null;
    const endpoint = download_url[opensubtitles_remote_prefix.len..];
    if (endpoint.len == 0) return null;
    return endpoint;
}

fn inferFilenameFromUrl(url: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const trimmed = url[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
    if (slash + 1 >= trimmed.len) return null;
    return trimmed[slash + 1 ..];
}

fn preferredSubtitleDownloadName(allocator: Allocator, subtitle: SubtitleChoice, source_url: []const u8) ![]u8 {
    if (nonEmptyTrimmed(subtitle.filename)) |name| {
        if (!isGenericSubtitleFilename(name)) return try allocator.dupe(u8, name);
    }
    if (subtitleNameFromLabel(subtitle.label)) |name| {
        if (!isGenericSubtitleFilename(name)) return try allocator.dupe(u8, name);
    }
    if (inferFilenameFromUrl(source_url)) |name| {
        if (!isGenericSubtitleFilename(name)) return try allocator.dupe(u8, name);
    }
    return try allocator.dupe(u8, "subtitle");
}

fn subtitleNameFromLabel(label: []const u8) ?[]const u8 {
    var text = std.mem.trim(u8, label, " \t\r\n");
    if (std.mem.endsWith(u8, text, "[no direct download]")) {
        text = std.mem.trim(u8, text[0 .. text.len - "[no direct download]".len], " \t\r\n");
    }
    var last = text;
    var it = std.mem.splitScalar(u8, text, '|');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len > 0) last = trimmed;
    }
    if (std.ascii.eqlIgnoreCase(last, "Without release")) return null;
    return if (last.len > 0) last else null;
}

fn isGenericSubtitleFilename(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, common.pathBaseName(name), " \t\r\n.");
    if (trimmed.len == 0) return true;
    const stem = if (std.mem.lastIndexOfScalar(u8, trimmed, '.')) |dot| trimmed[0..dot] else trimmed;
    return std.ascii.eqlIgnoreCase(stem, "subtitle") or
        std.ascii.eqlIgnoreCase(stem, "subtitles") or
        std.ascii.eqlIgnoreCase(stem, "sub") or
        std.ascii.eqlIgnoreCase(stem, "subs") or
        std.ascii.eqlIgnoreCase(stem, "download") or
        std.ascii.eqlIgnoreCase(stem, "file") or
        std.ascii.eqlIgnoreCase(stem, "default") or
        std.ascii.eqlIgnoreCase(stem, "index") or
        std.ascii.eqlIgnoreCase(stem, "srt") or
        std.ascii.eqlIgnoreCase(stem, "zip");
}

fn ensureFilenameExtension(
    allocator: Allocator,
    preferred_name: []const u8,
    source_url: []const u8,
    archive_kind: ArchiveKind,
    fallback_ext: []const u8,
) ![]u8 {
    const archive_ext: ?[]const u8 = switch (archive_kind) {
        .zip => ".zip",
        .rar => ".rar",
        .seven_z => ".7z",
        .none => null,
    };
    if (archive_ext) |wanted_ext| {
        if (filenameExtension(preferred_name)) |existing_ext| {
            if (std.ascii.eqlIgnoreCase(existing_ext, wanted_ext)) return try allocator.dupe(u8, preferred_name);
            return try std.fmt.allocPrint(
                allocator,
                "{s}{s}",
                .{ preferred_name[0 .. preferred_name.len - existing_ext.len], wanted_ext },
            );
        }
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ preferred_name, wanted_ext });
    }

    if (filenameExtension(preferred_name) != null) return try allocator.dupe(u8, preferred_name);

    if (inferFilenameFromUrl(source_url)) |url_name| {
        if (filenameExtension(url_name)) |ext| {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ preferred_name, ext });
        }
    }

    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ preferred_name, fallback_ext });
}

fn filenameExtension(name: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(name);
    if (ext.len <= 1) return null;
    return ext;
}

fn sanitizeFilename(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const valid_utf8 = std.unicode.utf8ValidateSlice(input);
    for (input) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            (valid_utf8 and c >= 0x80) or c == '.' or c == '-' or c == '_' or c == ' ' or c == '(' or c == ')';
        if (ok) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '_');
        }
    }

    const owned = try out.toOwnedSlice(allocator);
    errdefer allocator.free(owned);

    const trimmed = std.mem.trim(u8, owned, " .");
    if (trimmed.len == 0) {
        const fallback = try allocator.dupe(u8, "subtitle.bin");
        allocator.free(owned);
        return fallback;
    }
    if (common.isWindowsReservedFilename(trimmed)) {
        const safe = try std.fmt.allocPrint(allocator, "_{s}", .{trimmed});
        allocator.free(owned);
        return safe;
    }
    if (trimmed.len == owned.len) return owned;

    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return duped;
}

fn publishUniqueFile(allocator: Allocator, out_dir: []const u8, base_name: []const u8, bytes: []const u8) ![]u8 {
    for (0..10000) |attempt| {
        const name = if (attempt == 0) try allocator.dupe(u8, base_name) else try appendNumericSuffix(allocator, base_name, attempt);
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ out_dir, name });
        errdefer allocator.free(path);
        if (std.Io.Dir.cwd().statFile(runtime_io.get(), path, .{ .follow_symlinks = false })) |_| {
            allocator.free(path);
            continue;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        var atomic = try std.Io.Dir.cwd().createFileAtomic(runtime_io.get(), path, .{});
        defer atomic.deinit(runtime_io.get());
        try atomic.file.writeStreamingAll(runtime_io.get(), bytes);
        try atomic.file.sync(runtime_io.get());
        atomic.link(runtime_io.get()) catch |err| {
            if (err == error.PathAlreadyExists) {
                allocator.free(path);
                continue;
            }
            return err;
        };
        return path;
    }
    return error.TooManyOutputCollisions;
}

fn appendNumericSuffix(allocator: Allocator, base_name: []const u8, suffix: usize) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, base_name, '.');
    if (dot) |idx| {
        if (idx == 0) return std.fmt.allocPrint(allocator, "{s}-{d}", .{ base_name, suffix });
        const stem = base_name[0..idx];
        const ext = base_name[idx..];
        return std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ stem, suffix, ext });
    }
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ base_name, suffix });
}

fn shouldRunTuiLiveSmoke(allocator: Allocator) bool {
    return common.shouldRunLiveTests(allocator) and common.liveTuiSuiteEnabled();
}

fn validateUtfNoReplacement(value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8Data;
    var i: usize = 0;
    while (i < value.len) {
        const seq_len_raw = std.unicode.utf8ByteSequenceLength(value[i]) catch return error.InvalidUtf8Data;
        const seq_len: usize = @intCast(seq_len_raw);
        if (i + seq_len > value.len) return error.InvalidUtf8Data;
        const cp = std.unicode.utf8Decode(value[i .. i + seq_len]) catch return error.InvalidUtf8Data;
        if (cp == 0xFFFD) return error.InvalidUtf8Data;
        i += seq_len;
    }
}

fn liveQueryForProvider(provider: Provider) []const u8 {
    return switch (provider) {
        .tvsubtitles_net => "Chernobyl",
        .subtitlecat_com => "The Matrix Revolutions 2003",
        .gestdown_info => "Chernobyl",
        .greeksubtitles_com => "The Matrix 1999",
        .subtitles_ajatt_top => "Spirited Away",
        .greeksubs_net => "Interstellar",
        .cc_edatribe_com => "Spirited Away",
        .subtitrari_noi_ro => "The Matrix Resurrections",
        .subclub_eu => "Inception",
        .subs_ro => "The Matrix",
        .subs4free_info => "The Matrix",
        .tsukihime_org => "Akira",
        .subtitri_nekur_net => "The Matrix",
        .subsynchro_com => "Inception",
        .titrari_ro => "The Matrix Resurrections",
        .subs_sab_bz => "The Matrix",
        .subtitri_do_am => "The Matrix",
        .prijevodi_online_org => "Chernobyl",
        .animekalesi_com => "Death Note",
        .subcentral_de => "Breaking Bad",
        .subtitulamos_tv => "Chernobyl",
        .feliratok_eu => "The Matrix",
        .animesub_info => "Spirited Away",
        .animetosho_xyz => "Spirited Away",
        .kitsunekko_net => "Spirited Away",
        .thesubtitledb_org => "Inception",
        .napisy24_pl => "Avatar",
        .nyasub_cz => "Ryuu to Sobakasu no Hime",
        .subhd_tv => "The Matrix",
        .fansubs_ru => "Spirited Away",
        .legendei_net => "The Matrix Resurrections",
        .zoom_lk => "Centigrade",
        .wizdom_xyz => "The Matrix",
        .miraianime_net => "Kimi no Na wa",
        .animesubtitle_ir => "Given Umi e",
        .grupahatak_pl => "Teen Wolf",
        .jimaku_cc => "Kimi no Na wa",
        else => "The Matrix",
    };
}

/// URL shown in logs/UI for a search result. It is not always the exact request
/// URL used later, but it is the best provider-specific page to show the user.
pub fn searchRefUrl(ref: SearchRef) []const u8 {
    return switch (ref) {
        .subdl_com => |item| item.link,
        .opensubtitles_com => |item| item.subtitles_list_url,
        .opensubtitles_org => |item| item.page_url,
        .moviesubtitles_org => |item| item.link,
        .moviesubtitlesrt_com => |item| item.page_url,
        .podnapisi_net => |item| item.subtitles_page_url,
        .yifysubtitles_ch => |item| item.movie_page_url,
        .subtitlecat_com => |item| item.details_url,
        .isubtitles_org => |item| item.details_url,
        .my_subs_co => |item| item.details_url,
        .subsource_net => |item| item.link,
        .sub_scene_com => |item| item.page_url,
        .tvsubtitles_net => |item| item.show_url,
        .gestdown_info => |item| item.id,
        .greeksubtitles_com => |item| item.page_url,
        .subsunacs_net => |item| item.page_url,
        .subtitles_ajatt_top => |item| item.page_url,
        .subtis_io => |item| item.page_url,
        .greeksubs_net => |item| item.page_url,
        .indexsubtitle_cc => |item| item.page_url,
        .sous_titres_eu => |item| item.page_url,
        .cc_edatribe_com => |item| item.page_url,
        .subtitrari_noi_ro => |item| item.page_url,
        .subclub_eu => |item| item.page_url,
        .subs_ro => |item| item.page_url,
        .subs4free_info => |item| item.page_url,
        .tsukihime_org => |item| item.page_url,
        .subtitri_nekur_net => |item| item.page_url,
        .subsynchro_com => |item| item.page_url,
        .titrari_ro => |item| item.page_url,
        .subs_sab_bz => |item| item.page_url,
        .subtitri_do_am => |item| item.page_url,
        .prijevodi_online_org => |item| item.page_url,
        .animekalesi_com => |item| item.page_url,
        .subcentral_de => |item| item.thread_url,
        .subtitulamos_tv => |item| item.page_url,
        .feliratok_eu => |item| item.page_url,
        .animesub_info => |item| item.page_url,
        .animetosho_xyz => |item| item.page_url,
        .kitsunekko_net => |item| item.page_url,
        .thesubtitledb_org => |item| item.page_url,
        .napisy24_pl => |item| item.page_url,
        .nyasub_cz => |item| item.page_url,
        .subhd_tv => |item| item.detail_url,
        .fansubs_ru => |item| item.page_url,
        .legendei_net => |item| item.page_url,
        .zoom_lk => |item| item.page_url,
        .justsubtitles_com => |item| item.page_url,
        .wizdom_xyz => |item| item.page_url,
        .miraianime_net => |item| item.page_url,
        .animesubtitle_ir => |item| item.page_url,
        .grupahatak_pl => |item| item.page_url,
        .jimaku_cc => |item| item.page_url,
    };
}

fn firstDownloadCandidate(subtitles: []const SubtitleChoice) ?usize {
    for (subtitles, 0..) |sub, idx| {
        const url = sub.download_url orelse continue;
        if (likelyArchiveSource(url, sub.filename)) return idx;
    }
    for (subtitles, 0..) |sub, idx| {
        const url = sub.download_url orelse continue;
        if (!isSubtitlecatTranslateTokenUrl(url)) return idx;
    }
    for (subtitles, 0..) |sub, idx| {
        if (sub.download_url != null) return idx;
    }
    return null;
}

fn likelyArchiveSource(url: []const u8, filename: ?[]const u8) bool {
    if (std.ascii.endsWithIgnoreCase(url, ".zip") or std.ascii.endsWithIgnoreCase(url, ".rar") or std.ascii.endsWithIgnoreCase(url, ".7z")) return true;
    if (std.mem.indexOf(u8, url, ".zip?") != null or std.mem.indexOf(u8, url, ".rar?") != null or std.mem.indexOf(u8, url, ".7z?") != null) return true;
    if (filename) |name| {
        if (std.ascii.endsWithIgnoreCase(name, ".zip") or std.ascii.endsWithIgnoreCase(name, ".rar") or std.ascii.endsWithIgnoreCase(name, ".7z")) return true;
    }
    return false;
}

fn isSubtitlecatTranslateTokenUrl(download_url: ?[]const u8) bool {
    const url = download_url orelse return false;
    return std.mem.startsWith(u8, url, subtitlecat_translate_prefix);
}

fn prepareDownloadOutDir(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), path);
}

fn cleanupDownloadOutDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(runtime_io.get(), path) catch {};
}

test "active provider registry excludes retired providers" {
    const expected = [_][]const u8{
        "subdl_com",
        "opensubtitles_com",
        "moviesubtitles_org",
        "yifysubtitles_ch",
        "subtitlecat_com",
        "isubtitles_org",
        "subsource_net",
        "sub_scene_com",
        "gestdown_info",
        "subsunacs_net",
        "subtitles_ajatt_top",
        "subtis_io",
        "greeksubs_net",
        "indexsubtitle_cc",
        "sous_titres_eu",
        "cc_edatribe_com",
        "subtitrari_noi_ro",
        "subclub_eu",
        "subs_ro",
        "subs4free_info",
        "tsukihime_org",
        "subtitri_nekur_net",
        "subsynchro_com",
        "titrari_ro",
        "subs_sab_bz",
        "subtitri_do_am",
        "prijevodi_online_org",
        "animekalesi_com",
        "subcentral_de",
        "subtitulamos_tv",
        "feliratok_eu",
        "animesub_info",
        "animetosho_xyz",
        "kitsunekko_net",
        "thesubtitledb_org",
        "napisy24_pl",
        "nyasub_cz",
        "subhd_tv",
        "fansubs_ru",
        "legendei_net",
        "zoom_lk",
        "justsubtitles_com",
        "wizdom_xyz",
        "miraianime_net",
        "grupahatak_pl",
        "jimaku_cc",
    };

    const actual = providers();
    try std.testing.expectEqual(expected.len, actual.len);

    for (expected) |name| {
        var found = false;
        for (actual) |provider| {
            if (std.mem.eql(u8, providerName(provider), name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "parseProvider accepts active dotted/hyphenated provider names" {
    try std.testing.expect(parseProvider("subdl.com") == .subdl_com);
    try std.testing.expect(parseProvider("opensubtitles.com") == .opensubtitles_com);
    try std.testing.expect(parseProvider("opensubtitles.org") == null);
    try std.testing.expect(parseProvider("moviesubtitles.org") == .moviesubtitles_org);
    try std.testing.expect(parseProvider("moviesubtitlesrt.com") == null);
    try std.testing.expect(parseProvider("podnapisi.net") == null);
    try std.testing.expect(parseProvider("yifysubtitles.ch") == .yifysubtitles_ch);
    try std.testing.expect(parseProvider("subtitlecat.com") == .subtitlecat_com);
    try std.testing.expect(parseProvider("isubtitles.org") == .isubtitles_org);
    try std.testing.expect(parseProvider("my-subs.co") == null);
    try std.testing.expect(parseProvider("subsource.net") == .subsource_net);
    try std.testing.expect(parseProvider("sub-scene.com") == .sub_scene_com);
    try std.testing.expect(parseProvider("tvsubtitles.net") == null);
    try std.testing.expect(parseProvider("gestdown.info") == .gestdown_info);
    try std.testing.expect(parseProvider("greek-subtitles.com") == null);
    try std.testing.expect(parseProvider("subsunacs.net") == .subsunacs_net);
    try std.testing.expect(parseProvider("subtitles.ajatt.top") == .subtitles_ajatt_top);
    try std.testing.expect(parseProvider("subtis.io") == .subtis_io);
    try std.testing.expect(parseProvider("greeksubs.net") == .greeksubs_net);
    try std.testing.expect(parseProvider("indexsubtitle.cc") == .indexsubtitle_cc);
    try std.testing.expect(parseProvider("sous-titres.eu") == .sous_titres_eu);
    try std.testing.expect(parseProvider("cc.edatribe.com") == .cc_edatribe_com);
    try std.testing.expect(parseProvider("subtitrari-noi.ro") == .subtitrari_noi_ro);
    try std.testing.expect(parseProvider("subclub.eu") == .subclub_eu);
    try std.testing.expect(parseProvider("subs.ro") == .subs_ro);
    try std.testing.expect(parseProvider("subs4free.info") == .subs4free_info);
    try std.testing.expect(parseProvider("tsukihime.org") == .tsukihime_org);
    try std.testing.expect(parseProvider("subtitri.nekur.net") == .subtitri_nekur_net);
    try std.testing.expect(parseProvider("subsynchro.com") == .subsynchro_com);
    try std.testing.expect(parseProvider("titrari.ro") == .titrari_ro);
    try std.testing.expect(parseProvider("subs.sab.bz") == .subs_sab_bz);
    try std.testing.expect(parseProvider("subtitri.do.am") == .subtitri_do_am);
    try std.testing.expect(parseProvider("prijevodi-online.org") == .prijevodi_online_org);
    try std.testing.expect(parseProvider("animekalesi.com") == .animekalesi_com);
    try std.testing.expect(parseProvider("subcentral.de") == .subcentral_de);
    try std.testing.expect(parseProvider("subtitulamos.tv") == .subtitulamos_tv);
    try std.testing.expect(parseProvider("feliratok.eu") == .feliratok_eu);
    try std.testing.expect(parseProvider("animesub.info") == .animesub_info);
    try std.testing.expect(parseProvider("animetosho.xyz") == .animetosho_xyz);
    try std.testing.expect(parseProvider("kitsunekko.net") == .kitsunekko_net);
    try std.testing.expect(parseProvider("thesubtitledb.org") == .thesubtitledb_org);
    try std.testing.expect(parseProvider("napisy24.pl") == .napisy24_pl);
    try std.testing.expect(parseProvider("nyasub.cz") == .nyasub_cz);
    try std.testing.expect(parseProvider("subhd.tv") == .subhd_tv);
    try std.testing.expect(parseProvider("fansubs.ru") == .fansubs_ru);
    try std.testing.expect(parseProvider("legendei.net") == .legendei_net);
    try std.testing.expect(parseProvider("zoom.lk") == .zoom_lk);
    try std.testing.expect(parseProvider("justsubtitles.com") == .justsubtitles_com);
    try std.testing.expect(parseProvider("wizdom.xyz") == .wizdom_xyz);
    try std.testing.expect(parseProvider("miraianime.net") == .miraianime_net);
    try std.testing.expect(parseProvider("animesubtitle.ir") == null);
    try std.testing.expect(parseProvider("grupahatak.pl") == .grupahatak_pl);
    try std.testing.expect(parseProvider("jimaku.cc") == .jimaku_cc);
}

test "resolveProvider accepts unique prefixes and rejects ambiguous prefixes" {
    try std.testing.expect(try resolveProvider("subdl") == .subdl_com);
    try std.testing.expect(try resolveProvider("yify") == .yifysubtitles_ch);
    try std.testing.expect(try resolveProvider("subtitlecat") == .subtitlecat_com);
    try std.testing.expect(try resolveProvider("isubtitles") == .isubtitles_org);
    try std.testing.expectError(error.UnknownProvider, resolveProvider("my_subs"));
    try std.testing.expect(try resolveProvider("subsource") == .subsource_net);
    try std.testing.expect(try resolveProvider("sub_scene") == .sub_scene_com);
    try std.testing.expect(try resolveProvider("gestdown") == .gestdown_info);
    try std.testing.expectError(error.UnknownProvider, resolveProvider("greek_subtitles"));
    try std.testing.expect(try resolveProvider("subsunacs") == .subsunacs_net);
    try std.testing.expect(try resolveProvider("subtitles_ajatt") == .subtitles_ajatt_top);
    try std.testing.expect(try resolveProvider("subtis") == .subtis_io);
    try std.testing.expect(try resolveProvider("greeksubs") == .greeksubs_net);
    try std.testing.expect(try resolveProvider("indexsubtitle") == .indexsubtitle_cc);
    try std.testing.expect(try resolveProvider("sous_titres") == .sous_titres_eu);
    try std.testing.expect(try resolveProvider("cc_edatribe") == .cc_edatribe_com);
    try std.testing.expect(try resolveProvider("subtitrari_noi") == .subtitrari_noi_ro);
    try std.testing.expect(try resolveProvider("subclub") == .subclub_eu);
    try std.testing.expect(try resolveProvider("subs_ro") == .subs_ro);
    try std.testing.expect(try resolveProvider("subs4free") == .subs4free_info);
    try std.testing.expect(try resolveProvider("tsukihime") == .tsukihime_org);
    try std.testing.expect(try resolveProvider("subtitri_nekur") == .subtitri_nekur_net);
    try std.testing.expect(try resolveProvider("subsynchro") == .subsynchro_com);
    try std.testing.expect(try resolveProvider("titrari") == .titrari_ro);
    try std.testing.expect(try resolveProvider("subs_sab") == .subs_sab_bz);
    try std.testing.expect(try resolveProvider("subtitri_do") == .subtitri_do_am);
    try std.testing.expectError(error.AmbiguousProvider, resolveProvider("subtitri"));
    try std.testing.expect(try resolveProvider("prijevodi") == .prijevodi_online_org);
    try std.testing.expect(try resolveProvider("animekalesi") == .animekalesi_com);
    try std.testing.expect(try resolveProvider("subcentral") == .subcentral_de);
    try std.testing.expect(try resolveProvider("subtitulamos") == .subtitulamos_tv);
    try std.testing.expect(try resolveProvider("feliratok") == .feliratok_eu);
    try std.testing.expect(try resolveProvider("animesub_i") == .animesub_info);
    try std.testing.expect(try resolveProvider("animetosho") == .animetosho_xyz);
    try std.testing.expect(try resolveProvider("kitsunekko") == .kitsunekko_net);
    try std.testing.expect(try resolveProvider("thesubtitledb") == .thesubtitledb_org);
    try std.testing.expect(try resolveProvider("napisy24") == .napisy24_pl);
    try std.testing.expect(try resolveProvider("nyasub") == .nyasub_cz);
    try std.testing.expectError(error.AmbiguousProvider, resolveProvider("sub"));
    try std.testing.expect(try resolveProvider("subhd") == .subhd_tv);
    try std.testing.expect(try resolveProvider("fansubs") == .fansubs_ru);
    try std.testing.expect(try resolveProvider("legendei") == .legendei_net);
    try std.testing.expect(try resolveProvider("zoom") == .zoom_lk);
    try std.testing.expect(try resolveProvider("justsubtitles") == .justsubtitles_com);
    try std.testing.expect(try resolveProvider("wizdom") == .wizdom_xyz);
    try std.testing.expect(try resolveProvider("miraianime") == .miraianime_net);
    try std.testing.expectError(error.UnknownProvider, resolveProvider("animesubtitle"));
    try std.testing.expect(try resolveProvider("grupahatak") == .grupahatak_pl);
    try std.testing.expect(try resolveProvider("jimaku") == .jimaku_cc);
    try std.testing.expect(try resolveProvider("open") == .opensubtitles_com);
    try std.testing.expectError(error.UnknownProvider, resolveProvider("tvsubtitles"));
    try std.testing.expectError(error.UnknownProvider, resolveProvider("missing"));
}

test "provider pagination support flags" {
    try std.testing.expect(providerSupportsSearchPagination(.opensubtitles_org));
    try std.testing.expect(providerSupportsSearchPagination(.moviesubtitlesrt_com));
    try std.testing.expect(providerSupportsSearchPagination(.podnapisi_net));
    try std.testing.expect(providerSupportsSearchPagination(.isubtitles_org));
    try std.testing.expect(!providerSupportsSearchPagination(.my_subs_co));
    try std.testing.expect(!providerSupportsSearchPagination(.tvsubtitles_net));
    try std.testing.expect(!providerSupportsSearchPagination(.subdl_com));

    try std.testing.expect(providerSupportsSubtitlesPagination(.opensubtitles_org));
    try std.testing.expect(providerSupportsSubtitlesPagination(.isubtitles_org));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.my_subs_co));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.tvsubtitles_net));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.moviesubtitlesrt_com));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.subdl_com));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.opensubtitles_com));
}

test "searchPage returns empty page for unsupported provider page > 1" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    const unsupported_providers = [_]Provider{ .subdl_com, .my_subs_co, .tvsubtitles_net };
    for (unsupported_providers) |provider| {
        var page = try searchPage(std.testing.allocator, &client, provider, "matrix", 2);
        defer page.deinit();

        try std.testing.expectEqual(@as(usize, 0), page.items.len);
        try std.testing.expectEqual(@as(usize, 2), page.page);
        try std.testing.expect(page.has_prev_page);
        try std.testing.expect(!page.has_next_page);
    }
}

test "fetchSubtitlesPage returns empty page for unsupported provider page > 1" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    const ref: SearchRef = .{ .subdl_com = .{
        .title = "The Matrix",
        .media_type = .movie,
        .link = "https://subdl.com/subtitle/the-matrix",
    } };

    const refs = [_]SearchRef{
        ref,
        .{ .my_subs_co = .{
            .title = "The Matrix",
            .details_url = "https://my-subs.co/movie/the-matrix",
            .media_kind = .movie,
        } },
        .{ .tvsubtitles_net = .{
            .title = "Chernobyl",
            .show_url = "https://www.tvsubtitles.net/tvshow-1234-1.html",
        } },
    };

    for (refs) |item_ref| {
        var page = try fetchSubtitlesPage(std.testing.allocator, &client, item_ref, 2);
        defer page.deinit();

        try std.testing.expectEqual(@as(usize, 0), page.items.len);
        try std.testing.expectEqual(@as(usize, 2), page.page);
        try std.testing.expect(page.has_prev_page);
        try std.testing.expect(!page.has_next_page);
        try std.testing.expectEqualStrings(titleFromRef(item_ref), page.title);
    }
}

test "opensubtitles remote token helpers" {
    const allocator = std.testing.allocator;
    const token = try makeOpenSubtitlesRemoteToken(allocator, "/en/subtitleserve/file/abc");
    defer allocator.free(token);

    const parsed = parseOpenSubtitlesRemoteToken(token) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/en/subtitleserve/file/abc", parsed);
    try std.testing.expect(parseOpenSubtitlesRemoteToken("https://example.com/file.zip") == null);
}

test "subsource remote token helpers" {
    const allocator = std.testing.allocator;
    const token = try makeSubsourceRemoteToken(allocator, "malcolm-in-the-middle-season-1/english/123");
    defer allocator.free(token);
    try std.testing.expectEqualStrings("malcolm-in-the-middle-season-1/english/123", parseSubsourceRemoteToken(token).?);
    try std.testing.expect(parseSubsourceRemoteToken("https://api.subsource.net/file.zip") == null);
}

test "subtitlecat translate token helpers" {
    const allocator = std.testing.allocator;

    const token = try makeSubtitlecatTranslateToken(
        allocator,
        "https://www.subtitlecat.com/subs/file-orig.srt",
        "es",
        "movie-es.srt",
    );
    defer allocator.free(token);

    const parsed = (try parseSubtitlecatTranslateToken(allocator, token)) orelse return error.TestUnexpectedResult;
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("https://www.subtitlecat.com/subs/file-orig.srt", parsed.source_url);
    try std.testing.expectEqualStrings("es", parsed.target_lang);
    try std.testing.expectEqualStrings("movie-es.srt", parsed.filename);

    try std.testing.expect((try parseSubtitlecatTranslateToken(allocator, "https://example.com/file.srt")) == null);
}

test "subtitlecat source download preserves rate limits" {
    try requireSubtitlecatSourceStatus(.ok);
    try std.testing.expectError(error.RateLimited, requireSubtitlecatSourceStatus(.too_many_requests));
    try std.testing.expectError(error.UnexpectedHttpStatus, requireSubtitlecatSourceStatus(.service_unavailable));
}

test "google translate result parser extracts text chunks" {
    const allocator = std.testing.allocator;
    const raw =
        \\[[["hello ","hola ",null,null,10],["world","mundo",null,null,10]],null,"en"]
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const text = try googleTranslateResultToString(allocator, parsed.value);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}

test "download referer is scoped to providers that require it" {
    try std.testing.expectEqualStrings("https://yifysubtitles.ch/", downloadRefererForUrl("https://yifysubtitles.ch/subtitle/test.zip").?);
    try std.testing.expectEqualStrings("https://napisy24.pl/", downloadRefererForUrl("https://napisy24.pl/run/pages/download.php?napisId=123&typ=sr").?);
    try std.testing.expect(downloadRefererForUrl("https://www.opensubtitles.com/file.zip") == null);
}

test "cloudflare target excludes yify downloads" {
    try std.testing.expect(cloudflareTargetForUrl("https://yifysubtitles.ch/subtitle/test.zip") == null);
    try std.testing.expect(cloudflareTargetForUrl("https://www.opensubtitles.com/nocache/download/123") != null);
    try std.testing.expect(!isOpenSubtitlesChallengeResponse(.forbidden, "ordinary denial"));
    try std.testing.expect(!isOpenSubtitlesChallengeResponse(.service_unavailable, ""));
    try std.testing.expect(!isOpenSubtitlesChallengeResponse(.bad_gateway, "ordinary outage"));
    try std.testing.expect(isOpenSubtitlesChallengeResponse(
        .ok,
        "<html><script>window._cf_chl_opt = {};</script></html>",
    ));
}

test "OpenSubtitles session cookies require the exact HTTPS origin" {
    for ([_][]const u8{
        "https://www.opensubtitles.com/",
        "https://www.opensubtitles.com/download/1?format=srt",
        "https://WWW.OPENSUBTITLES.COM:443/download/1",
    }) |url| {
        const target = cloudflareTargetForUrl(url).?;
        try std.testing.expectEqualStrings(url, target.challenge_url);
        try std.testing.expectEqualStrings("www.opensubtitles.com", target.domain);
    }

    const foreign_urls = [_][]const u8{
        "https://example.test/opensubtitles.com/download/1",
        "https://example.test/?next=https://www.opensubtitles.com/",
        "https://www.opensubtitles.com.example.test/download/1",
        "https://fakewww.opensubtitles.com/download/1",
        "https://rest.opensubtitles.com/download/1",
        "https://www.opensubtitles.com@other.test/download/1",
        "https://user@www.opensubtitles.com/download/1",
        "https://user:password@www.opensubtitles.com/download/1",
        "https://www.opensubtitles.com:444/download/1",
        "http://www.opensubtitles.com/download/1",
        "https://www.opensubtitles.com./download/1",
        "https://www.%6fpensubtitles.com/download/1",
        "/www.opensubtitles.com/download/1",
    };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const cookies = [_]cf.Cookie{.{
        .name = "fixture",
        .value = "session",
        .domain = "www.opensubtitles.com",
        .path = "/",
        .secure = true,
        .host_only = true,
        .expires_unix_seconds = null,
    }};
    const session: cf.Session = .{
        .cookies = &cookies,
        .cf_clearance = "fixture",
        .user_agent = "fixture",
        .acquired_at_unix = 0,
        .generation = 1,
    };
    for (foreign_urls) |url| {
        try std.testing.expect(cloudflareTargetForUrl(url) == null);
        try std.testing.expectError(error.InvalidDownloadUrl, fetchBytesUsingSession(&client, std.testing.allocator, url, "*/*", null, session));
        try std.testing.expectError(error.InvalidDownloadUrl, fetchBytesWithCloudflareSession(&client, std.testing.allocator, url, "www.opensubtitles.com", "https://www.opensubtitles.com/", "*/*", null));
    }
    try std.testing.expectError(error.InvalidDownloadUrl, fetchBytesWithCloudflareSession(&client, std.testing.allocator, "https://www.opensubtitles.com/file", "other.test", "https://www.opensubtitles.com/", "*/*", null));
    try std.testing.expectError(error.InvalidDownloadUrl, fetchBytesWithCloudflareSession(&client, std.testing.allocator, "https://www.opensubtitles.com/file", "www.opensubtitles.com", "https://other.test/", "*/*", null));
}

test "OpenSubtitles session static cookie header excludes path-scoped cookies" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, allocator: Allocator, _: []const u8, options: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            try std.testing.expect(options.allow_non_ok);
            try std.testing.expect(!options.cache);
            try std.testing.expect(!options.retry_on_429);
            try std.testing.expect(options.require_https);

            var cookie: ?[]const u8 = null;
            for (options.extra_headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "cookie")) cookie = header.value;
            }
            try std.testing.expectEqualStrings("cf_clearance=clearance; root=ok", cookie orelse return error.TestUnexpectedResult);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "subtitle") };
        }
    };
    const cookies = [_]cf.Cookie{
        .{ .name = "cf_clearance", .value = "clearance", .domain = "www.opensubtitles.com", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "root", .value = "ok", .domain = "www.opensubtitles.com", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "path_secret", .value = "must-not-follow", .domain = "www.opensubtitles.com", .path = "/download", .secure = true, .host_only = true, .expires_unix_seconds = null },
    };
    const session: cf.Session = .{
        .cookies = &cookies,
        .cf_clearance = "clearance",
        .user_agent = "fixture-agent",
        .acquired_at_unix = 0,
        .generation = 1,
    };
    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    const response = try fetchBytesUsingSessionWith(
        Fixture.fetch,
        &fixture.client,
        std.testing.allocator,
        "https://www.opensubtitles.com/download/private/file.zip",
        "*/*",
        null,
        session,
    );
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "OpenSubtitles session cookie names are case-sensitive" {
    try std.testing.expect(cookieHeaderValue("CF_CLEARANCE=wrong", "cf_clearance") == null);
    try std.testing.expectEqualStrings(
        "right",
        cookieHeaderValue("CF_CLEARANCE=wrong; cf_clearance=right", "cf_clearance").?,
    );
}

test "OpenSubtitles session requires root-scoped cf_clearance before fetching" {
    const Fixture = struct {
        client: std.http.Client,
        calls: usize = 0,

        fn fetch(client: *std.http.Client, _: Allocator, _: []const u8, _: common.FetchOptions) anyerror!common.HttpResponse {
            const self: *@This() = @fieldParentPtr("client", client);
            self.calls += 1;
            return error.TestUnexpectedResult;
        }
    };
    const cookies = [_]cf.Cookie{
        .{ .name = "cf_clearance", .value = "scoped", .domain = "www.opensubtitles.com", .path = "/download", .secure = true, .host_only = true, .expires_unix_seconds = null },
        .{ .name = "root", .value = "ok", .domain = "www.opensubtitles.com", .path = "/", .secure = true, .host_only = true, .expires_unix_seconds = null },
    };
    const session: cf.Session = .{
        .cookies = &cookies,
        .cf_clearance = "scoped",
        .user_agent = "fixture-agent",
        .acquired_at_unix = 0,
        .generation = 1,
    };
    var fixture: Fixture = .{ .client = .{ .allocator = std.testing.allocator, .io = std.testing.io } };
    defer fixture.client.deinit();
    try std.testing.expectError(error.CloudflareSessionUnavailable, fetchBytesUsingSessionWith(
        Fixture.fetch,
        &fixture.client,
        std.testing.allocator,
        "https://www.opensubtitles.com/download/private/file.zip",
        "*/*",
        null,
        session,
    ));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "subtitle downloads reject response pages and preserve subtitle formats" {
    try std.testing.expectError(
        error.CloudflareChallenge,
        validateSubtitleDownloadBody(std.testing.allocator, "<!doctype html><script src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script>"),
    );
    for ([_][]const u8{
        "",                                                 " \t\r\n",                                                                    "\xEF\xBB\xBF \n",
        "<!doctype html><html><body>Sign in</body></html>", "\xEF\xBB\xBF<!-- gateway --><HTML><BODY>Verify you are human</BODY></HTML>", "<head><title>Error</title></head>",
        "{\"error\":\"expired\"}",                          " { \"message\":\"login required\" } ",                                       "[{\"error\":\"rate limited\"}]",
        "{}",                                               "[]",                                                                         "error",
        "Access denied",                                    "WEBVTT\n\nerror",                                                            "[Events]\nerror",
        "{25}{50}",                                         "[25][50]",                                                                   "00:00:99,000 --> 00:00:02,000\nerror",
        "00:61:01:invalid minute",                          "00:00:01:service started\nnot a subtitle cue",                               "prefix 00:00:01:embedded timestamp",
    }) |body| try std.testing.expectError(error.InvalidDownloadPayload, validateSubtitleDownloadBody(std.testing.allocator, body));
    try std.testing.expectError(error.ProviderAccessBlocked, validateSubtitleDownloadBody(std.testing.allocator, "Access to Website Disabled by the Federal Court of Australia"));

    for ([_][]const u8{
        "1\n00:00:01,000 --> 00:00:02,000\nHello <i>world</i>\n",
        "1\n00:00:01,000 --> 00:00:02,000\nThe <html> and <body> tags.\n",
        "\xEF\xBB\xBF1\r\n00:00:01,000 --> 00:00:02,000\r\nCaf\xC3\xA9\r\n",
        "[Script Info]\nScriptType: v4.00+\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello\n",
        "[Script Info]\nScriptType: v4.00\n[Events]\nDialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello\n",
        "WEBVTT\n\n00:01.000 --> 00:02.000\nHello\n",
        "0:00:01.000,0:00:02.000\nHello\n",
        "<SAMI><BODY><SYNC Start=1000><P Class=ENCC>Hello</P></SYNC></BODY></SAMI>",
        "<?xml version=\"1.0\"?><tt xmlns=\"http://www.w3.org/ns/ttml\"><body><p begin=\"00:00:01.000\" end=\"00:00:02.000\">Hello</p></body></tt>",
        "# VobSub index file, v7\ntimestamp: 00:00:01:000, filepos: 000000000\n",
        "{25}{50}Hello|world\n",
        "[25][50]Hello\n",
        "[INFORMATION]\n[TITLE]Example\n[SUBTITLE]\n00:00:01.00,00:00:02.00\nHello\n",
        "00:00:01:Subtitle text",
        "00:00:01:First subtitle|continued\n00:00:03:Second subtitle\n",
        "\xFF\xFE{\x002\x005\x00}\x00{\x005\x000\x00}\x00H\x00i\x00",
        "\xFE\xFF\x00{\x002\x005\x00}\x00{\x005\x000\x00}\x00H\x00i",
        "PK\x05\x06\x00\x00\x00\x00",
        "Rar!\x1A\x07\x00",
        "\x37\x7A\xBC\xAF\x27\x1C",
        "PG\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x00\x00\x01\xBA\x00",
    }) |body| try validateSubtitleDownloadBody(std.testing.allocator, body);

    const long_ass = "[Script Info]\n;" ++ "x" ** 9000 ++ "\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello\n";
    const utf16 = try std.testing.allocator.alloc(u8, 2 + long_ass.len * 2);
    defer std.testing.allocator.free(utf16);
    utf16[0] = 0xFF;
    utf16[1] = 0xFE;
    for (long_ass, 0..) |byte, i| {
        utf16[2 + i * 2] = byte;
        utf16[3 + i * 2] = 0;
    }
    try validateSubtitleDownloadBody(std.testing.allocator, utf16);
}

test "subtitleLabel uses Without release fallback for missing filename" {
    const allocator = std.testing.allocator;

    const a = try subtitleLabel(allocator, null, null, "https://example.com/sub.zip");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("Without release", a);

    const b = try subtitleLabel(allocator, "English", "", "https://example.com/sub.zip");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("English • Without release", b);

    const c = try subtitleLabel(allocator, "  ", " \t ", null);
    defer allocator.free(c);
    try std.testing.expectEqualStrings("Without release [no direct download]", c);
}

test "ensureFilenameExtension uses url extension when missing in preferred name" {
    const allocator = std.testing.allocator;
    const name = try ensureFilenameExtension(
        allocator,
        "S01E01-13",
        "https://api.subsource.net/v1/subtitle/download/abc.zip",
        .none,
        ".srt",
    );
    defer allocator.free(name);
    try std.testing.expectEqualStrings("S01E01-13.zip", name);
}

test "ensureFilenameExtension falls back to archive extension from kind" {
    const allocator = std.testing.allocator;
    const name = try ensureFilenameExtension(
        allocator,
        "subtitle_pack",
        "https://api.example.com/download/token",
        .rar,
        ".srt",
    );
    defer allocator.free(name);
    try std.testing.expectEqualStrings("subtitle_pack.rar", name);
}

test "ensureFilenameExtension archive kind overrides endpoint and false extension" {
    const allocator = std.testing.allocator;

    const endpoint_name = try ensureFilenameExtension(
        allocator,
        "The Matrix",
        "https://example.com/getp.php?id=1",
        .zip,
        ".srt",
    );
    defer allocator.free(endpoint_name);
    try std.testing.expectEqualStrings("The Matrix.zip", endpoint_name);

    const wrapped_name = try ensureFilenameExtension(
        allocator,
        "The Matrix.srt",
        "https://example.com/download",
        .zip,
        ".srt",
    );
    defer allocator.free(wrapped_name);
    try std.testing.expectEqualStrings("The Matrix.zip", wrapped_name);
}

test "detectArchiveKind recognizes 7z from extension and signature" {
    try std.testing.expectEqual(ArchiveKind.seven_z, detectArchiveKind("pack.7z", "https://example.com/file", ""));
    try std.testing.expectEqual(
        ArchiveKind.seven_z,
        detectArchiveKind("pack", "https://example.com/file", "\x37\x7A\xBC\xAF\x27\x1C\x00\x00"),
    );
}

fn runProviderSmokeTest(provider: Provider) !void {
    const start_ms = common.compatMilliTimestamp();
    std.debug.print("[live][providers_app][{s}] test_start\n", .{providerName(provider)});
    defer {
        const elapsed_ms = common.compatMilliTimestamp() - start_ms;
        std.debug.print("[live][providers_app][{s}] test_end elapsed_ms={d}\n", .{ providerName(provider), elapsed_ms });
    }

    var allocator_state = runtime_alloc.RuntimeAllocator.init();
    defer allocator_state.deinit();
    const allocator = allocator_state.allocator();

    var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    var phase = common.LivePhase.init(providerName(provider), "providers_app_tui_smoke");
    phase.start();
    defer phase.finish();
    try runProviderTuiSmoke(allocator, &client, provider);
}

fn runProviderTuiSmoke(allocator: std.mem.Allocator, client: *std.http.Client, provider: Provider) !void {
    const query = liveQueryForProvider(provider);
    return runProviderTuiSmokeQuery(allocator, client, provider, query, false);
}

fn runProviderTuiSmokeQuery(allocator: std.mem.Allocator, client: *std.http.Client, provider: Provider, query: []const u8, require_series: bool) !void {
    std.debug.print("[live][providers_app][{s}] query={s}\n", .{ providerName(provider), query });

    std.debug.print("[live][providers_app][{s}] phase=search_start\n", .{providerName(provider)});
    var search_response = try search(allocator, client, provider, query);
    defer search_response.deinit();
    std.debug.print("[live][providers_app][{s}] phase=search_done items={d}\n", .{
        providerName(provider),
        search_response.items.len,
    });

    if (search_response.items.len == 0) return error.TestUnexpectedResult;
    std.debug.print("[live][providers_app][{s}] search_items={d}\n", .{ providerName(provider), search_response.items.len });

    var chosen_idx: usize = 0;
    var subtitles_opt: ?SubtitlesResponse = null;
    defer if (subtitles_opt) |*subtitles| subtitles.deinit();
    for (search_response.items, 0..) |candidate, idx| {
        if (require_series and !try liveSeriesCandidateMatches(allocator, candidate.ref, query)) {
            std.debug.print("[live][providers_app][{s}] skip_search={d} reason=not_requested_series\n", .{ providerName(provider), idx });
            continue;
        }
        var candidate_subtitles = fetchSubtitles(allocator, client, candidate.ref) catch |err| {
            std.debug.print("[live][providers_app][{s}] listing_failed={d} err={s}\n", .{ providerName(provider), idx, @errorName(err) });
            return err;
        };
        if (candidate_subtitles.items.len == 0 or firstDownloadCandidate(candidate_subtitles.items) == null) {
            std.debug.print("[live][providers_app][{s}] skip_search={d} reason=no_downloadable_subtitles\n", .{ providerName(provider), idx });
            candidate_subtitles.deinit();
            continue;
        }
        chosen_idx = idx;
        subtitles_opt = candidate_subtitles;
        break;
    }
    const subtitles = if (subtitles_opt) |*value| value else return error.TestUnexpectedResult;
    const picked_search = search_response.items[chosen_idx];
    std.debug.print("[live][providers_app][{s}][search][{d}]\n", .{ providerName(provider), chosen_idx });
    const picked_title = titleFromRef(picked_search.ref);
    try validateUtfNoReplacement(picked_title);
    try validateUtfNoReplacement(picked_search.label);
    try common.livePrintField(allocator, "title", picked_title);
    try common.livePrintField(allocator, "label", picked_search.label);
    try common.livePrintField(allocator, "url", searchRefUrl(picked_search.ref));
    std.debug.print("[live][providers_app][{s}] chosen_search={d}\n", .{ providerName(provider), chosen_idx });
    try common.livePrintField(allocator, "chosen_search_title", picked_title);
    try common.livePrintField(allocator, "chosen_search_url", searchRefUrl(picked_search.ref));

    std.debug.print("[live][providers_app][{s}] phase=fetch_chosen_subtitles_done items={d}\n", .{
        providerName(provider),
        subtitles.items.len,
    });

    try validateUtfNoReplacement(subtitles.title);
    try common.livePrintField(allocator, "subtitles_title", subtitles.title);
    std.debug.print("[live][providers_app][{s}] subtitles_items={d}\n", .{ providerName(provider), subtitles.items.len });
    const download_idx = firstDownloadCandidate(subtitles.items) orelse return error.TestUnexpectedResult;
    const chosen_subtitle = subtitles.items[download_idx];
    std.debug.print("[live][providers_app][{s}][subtitle][{d}]\n", .{ providerName(provider), download_idx });
    try validateUtfNoReplacement(chosen_subtitle.label);
    try common.livePrintField(allocator, "label", chosen_subtitle.label);
    try common.livePrintOptionalField(allocator, "language", chosen_subtitle.language);
    try common.livePrintOptionalField(allocator, "filename", chosen_subtitle.filename);
    try common.livePrintOptionalField(allocator, "download_url", chosen_subtitle.download_url);
    if (chosen_subtitle.language) |v| try validateUtfNoReplacement(v);
    if (chosen_subtitle.filename) |v| try validateUtfNoReplacement(v);
    if (chosen_subtitle.download_url) |v| try validateUtfNoReplacement(v);

    const unique = common.compatNanoTimestamp();
    const out_dir = try std.fmt.allocPrint(allocator, ".zig-cache/live-downloads/{s}-{d}-{d}", .{ providerName(provider), chosen_idx, unique });
    defer allocator.free(out_dir);
    try prepareDownloadOutDir(out_dir);
    defer cleanupDownloadOutDir(out_dir);

    std.debug.print("[live][providers_app][{s}] download_attempt idx={d} mode=single\n", .{ providerName(provider), download_idx });
    var download = try downloadSubtitleWithOptions(allocator, client, chosen_subtitle, out_dir, .{
        .extract_archive = true,
    });
    defer download.deinit(allocator);

    std.debug.print("[live][providers_app][{s}] download_ok idx={d} bytes={d}\n", .{ providerName(provider), download_idx, download.bytes_written });
    try common.livePrintField(allocator, "download_file_path", download.file_path);
    if (download.archive_path) |p| try common.livePrintField(allocator, "download_archive_path", p);
    for (download.extracted_files) |path| {
        try common.livePrintField(allocator, "extracted_file", path);
        try std.Io.Dir.cwd().access(runtime_io.get(), path, .{});
    }

    if (download.bytes_written == 0) return error.TestUnexpectedResult;
    if (download.archive_path != null and download.extracted_files.len == 0 and !download.extraction_unavailable) return error.TestUnexpectedResult;
    if (download.extraction_unavailable) {
        std.debug.print("[live][providers_app][{s}] archive_download_ok external_extraction_required\n", .{providerName(provider)});
    } else if (download.extracted_files.len > 0) {
        std.debug.print("[live][providers_app][{s}] extraction_ok idx={d} files={d}\n", .{
            providerName(provider),
            download_idx,
            download.extracted_files.len,
        });
    } else {
        std.debug.print("[live][providers_app][{s}] direct_download_ok idx={d}\n", .{
            providerName(provider),
            download_idx,
        });
    }
}

fn seriesQueryForProvider(provider: Provider) []const u8 {
    return switch (provider) {
        .subdl_com, .subsource_net, .subtitlecat_com => "Malcolm in the Middle",
        .sub_scene_com => "Chernobyl - First Season",
        .greeksubtitles_com => "Chernobyl S01E01",
        .subsunacs_net => "Game of Thrones 01 01",
        .subtitles_ajatt_top => "Death Note",
        .greeksubs_net => "Game of Thrones",
        .cc_edatribe_com => "Attack on Titan",
        .subtitrari_noi_ro => "Reacher",
        .subclub_eu => "Chernobyl",
        .subs_ro => "Chernobyl",
        .tsukihime_org => "Death Note S01E01",
        .titrari_ro => "Reacher",
        .subs_sab_bz => "Reacher",
        .prijevodi_online_org => "Chernobyl",
        .animekalesi_com => "Death Note",
        .subcentral_de => "Breaking Bad",
        .subtitulamos_tv => "Chernobyl",
        .animesub_info => "Death Note",
        .animetosho_xyz => "Death Note S01E01",
        .kitsunekko_net => "Death Note S01E01",
        .thesubtitledb_org => "Breaking Bad S01E01",
        .napisy24_pl => "Breaking Bad S01E01",
        .nyasub_cz => "30-sai made Doutei dato Mahoutsukai ni Nareru Rashii S01E01",
        .subhd_tv => "Chernobyl S01E01",
        .fansubs_ru => "Death Note",
        .legendei_net => "Chernobyl S01E01",
        .zoom_lk => "Teen Wolf",
        .wizdom_xyz => "Chernobyl S01E01",
        .miraianime_net => "Death Note",
        .animesubtitle_ir => "Wind Breaker",
        .grupahatak_pl => "Teen Wolf",
        .jimaku_cc => "86 Eighty Six",
        else => "Chernobyl",
    };
}

fn runProviderSeriesTest(provider: Provider) !void {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    std.debug.print("[live][providers_app][{s}][series] test_start\n", .{providerName(provider)});
    defer std.debug.print("[live][providers_app][{s}][series] test_end\n", .{providerName(provider)});
    try runProviderTuiSmokeQuery(std.testing.allocator, &client, provider, seriesQueryForProvider(provider), true);
}

fn runSubtitlecatTranslateDownloadLive(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    const provider_name = "subtitlecat_com";
    std.debug.print("[live][providers_app][subtitlecat_com][translate] start\n", .{});

    var search_response = try search(allocator, client, .subtitlecat_com, "The Matrix");
    defer search_response.deinit();
    if (search_response.items.len == 0) return error.TestUnexpectedResult;

    var chosen_subtitle: ?SubtitleChoice = null;
    var chosen_listing_idx: ?usize = null;

    const max_listings = @min(search_response.items.len, @as(usize, 8));
    var i: usize = 0;
    while (i < max_listings and chosen_subtitle == null) : (i += 1) {
        const listing = search_response.items[i];
        var subtitles = fetchSubtitles(allocator, client, listing.ref) catch |err| {
            std.debug.print("[live][providers_app][subtitlecat_com][translate] skip listing={d} err={s}\n", .{ i, @errorName(err) });
            continue;
        };
        defer subtitles.deinit();

        for (subtitles.items) |sub| {
            if (!isSubtitlecatTranslateTokenUrl(sub.download_url)) continue;
            chosen_subtitle = .{
                .label = try allocator.dupe(u8, sub.label),
                .language = try common.dupOptional(allocator, sub.language),
                .filename = try common.dupOptional(allocator, sub.filename),
                .download_url = try common.dupOptional(allocator, sub.download_url),
            };
            chosen_listing_idx = i;
            break;
        }
    }

    if (chosen_subtitle == null) return error.TestUnexpectedResult;
    defer {
        const sub = chosen_subtitle.?;
        allocator.free(sub.label);
        if (sub.language) |v| allocator.free(v);
        if (sub.filename) |v| allocator.free(v);
        if (sub.download_url) |v| allocator.free(v);
    }

    std.debug.print("[live][providers_app][subtitlecat_com][translate] chosen_listing={d}\n", .{chosen_listing_idx.?});
    try common.livePrintField(allocator, "provider", provider_name);
    try common.livePrintField(allocator, "subtitle_label", chosen_subtitle.?.label);
    try common.livePrintOptionalField(allocator, "download_url", chosen_subtitle.?.download_url);

    const unique = common.compatNanoTimestamp();
    const out_dir = try std.fmt.allocPrint(allocator, ".zig-cache/live-downloads/subtitlecat-translate-{d}", .{unique});
    defer allocator.free(out_dir);
    try prepareDownloadOutDir(out_dir);
    defer cleanupDownloadOutDir(out_dir);

    var download = try downloadSubtitleWithOptions(allocator, client, chosen_subtitle.?, out_dir, .{
        .extract_archive = true,
    });
    defer download.deinit(allocator);
    std.debug.print("[live][providers_app][subtitlecat_com][translate] download_ok bytes={d}\n", .{download.bytes_written});
    try common.livePrintField(allocator, "download_file_path", download.file_path);
    try std.Io.Dir.cwd().access(runtime_io.get(), download.file_path, .{});
    if (download.bytes_written == 0) return error.TestUnexpectedResult;
}

fn liveProviderSelected(info: provider_registry.Info) bool {
    const filter = common.liveProviderFilter();
    if (filter) |value| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "active")) return info.active;
    }
    return common.providerMatchesLiveFilter(filter, info.id);
}

test "live providers_app tui-path smoke" {
    if (!shouldRunTuiLiveSmoke(std.testing.allocator)) return error.SkipZigTest;
    var ran = false;
    for (provider_registry.all) |info| {
        if (!liveProviderSelected(info)) continue;
        ran = true;
        try runProviderSmokeTest(info.provider);
    }
    if (!ran) return error.SkipZigTest;
}

test "live providers_app subtitlecat translated download path" {
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "SUBTITLECAT_COM")) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitlecat_com")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try runSubtitlecatTranslateDownloadLive(std.testing.allocator, &client);
}

test "live providers_app series download path" {
    if (!shouldRunTuiLiveSmoke(std.testing.allocator)) return error.SkipZigTest;
    var ran = false;
    for (provider_registry.all) |info| {
        if (!info.supports_tv or !liveProviderSelected(info)) continue;
        ran = true;
        try runProviderSeriesTest(info.provider);
    }
    if (!ran) return error.SkipZigTest;
}

fn freeExtractedPaths(allocator: Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}
test "ZIP extraction verifies CRC and publishes complete bounded output" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    if (!unarr.enabled) {
        try std.testing.expectError(error.ArchiveExtractionUnavailable, extractArchiveFiles(allocator, @embedFile("fixtures/safe.zip"), .zip, root, "bundle.zip"));
        return;
    }
    const paths = try extractArchiveFiles(allocator, @embedFile("fixtures/safe.zip"), .zip, root, "bundle.zip");
    defer freeExtractedPaths(allocator, paths);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expect(!std.mem.eql(u8, paths[0], paths[1]));
    for (paths, [_][]const u8{ "first subtitle", "second subtitle" }) |path, expected| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(100));
        defer allocator.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }
}
test "invalid ZIPs fail before publishing extracted files" {
    if (!unarr.enabled) return error.SkipZigTest;
    const fixtures = [_][]const u8{
        @embedFile("fixtures/empty.zip"),            @embedFile("fixtures/directories.zip"), @embedFile("fixtures/many-directories.zip"),
        @embedFile("fixtures/parent.zip"),           @embedFile("fixtures/drive.zip"),       @embedFile("fixtures/drive-relative.zip"),
        @embedFile("fixtures/unc.zip"),              @embedFile("fixtures/bad-crc.zip"),     @embedFile("fixtures/bad-extra.zip"),
        @embedFile("fixtures/ambiguous-footer.zip"),
    };
    for (fixtures) |body| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer std.testing.allocator.free(root);
        if (extractArchiveFiles(std.testing.allocator, body, .zip, root, "bundle.zip")) |paths| {
            freeExtractedPaths(std.testing.allocator, paths);
            return error.ExpectedArchiveRejection;
        } else |_| {}
        var entries = tmp.dir.iterate();
        try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(runtime_io.get()));
    }
}
test "download publication never replaces existing files or dangling symlinks" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const first = try publishUniqueFile(allocator, root, "movie.srt", "old");
    defer allocator.free(first);
    const second = try publishUniqueFile(allocator, root, "movie.srt", "new");
    defer allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const original = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), first, allocator, .limited(100));
    defer allocator.free(original);
    try std.testing.expectEqualStrings("old", original);
    if (@import("builtin").os.tag != .windows) {
        try tmp.dir.symLink(runtime_io.get(), "missing-target.srt", "link.srt", .{});
        const result = try publishUniqueFile(allocator, root, "link.srt", "safe");
        defer allocator.free(result);
        try std.testing.expect(std.mem.endsWith(u8, result, "link-1.srt"));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(runtime_io.get(), "missing-target.srt", .{}));
    }
}
test "download filenames avoid Windows device names and archive bytes override suffix" {
    for ([_][]const u8{ "CON.srt", "CON .srt", "LPT9.ass", "NUL" }) |name| {
        const safe = try sanitizeFilename(std.testing.allocator, name);
        defer std.testing.allocator.free(safe);
        try std.testing.expect(safe[0] == '_');
    }
    try std.testing.expectEqual(ArchiveKind.rar, detectArchiveKind("wrong.zip", "https://fixture.invalid/x", "Rar!\x1a\x07\x00"));
}

fn checkFilenameAllocationFailures(allocator: Allocator) !void {
    for ([_][]const u8{ "...", "CON.srt", " ordinary.srt ", "file.srt" }) |name| {
        const result = try sanitizeFilename(allocator, name);
        allocator.free(result);
    }
}
test "download filename normalization has no partial ownership on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkFilenameAllocationFailures, .{});
}

const LiveMediaClassification = enum { unknown, movie, series };

fn liveSeriesCandidateMatches(allocator: Allocator, ref: SearchRef, query: []const u8) !bool {
    var classification: LiveMediaClassification = switch (ref) {
        inline else => |item| blk: {
            if (@hasField(@TypeOf(item), "media_kind")) {
                const tag = @tagName(item.media_kind);
                if (std.ascii.eqlIgnoreCase(tag, "movie") or std.ascii.eqlIgnoreCase(tag, "film")) break :blk .movie;
                if (std.ascii.eqlIgnoreCase(tag, "tv") or std.ascii.eqlIgnoreCase(tag, "series") or std.ascii.eqlIgnoreCase(tag, "show") or std.ascii.eqlIgnoreCase(tag, "episode")) break :blk .series;
            }
            break :blk .unknown;
        },
    };
    if (classification == .movie) return false;
    switch (ref) {
        .opensubtitles_com => |item| if (item.item_type) |kind| {
            if (std.ascii.eqlIgnoreCase(kind, "movie")) return false;
            if (std.ascii.eqlIgnoreCase(kind, "tv") or std.ascii.eqlIgnoreCase(kind, "series") or std.ascii.eqlIgnoreCase(kind, "episode")) classification = .series;
        },
        .subdl_com => |item| if (std.ascii.eqlIgnoreCase(@tagName(item.media_type), "movie")) return false,
        .subsource_net => |item| {
            if (std.ascii.eqlIgnoreCase(item.media_type, "movie")) return false;
            if (std.ascii.eqlIgnoreCase(item.media_type, "tv") or std.ascii.eqlIgnoreCase(item.media_type, "series")) classification = .series;
        },
        else => {},
    }
    const title = try common.normalizeTitle(allocator, common.splitTrailingYear(common.parseEpisodeQuery(titleFromRef(ref)).title).title);
    defer allocator.free(title);
    const expected_title = if (ref == .subsunacs_net and std.mem.eql(u8, query, "Game of Thrones 01 01")) "Game of Thrones" else common.parseEpisodeQuery(query).title;
    const expected = try common.normalizeTitle(allocator, expected_title);
    defer allocator.free(expected);
    if (std.mem.indexOf(u8, title, expected) == null) return false;
    // Ambiguous plain-title endpoints otherwise mistake the 2012 movie for
    // the requested miniseries, giving false positive TV coverage.
    if (classification != .series and std.mem.eql(u8, expected, "chernobyl") and !std.mem.eql(u8, title, expected)) return false;
    return true;
}

test "series live selection rejects unrelated and movie-only search hits" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try liveSeriesCandidateMatches(allocator, .{ .isubtitles_org = .{ .title = "Chernobyl Diaries", .details_url = "" } }, "Chernobyl"));
    try std.testing.expect(!try liveSeriesCandidateMatches(allocator, .{ .isubtitles_org = .{ .title = "Crumb", .details_url = "" } }, "Chernobyl"));
    try std.testing.expect(!try liveSeriesCandidateMatches(allocator, .{ .isubtitles_org = .{ .title = "The Battle of Chernobyl", .details_url = "" } }, "Chernobyl"));
    try std.testing.expect(try liveSeriesCandidateMatches(allocator, .{ .isubtitles_org = .{ .title = "Chernobyl (2019)", .details_url = "" } }, "Chernobyl"));
    try std.testing.expect(try liveSeriesCandidateMatches(allocator, .{ .isubtitles_org = .{ .title = "Chernobyl\u{a0}", .details_url = "" } }, "Chernobyl"));
    try std.testing.expect(try liveSeriesCandidateMatches(allocator, .{ .subs_ro = .{
        .title = "Chernobyl - Sezonul 1",
        .year = 2019,
        .media_kind = .tv,
        .language_code = "ro",
        .release = "Chernobyl - Sezonul 1",
        .page_url = "https://subs.ro/subtitrare/chernobyl-sezonul-1-2019/129054",
        .download_url = "https://subs.ro/subtitrare/descarca/chernobyl-sezonul-1-2019/129054",
    } }, "Chernobyl"));
}

test "ZIP download template whitespace preserves exact decoder boundary" {
    const valid = @embedFile("fixtures/safe.zip");
    const padded = valid ++ "\n  \t \r\n";
    const canonical = try canonicalZipBody(padded);
    try std.testing.expectEqualSlices(u8, valid, canonical);
    try preflightZip(canonical);
    try std.testing.expectError(error.ArchiveExtractionFailed, canonicalZipBody(valid ++ "unexpected trailer"));
    try std.testing.expectError(error.ArchiveExtractionFailed, canonicalZipBody(valid ++ (" " ** 4097)));
}

fn applyTranslatedLines(allocator: Allocator, source: []const []const u8, translated: []?[]u8, indices: []const usize, lines: []const []const u8, incomplete: *bool) !void {
    for (indices, 0..) |line_idx, i| {
        const missing = std.mem.trim(u8, lines[i], " \t\r\n").len == 0;
        if (missing) incomplete.* = true;
        translated[line_idx] = try allocator.dupe(u8, if (missing) source[line_idx] else lines[i]);
    }
}
test "empty translated lines preserve source and report incomplete output" {
    const allocator = std.testing.allocator;
    var translated: [2]?[]u8 = @splat(null);
    defer for (translated) |line| if (line) |bytes| allocator.free(bytes);
    var incomplete = false;
    try applyTranslatedLines(allocator, &.{ "Hello", "world" }, &translated, &.{ 0, 1 }, &.{ "Bonjour", "" }, &incomplete);
    try std.testing.expect(incomplete);
    try std.testing.expectEqualStrings("Bonjour", translated[0].?);
    try std.testing.expectEqualStrings("world", translated[1].?);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[[]]", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidField, googleTranslateResultToString(allocator, parsed.value));
}

test "malformed translation fragments cannot silently drop source text" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "[[[\"Bonjour\",\"Hello\"],[null,\" world\"]]]",
        "[[[\"Bonjour\",\"Hello\"],[\"\",\" world\"]]]",
        "[[[\"Bonjour\",\"Hello\"],[]]]",
    }) |payload| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        if (googleTranslateResultToString(allocator, parsed.value)) |result| {
            allocator.free(result);
            return error.ExpectedInvalidTranslation;
        } else |err| {
            try std.testing.expect(err == error.InvalidField or err == error.InvalidFieldType);
        }
    }
}

test "download filenames preserve valid Unicode and guard device aliases" {
    for ([_][2][]const u8{
        .{ "字幕.srt", "字幕.srt" },
        .{ "école.ass", "école.ass" },
        .{ "COM¹.srt", "_COM¹.srt" },
        .{ "LPT².ass", "_LPT².ass" },
    }) |case| {
        const name = try sanitizeFilename(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(name);
        try std.testing.expectEqualStrings(case[1], name);
    }
}
