const std = @import("std");

pub const subdl_com = @import("subdl.com.zig");
pub const opensubtitles_com = @import("opensubtitles.com.zig");
pub const opensubtitles_org = @import("opensubtitles.org.zig");
pub const moviesubtitles_org = @import("moviesubtitles.org.zig");
pub const moviesubtitlesrt_com = @import("moviesubtitlesrt.com.zig");
pub const podnapisi_net = @import("podnapisi.net.zig");
pub const yifysubtitles_ch = @import("yifysubtitles.ch.zig");
pub const subtitlecat_com = @import("subtitlecat.com.zig");
pub const isubtitles_org = @import("isubtitles.org.zig");
pub const my_subs_co = @import("my-subs.co.zig");
pub const subsource_net = @import("subsource.net.zig");
pub const sub_scene_com = @import("sub-scene.com.zig");
pub const tvsubtitles_net = @import("tvsubtitles.net.zig");
pub const gestdown_info = @import("gestdown.info.zig");
pub const greeksubtitles_com = @import("greek-subtitles.com.zig");
pub const subsunacs_net = @import("subsunacs.net.zig");
pub const subtitles_ajatt_top = @import("subtitles.ajatt.top.zig");
pub const subtis_io = @import("subtis.io.zig");
pub const greeksubs_net = @import("greeksubs.net.zig");
pub const indexsubtitle_cc = @import("indexsubtitle.cc.zig");
pub const sous_titres_eu = @import("sous-titres.eu.zig");
pub const cc_edatribe_com = @import("cc.edatribe.com.zig");
pub const subtitrari_noi_ro = @import("subtitrari-noi.ro.zig");
pub const subs_ro = @import("subs.ro.zig");
pub const titrari_ro = @import("titrari.ro.zig");
pub const subs_sab_bz = @import("subs.sab.bz.zig");
pub const subtitri_do_am = @import("subtitri.do.am.zig");
pub const prijevodi_online_org = @import("prijevodi-online.org.zig");
pub const animekalesi_com = @import("animekalesi.com.zig");
pub const subcentral_de = @import("subcentral.de.zig");
pub const subtitulamos_tv = @import("subtitulamos.tv.zig");
pub const feliratok_eu = @import("feliratok.eu.zig");
pub const animesub_info = @import("animesub.info.zig");
pub const subhd_tv = @import("subhd.tv.zig");
pub const fansubs_ru = @import("fansubs.ru.zig");
pub const legendei_net = @import("legendei.net.zig");
pub const zoom_lk = @import("zoom.lk.zig");
pub const justsubtitles_com = @import("justsubtitles.com.zig");
pub const wizdom_xyz = @import("wizdom.xyz.zig");
pub const miraianime_net = @import("miraianime.net.zig");
pub const animesubtitle_ir = @import("animesubtitle.ir.zig");
pub const grupahatak_pl = @import("grupahatak.pl.zig");
pub const jimaku_cc = @import("jimaku.cc.zig");

