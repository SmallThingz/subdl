const std = @import("std");
const subdl = @import("../scrapers/subdl.zig");
const runtime_alloc = @import("runtime_alloc");
const runtime_io = @import("runtime_io");
const unarr = @import("unarr");

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

pub const Provider = enum {
    subdl_com,
    opensubtitles_com,
    opensubtitles_org,
    moviesubtitles_org,
    moviesubtitlesrt_com,
    podnapisi_net,
    yifysubtitles_ch,
    subtitlecat_com,
    isubtitles_org,
    my_subs_co,
    subsource_net,
    sub_scene_com,
    tvsubtitles_net,
    gestdown_info,
    greeksubtitles_com,
    subsunacs_net,
    subtitles_ajatt_top,
    subtis_io,
    greeksubs_net,
    indexsubtitle_cc,
    sous_titres_eu,
    cc_edatribe_com,
    subtitrari_noi_ro,
    subs_ro,
    subtitri_nekur_net,
    titrari_ro,
    subs_sab_bz,
    subtitri_do_am,
    prijevodi_online_org,
    animekalesi_com,
    subcentral_de,
    subtitulamos_tv,
    feliratok_eu,
    animesub_info,
    subhd_tv,
    fansubs_ru,
    legendei_net,
    zoom_lk,
    justsubtitles_com,
    wizdom_xyz,
    miraianime_net,
    animesubtitle_ir,
    grupahatak_pl,
    jimaku_cc,
};

const provider_values = [_]Provider{
    .subdl_com,
    .opensubtitles_com,
    .yifysubtitles_ch,
    .subtitlecat_com,
    .isubtitles_org,
    .my_subs_co,
    .subsource_net,
    .sub_scene_com,
    .gestdown_info,
    .subsunacs_net,
    .subtitles_ajatt_top,
    .greeksubs_net,
    .indexsubtitle_cc,
    .sous_titres_eu,
    .cc_edatribe_com,
    .subs_ro,
    .subtitri_nekur_net,
    .titrari_ro,
    .subs_sab_bz,
    .subtitri_do_am,
    .prijevodi_online_org,
    .animekalesi_com,
    .subcentral_de,
    .subtitulamos_tv,
    .feliratok_eu,
    .animesub_info,
    .subhd_tv,
    .fansubs_ru,
    .legendei_net,
    .zoom_lk,
    .justsubtitles_com,
    .wizdom_xyz,
    .miraianime_net,
    .grupahatak_pl,
    .jimaku_cc,
};

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
    return switch (provider) {
        .subdl_com => "subdl_com",
        .opensubtitles_com => "opensubtitles_com",
        .opensubtitles_org => "opensubtitles_org",
        .moviesubtitles_org => "moviesubtitles_org",
        .moviesubtitlesrt_com => "moviesubtitlesrt_com",
        .podnapisi_net => "podnapisi_net",
        .yifysubtitles_ch => "yifysubtitles_ch",
        .subtitlecat_com => "subtitlecat_com",
        .isubtitles_org => "isubtitles_org",
        .my_subs_co => "my_subs_co",
        .subsource_net => "subsource_net",
        .sub_scene_com => "sub_scene_com",
        .tvsubtitles_net => "tvsubtitles_net",
        .gestdown_info => "gestdown_info",
        .greeksubtitles_com => "greek_subtitles_com",
        .subsunacs_net => "subsunacs_net",
        .subtitles_ajatt_top => "subtitles_ajatt_top",
        .subtis_io => "subtis_io",
        .greeksubs_net => "greeksubs_net",
        .indexsubtitle_cc => "indexsubtitle_cc",
        .sous_titres_eu => "sous_titres_eu",
        .cc_edatribe_com => "cc_edatribe_com",
        .subtitrari_noi_ro => "subtitrari_noi_ro",
        .subs_ro => "subs_ro",
        .subtitri_nekur_net => "subtitri_nekur_net",
        .titrari_ro => "titrari_ro",
        .subs_sab_bz => "subs_sab_bz",
        .subtitri_do_am => "subtitri_do_am",
        .prijevodi_online_org => "prijevodi_online_org",
        .animekalesi_com => "animekalesi_com",
        .subcentral_de => "subcentral_de",
        .subtitulamos_tv => "subtitulamos_tv",
        .feliratok_eu => "feliratok_eu",
        .animesub_info => "animesub_info",
        .subhd_tv => "subhd_tv",
        .fansubs_ru => "fansubs_ru",
        .legendei_net => "legendei_net",
        .zoom_lk => "zoom_lk",
        .justsubtitles_com => "justsubtitles_com",
        .wizdom_xyz => "wizdom_xyz",
        .miraianime_net => "miraianime_net",
        .animesubtitle_ir => "animesubtitle_ir",
        .grupahatak_pl => "grupahatak_pl",
        .jimaku_cc => "jimaku_cc",
    };
}

pub const ProviderInfo = struct {
    id: []const u8,
    display_name: []const u8,
    site_url: []const u8,
    supports_search_pagination: bool,
    supports_subtitles_pagination: bool,
    protected: bool,
    supports_movies: bool,
    supports_tv: bool,
};

/// User-facing provider metadata is derived from the enum, not copied into
/// scraper-specific structs. This keeps CLI/TUI provider lists consistent with
/// the actual dispatch table below.
pub fn providerInfo(provider: Provider) ProviderInfo {
    return .{
        .id = providerName(provider),
        .display_name = providerDisplayName(provider),
        .site_url = providerSiteUrl(provider),
        .supports_search_pagination = providerSupportsSearchPagination(provider),
        .supports_subtitles_pagination = providerSupportsSubtitlesPagination(provider),
        .protected = providerRequiresBrowserSession(provider),
        .supports_movies = providerSupportsMovies(provider),
        .supports_tv = providerSupportsTv(provider),
    };
}

pub fn providerDisplayName(provider: Provider) []const u8 {
    return switch (provider) {
        .subdl_com => "SubDL",
        .opensubtitles_com => "OpenSubtitles.com",
        .opensubtitles_org => "OpenSubtitles.org",
        .moviesubtitles_org => "MovieSubtitles.org",
        .moviesubtitlesrt_com => "MovieSubtitlesRT",
        .podnapisi_net => "Podnapisi",
        .yifysubtitles_ch => "YIFY Subtitles",
        .subtitlecat_com => "Subtitle Cat",
        .isubtitles_org => "iSubtitles",
        .my_subs_co => "My Subs",
        .subsource_net => "SubSource",
        .sub_scene_com => "Sub-Scene",
        .tvsubtitles_net => "TVSubtitles",
        .gestdown_info => "Gestdown",
        .greeksubtitles_com => "GreekSubtitles",
        .subsunacs_net => "SubsUnacs",
        .subtitles_ajatt_top => "AJATT Subtitles",
        .subtis_io => "Subtis",
        .greeksubs_net => "GreekSubs",
        .indexsubtitle_cc => "IndexSubtitle",
        .sous_titres_eu => "Sous-Titres.eu",
        .cc_edatribe_com => "Closed Caption Browser",
        .subtitrari_noi_ro => "Subtitrari-Noi",
        .subs_ro => "Subs.ro",
        .subtitri_nekur_net => "Nekur",
        .titrari_ro => "Titrari",
        .subs_sab_bz => "Subs.SAB",
        .subtitri_do_am => "Subtitri",
        .prijevodi_online_org => "Prijevodi Online",
        .animekalesi_com => "AnimeKalesi",
        .subcentral_de => "SubCentral",
        .subtitulamos_tv => "Subtitulamos",
        .feliratok_eu => "SuperSubtitles",
        .animesub_info => "AnimeSub.info",
        .subhd_tv => "SubHD",
        .fansubs_ru => "Fansubs.ru",
        .legendei_net => "Legendei",
        .zoom_lk => "Zoom.LK",
        .justsubtitles_com => "JustSubtitles",
        .wizdom_xyz => "Wizdom",
        .miraianime_net => "MiraiAnime",
        .animesubtitle_ir => "AnimeSubtitle.ir",
        .grupahatak_pl => "GrupaHatak",
        .jimaku_cc => "Jimaku",
    };
}

