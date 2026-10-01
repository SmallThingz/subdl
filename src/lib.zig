const std = @import("std");

pub const subdl = @import("scrapers/subdl.zig");
pub const providers_app = @import("app/providers_app.zig");

pub const common = subdl.common;
pub const errors = subdl.errors;

pub const subdl_com = subdl.subdl_com;
pub const opensubtitles_com = subdl.opensubtitles_com;
pub const opensubtitles_org = subdl.opensubtitles_org;
pub const moviesubtitles_org = subdl.moviesubtitles_org;
pub const moviesubtitlesrt_com = subdl.moviesubtitlesrt_com;
pub const podnapisi_net = subdl.podnapisi_net;
pub const yifysubtitles_ch = subdl.yifysubtitles_ch;
pub const subtitlecat_com = subdl.subtitlecat_com;
pub const isubtitles_org = subdl.isubtitles_org;
pub const my_subs_co = subdl.my_subs_co;
pub const subsource_net = subdl.subsource_net;
pub const sub_scene_com = subdl.sub_scene_com;
pub const tvsubtitles_net = subdl.tvsubtitles_net;
pub const gestdown_info = subdl.gestdown_info;
pub const greeksubtitles_com = subdl.greeksubtitles_com;
pub const subsunacs_net = subdl.subsunacs_net;
pub const subtitles_ajatt_top = subdl.subtitles_ajatt_top;
pub const subtis_io = subdl.subtis_io;
pub const greeksubs_net = subdl.greeksubs_net;
pub const indexsubtitle_cc = subdl.indexsubtitle_cc;
pub const sous_titres_eu = subdl.sous_titres_eu;
pub const cc_edatribe_com = subdl.cc_edatribe_com;
pub const subtitrari_noi_ro = subdl.subtitrari_noi_ro;
pub const subclub_eu = subdl.subclub_eu;
pub const subs_ro = subdl.subs_ro;
pub const subs4free_info = subdl.subs4free_info;
pub const tsukihime_org = subdl.tsukihime_org;
pub const subtitri_nekur_net = subdl.subtitri_nekur_net;
pub const subsynchro_com = subdl.subsynchro_com;
pub const titrari_ro = subdl.titrari_ro;
pub const subs_sab_bz = subdl.subs_sab_bz;
pub const subtitri_do_am = subdl.subtitri_do_am;
pub const prijevodi_online_org = subdl.prijevodi_online_org;
pub const animekalesi_com = subdl.animekalesi_com;
pub const subcentral_de = subdl.subcentral_de;
pub const subtitulamos_tv = subdl.subtitulamos_tv;
pub const feliratok_eu = subdl.feliratok_eu;
pub const animesub_info = subdl.animesub_info;
pub const subhd_tv = subdl.subhd_tv;
pub const fansubs_ru = subdl.fansubs_ru;
pub const legendei_net = subdl.legendei_net;
pub const zoom_lk = subdl.zoom_lk;
pub const justsubtitles_com = subdl.justsubtitles_com;
pub const wizdom_xyz = subdl.wizdom_xyz;
pub const miraianime_net = subdl.miraianime_net;
pub const animesubtitle_ir = subdl.animesubtitle_ir;
pub const grupahatak_pl = subdl.grupahatak_pl;
pub const jimaku_cc = subdl.jimaku_cc;
pub const provider_union = subdl.provider_union;

pub const Scraper = subdl.Scraper;
pub const Error = subdl.Error;

test {
    std.testing.refAllDecls(@This());
}
