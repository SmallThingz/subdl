const std = @import("std");

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
    subclub_eu,
    subs_ro,
    subs4free_info,
    tsukihime_org,
    subtitri_nekur_net,
    subsynchro_com,
    titrari_ro,
    subs_sab_bz,
    subtitri_do_am,
    prijevodi_online_org,
    animekalesi_com,
    subcentral_de,
    subtitulamos_tv,
    feliratok_eu,
    animesub_info,
    animetosho_xyz,
    kitsunekko_net,
    thesubtitledb_org,
    napisy24_pl,
    nyasub_cz,
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

pub const Info = struct {
    provider: Provider,
    id: []const u8,
    live_name: []const u8,
    display_name: []const u8,
    site_url: []const u8,
    active: bool = true,
    supports_search_pagination: bool = false,
    supports_subtitles_pagination: bool = false,
    supports_movies: bool = true,
    supports_tv: bool = true,
    live_timeout_seconds: ?u32 = null,
    live_serial: bool = false,
};

pub const all = [_]Info{
    .{ .provider = .subdl_com, .id = "subdl_com", .live_name = "subdl.com", .display_name = "SubDL", .site_url = "https://subdl.com" },
    .{ .provider = .opensubtitles_com, .id = "opensubtitles_com", .live_name = "opensubtitles.com", .display_name = "OpenSubtitles.com", .site_url = "https://www.opensubtitles.com" },
    .{ .provider = .opensubtitles_org, .id = "opensubtitles_org", .live_name = "opensubtitles.org", .display_name = "OpenSubtitles.org", .site_url = "https://www.opensubtitles.org", .active = false, .supports_search_pagination = true, .supports_subtitles_pagination = true },
    .{ .provider = .moviesubtitles_org, .id = "moviesubtitles_org", .live_name = "moviesubtitles.org", .display_name = "MovieSubtitles.org", .site_url = "https://www.moviesubtitles.org", .supports_tv = false },
    .{ .provider = .moviesubtitlesrt_com, .id = "moviesubtitlesrt_com", .live_name = "moviesubtitlesrt.com", .display_name = "MovieSubtitlesRT", .site_url = "https://moviesubtitlesrt.com", .active = false, .supports_search_pagination = true, .supports_tv = false },
    .{ .provider = .podnapisi_net, .id = "podnapisi_net", .live_name = "podnapisi.net", .display_name = "Podnapisi", .site_url = "https://www.podnapisi.net", .active = false, .supports_search_pagination = true },
    .{ .provider = .yifysubtitles_ch, .id = "yifysubtitles_ch", .live_name = "yifysubtitles.ch", .display_name = "YIFY Subtitles", .site_url = "https://yifysubtitles.ch", .supports_tv = false, .live_timeout_seconds = 120 },
    .{ .provider = .subtitlecat_com, .id = "subtitlecat_com", .live_name = "subtitlecat.com", .display_name = "Subtitle Cat", .site_url = "https://www.subtitlecat.com" },
    .{ .provider = .isubtitles_org, .id = "isubtitles_org", .live_name = "isubtitles.org", .display_name = "iSubtitles", .site_url = "https://isubtitles.org", .supports_search_pagination = true, .supports_subtitles_pagination = true, .live_timeout_seconds = 120 },
    .{ .provider = .my_subs_co, .id = "my_subs_co", .live_name = "my-subs.co", .display_name = "My Subs", .site_url = "https://my-subs.co", .active = false },
    .{ .provider = .subsource_net, .id = "subsource_net", .live_name = "subsource.net", .display_name = "SubSource", .site_url = "https://subsource.net" },
    .{ .provider = .sub_scene_com, .id = "sub_scene_com", .live_name = "sub-scene.com", .display_name = "Sub-Scene", .site_url = "https://sub-scene.com", .live_timeout_seconds = 120, .live_serial = true },
    .{ .provider = .tvsubtitles_net, .id = "tvsubtitles_net", .live_name = "tvsubtitles.net", .display_name = "TVSubtitles", .site_url = "https://www.tvsubtitles.net", .active = false, .supports_movies = false },
    .{ .provider = .gestdown_info, .id = "gestdown_info", .live_name = "gestdown.info", .display_name = "Gestdown", .site_url = "https://www.gestdown.info", .supports_movies = false },
    .{ .provider = .greeksubtitles_com, .id = "greek_subtitles_com", .live_name = "greek-subtitles.com", .display_name = "GreekSubtitles", .site_url = "https://gr.greek-subtitles.com", .active = false, .live_timeout_seconds = 240 },
    .{ .provider = .subsunacs_net, .id = "subsunacs_net", .live_name = "subsunacs.net", .display_name = "SubsUnacs", .site_url = "https://subsunacs.net", .live_timeout_seconds = 120, .live_serial = true },
    .{ .provider = .subtitles_ajatt_top, .id = "subtitles_ajatt_top", .live_name = "subtitles.ajatt.top", .display_name = "AJATT Subtitles", .site_url = "https://subtitles.ajatt.top" },
    .{ .provider = .subtis_io, .id = "subtis_io", .live_name = "subtis.io", .display_name = "Subtis", .site_url = "https://subtis.io", .active = false, .supports_tv = false },
    .{ .provider = .greeksubs_net, .id = "greeksubs_net", .live_name = "greeksubs.net", .display_name = "GreekSubs", .site_url = "https://greeksubs.net" },
    .{ .provider = .indexsubtitle_cc, .id = "indexsubtitle_cc", .live_name = "indexsubtitle.cc", .display_name = "IndexSubtitle", .site_url = "https://indexsubtitle.cc", .live_serial = true },
    .{ .provider = .sous_titres_eu, .id = "sous_titres_eu", .live_name = "sous-titres.eu", .display_name = "Sous-Titres.eu", .site_url = "https://www.sous-titres.eu" },
    .{ .provider = .cc_edatribe_com, .id = "cc_edatribe_com", .live_name = "cc.edatribe.com", .display_name = "Closed Caption Browser", .site_url = "https://cc.edatribe.com", .live_serial = true },
    .{ .provider = .subtitrari_noi_ro, .id = "subtitrari_noi_ro", .live_name = "subtitrari-noi.ro", .display_name = "Subtitrari-Noi", .site_url = "https://www.subtitrari-noi.ro", .active = false },
    .{ .provider = .subclub_eu, .id = "subclub_eu", .live_name = "subclub.eu", .display_name = "SubClub", .site_url = "https://www.subclub.eu", .live_serial = true },
    .{ .provider = .subs_ro, .id = "subs_ro", .live_name = "subs.ro", .display_name = "Subs.ro", .site_url = "https://subs.ro", .live_serial = true },
    .{ .provider = .subs4free_info, .id = "subs4free_info", .live_name = "subs4free.info", .display_name = "Subs4Free", .site_url = "https://www.subs4free.info", .supports_tv = false, .live_serial = true },
    .{ .provider = .tsukihime_org, .id = "tsukihime_org", .live_name = "tsukihime.org", .display_name = "TsukiHime", .site_url = "https://tsukihime.org", .live_timeout_seconds = 120 },
    .{ .provider = .subtitri_nekur_net, .id = "subtitri_nekur_net", .live_name = "subtitri.nekur.net", .display_name = "Nekur", .site_url = "https://subtitri.nekur.net", .supports_tv = false },
    .{ .provider = .subsynchro_com, .id = "subsynchro_com", .live_name = "subsynchro.com", .display_name = "Subsynchro", .site_url = "http://www.subsynchro.com", .supports_tv = false, .live_serial = true },
    .{ .provider = .titrari_ro, .id = "titrari_ro", .live_name = "titrari.ro", .display_name = "Titrari", .site_url = "https://www.titrari.ro" },
    .{ .provider = .subs_sab_bz, .id = "subs_sab_bz", .live_name = "subs.sab.bz", .display_name = "Subs.SAB", .site_url = "http://subs.sab.bz" },
    .{ .provider = .subtitri_do_am, .id = "subtitri_do_am", .live_name = "subtitri.do.am", .display_name = "Subtitri", .site_url = "https://subtitri.do.am", .supports_tv = false },
    .{ .provider = .prijevodi_online_org, .id = "prijevodi_online_org", .live_name = "prijevodi-online.org", .display_name = "Prijevodi Online", .site_url = "https://www.prijevodi-online.org", .supports_movies = false },
    .{ .provider = .animekalesi_com, .id = "animekalesi_com", .live_name = "animekalesi.com", .display_name = "AnimeKalesi", .site_url = "https://animekalesi.com", .supports_movies = false },
    .{ .provider = .subcentral_de, .id = "subcentral_de", .live_name = "subcentral.de", .display_name = "SubCentral", .site_url = "https://www.subcentral.de", .supports_movies = false, .live_timeout_seconds = 120 },
    .{ .provider = .subtitulamos_tv, .id = "subtitulamos_tv", .live_name = "subtitulamos.tv", .display_name = "Subtitulamos", .site_url = "https://www.subtitulamos.tv", .supports_movies = false, .live_serial = true },
    .{ .provider = .feliratok_eu, .id = "feliratok_eu", .live_name = "feliratok.eu", .display_name = "SuperSubtitles", .site_url = "https://feliratok.eu", .supports_tv = false },
    .{ .provider = .animesub_info, .id = "animesub_info", .live_name = "animesub.info", .display_name = "AnimeSub.info", .site_url = "http://animesub.info", .live_timeout_seconds = 180, .live_serial = true },
    .{ .provider = .animetosho_xyz, .id = "animetosho_xyz", .live_name = "animetosho.xyz", .display_name = "AnimeTosho", .site_url = "https://animetosho.net", .live_timeout_seconds = 120 },
    .{ .provider = .kitsunekko_net, .id = "kitsunekko_net", .live_name = "kitsunekko.net", .display_name = "Kitsunekko", .site_url = "https://kitsunekko.net", .live_timeout_seconds = 120 },
    .{ .provider = .thesubtitledb_org, .id = "thesubtitledb_org", .live_name = "thesubtitledb.org", .display_name = "TheSubtitleDB", .site_url = "https://thesubtitledb.org", .live_timeout_seconds = 120 },
    .{ .provider = .napisy24_pl, .id = "napisy24_pl", .live_name = "napisy24.pl", .display_name = "Napisy24", .site_url = "https://napisy24.pl", .live_timeout_seconds = 120 },
    .{ .provider = .nyasub_cz, .id = "nyasub_cz", .live_name = "nyasub.cz", .display_name = "NyaSub", .site_url = "https://nyasub.cz", .live_timeout_seconds = 240, .live_serial = true },
    .{ .provider = .subhd_tv, .id = "subhd_tv", .live_name = "subhd.tv", .display_name = "SubHD", .site_url = "https://subhd.tv", .active = false, .live_timeout_seconds = 120, .live_serial = true },
    .{ .provider = .fansubs_ru, .id = "fansubs_ru", .live_name = "fansubs.ru", .display_name = "Fansubs.ru", .site_url = "http://fansubs.ru", .live_timeout_seconds = 120, .live_serial = true },
    .{ .provider = .legendei_net, .id = "legendei_net", .live_name = "legendei.net", .display_name = "Legendei", .site_url = "https://legendei.net" },
    .{ .provider = .zoom_lk, .id = "zoom_lk", .live_name = "zoom.lk", .display_name = "Zoom.LK", .site_url = "https://zoom.lk", .live_timeout_seconds = 120, .live_serial = true },
    .{ .provider = .justsubtitles_com, .id = "justsubtitles_com", .live_name = "justsubtitles.com", .display_name = "JustSubtitles", .site_url = "https://www.justsubtitles.com", .supports_tv = false },
    .{ .provider = .wizdom_xyz, .id = "wizdom_xyz", .live_name = "wizdom.xyz", .display_name = "Wizdom", .site_url = "https://wizdom.xyz" },
    .{ .provider = .miraianime_net, .id = "miraianime_net", .live_name = "miraianime.net", .display_name = "MiraiAnime", .site_url = "https://miraianime.net" },
    .{ .provider = .animesubtitle_ir, .id = "animesubtitle_ir", .live_name = "animesubtitle.ir", .display_name = "AnimeSubtitle.ir", .site_url = "https://animesubtitle.ir", .active = false },
    .{ .provider = .grupahatak_pl, .id = "grupahatak_pl", .live_name = "grupahatak.pl", .display_name = "GrupaHatak", .site_url = "https://grupahatak.pl", .supports_movies = false },
    .{ .provider = .jimaku_cc, .id = "jimaku_cc", .live_name = "jimaku.cc", .display_name = "Jimaku", .site_url = "https://jimaku.cc" },
};

pub const active_count = blk: {
    var count: usize = 0;
    for (all) |entry| {
        if (entry.active) count += 1;
    }
    break :blk count;
};

pub const active_providers = blk: {
    var result: [active_count]Provider = undefined;
    var index: usize = 0;
    for (all) |entry| {
        if (!entry.active) continue;
        result[index] = entry.provider;
        index += 1;
    }
    break :blk result;
};

pub fn info(provider: Provider) Info {
    inline for (all) |entry| {
        if (entry.provider == provider) return entry;
    }
    unreachable;
}

test "registry covers every provider exactly once" {
    try std.testing.expectEqual(@typeInfo(Provider).@"enum".fields.len, all.len);

    var seen = [_]bool{false} ** all.len;
    for (all) |entry| {
        const index = @intFromEnum(entry.provider);
        try std.testing.expect(index < seen.len);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        try std.testing.expect(entry.id.len > 0);
        try std.testing.expect(entry.live_name.len > 0);
        try std.testing.expect(entry.display_name.len > 0);
        try std.testing.expect(entry.site_url.len > 0);
    }
}