pub fn providerSiteUrl(provider: Provider) []const u8 {
    return switch (provider) {
        .subdl_com => "https://subdl.com",
        .opensubtitles_com => "https://www.opensubtitles.com",
        .opensubtitles_org => "https://www.opensubtitles.org",
        .moviesubtitles_org => "https://www.moviesubtitles.org",
        .moviesubtitlesrt_com => "https://moviesubtitlesrt.com",
        .podnapisi_net => "https://www.podnapisi.net",
        .yifysubtitles_ch => "https://yifysubtitles.ch",
        .subtitlecat_com => "https://www.subtitlecat.com",
        .isubtitles_org => "https://isubtitles.org",
        .my_subs_co => "https://my-subs.co",
        .subsource_net => "https://subsource.net",
        .sub_scene_com => "https://sub-scene.com",
        .tvsubtitles_net => "https://www.tvsubtitles.net",
        .gestdown_info => "https://www.gestdown.info",
        .greeksubtitles_com => "https://gr.greek-subtitles.com",
        .subsunacs_net => "https://subsunacs.net",
        .subtitles_ajatt_top => "https://subtitles.ajatt.top",
        .subtis_io => "https://subtis.io",
        .greeksubs_net => "https://greeksubs.net",
        .indexsubtitle_cc => "https://indexsubtitle.cc",
        .sous_titres_eu => "https://www.sous-titres.eu",
        .cc_edatribe_com => "https://cc.edatribe.com",
        .subtitrari_noi_ro => "https://www.subtitrari-noi.ro",
        .subs_ro => "https://subs.ro",
        .subtitri_nekur_net => "https://subtitri.nekur.net",
        .titrari_ro => "https://www.titrari.ro",
        .subs_sab_bz => "http://subs.sab.bz",
        .subtitri_do_am => "https://subtitri.do.am",
        .prijevodi_online_org => "https://www.prijevodi-online.org",
        .animekalesi_com => "https://animekalesi.com",
        .subcentral_de => "https://www.subcentral.de",
        .subtitulamos_tv => "https://www.subtitulamos.tv",
        .feliratok_eu => "https://feliratok.eu",
        .animesub_info => "http://animesub.info",
        .subhd_tv => "https://subhd.tv",
        .fansubs_ru => "http://fansubs.ru",
        .legendei_net => "https://legendei.net",
        .zoom_lk => "https://zoom.lk",
        .justsubtitles_com => "https://www.justsubtitles.com",
        .wizdom_xyz => "https://wizdom.xyz",
        .miraianime_net => "https://miraianime.net",
        .animesubtitle_ir => "https://animesubtitle.ir",
        .grupahatak_pl => "https://grupahatak.pl",
        .jimaku_cc => "https://jimaku.cc",
    };
}

pub fn providerRequiresBrowserSession(provider: Provider) bool {
    _ = provider;
    return false;
}

pub fn providerSupportsMovies(provider: Provider) bool {
    return switch (provider) {
        .tvsubtitles_net, .gestdown_info, .prijevodi_online_org, .animekalesi_com, .subcentral_de, .subtitulamos_tv, .grupahatak_pl => false,
        else => true,
    };
}

pub fn providerSupportsTv(provider: Provider) bool {
    return switch (provider) {
        .moviesubtitles_org, .moviesubtitlesrt_com, .yifysubtitles_ch, .subtis_io, .subtitri_do_am, .subtitri_nekur_net, .feliratok_eu, .justsubtitles_com => false,
        else => true,
    };
}

pub fn providerSupportsSearchPagination(provider: Provider) bool {
    return switch (provider) {
        .opensubtitles_org, .moviesubtitlesrt_com, .podnapisi_net, .isubtitles_org => true,
        else => false,
    };
}

pub fn providerSupportsSubtitlesPagination(provider: Provider) bool {
    return switch (provider) {
        .opensubtitles_org, .isubtitles_org => true,
        else => false,
    };
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
        if (normalizeProviderChar(input[i]) != normalizeProviderChar(canonical[i])) return false;
    }
    return true;
}

fn matchesProvider(input: []const u8, canonical: []const u8) bool {
    if (input.len != canonical.len) return false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (normalizeProviderChar(input[i]) != normalizeProviderChar(canonical[i])) return false;
    }
    return true;
}

fn normalizeProviderChar(c: u8) u8 {
    return switch (c) {
        '.', '-' => '_',
        else => std.ascii.toLower(c),
    };
}

pub fn providerSelectionAll() [provider_values.len]bool {
    return [_]bool{true} ** provider_values.len;
}