pub const ProviderTag = enum {
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

pub const SearchItemUnion = union(ProviderTag) {
    subdl_com: subdl_com.SearchItem,
    opensubtitles_com: opensubtitles_com.SearchItem,
    opensubtitles_org: opensubtitles_org.SearchItem,
    moviesubtitles_org: moviesubtitles_org.SearchItem,
    moviesubtitlesrt_com: moviesubtitlesrt_com.SearchItem,
    podnapisi_net: podnapisi_net.SearchItem,
    yifysubtitles_ch: yifysubtitles_ch.SearchItem,
    subtitlecat_com: subtitlecat_com.SearchItem,
    isubtitles_org: isubtitles_org.SearchItem,
    my_subs_co: my_subs_co.SearchItem,
    subsource_net: subsource_net.SearchItem,
    sub_scene_com: sub_scene_com.SearchItem,
    tvsubtitles_net: tvsubtitles_net.SearchItem,
    gestdown_info: gestdown_info.SearchItem,
    greeksubtitles_com: greeksubtitles_com.SearchItem,
    subsunacs_net: subsunacs_net.SearchItem,
    subtitles_ajatt_top: subtitles_ajatt_top.SearchItem,
    subtis_io: subtis_io.SearchItem,
    greeksubs_net: greeksubs_net.SearchItem,
    indexsubtitle_cc: indexsubtitle_cc.SearchItem,
    sous_titres_eu: sous_titres_eu.SearchItem,
    cc_edatribe_com: cc_edatribe_com.SearchItem,
    subtitrari_noi_ro: subtitrari_noi_ro.SearchItem,
    subs_ro: subs_ro.SearchItem,
    titrari_ro: titrari_ro.SearchItem,
    subs_sab_bz: subs_sab_bz.SearchItem,
    subtitri_do_am: subtitri_do_am.SearchItem,
    prijevodi_online_org: prijevodi_online_org.SearchItem,
    animekalesi_com: animekalesi_com.SearchItem,
    subcentral_de: subcentral_de.SearchItem,
    subtitulamos_tv: subtitulamos_tv.SearchItem,
    feliratok_eu: feliratok_eu.SearchItem,
    animesub_info: animesub_info.SearchItem,
    subhd_tv: subhd_tv.SearchItem,
    fansubs_ru: fansubs_ru.SearchItem,
    legendei_net: legendei_net.SearchItem,
    zoom_lk: zoom_lk.SearchItem,
    justsubtitles_com: justsubtitles_com.SearchItem,
    wizdom_xyz: wizdom_xyz.SearchItem,
    miraianime_net: miraianime_net.SearchItem,
    animesubtitle_ir: animesubtitle_ir.SearchItem,
    grupahatak_pl: grupahatak_pl.SearchItem,
    jimaku_cc: jimaku_cc.SearchItem,
};

pub const SubtitleUnion = union(ProviderTag) {
    subdl_com: subdl_com.SubtitleItem,
    opensubtitles_com: opensubtitles_com.SubtitleItem,
    opensubtitles_org: opensubtitles_org.SubtitleItem,
    moviesubtitles_org: moviesubtitles_org.SubtitleItem,
    moviesubtitlesrt_com: moviesubtitlesrt_com.SubtitleInfo,
    podnapisi_net: podnapisi_net.SubtitleItem,
    yifysubtitles_ch: yifysubtitles_ch.SubtitleItem,
    subtitlecat_com: subtitlecat_com.SubtitleItem,
    isubtitles_org: isubtitles_org.SubtitleItem,
    my_subs_co: my_subs_co.SubtitleItem,
    subsource_net: subsource_net.SubtitleItem,
    sub_scene_com: sub_scene_com.SubtitleItem,
    tvsubtitles_net: tvsubtitles_net.SubtitleItem,
    gestdown_info: gestdown_info.SubtitleItem,
    greeksubtitles_com: greeksubtitles_com.SubtitleItem,
    subsunacs_net: subsunacs_net.SubtitleItem,
    subtitles_ajatt_top: subtitles_ajatt_top.SubtitleItem,
    subtis_io: subtis_io.SubtitleItem,
    greeksubs_net: greeksubs_net.SubtitleItem,
    indexsubtitle_cc: indexsubtitle_cc.SubtitleItem,
    sous_titres_eu: sous_titres_eu.SubtitleItem,
    cc_edatribe_com: cc_edatribe_com.SubtitleItem,
    subtitrari_noi_ro: subtitrari_noi_ro.SubtitleItem,
    subs_ro: subs_ro.SubtitleItem,
    titrari_ro: titrari_ro.SubtitleItem,
    subs_sab_bz: subs_sab_bz.SubtitleItem,
    subtitri_do_am: subtitri_do_am.SubtitleItem,
    prijevodi_online_org: prijevodi_online_org.SubtitleItem,
    animekalesi_com: animekalesi_com.SubtitleItem,
    subcentral_de: subcentral_de.SubtitleItem,
    subtitulamos_tv: subtitulamos_tv.SubtitleItem,
    feliratok_eu: feliratok_eu.SubtitleItem,
    animesub_info: animesub_info.SubtitleItem,
    subhd_tv: subhd_tv.SubtitleItem,
    fansubs_ru: fansubs_ru.SubtitleItem,
    legendei_net: legendei_net.SubtitleItem,
    zoom_lk: zoom_lk.SubtitleItem,
    justsubtitles_com: justsubtitles_com.SubtitleItem,
    wizdom_xyz: wizdom_xyz.SubtitleItem,
    miraianime_net: miraianime_net.SubtitleItem,
    animesubtitle_ir: animesubtitle_ir.SubtitleItem,
    grupahatak_pl: grupahatak_pl.SubtitleItem,
    jimaku_cc: jimaku_cc.SubtitleItem,
};

pub const TitleUnion = union(ProviderTag) {
    subdl_com: subdl_com.TitleInfo,
    opensubtitles_com: opensubtitles_com.SearchItem,
    opensubtitles_org: opensubtitles_org.SearchItem,
    moviesubtitles_org: moviesubtitles_org.SearchItem,
    moviesubtitlesrt_com: moviesubtitlesrt_com.SearchItem,
    podnapisi_net: podnapisi_net.SearchItem,
    yifysubtitles_ch: yifysubtitles_ch.SearchItem,
    subtitlecat_com: subtitlecat_com.SearchItem,
    isubtitles_org: isubtitles_org.SearchItem,
    my_subs_co: my_subs_co.SearchItem,
    subsource_net: subsource_net.SearchItem,
    sub_scene_com: sub_scene_com.SearchItem,
    tvsubtitles_net: tvsubtitles_net.SearchItem,
    gestdown_info: gestdown_info.SearchItem,
    greeksubtitles_com: greeksubtitles_com.SearchItem,
    subsunacs_net: subsunacs_net.SearchItem,
    subtitles_ajatt_top: subtitles_ajatt_top.SearchItem,
    subtis_io: subtis_io.SearchItem,
    greeksubs_net: greeksubs_net.SearchItem,
    indexsubtitle_cc: indexsubtitle_cc.SearchItem,
    sous_titres_eu: sous_titres_eu.SearchItem,
    cc_edatribe_com: cc_edatribe_com.SearchItem,
    subtitrari_noi_ro: subtitrari_noi_ro.SearchItem,
    subs_ro: subs_ro.SearchItem,
    titrari_ro: titrari_ro.SearchItem,
    subs_sab_bz: subs_sab_bz.SearchItem,
    subtitri_do_am: subtitri_do_am.SearchItem,
    prijevodi_online_org: prijevodi_online_org.SearchItem,
    animekalesi_com: animekalesi_com.SearchItem,
    subcentral_de: subcentral_de.SearchItem,
    subtitulamos_tv: subtitulamos_tv.SearchItem,
    feliratok_eu: feliratok_eu.SearchItem,
    animesub_info: animesub_info.SearchItem,
    subhd_tv: subhd_tv.SearchItem,
    fansubs_ru: fansubs_ru.SearchItem,
    legendei_net: legendei_net.SearchItem,
    zoom_lk: zoom_lk.SearchItem,
    justsubtitles_com: justsubtitles_com.SearchItem,
    wizdom_xyz: wizdom_xyz.SearchItem,
    miraianime_net: miraianime_net.SearchItem,
    animesubtitle_ir: animesubtitle_ir.SearchItem,
    grupahatak_pl: grupahatak_pl.SearchItem,
    jimaku_cc: jimaku_cc.SearchItem,
};

pub fn fromSubdlSearch(allocator: std.mem.Allocator, items: []const subdl_com.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subdl_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromOpenSubtitlesComSearch(allocator: std.mem.Allocator, items: []const opensubtitles_com.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .opensubtitles_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromOpenSubtitlesOrgSearch(allocator: std.mem.Allocator, items: []const opensubtitles_org.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .opensubtitles_org = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromMovieSubtitlesOrgSearch(allocator: std.mem.Allocator, items: []const moviesubtitles_org.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .moviesubtitles_org = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromMovieSubtitlesRtSearch(allocator: std.mem.Allocator, items: []const moviesubtitlesrt_com.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .moviesubtitlesrt_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromPodnapisiSearch(allocator: std.mem.Allocator, items: []const podnapisi_net.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .podnapisi_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromYifySearch(allocator: std.mem.Allocator, items: []const yifysubtitles_ch.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .yifysubtitles_ch = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtitleCatSearch(allocator: std.mem.Allocator, items: []const subtitlecat_com.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitlecat_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromISubtitlesSearch(allocator: std.mem.Allocator, items: []const isubtitles_org.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .isubtitles_org = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromMySubsSearch(allocator: std.mem.Allocator, items: []const my_subs_co.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .my_subs_co = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubsourceSearch(allocator: std.mem.Allocator, items: []const subsource_net.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subsource_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubSceneSearch(allocator: std.mem.Allocator, items: []const sub_scene_com.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .sub_scene_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromTvSubtitlesSearch(allocator: std.mem.Allocator, items: []const tvsubtitles_net.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .tvsubtitles_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromGestdownSearch(allocator: std.mem.Allocator, items: []const gestdown_info.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .gestdown_info = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromGreekSubtitlesSearch(allocator: std.mem.Allocator, items: []const greeksubtitles_com.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .greeksubtitles_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubsUnacsSearch(allocator: std.mem.Allocator, items: []const subsunacs_net.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subsunacs_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromAjattSearch(allocator: std.mem.Allocator, items: []const subtitles_ajatt_top.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitles_ajatt_top = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtisSearch(allocator: std.mem.Allocator, items: []const subtis_io.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtis_io = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromGreekSubsSearch(allocator: std.mem.Allocator, items: []const greeksubs_net.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .greeksubs_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromIndexSubtitleSearch(allocator: std.mem.Allocator, items: []const indexsubtitle_cc.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .indexsubtitle_cc = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSousTitresSearch(allocator: std.mem.Allocator, items: []const sous_titres_eu.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .sous_titres_eu = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromClosedCaptionBrowserSearch(allocator: std.mem.Allocator, items: []const cc_edatribe_com.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .cc_edatribe_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtitrariNoiSearch(allocator: std.mem.Allocator, items: []const subtitrari_noi_ro.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitrari_noi_ro = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubsRoSearch(allocator: std.mem.Allocator, items: []const subs_ro.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subs_ro = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromTitrariSearch(allocator: std.mem.Allocator, items: []const titrari_ro.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .titrari_ro = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubsSabSearch(allocator: std.mem.Allocator, items: []const subs_sab_bz.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subs_sab_bz = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtitriSearch(allocator: std.mem.Allocator, items: []const subtitri_do_am.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitri_do_am = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromPrijevodiOnlineSearch(allocator: std.mem.Allocator, items: []const prijevodi_online_org.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .prijevodi_online_org = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromAnimeKalesiSearch(allocator: std.mem.Allocator, items: []const animekalesi_com.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .animekalesi_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubCentralSearch(allocator: std.mem.Allocator, items: []const subcentral_de.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subcentral_de = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtitulamosSearch(allocator: std.mem.Allocator, items: []const subtitulamos_tv.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitulamos_tv = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromFeliratokSearch(allocator: std.mem.Allocator, items: []const feliratok_eu.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .feliratok_eu = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromAnimeSubInfoSearch(allocator: std.mem.Allocator, items: []const animesub_info.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .animesub_info = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubHdSearch(allocator: std.mem.Allocator, items: []const subhd_tv.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subhd_tv = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromFansubsSearch(allocator: std.mem.Allocator, items: []const fansubs_ru.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .fansubs_ru = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromLegendeiSearch(allocator: std.mem.Allocator, items: []const legendei_net.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .legendei_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromZoomSearch(allocator: std.mem.Allocator, items: []const zoom_lk.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .zoom_lk = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromJustSubtitlesSearch(allocator: std.mem.Allocator, items: []const justsubtitles_com.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .justsubtitles_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromWizdomSearch(allocator: std.mem.Allocator, items: []const wizdom_xyz.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .wizdom_xyz = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromMiraiAnimeSearch(allocator: std.mem.Allocator, items: []const miraianime_net.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .miraianime_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromAnimeSubtitleIrSearch(allocator: std.mem.Allocator, items: []const animesubtitle_ir.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .animesubtitle_ir = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromGrupaHatakSearch(allocator: std.mem.Allocator, items: []const grupahatak_pl.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .grupahatak_pl = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromJimakuSearch(allocator: std.mem.Allocator, items: []const jimaku_cc.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .jimaku_cc = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubdlSubtitles(allocator: std.mem.Allocator, items: []const subdl_com.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subdl_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromOpenSubtitlesComSubtitles(allocator: std.mem.Allocator, items: []const opensubtitles_com.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .opensubtitles_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromOpenSubtitlesOrgSubtitles(allocator: std.mem.Allocator, items: []const opensubtitles_org.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .opensubtitles_org = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromMovieSubtitlesOrgSubtitles(allocator: std.mem.Allocator, items: []const moviesubtitles_org.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .moviesubtitles_org = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromMovieSubtitlesRtSubtitles(allocator: std.mem.Allocator, item: moviesubtitlesrt_com.SubtitleInfo) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, .{ .moviesubtitlesrt_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromPodnapisiSubtitles(allocator: std.mem.Allocator, items: []const podnapisi_net.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .podnapisi_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromYifySubtitles(allocator: std.mem.Allocator, items: []const yifysubtitles_ch.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .yifysubtitles_ch = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtitleCatSubtitles(allocator: std.mem.Allocator, items: []const subtitlecat_com.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitlecat_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromISubtitlesSubtitles(allocator: std.mem.Allocator, items: []const isubtitles_org.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .isubtitles_org = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromMySubsSubtitles(allocator: std.mem.Allocator, items: []const my_subs_co.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .my_subs_co = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubsourceSubtitles(allocator: std.mem.Allocator, items: []const subsource_net.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subsource_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubSceneSubtitles(allocator: std.mem.Allocator, items: []const sub_scene_com.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .sub_scene_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromTvSubtitlesSubtitles(allocator: std.mem.Allocator, items: []const tvsubtitles_net.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .tvsubtitles_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromGestdownSubtitles(allocator: std.mem.Allocator, items: []const gestdown_info.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .gestdown_info = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromGreekSubtitlesSubtitles(allocator: std.mem.Allocator, items: []const greeksubtitles_com.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .greeksubtitles_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubsUnacsSubtitles(allocator: std.mem.Allocator, items: []const subsunacs_net.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subsunacs_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromAjattSubtitles(allocator: std.mem.Allocator, items: []const subtitles_ajatt_top.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitles_ajatt_top = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtisSubtitles(allocator: std.mem.Allocator, items: []const subtis_io.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtis_io = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromGreekSubsSubtitles(allocator: std.mem.Allocator, items: []const greeksubs_net.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .greeksubs_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromIndexSubtitleSubtitles(allocator: std.mem.Allocator, items: []const indexsubtitle_cc.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .indexsubtitle_cc = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSousTitresSubtitles(allocator: std.mem.Allocator, items: []const sous_titres_eu.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .sous_titres_eu = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromClosedCaptionBrowserSubtitles(allocator: std.mem.Allocator, items: []const cc_edatribe_com.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .cc_edatribe_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtitrariNoiSubtitles(allocator: std.mem.Allocator, items: []const subtitrari_noi_ro.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitrari_noi_ro = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubsRoSubtitles(allocator: std.mem.Allocator, items: []const subs_ro.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subs_ro = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromTitrariSubtitles(allocator: std.mem.Allocator, items: []const titrari_ro.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .titrari_ro = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubsSabSubtitles(allocator: std.mem.Allocator, items: []const subs_sab_bz.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subs_sab_bz = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtitriSubtitles(allocator: std.mem.Allocator, items: []const subtitri_do_am.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitri_do_am = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromPrijevodiOnlineSubtitles(allocator: std.mem.Allocator, items: []const prijevodi_online_org.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .prijevodi_online_org = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromAnimeKalesiSubtitles(allocator: std.mem.Allocator, items: []const animekalesi_com.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .animekalesi_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubCentralSubtitles(allocator: std.mem.Allocator, items: []const subcentral_de.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subcentral_de = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubtitulamosSubtitles(allocator: std.mem.Allocator, items: []const subtitulamos_tv.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subtitulamos_tv = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromFeliratokSubtitles(allocator: std.mem.Allocator, items: []const feliratok_eu.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .feliratok_eu = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromAnimeSubInfoSubtitles(allocator: std.mem.Allocator, items: []const animesub_info.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .animesub_info = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromSubHdSubtitles(allocator: std.mem.Allocator, items: []const subhd_tv.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .subhd_tv = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromFansubsSubtitles(allocator: std.mem.Allocator, items: []const fansubs_ru.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .fansubs_ru = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromLegendeiSubtitles(allocator: std.mem.Allocator, items: []const legendei_net.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .legendei_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromZoomSubtitles(allocator: std.mem.Allocator, items: []const zoom_lk.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .zoom_lk = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromJustSubtitlesSubtitles(allocator: std.mem.Allocator, items: []const justsubtitles_com.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .justsubtitles_com = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromWizdomSubtitles(allocator: std.mem.Allocator, items: []const wizdom_xyz.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .wizdom_xyz = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromMiraiAnimeSubtitles(allocator: std.mem.Allocator, items: []const miraianime_net.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .miraianime_net = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromAnimeSubtitleIrSubtitles(allocator: std.mem.Allocator, items: []const animesubtitle_ir.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .animesubtitle_ir = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromGrupaHatakSubtitles(allocator: std.mem.Allocator, items: []const grupahatak_pl.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .grupahatak_pl = item });
    return try out.toOwnedSlice(allocator);
}

pub fn fromJimakuSubtitles(allocator: std.mem.Allocator, items: []const jimaku_cc.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .jimaku_cc = item });
    return try out.toOwnedSlice(allocator);
}

test "union conversion from yify search" {
    const allocator = std.testing.allocator;
    const sample = [_]yifysubtitles_ch.SearchItem{.{
        .movie = "The Matrix",
        .imdb_id = "0133093",
        .movie_page_url = "https://yifysubtitles.ch/movie-imdb/tt0133093",
    }};
    const converted = try fromYifySearch(allocator, &sample);
    defer allocator.free(converted);
    try std.testing.expect(converted.len == 1);
    try std.testing.expect(converted[0] == .yifysubtitles_ch);
}