pub fn providerSelectionNone() [provider_values.len]bool {
    return [_]bool{false} ** provider_values.len;
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
    opensubtitles_org: struct {
        title: []const u8,
        page_url: []const u8,
    },
    moviesubtitles_org: struct {
        title: []const u8,
        link: []const u8,
    },
    moviesubtitlesrt_com: struct {
        title: []const u8,
        page_url: []const u8,
    },
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
    sub_scene_com: struct {
        title: []const u8,
        page_url: []const u8,
    },
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
    indexsubtitle_cc: struct {
        title: []const u8,
        page_url: []const u8,
    },
    sous_titres_eu: struct {
        title: []const u8,
        media_kind: subdl.sous_titres_eu.MediaKind,
        page_url: []const u8,
    },
    cc_edatribe_com: struct {
        title: []const u8,
        media_kind: subdl.cc_edatribe_com.MediaKind,
        page_url: []const u8,
    },
    subtitrari_noi_ro: struct {
        title: []const u8,
        year: ?i64,
        page_url: []const u8,
        download_url: []const u8,
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
    subtitri_nekur_net: struct {
        title: []const u8,
        year: ?i64,
        imdb_id: ?[]const u8,
        fps: ?[]const u8,
        page_url: []const u8,
        download_url: []const u8,
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
    subtitri_do_am: struct {
        title: []const u8,
        page_url: []const u8,
    },
    prijevodi_online_org: struct {
        title: []const u8,
        series_id: i64,
        slug: []const u8,
        page_url: []const u8,
    },
    animekalesi_com: struct {
        title: []const u8,
        page_url: []const u8,
    },
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
    grupahatak_pl: struct {
        title: []const u8,
        page_url: []const u8,
    },
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

pub const SubdlSeasonChoice = struct {
    label: []const u8,
    season_slug: []const u8,
};

pub const SubdlSeasonsResponse = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    items: []const SubdlSeasonChoice,

    pub fn deinit(self: *SubdlSeasonsResponse) void {
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
    bytes_written: usize,
    source_url: []const u8,

    pub fn deinit(self: *DownloadResult, allocator: Allocator) void {
        allocator.free(self.file_path);
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
            defer scraper.deinit();
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
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const year = try dupOptional(a, item.year);
                const item_type = try dupOptional(a, item.item_type);
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            var scraper = subdl.moviesubtitlesrt_com.Scraper.init(allocator, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            var scraper = subdl.sub_scene_com.Scraper.init(allocator, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .sub_scene_com = .{
                        .title = title,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .tvsubtitles_net => {
            var scraper = subdl.tvsubtitles_net.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const language_code = try dupOptional(a, item.language_code);
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            var scraper = subdl.indexsubtitle_cc.Scraper.init(allocator, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .indexsubtitle_cc = .{
                        .title = title,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .sous_titres_eu => {
            var scraper = subdl.sous_titres_eu.Scraper.init(allocator, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try std.fmt.allocPrint(a, "[{s}] {s}", .{ @tagName(item.media_kind), title }),
                    .ref = .{ .sous_titres_eu = .{
                        .title = title,
                        .media_kind = item.media_kind,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .cc_edatribe_com => {
            var scraper = subdl.cc_edatribe_com.Scraper.init(allocator, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try std.fmt.allocPrint(a, "[{s}] {s}", .{ @tagName(item.media_kind), title }),
                    .ref = .{ .cc_edatribe_com = .{
                        .title = title,
                        .media_kind = item.media_kind,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .subtitrari_noi_ro => {
            var scraper = subdl.subtitrari_noi_ro.Scraper.init(allocator, client);
            defer scraper.deinit();
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
        .subs_ro => {
            var scraper = subdl.subs_ro.Scraper.init(allocator, client);
            defer scraper.deinit();
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
        .subtitri_nekur_net => {
            var scraper = subdl.subtitri_nekur_net.Scraper.init(allocator, client);
            defer scraper.deinit();
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
                        .imdb_id = try dupOptional(a, item.imdb_id),
                        .fps = try dupOptional(a, item.fps),
                        .page_url = try a.dupe(u8, item.page_url),
                        .download_url = try a.dupe(u8, item.download_url),
                    } },
                });
            }
        },
        .titrari_ro => {
            var scraper = subdl.titrari_ro.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            var scraper = subdl.subtitri_do_am.Scraper.init(allocator, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try a.dupe(u8, title),
                    .ref = .{ .subtitri_do_am = .{
                        .title = title,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .prijevodi_online_org => {
            var scraper = subdl.prijevodi_online_org.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            var scraper = subdl.animekalesi_com.Scraper.init(allocator, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try std.fmt.allocPrint(a, "[tv] {s}", .{title}),
                    .ref = .{ .animekalesi_com = .{
                        .title = title,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .subcentral_de => {
            var scraper = subdl.subcentral_de.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
        .subhd_tv => {
            var scraper = subdl.subhd_tv.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            var scraper = subdl.grupahatak_pl.Scraper.init(allocator, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                try out.append(a, .{
                    .label = try std.fmt.allocPrint(a, "[tv] {s} • pl", .{title}),
                    .ref = .{ .grupahatak_pl = .{
                        .title = title,
                        .page_url = try a.dupe(u8, item.page_url),
                    } },
                });
            }
        },
        .jimaku_cc => {
            var scraper = subdl.jimaku_cc.Scraper.init(allocator, client);
            defer scraper.deinit();
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

    return .{
        .arena = arena,
        .provider = provider,
        .items = try out.toOwnedSlice(a),
    };
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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

    return .{
        .arena = arena,
        .provider = provider,
        .items = try out.toOwnedSlice(a),
        .page = requested_page,
        .has_prev_page = requested_page > 1,
        .has_next_page = has_next_page,
    };
}

pub fn fetchSubdlSeasons(allocator: Allocator, client: *std.http.Client, ref: SearchRef) !SubdlSeasonsResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SubdlSeasonChoice) = .empty;
    var title: []const u8 = "";

    switch (ref) {
        .subdl_com => |item| {
            if (item.media_type != .tv) return error.UnexpectedTitleType;
            var scraper = subdl.subdl_com.Scraper.init(allocator, client);
            defer scraper.deinit();

            var seasons = try scraper.fetchTvSeasonsByLink(item.link);
            defer seasons.deinit();
            title = try a.dupe(u8, seasons.tv.name);

            for (seasons.seasons) |season| {
                const season_slug = try a.dupe(u8, season.number);
                const label = if (season.name.len == 0 or std.mem.eql(u8, season.name, season.number))
                    try a.dupe(u8, season.number)
                else
                    try std.fmt.allocPrint(a, "{s} ({s})", .{ season.name, season.number });
                try out.append(a, .{
                    .label = label,
                    .season_slug = season_slug,
                });
            }
        },
        else => return error.UnsupportedProvider,
    }

    return .{
        .arena = arena,
        .title = title,
        .items = try out.toOwnedSlice(a),
    };
}

pub fn fetchSubdlSeasonSubtitles(allocator: Allocator, client: *std.http.Client, ref: SearchRef, season_slug: []const u8) !SubtitlesResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SubtitleChoice) = .empty;
    var title: []const u8 = "";

    switch (ref) {
        .subdl_com => |item| {
            if (item.media_type != .tv) return error.UnexpectedTitleType;
            var scraper = subdl.subdl_com.Scraper.init(allocator, client);
            defer scraper.deinit();

            var season_data = try scraper.fetchTvSeasonByLink(item.link, season_slug);
            defer season_data.deinit();
            title = try std.fmt.allocPrint(a, "{s} • {s}", .{ season_data.tv.name, season_slug });

            for (season_data.languages) |group| {
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
        else => return error.UnsupportedProvider,
    }

    return .{
        .arena = arena,
        .provider = .subdl_com,
        .title = title,
        .items = try out.toOwnedSlice(a),
    };
}

pub fn fetchSubdlSeasonSubtitlesPage(
    allocator: Allocator,
    client: *std.http.Client,
    ref: SearchRef,
    season_slug: []const u8,
    page: usize,
) !SubtitlesResponse {
    const requested_page = if (page == 0) 1 else page;
    if (requested_page == 1) {
        var first = try fetchSubdlSeasonSubtitles(allocator, client, ref, season_slug);
        first.page = 1;
        first.has_prev_page = false;
        first.has_next_page = false;
        return first;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    return .{
        .arena = arena,
        .provider = .subdl_com,
        .title = titleFromRef(ref),
        .items = &.{},
        .page = requested_page,
        .has_prev_page = true,
        .has_next_page = false,
    };
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
            defer scraper.deinit();

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
                        var season_data = scraper.fetchTvSeasonByLink(item.link, season.number) catch continue;
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
            defer scraper.deinit();

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
                    .language = try dupOptional(a, subtitle.language),
                    .filename = try dupOptional(a, subtitle.filename),
                    .download_url = try a.dupe(u8, download_url),
                });
            }
        },
        .opensubtitles_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.opensubtitles_org.Scraper.init(allocator, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByMoviePage(item.page_url);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const download_url = if (subtitle.direct_zip_url.len > 0) subtitle.direct_zip_url else null;
                const filename = subtitle.filename orelse subtitle.release;
                const label = try subtitleLabel(a, subtitle.language_code, filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try dupOptional(a, filename),
                    .download_url = try dupOptional(a, download_url),
                });
            }
        },
        .moviesubtitles_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.moviesubtitles_org.Scraper.init(allocator, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByMovieLink(item.link);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .moviesubtitlesrt_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.moviesubtitlesrt_com.Scraper.init(allocator, client);
            defer scraper.deinit();
            var subtitle = try scraper.fetchSubtitleByLink(item.page_url);
            defer subtitle.deinit();
            title = try a.dupe(u8, subtitle.subtitle.title);

            const label = try subtitleLabel(a, subtitle.subtitle.language_code, subtitle.subtitle.title, subtitle.subtitle.download_url);
            try out.append(a, .{
                .label = label,
                .language = try dupOptional(a, subtitle.subtitle.language_code),
                .filename = try a.dupe(u8, subtitle.subtitle.title),
                .download_url = try a.dupe(u8, subtitle.subtitle.download_url),
            });
        },
        .podnapisi_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.podnapisi_net.Scraper.init(allocator, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesBySearchLink(item.subtitles_page_url);
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language, subtitle.release, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language),
                    .filename = try dupOptional(a, subtitle.release),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .yifysubtitles_ch => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.yifysubtitles_ch.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByDetailsLink(item.details_url);
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                var resolved_download_url: ?[]const u8 = try dupOptional(a, subtitle.download_url);
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
                    .language = try dupOptional(a, subtitle.language_code orelse subtitle.language_label),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = resolved_download_url,
                });
            }
        },
        .isubtitles_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.isubtitles_org.Scraper.init(allocator, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByMovieLinkWithOptions(item.details_url, .{ .max_pages = 3 });
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_page_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_page_url),
                });
            }
        },
        .my_subs_co => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.my_subs_co.Scraper.init(allocator, client);
            defer scraper.deinit();
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
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, download_url),
                });
            }
        },
        .subsource_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subsource_net.Scraper.init(allocator, client);
            defer scraper.deinit();

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
            });
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const filename = subtitle.release_info orelse subtitle.release_type;
                const download_url = try makeSubsourceRemoteToken(a, subtitle.details_path);
                const label = try subtitleLabel(a, subtitle.language_code, filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try dupOptional(a, filename),
                    .download_url = download_url,
                });
            }
        },
        .sub_scene_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.sub_scene_com.Scraper.init(allocator, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitles(item.page_url);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const filename = subtitle.release orelse "Without release";
                const label = try subtitleLabel(a, subtitle.language_code orelse subtitle.language, filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code orelse subtitle.language),
                    .filename = try a.dupe(u8, filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .tvsubtitles_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.tvsubtitles_net.Scraper.init(allocator, client);
            defer scraper.deinit();
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
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, download_url),
                });
            }
        },
        .gestdown_info => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.gestdown_info.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            defer scraper.deinit();
            const query_item: subdl.greeksubtitles_com.SearchItem = .{
                .title = item.title,
                .language_code = item.language_code,
                .page_url = item.page_url,
                .download_url = item.download_url,
                .downloads = null,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subsunacs_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subsunacs_net.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.subsunacs_net.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .page_url = item.page_url,
                .download_page_url = item.download_page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, "en", subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, "en"),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subtitles_ajatt_top => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitles_ajatt_top.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.subtitles_ajatt_top.SearchItem = .{
                .title = item.title,
                .english_name = null,
                .japanese_name = null,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, "ja", subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, "ja"),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subtis_io => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtis_io.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.subtis_io.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .slug = item.slug,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, "es", subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, "es"),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .greeksubs_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.greeksubs_net.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.greeksubs_net.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .indexsubtitle_cc => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.indexsubtitle_cc.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            defer scraper.deinit();
            const query_item: subdl.sous_titres_eu.SearchItem = .{
                .title = item.title,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .cc_edatribe_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.cc_edatribe_com.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.cc_edatribe_com.SearchItem = .{
                .title = item.title,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subtitrari_noi_ro => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitrari_noi_ro.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.subtitrari_noi_ro.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .page_url = item.page_url,
                .download_url = item.download_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subs_ro => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subs_ro.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subtitri_nekur_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitri_nekur_net.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .titrari_ro => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.titrari_ro.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subs_sab_bz => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subs_sab_bz.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subtitri_do_am => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitri_do_am.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.subtitri_do_am.SearchItem = .{
                .title = item.title,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .prijevodi_online_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.prijevodi_online_org.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.prijevodi_online_org.SearchItem = .{
                .title = item.title,
                .series_id = item.series_id,
                .slug = item.slug,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try std.fmt.allocPrint(
                    a,
                    "S{d:0>2}E{d:0>2} • {s} • {s}",
                    .{ subtitle.season, subtitle.episode, subtitle.language_code, subtitle.filename },
                );
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .animekalesi_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.animekalesi_com.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.animekalesi_com.SearchItem = .{
                .title = item.title,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try std.fmt.allocPrint(
                    a,
                    "S{d:0>2}E{d:0>2} • {s} • {s}",
                    .{ subtitle.season, subtitle.episode, subtitle.language_code, subtitle.filename },
                );
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subcentral_de => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subcentral_de.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .animesub_info => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.animesub_info.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .subhd_tv => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subhd_tv.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .fansubs_ru => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.fansubs_ru.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.fansubs_ru.SearchItem = .{
                .title = item.title,
                .media_id = item.media_id,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .legendei_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.legendei_net.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .zoom_lk => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.zoom_lk.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.zoom_lk.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .media_kind = item.media_kind,
                .season = item.season,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .justsubtitles_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.justsubtitles_com.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .animesubtitle_ir => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.animesubtitle_ir.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.animesubtitle_ir.SearchItem = .{
                .title = item.title,
                .post_id = item.post_id,
                .media_kind = item.media_kind,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .grupahatak_pl => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.grupahatak_pl.Scraper.init(allocator, client);
            defer scraper.deinit();
            const query_item: subdl.grupahatak_pl.SearchItem = .{
                .title = item.title,
                .page_url = item.page_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItem(query_item);
            defer subtitles.deinit();
            for (subtitles.subtitles) |subtitle| {
                const label = try std.fmt.allocPrint(
                    a,
                    "S{d:0>2}E{d:0>2} • {s} • {s}",
                    .{ subtitle.season, subtitle.episode, subtitle.language_code, subtitle.filename },
                );
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .jimaku_cc => |item| {
            title = try a.dupe(u8, item.english_name orelse item.title);
            var scraper = subdl.jimaku_cc.Scraper.init(allocator, client);
            defer scraper.deinit();
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
            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
    }

    return .{
        .arena = arena,
        .provider = std.meta.activeTag(ref),
        .title = title,
        .items = try out.toOwnedSlice(a),
    };
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
    var title = titleFromRef(ref);
    var has_next_page = false;

    switch (ref) {
        .opensubtitles_org => |item| {
            var scraper = subdl.opensubtitles_org.Scraper.init(allocator, client);
            defer scraper.deinit();
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
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try dupOptional(a, filename),
                    .download_url = try dupOptional(a, download_url),
                });
            }
        },
        .isubtitles_org => |item| {
            var scraper = subdl.isubtitles_org.Scraper.init(allocator, client);
            defer scraper.deinit();
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
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_page_url),
                });
            }
        },
        else => return error.UnsupportedProvider,
    }

    return .{
        .arena = arena,
        .provider = provider,
        .title = title,
        .items = try out.toOwnedSlice(a),
        .page = requested_page,
        .has_prev_page = requested_page > 1,
        .has_next_page = has_next_page,
    };
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
    return .{
        .arena = arena,
        .provider = std.meta.activeTag(ref),
        .title = titleFromRef(ref),
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
        .subs_ro => |item| item.title,
        .subtitri_nekur_net => |item| item.title,
        .titrari_ro => |item| item.title,
        .subs_sab_bz => |item| item.title,
        .subtitri_do_am => |item| item.title,
        .prijevodi_online_org => |item| item.title,
        .animekalesi_com => |item| item.title,
        .subcentral_de => |item| item.title,
        .subtitulamos_tv => |item| item.title,
        .feliratok_eu => |item| item.title,
        .animesub_info => |item| item.title,
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

    emitDownloadPhase(progress, .resolving_url);
    const greeksubs_download = subdl.greeksubs_net.parseDownloadToken(source_url) != null;
    const indexsubtitle_download = subdl.indexsubtitle_cc.parseDownloadToken(source_url) != null;
    const titrari_download = subdl.titrari_ro.parseDownloadToken(source_url) != null;
    const subs_sab_download = subdl.subs_sab_bz.parseDownloadToken(source_url) != null;
    const animekalesi_download = subdl.animekalesi_com.parseDownloadToken(source_url) != null;
    const animesub_download = subdl.animesub_info.parseDownloadToken(source_url) != null;
    const subhd_download = subdl.subhd_tv.parseDownloadToken(source_url) != null;
    const fansubs_download = subdl.fansubs_ru.parseDownloadToken(source_url) != null;
    const grupahatak_download = subdl.grupahatak_pl.parseDownloadToken(source_url) != null;
    const url = if (greeksubs_download or indexsubtitle_download or titrari_download or subs_sab_download or animekalesi_download or animesub_download or subhd_download or fansubs_download or grupahatak_download)
        try allocator.dupe(u8, source_url)
    else
        try resolveDownloadUrlIfNeeded(allocator, client, source_url);
    defer allocator.free(url);

    emitDownloadPhase(progress, .downloading_file);
    const response = if (greeksubs_download) blk: {
        var scraper = subdl.greeksubs_net.Scraper.init(allocator, client);
        defer scraper.deinit();
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (indexsubtitle_download) blk: {
        var scraper = subdl.indexsubtitle_cc.Scraper.init(allocator, client);
        defer scraper.deinit();
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (titrari_download) blk: {
        var scraper = subdl.titrari_ro.Scraper.init(allocator, client);
        defer scraper.deinit();
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (subs_sab_download) blk: {
        var scraper = subdl.subs_sab_bz.Scraper.init(allocator, client);
        defer scraper.deinit();
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (animekalesi_download) blk: {
        var scraper = subdl.animekalesi_com.Scraper.init(allocator, client);
        defer scraper.deinit();
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (animesub_download) blk: {
        var scraper = subdl.animesub_info.Scraper.init(allocator, client);
        defer scraper.deinit();
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (subhd_download) blk: {
        var scraper = subdl.subhd_tv.Scraper.init(allocator, client);
        defer scraper.deinit();
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (fansubs_download) blk: {
        var scraper = subdl.fansubs_ru.Scraper.init(allocator, client);
        defer scraper.deinit();
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else if (grupahatak_download) blk: {
        var scraper = subdl.grupahatak_pl.Scraper.init(allocator, client);
        defer scraper.deinit();
        break :blk try scraper.fetchDownloadByToken(allocator, source_url);
    } else try fetchDownloadBytes(client, allocator, url);
    defer allocator.free(response.body);
    if (response.status != .ok) return error.UnexpectedHttpStatus;
    const body = response.body;
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

    const output_path = try nextAvailableOutputPath(allocator, out_dir, safe_name);
    errdefer allocator.free(output_path);
    try std.Io.Dir.cwd().writeFile(runtime_io.get(), .{ .sub_path = output_path, .data = body });

    if (archive_kind == .none) {
        return .{
            .file_path = output_path,
            .bytes_written = bytes_written,
            .source_url = source_url,
        };
    }

    const archive_copy = try allocator.dupe(u8, output_path);
    errdefer allocator.free(archive_copy);

    if (!options.extract_archive) {
        return .{
            .file_path = output_path,
            .archive_path = archive_copy,
            .bytes_written = bytes_written,
            .source_url = source_url,
        };
    }

    emitDownloadPhase(progress, .extracting_archive);
    const extracted_files = if (archive_kind == .zip)
        extractZipArchiveFiles(allocator, out_dir, output_path) catch
            try extractArchiveFiles(allocator, body, archive_kind, out_dir, output_path)
    else
        try extractArchiveFiles(allocator, body, archive_kind, out_dir, output_path);
    errdefer {
        for (extracted_files) |path| allocator.free(path);
        allocator.free(extracted_files);
    }

    return .{
        .file_path = output_path,
        .archive_path = archive_copy,
        .extracted_files = extracted_files,
        .bytes_written = bytes_written,
        .source_url = source_url,
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
    emitDownloadPhase(progress, .fetching_source);
    const source_response = try common.fetchBytes(client, allocator, token.source_url, .{
        .accept = "text/plain,*/*",
        .allow_non_ok = true,
        .max_attempts = 2,
    });
    defer allocator.free(source_response.body);
    if (source_response.status != .ok) return error.UnexpectedHttpStatus;

    const target_lang = languageToGoogleCode(token.target_lang) orelse "";

    emitDownloadPhase(progress, .translating);
    const translated_text = if (target_lang.len > 0)
        translateSubtitlecatSrt(allocator, client, source_response.body, target_lang, progress) catch
            try allocator.dupe(u8, source_response.body)
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

    const output_path = try nextAvailableOutputPath(allocator, out_dir, safe_name);
    errdefer allocator.free(output_path);
    try std.Io.Dir.cwd().writeFile(runtime_io.get(), .{ .sub_path = output_path, .data = translated_text });

    return .{
        .file_path = output_path,
        .bytes_written = translated_text.len,
        .source_url = source_token,
    };
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
            const batch = SubtitlecatBatch{
                .text = try batch_text.toOwnedSlice(allocator),
                .indices = try batch_indices.toOwnedSlice(allocator),
            };
            defer allocator.free(batch.text);
            defer allocator.free(batch.indices);
            batch_text.clearRetainingCapacity();
            batch_indices.clearRetainingCapacity();
            try applySubtitlecatBatch(allocator, client, lines.items, translated.items, batch, target_lang, progress, &done_units, total_units);
        }

        if (batch_indices.items.len > 0) try batch_text.appendSlice(allocator, subtitlecat_batch_separator);
        try batch_text.appendSlice(allocator, sanitized);
        try batch_indices.append(allocator, idx);
    }

    if (batch_indices.items.len > 0) {
        const batch = SubtitlecatBatch{
            .text = try batch_text.toOwnedSlice(allocator),
            .indices = try batch_indices.toOwnedSlice(allocator),
        };
        defer allocator.free(batch.text);
        defer allocator.free(batch.indices);
        try applySubtitlecatBatch(allocator, client, lines.items, translated.items, batch, target_lang, progress, &done_units, total_units);
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
) !void {
    const translated_batch = translateViaGoogle(allocator, client, batch.text, target_lang) catch null;
    if (translated_batch) |batch_text| {
        defer allocator.free(batch_text);
        var out_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer out_lines.deinit(allocator);

        var line_it = std.mem.splitSequence(u8, batch_text, subtitlecat_batch_separator);
        while (line_it.next()) |line| try out_lines.append(allocator, line);

        if (out_lines.items.len == batch.indices.len) {
            for (batch.indices, 0..) |line_idx, i| {
                translated_lines[line_idx] = try allocator.dupe(u8, out_lines.items[i]);
            }
            done_units.* += batch.indices.len;
            emitDownloadUnits(progress, done_units.*, total_units);
            return;
        }
    }

    // A provider response can normalize separators. Do not turn that into one
    // network request per subtitle line; preserve the source batch instead.
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
        if (part != .array) continue;
        if (part.array.items.len == 0) continue;
        if (part.array.items[0] != .string) continue;
        try out.appendSlice(allocator, part.array.items[0].string);
    }

    return try out.toOwnedSlice(allocator);
}

/// Some providers publish an intermediate download page instead of the final
/// archive URL. Resolve only the known cases here; all other URLs are treated
/// as already-downloadable.
fn resolveDownloadUrlIfNeeded(allocator: Allocator, client: *std.http.Client, download_url: []const u8) ![]const u8 {
    if (parseOpenSubtitlesRemoteToken(download_url)) |remote_endpoint| {
        var scraper = subdl.opensubtitles_com.Scraper.init(allocator, client);
        defer scraper.deinit();
        if (try scraper.resolveVerifiedDownloadUrl(allocator, remote_endpoint)) |resolved| return resolved;
        return error.InvalidDownloadUrl;
    }

    if (parseSubsourceRemoteToken(download_url)) |details_path| {
        var scraper = subdl.subsource_net.Scraper.init(allocator, client);
        defer scraper.deinit();
        return try scraper.resolveDownloadUrl(allocator, details_path) orelse error.InvalidDownloadUrl;
    }

    if (std.mem.indexOf(u8, download_url, "my-subs.co/downloads/") != null) {
        var scraper = subdl.my_subs_co.Scraper.init(allocator, client);
        defer scraper.deinit();
        return scraper.resolveDownloadPageUrl(allocator, download_url);
    }

    if (std.mem.indexOf(u8, download_url, "tvsubtitles.net/download-") != null) {
        var scraper = subdl.tvsubtitles_net.Scraper.init(allocator, client);
        defer scraper.deinit();
        return scraper.resolveDownloadPageUrl(allocator, download_url);
    }

    return allocator.dupe(u8, download_url);
}

/// Download fetch has provider-specific recovery hooks because several sites
/// accept normal search requests but protect binary/archive endpoints.
fn fetchDownloadBytes(client: *std.http.Client, allocator: Allocator, url: []const u8) !common.HttpResponse {
    const yify_referer = yifyRefererForUrl(url);
    const provider_headers = if (yify_referer) |referer|
        &[_]std.http.Header{.{ .name = "referer", .value = referer }}
    else
        &[_]std.http.Header{};

    const primary = try common.fetchBytes(client, allocator, url, .{
        .accept = "*/*",
        .extra_headers = provider_headers,
        .allow_non_ok = true,
        .max_attempts = 2,
    });

    if (primary.status == .ok) return primary;
    const was_forbidden = primary.status == .forbidden;
    allocator.free(primary.body);

    if (was_forbidden) {
        if (cloudflareTargetForUrl(url)) |target| {
            const with_cf = try fetchBytesWithCloudflareSession(client, allocator, url, target.domain, target.challenge_url, "*/*", yify_referer);
            if (with_cf.status == .ok) return with_cf;
            allocator.free(with_cf.body);
        }
    }

    return error.UnexpectedHttpStatus;
}

const CloudflareTarget = struct {
    domain: []const u8,
    challenge_url: []const u8,
};

fn cloudflareTargetForUrl(url: []const u8) ?CloudflareTarget {
    if (std.mem.indexOf(u8, url, "opensubtitles.com/") != null) {
        return .{
            .domain = "www.opensubtitles.com",
            .challenge_url = "https://www.opensubtitles.com/",
        };
    }

    return null;
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
    var session = try cf.ensureDomainSession(allocator, .{
        .domain = domain,
        .challenge_url = challenge_url,
    });
    defer session.deinit(allocator);

    const first = try fetchBytesUsingSession(client, allocator, url, accept, referer, session);
    if (first.status != .forbidden) return first;
    allocator.free(first.body);

    var refreshed = try cf.ensureDomainSession(allocator, .{
        .domain = domain,
        .challenge_url = challenge_url,
        .force_refresh = true,
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
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "cookie", .value = session.cookie_header });
    try headers.append(allocator, .{ .name = "user-agent", .value = session.user_agent });
    if (referer) |value| {
        try headers.append(allocator, .{ .name = "referer", .value = value });
    }

    return common.fetchBytes(client, allocator, url, .{
        .accept = accept,
        .extra_headers = headers.items,
        .allow_non_ok = true,
        .max_attempts = 2,
    });
}

const ArchiveKind = enum {
    none,
    zip,
    rar,
    seven_z,
};

/// Prefer filename/URL extensions but fall back to magic bytes because many
/// subtitle providers serve archives from extensionless download endpoints.
fn detectArchiveKind(file_name: []const u8, url: []const u8, body: []const u8) ArchiveKind {
    if (std.ascii.endsWithIgnoreCase(file_name, ".zip") or std.ascii.endsWithIgnoreCase(url, ".zip")) return .zip;
    if (std.ascii.endsWithIgnoreCase(file_name, ".rar") or std.ascii.endsWithIgnoreCase(url, ".rar")) return .rar;
    if (std.ascii.endsWithIgnoreCase(file_name, ".7z") or std.ascii.endsWithIgnoreCase(url, ".7z")) return .seven_z;
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "PK\x03\x04")) return .zip;
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "PK\x05\x06")) return .zip;
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "PK\x07\x08")) return .zip;
    if (body.len >= 7 and std.mem.eql(u8, body[0..7], "Rar!\x1A\x07\x00")) return .rar;
    if (body.len >= 8 and std.mem.eql(u8, body[0..8], "Rar!\x1A\x07\x01\x00")) return .rar;
    if (body.len >= 6 and std.mem.eql(u8, body[0..6], "\x37\x7A\xBC\xAF\x27\x1C")) return .seven_z;
    return .none;
}

const max_archive_entry_size_bytes: usize = 64 * 1024 * 1024;
const max_archive_entries: usize = 256;

fn extractArchiveFiles(
    allocator: Allocator,
    archive_body: []const u8,
    archive_kind: ArchiveKind,
    out_dir: []const u8,
    archive_path: []const u8,
) ![]const []const u8 {
    _ = archive_path;
    if (comptime !unarr.enabled) {
        return error.ArchiveExtractionUnavailable;
    }

    const archive_format: unarr.Format = switch (archive_kind) {
        .zip => .zip,
        .rar => .rar,
        .seven_z => .@"7z",
        .none => return error.ArchiveExtractionFailed,
    };

    var archive = unarr.Archive.openMemory(archive_format, archive_body, .{}) catch return error.ArchiveExtractionFailed;
    defer archive.deinit();

    var extracted: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (extracted.items) |path| allocator.free(path);
        extracted.deinit(allocator);
    }

    var entry_index: usize = 0;
    while (entry_index < max_archive_entries) : (entry_index += 1) {
        const maybe_entry = archive.nextEntry() catch return error.ArchiveExtractionFailed;
        const entry = maybe_entry orelse break;
        if (entry.size() == 0) continue;

        const entry_name = entry.name() orelse entry.rawName() orelse "";
        if (std.mem.endsWith(u8, entry_name, "/") or std.mem.endsWith(u8, entry_name, "\\")) continue;

        const entry_base_name = try archiveEntryOutputName(allocator, entry_name, entry_index + 1);
        defer allocator.free(entry_base_name);

        const entry_data = entry.readAlloc(allocator, max_archive_entry_size_bytes) catch |err| switch (err) {
            error.EntryTooLarge => continue,
            else => return error.ArchiveExtractionFailed,
        };
        defer allocator.free(entry_data);
        if (entry_data.len == 0) continue;

        const output_path = try nextAvailableOutputPath(allocator, out_dir, entry_base_name);
        errdefer allocator.free(output_path);

        std.Io.Dir.cwd().writeFile(runtime_io.get(), .{ .sub_path = output_path, .data = entry_data }) catch return error.ArchiveExtractionFailed;

        try extracted.append(allocator, output_path);
    }

    if (extracted.items.len == 0) return error.ArchiveExtractionFailed;
    return try extracted.toOwnedSlice(allocator);
}

fn extractZipArchiveFiles(
    allocator: Allocator,
    out_dir: []const u8,
    archive_path: []const u8,
) ![]const []const u8 {
    const extract_dir_name = try extractionDirBaseName(allocator, archive_path);
    defer allocator.free(extract_dir_name);
    const extract_dir_path = try nextAvailableOutputPath(allocator, out_dir, extract_dir_name);
    errdefer allocator.free(extract_dir_path);

    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), extract_dir_path);
    var dest_dir = try std.Io.Dir.cwd().openDir(runtime_io.get(), extract_dir_path, .{ .iterate = true });
    defer dest_dir.close(runtime_io.get());

    var archive_file = try std.Io.Dir.cwd().openFile(runtime_io.get(), archive_path, .{});
    defer archive_file.close(runtime_io.get());
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = archive_file.reader(runtime_io.get(), &file_buf);

    std.zip.extract(dest_dir, &file_reader, .{ .allow_backslashes = true }) catch return error.ArchiveExtractionFailed;
    const files = try collectExtractedFilesRecursive(allocator, extract_dir_path);
    allocator.free(extract_dir_path);
    if (files.len == 0) {
        allocator.free(files);
        return error.ArchiveExtractionFailed;
    }
    return files;
}

fn extractionDirBaseName(allocator: Allocator, archive_path: []const u8) ![]u8 {
    const base = pathBaseNameLocal(archive_path);
    const sanitized = try sanitizeFilename(allocator, base);
    defer allocator.free(sanitized);
    const raw_stem = if (std.mem.lastIndexOfScalar(u8, sanitized, '.')) |dot| sanitized[0..dot] else sanitized;
    const stem = std.mem.trim(u8, raw_stem, " .");
    const chosen = if (stem.len == 0) "archive" else stem;
    return try std.fmt.allocPrint(allocator, "{s}.extracted", .{chosen});
}

fn collectExtractedFilesRecursive(allocator: Allocator, root_path: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }
    try collectExtractedFilesRecursiveInner(allocator, root_path, &out);
    return try out.toOwnedSlice(allocator);
}

fn collectExtractedFilesRecursiveInner(
    allocator: Allocator,
    dir_path: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(runtime_io.get(), dir_path, .{ .iterate = true });
    defer dir.close(runtime_io.get());
    var it = dir.iterate();
    while (try it.next(runtime_io.get())) |entry| {
        var renamed_name: ?[]u8 = null;
        defer if (renamed_name) |name| allocator.free(name);

        const entry_name = if (archiveExtractedNameNeedsSanitizing(entry.name)) blk: {
            const sanitized = try sanitizeFilename(allocator, entry.name);
            defer allocator.free(sanitized);
            const candidate_path = try nextAvailableOutputPath(allocator, dir_path, sanitized);
            defer allocator.free(candidate_path);
            const candidate_name = pathBaseNameLocal(candidate_path);
            const owned_name = try allocator.dupe(u8, candidate_name);
            errdefer allocator.free(owned_name);
            try dir.rename(entry.name, dir, owned_name, runtime_io.get());
            renamed_name = owned_name;
            break :blk owned_name;
        } else entry.name;

        const path = try std.fs.path.join(allocator, &.{ dir_path, entry_name });
        errdefer allocator.free(path);
        switch (entry.kind) {
            .file => try out.append(allocator, path),
            .directory => {
                try collectExtractedFilesRecursiveInner(allocator, path, out);
                allocator.free(path);
            },
            else => allocator.free(path),
        }
    }
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

fn dupOptional(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
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
    const trimmed = std.mem.trim(u8, pathBaseNameLocal(name), " \t\r\n.");
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

fn pathBaseNameLocal(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[slash + 1 ..];
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

    for (input) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '-' or c == '_' or c == ' ' or c == '(' or c == ')';
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
        allocator.free(owned);
        return try allocator.dupe(u8, "subtitle.bin");
    }
    if (trimmed.len == owned.len) return owned;

    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return duped;
}

fn nextAvailableOutputPath(allocator: Allocator, out_dir: []const u8, base_name: []const u8) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const file_name = if (attempt == 0)
            try allocator.dupe(u8, base_name)
        else
            try appendNumericSuffix(allocator, base_name, attempt);
        defer allocator.free(file_name);

        const full_path = try std.fs.path.join(allocator, &.{ out_dir, file_name });
        errdefer allocator.free(full_path);
        std.Io.Dir.cwd().access(runtime_io.get(), full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return full_path,
            else => return err,
        };
        allocator.free(full_path);
    }
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
        .subs_ro => "The Matrix",
        .subtitri_nekur_net => "The Matrix",
        .titrari_ro => "The Matrix Resurrections",
        .subs_sab_bz => "The Matrix",
        .subtitri_do_am => "The Matrix",
        .prijevodi_online_org => "Chernobyl",
        .animekalesi_com => "Death Note",
        .subcentral_de => "Breaking Bad",
        .subtitulamos_tv => "Chernobyl",
        .feliratok_eu => "The Matrix",
        .animesub_info => "Spirited Away",
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
        .subs_ro => |item| item.page_url,
        .subtitri_nekur_net => |item| item.page_url,
        .titrari_ro => |item| item.page_url,
        .subs_sab_bz => |item| item.page_url,
        .subtitri_do_am => |item| item.page_url,
        .prijevodi_online_org => |item| item.page_url,
        .animekalesi_com => |item| item.page_url,
        .subcentral_de => |item| item.thread_url,
        .subtitulamos_tv => |item| item.page_url,
        .feliratok_eu => |item| item.page_url,
        .animesub_info => |item| item.page_url,
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

fn iterDownloadCandidates(subtitles: []const SubtitleChoice, prefer_archive: bool, cursor: usize) ?usize {
    var seen: usize = 0;
    for (subtitles, 0..) |sub, idx| {
        const url = sub.download_url orelse continue;
        const is_archive_hint = likelyArchiveSource(url, sub.filename);
        if (prefer_archive and !is_archive_hint) continue;
        if (!prefer_archive and is_archive_hint) continue;
        if (seen == cursor) return idx;
        seen += 1;
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
        "yifysubtitles_ch",
        "subtitlecat_com",
        "isubtitles_org",
        "my_subs_co",
        "subsource_net",
        "sub_scene_com",
        "gestdown_info",
        "subsunacs_net",
        "subtitles_ajatt_top",
        "greeksubs_net",
        "indexsubtitle_cc",
        "sous_titres_eu",
        "cc_edatribe_com",
        "subs_ro",
        "subtitri_nekur_net",
        "titrari_ro",
        "subs_sab_bz",
        "subtitri_do_am",
        "prijevodi_online_org",
        "animekalesi_com",
        "subcentral_de",
        "subtitulamos_tv",
        "feliratok_eu",
        "animesub_info",
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
    try std.testing.expect(parseProvider("moviesubtitles.org") == null);
    try std.testing.expect(parseProvider("moviesubtitlesrt.com") == null);
    try std.testing.expect(parseProvider("podnapisi.net") == null);
    try std.testing.expect(parseProvider("yifysubtitles.ch") == .yifysubtitles_ch);
    try std.testing.expect(parseProvider("subtitlecat.com") == .subtitlecat_com);
    try std.testing.expect(parseProvider("isubtitles.org") == .isubtitles_org);
    try std.testing.expect(parseProvider("my-subs.co") == .my_subs_co);
    try std.testing.expect(parseProvider("subsource.net") == .subsource_net);
    try std.testing.expect(parseProvider("sub-scene.com") == .sub_scene_com);
    try std.testing.expect(parseProvider("tvsubtitles.net") == null);
    try std.testing.expect(parseProvider("gestdown.info") == .gestdown_info);
    try std.testing.expect(parseProvider("greek-subtitles.com") == null);
    try std.testing.expect(parseProvider("subsunacs.net") == .subsunacs_net);
    try std.testing.expect(parseProvider("subtitles.ajatt.top") == .subtitles_ajatt_top);
    try std.testing.expect(parseProvider("subtis.io") == null);
    try std.testing.expect(parseProvider("greeksubs.net") == .greeksubs_net);
    try std.testing.expect(parseProvider("indexsubtitle.cc") == .indexsubtitle_cc);
    try std.testing.expect(parseProvider("sous-titres.eu") == .sous_titres_eu);
    try std.testing.expect(parseProvider("cc.edatribe.com") == .cc_edatribe_com);
    try std.testing.expect(parseProvider("subtitrari-noi.ro") == null);
    try std.testing.expect(parseProvider("subs.ro") == .subs_ro);
    try std.testing.expect(parseProvider("subtitri.nekur.net") == .subtitri_nekur_net);
    try std.testing.expect(parseProvider("titrari.ro") == .titrari_ro);
    try std.testing.expect(parseProvider("subs.sab.bz") == .subs_sab_bz);
    try std.testing.expect(parseProvider("subtitri.do.am") == .subtitri_do_am);
    try std.testing.expect(parseProvider("prijevodi-online.org") == .prijevodi_online_org);
    try std.testing.expect(parseProvider("animekalesi.com") == .animekalesi_com);
    try std.testing.expect(parseProvider("subcentral.de") == .subcentral_de);
    try std.testing.expect(parseProvider("subtitulamos.tv") == .subtitulamos_tv);
    try std.testing.expect(parseProvider("feliratok.eu") == .feliratok_eu);
    try std.testing.expect(parseProvider("animesub.info") == .animesub_info);
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
    try std.testing.expect(try resolveProvider("my_subs") == .my_subs_co);
    try std.testing.expect(try resolveProvider("subsource") == .subsource_net);
    try std.testing.expect(try resolveProvider("sub_scene") == .sub_scene_com);
    try std.testing.expect(try resolveProvider("gestdown") == .gestdown_info);
    try std.testing.expectError(error.UnknownProvider, resolveProvider("greek_subtitles"));
    try std.testing.expect(try resolveProvider("subsunacs") == .subsunacs_net);
    try std.testing.expect(try resolveProvider("subtitles_ajatt") == .subtitles_ajatt_top);
    try std.testing.expect(try resolveProvider("greeksubs") == .greeksubs_net);
    try std.testing.expect(try resolveProvider("indexsubtitle") == .indexsubtitle_cc);
    try std.testing.expect(try resolveProvider("sous_titres") == .sous_titres_eu);
    try std.testing.expect(try resolveProvider("cc_edatribe") == .cc_edatribe_com);
    try std.testing.expect(try resolveProvider("subs_ro") == .subs_ro);
    try std.testing.expect(try resolveProvider("subtitri_nekur") == .subtitri_nekur_net);
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

test "yify referer is only added for yifysubtitles hosts" {
    try std.testing.expectEqualStrings("https://yifysubtitles.ch/", yifyRefererForUrl("https://yifysubtitles.ch/subtitle/test.zip").?);
    try std.testing.expect(yifyRefererForUrl("https://www.opensubtitles.com/file.zip") == null);
}

test "cloudflare target excludes yify downloads" {
    try std.testing.expect(cloudflareTargetForUrl("https://yifysubtitles.ch/subtitle/test.zip") == null);
    try std.testing.expect(cloudflareTargetForUrl("https://www.opensubtitles.com/nocache/download/123") != null);
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

const ProviderSmokeState = struct {
    provider: Provider,
    err: ?anyerror = null,
};

fn runProviderSmokeWorker(state: *ProviderSmokeState) void {
    const start_ms = common.compatMilliTimestamp();
    std.debug.print("[live][providers_app][{s}] worker_start state=0x{x}\n", .{
        providerName(state.provider),
        @intFromPtr(state),
    });
    defer {
        const elapsed_ms = common.compatMilliTimestamp() - start_ms;
        if (state.err) |err| {
            std.debug.print("[live][providers_app][{s}] worker_end status=err err={s} elapsed_ms={d}\n", .{
                providerName(state.provider),
                @errorName(err),
                elapsed_ms,
            });
        } else {
            std.debug.print("[live][providers_app][{s}] worker_end status=ok elapsed_ms={d}\n", .{
                providerName(state.provider),
                elapsed_ms,
            });
        }
    }

    var allocator_state = runtime_alloc.RuntimeAllocator.init();
    defer allocator_state.deinit();
    const allocator = allocator_state.allocator();

    var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    var phase = common.LivePhase.init(providerName(state.provider), "providers_app_tui_smoke");
    phase.start();
    runProviderTuiSmoke(allocator, &client, state.provider) catch |err| {
        phase.finish();
        state.err = err;
        return;
    };
    phase.finish();
}

fn runProviderTuiSmoke(allocator: std.mem.Allocator, client: *std.http.Client, provider: Provider) !void {
    const query = liveQueryForProvider(provider);
    return runProviderTuiSmokeQuery(allocator, client, provider, query);
}

fn runProviderTuiSmokeQuery(allocator: std.mem.Allocator, client: *std.http.Client, provider: Provider, query: []const u8) !void {
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
        var candidate_subtitles = fetchSubtitles(allocator, client, candidate.ref) catch |err| {
            std.debug.print("[live][providers_app][{s}] skip_search={d} err={s}\n", .{ providerName(provider), idx, @errorName(err) });
            continue;
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
    if (download.archive_path != null and download.extracted_files.len == 0) return error.TestUnexpectedResult;
    if (download.extracted_files.len > 0) {
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
        .subs_ro => "Chernobyl",
        .titrari_ro => "Reacher",
        .subs_sab_bz => "Reacher",
        .prijevodi_online_org => "Chernobyl",
        .animekalesi_com => "Death Note",
        .subcentral_de => "Breaking Bad",
        .subtitulamos_tv => "Chernobyl",
        .animesub_info => "Death Note",
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

fn runSingleProviderSeriesTest(provider: Provider) !void {
    if (!providerSupportsTv(provider) or !shouldRunSingleProviderSmoke(provider)) return error.SkipZigTest;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    std.debug.print("[live][providers_app][{s}][series] test_start\n", .{providerName(provider)});
    defer std.debug.print("[live][providers_app][{s}][series] test_end\n", .{providerName(provider)});
    try runProviderTuiSmokeQuery(std.testing.allocator, &client, provider, seriesQueryForProvider(provider));
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
                .language = try dupOptional(allocator, sub.language),
                .filename = try dupOptional(allocator, sub.filename),
                .download_url = try dupOptional(allocator, sub.download_url),
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

const tui_smoke_providers = [_]Provider{
    .subdl_com,
    .opensubtitles_com,
    .yifysubtitles_ch,
    .subtitlecat_com,
    .isubtitles_org,
    .my_subs_co,
    .subsource_net,
    .sub_scene_com,
    .gestdown_info,
    .subsunacs_net,
    .subtitles_ajatt_top,
    .subtis_io,
    .greeksubs_net,
    .indexsubtitle_cc,
    .sous_titres_eu,
    .cc_edatribe_com,
    .subs_ro,
    .subtitri_nekur_net,
    .subtitrari_noi_ro,
    .titrari_ro,
    .subs_sab_bz,
    .subtitri_do_am,
    .prijevodi_online_org,
    .animekalesi_com,
    .subcentral_de,
    .subtitulamos_tv,
    .feliratok_eu,
    .animesub_info,
    .subhd_tv,
    .fansubs_ru,
    .legendei_net,
    .zoom_lk,
    .justsubtitles_com,
    .wizdom_xyz,
    .miraianime_net,
    .animesubtitle_ir,
    .grupahatak_pl,
    .jimaku_cc,
};

fn runProvidersSmokeBatch(allocator: std.mem.Allocator, selected: []const Provider) !void {
    if (selected.len == 0) return error.SkipZigTest;
    std.debug.print("[live][providers_app] starting threaded smoke batch count={d}\n", .{selected.len});

    const states = try allocator.alloc(ProviderSmokeState, selected.len);
    defer allocator.free(states);
    for (selected, 0..) |provider, idx| {
        states[idx] = .{ .provider = provider };
    }

    const threads = try allocator.alloc(std.Thread, selected.len);
    defer allocator.free(threads);
    for (threads, states) |*thread, *state| {
        thread.* = try std.Thread.spawn(.{}, runProviderSmokeWorker, .{state});
    }
    for (threads) |thread| thread.join();
    std.debug.print("[live][providers_app] threaded smoke batch complete count={d}\n", .{selected.len});

    var first_err: ?anyerror = null;
    for (states) |state| {
        if (state.err) |err| {
            std.log.err("providers_app live smoke failed for {s}: {s}", .{
                providerName(state.provider),
                @errorName(err),
            });
            if (first_err == null) first_err = err;
        }
    }
    if (first_err) |err| return err;
}

fn isWholeSelection(filter: ?[]const u8) bool {
    const f = filter orelse return true;
    const trimmed = std.mem.trim(u8, f, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (std.mem.indexOfScalar(u8, trimmed, ',') != null) return true;
    if (std.mem.eql(u8, trimmed, "*")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return true;
    return false;
}

fn liveBatchEnabled() bool {
    const value = common.getenv("SCRAPERS_LIVE_BATCH") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn isCaptchaProvider(provider: Provider) bool {
    _ = provider;
    return false;
}

fn shouldRunSingleProviderSmoke(provider: Provider) bool {
    if (!shouldRunTuiLiveSmoke(std.testing.allocator)) return false;
    if (isCaptchaProvider(provider) and !common.liveIncludeCaptchaEnabled()) return false;
    return common.providerMatchesLiveFilter(common.liveProviderFilter(), providerName(provider));
}

fn runSingleProviderSmokeTest(provider: Provider) !void {
    if (!shouldRunSingleProviderSmoke(provider)) return error.SkipZigTest;
    std.debug.print("[live][providers_app][{s}] test_start\n", .{providerName(provider)});
    defer std.debug.print("[live][providers_app][{s}] test_end\n", .{providerName(provider)});
    const selected = [_]Provider{provider};
    try runProvidersSmokeBatch(std.testing.allocator, &selected);
}

test "live providers_app tui-path smoke: non-captcha providers" {
    if (!shouldRunTuiLiveSmoke(std.testing.allocator)) return error.SkipZigTest;
    if (!liveBatchEnabled()) return error.SkipZigTest;
    std.debug.print("[live][providers_app] tui-path smoke enabled\n", .{});

    const filter = common.liveProviderFilter();
    const whole_selection = isWholeSelection(filter);
    if (filter) |f| {
        std.debug.print("[live][providers_app] filter={s} is_whole={any}\n", .{ f, whole_selection });
    } else {
        std.debug.print("[live][providers_app] filter=<null> is_whole={any}\n", .{whole_selection});
    }
    if (!whole_selection) return error.SkipZigTest;

    var selected: std.ArrayListUnmanaged(Provider) = .empty;
    defer selected.deinit(std.testing.allocator);
    for (tui_smoke_providers) |provider| {
        if (isCaptchaProvider(provider) and !common.liveIncludeCaptchaEnabled()) continue;
        if (!common.providerMatchesLiveFilter(filter, providerName(provider))) continue;
        try selected.append(std.testing.allocator, provider);
    }
    if (selected.items.len == 0) return error.SkipZigTest;
    try runProvidersSmokeBatch(std.testing.allocator, selected.items);
}

test "live providers_app tui-path smoke provider: subdl.com" {
    try runSingleProviderSmokeTest(.subdl_com);
}

test "live providers_app tui-path smoke provider: isubtitles.org" {
    try runSingleProviderSmokeTest(.isubtitles_org);
}

test "live providers_app tui-path smoke provider: moviesubtitles.org" {
    try runSingleProviderSmokeTest(.moviesubtitles_org);
}

test "live providers_app tui-path smoke provider: moviesubtitlesrt.com" {
    try runSingleProviderSmokeTest(.moviesubtitlesrt_com);
}

test "live providers_app tui-path smoke provider: my-subs.co" {
    try runSingleProviderSmokeTest(.my_subs_co);
}

test "live providers_app tui-path smoke provider: podnapisi.net" {
    try runSingleProviderSmokeTest(.podnapisi_net);
}

test "live providers_app tui-path smoke provider: subtitlecat.com" {
    try runSingleProviderSmokeTest(.subtitlecat_com);
}

test "live providers_app subtitlecat translated download path" {
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "SUBTITLECAT_COM")) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitlecat_com")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try runSubtitlecatTranslateDownloadLive(std.testing.allocator, &client);
}

test "live providers_app tui-path smoke provider: subsource.net" {
    try runSingleProviderSmokeTest(.subsource_net);
}

test "live providers_app tui-path smoke provider: tvsubtitles.net" {
    try runSingleProviderSmokeTest(.tvsubtitles_net);
}

test "live providers_app tui-path smoke provider: opensubtitles.com" {
    try runSingleProviderSmokeTest(.opensubtitles_com);
}

test "live providers_app tui-path smoke provider: opensubtitles.org" {
    try runSingleProviderSmokeTest(.opensubtitles_org);
}

test "live providers_app tui-path smoke provider: yifysubtitles.ch" {
    try runSingleProviderSmokeTest(.yifysubtitles_ch);
}

test "live providers_app tui-path smoke provider: sub-scene.com" {
    try runSingleProviderSmokeTest(.sub_scene_com);
}

test "live providers_app tui-path smoke provider: gestdown.info" {
    try runSingleProviderSmokeTest(.gestdown_info);
}

test "live providers_app tui-path smoke provider: greeksubtitles.com" {
    try runSingleProviderSmokeTest(.greeksubtitles_com);
}

test "live providers_app tui-path smoke provider: subsunacs.net" {
    try runSingleProviderSmokeTest(.subsunacs_net);
}

test "live providers_app tui-path smoke provider: subtitles.ajatt.top" {
    try runSingleProviderSmokeTest(.subtitles_ajatt_top);
}

test "live providers_app tui-path smoke provider: subtis.io" {
    try runSingleProviderSmokeTest(.subtis_io);
}

test "live providers_app tui-path smoke provider: greeksubs.net" {
    try runSingleProviderSmokeTest(.greeksubs_net);
}

test "live providers_app tui-path smoke provider: indexsubtitle.cc" {
    try runSingleProviderSmokeTest(.indexsubtitle_cc);
}

test "live providers_app tui-path smoke provider: sous-titres.eu" {
    try runSingleProviderSmokeTest(.sous_titres_eu);
}

test "live providers_app tui-path smoke provider: cc.edatribe.com" {
    try runSingleProviderSmokeTest(.cc_edatribe_com);
}

test "live providers_app tui-path smoke provider: subtitrari-noi.ro" {
    try runSingleProviderSmokeTest(.subtitrari_noi_ro);
}

test "live providers_app tui-path smoke provider: subs.ro" {
    try runSingleProviderSmokeTest(.subs_ro);
}

test "live providers_app tui-path smoke provider: subtitri.nekur.net" {
    try runSingleProviderSmokeTest(.subtitri_nekur_net);
}

test "live providers_app tui-path smoke provider: titrari.ro" {
    try runSingleProviderSmokeTest(.titrari_ro);
}

test "live providers_app tui-path smoke provider: subs.sab.bz" {
    try runSingleProviderSmokeTest(.subs_sab_bz);
}

test "live providers_app tui-path smoke provider: subtitri.do.am" {
    try runSingleProviderSmokeTest(.subtitri_do_am);
}

test "live providers_app tui-path smoke provider: prijevodi-online.org" {
    try runSingleProviderSmokeTest(.prijevodi_online_org);
}

test "live providers_app tui-path smoke provider: animekalesi.com" {
    try runSingleProviderSmokeTest(.animekalesi_com);
}

test "live providers_app tui-path smoke provider: subcentral.de" {
    try runSingleProviderSmokeTest(.subcentral_de);
}

test "live providers_app tui-path smoke provider: subtitulamos.tv" {
    try runSingleProviderSmokeTest(.subtitulamos_tv);
}

test "live providers_app tui-path smoke provider: feliratok.eu" {
    try runSingleProviderSmokeTest(.feliratok_eu);
}

test "live providers_app tui-path smoke provider: animesub.info" {
    try runSingleProviderSmokeTest(.animesub_info);
}

test "live providers_app tui-path smoke provider: subhd.tv" {
    try runSingleProviderSmokeTest(.subhd_tv);
}

test "live providers_app tui-path smoke provider: fansubs.ru" {
    try runSingleProviderSmokeTest(.fansubs_ru);
}

test "live providers_app tui-path smoke provider: legendei.net" {
    try runSingleProviderSmokeTest(.legendei_net);
}

test "live providers_app tui-path smoke provider: zoom.lk" {
    try runSingleProviderSmokeTest(.zoom_lk);
}

test "live providers_app tui-path smoke provider: justsubtitles.com" {
    try runSingleProviderSmokeTest(.justsubtitles_com);
}

test "live providers_app tui-path smoke provider: wizdom.xyz" {
    try runSingleProviderSmokeTest(.wizdom_xyz);
}

test "live providers_app tui-path smoke provider: miraianime.net" {
    try runSingleProviderSmokeTest(.miraianime_net);
}

test "live providers_app tui-path smoke provider: animesubtitle.ir" {
    try runSingleProviderSmokeTest(.animesubtitle_ir);
}

test "live providers_app tui-path smoke provider: grupahatak.pl" {
    try runSingleProviderSmokeTest(.grupahatak_pl);
}

test "live providers_app tui-path smoke provider: jimaku.cc" {
    try runSingleProviderSmokeTest(.jimaku_cc);
}

test "live series download path provider: subdl.com" {
    try runSingleProviderSeriesTest(.subdl_com);
}

test "live series download path provider: opensubtitles.com" {
    try runSingleProviderSeriesTest(.opensubtitles_com);
}

test "live series download path provider: opensubtitles.org" {
    try runSingleProviderSeriesTest(.opensubtitles_org);
}

test "live series download path provider: podnapisi.net" {
    try runSingleProviderSeriesTest(.podnapisi_net);
}

test "live series download path provider: subtitlecat.com" {
    try runSingleProviderSeriesTest(.subtitlecat_com);
}

test "live series download path provider: isubtitles.org" {
    try runSingleProviderSeriesTest(.isubtitles_org);
}

test "live series download path provider: my-subs.co" {
    try runSingleProviderSeriesTest(.my_subs_co);
}

test "live series download path provider: subsource.net" {
    try runSingleProviderSeriesTest(.subsource_net);
}

test "live series download path provider: sub-scene.com" {
    try runSingleProviderSeriesTest(.sub_scene_com);
}

test "live series download path provider: tvsubtitles.net" {
    try runSingleProviderSeriesTest(.tvsubtitles_net);
}

test "live series download path provider: gestdown.info" {
    try runSingleProviderSeriesTest(.gestdown_info);
}

test "live series download path provider: greeksubtitles.com" {
    try runSingleProviderSeriesTest(.greeksubtitles_com);
}

test "live series download path provider: subsunacs.net" {
    try runSingleProviderSeriesTest(.subsunacs_net);
}

test "live series download path provider: subtitles.ajatt.top" {
    try runSingleProviderSeriesTest(.subtitles_ajatt_top);
}

test "live series download path provider: greeksubs.net" {
    try runSingleProviderSeriesTest(.greeksubs_net);
}

test "live series download path provider: indexsubtitle.cc" {
    try runSingleProviderSeriesTest(.indexsubtitle_cc);
}

test "live series download path provider: sous-titres.eu" {
    try runSingleProviderSeriesTest(.sous_titres_eu);
}

test "live series download path provider: cc.edatribe.com" {
    try runSingleProviderSeriesTest(.cc_edatribe_com);
}

test "live series download path provider: subtitrari-noi.ro" {
    try runSingleProviderSeriesTest(.subtitrari_noi_ro);
}

test "live series download path provider: subs.ro" {
    try runSingleProviderSeriesTest(.subs_ro);
}

test "live series download path provider: titrari.ro" {
    try runSingleProviderSeriesTest(.titrari_ro);
}

test "live series download path provider: subs.sab.bz" {
    try runSingleProviderSeriesTest(.subs_sab_bz);
}

test "live series download path provider: prijevodi-online.org" {
    try runSingleProviderSeriesTest(.prijevodi_online_org);
}

test "live series download path provider: animekalesi.com" {
    try runSingleProviderSeriesTest(.animekalesi_com);
}

test "live series download path provider: subcentral.de" {
    try runSingleProviderSeriesTest(.subcentral_de);
}

test "live series download path provider: subtitulamos.tv" {
    try runSingleProviderSeriesTest(.subtitulamos_tv);
}

test "live series download path provider: animesub.info" {
    try runSingleProviderSeriesTest(.animesub_info);
}

test "live series download path provider: subhd.tv" {
    try runSingleProviderSeriesTest(.subhd_tv);
}

test "live series download path provider: fansubs.ru" {
    try runSingleProviderSeriesTest(.fansubs_ru);
}

test "live series download path provider: legendei.net" {
    try runSingleProviderSeriesTest(.legendei_net);
}

test "live series download path provider: zoom.lk" {
    try runSingleProviderSeriesTest(.zoom_lk);
}

test "live series download path provider: wizdom.xyz" {
    try runSingleProviderSeriesTest(.wizdom_xyz);
}

test "live series download path provider: miraianime.net" {
    try runSingleProviderSeriesTest(.miraianime_net);
}

test "live series download path provider: animesubtitle.ir" {
    try runSingleProviderSeriesTest(.animesubtitle_ir);
}

test "live series download path provider: grupahatak.pl" {
    try runSingleProviderSeriesTest(.grupahatak_pl);
}

test "live series download path provider: jimaku.cc" {
    try runSingleProviderSeriesTest(.jimaku_cc);
}
