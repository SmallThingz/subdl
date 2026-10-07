//! Compatibility facade for consumers of the historical `subdl` module.
//! All declarations come from the canonical `scrapers` module so Zig assigns
//! each source file to exactly one module when an application imports both.
const std = @import("std");
const scrapers = @import("scrapers");
const legacy = scrapers.subdl;

pub const setIo = scrapers.setIo;

pub const common = legacy.common;
pub const errors = legacy.errors;

pub const subdl_com = legacy.subdl_com;
pub const opensubtitles_com = legacy.opensubtitles_com;
pub const opensubtitles_org = legacy.opensubtitles_org;
pub const moviesubtitles_org = legacy.moviesubtitles_org;
pub const moviesubtitlesrt_com = legacy.moviesubtitlesrt_com;
pub const podnapisi_net = legacy.podnapisi_net;
pub const yifysubtitles_ch = legacy.yifysubtitles_ch;
pub const subtitlecat_com = legacy.subtitlecat_com;
pub const isubtitles_org = legacy.isubtitles_org;
pub const my_subs_co = legacy.my_subs_co;
pub const subsource_net = legacy.subsource_net;
pub const sub_scene_com = legacy.sub_scene_com;
pub const tvsubtitles_net = legacy.tvsubtitles_net;
pub const gestdown_info = legacy.gestdown_info;
pub const greeksubtitles_com = legacy.greeksubtitles_com;
pub const subsunacs_net = legacy.subsunacs_net;
pub const subtitles_ajatt_top = legacy.subtitles_ajatt_top;
pub const subtis_io = legacy.subtis_io;
pub const greeksubs_net = legacy.greeksubs_net;
pub const indexsubtitle_cc = legacy.indexsubtitle_cc;
pub const sous_titres_eu = legacy.sous_titres_eu;
pub const cc_edatribe_com = legacy.cc_edatribe_com;
pub const subtitrari_noi_ro = legacy.subtitrari_noi_ro;
pub const subclub_eu = legacy.subclub_eu;
pub const subs_ro = legacy.subs_ro;
pub const subs4free_info = legacy.subs4free_info;
pub const tsukihime_org = legacy.tsukihime_org;
pub const subtitri_nekur_net = legacy.subtitri_nekur_net;
pub const subsynchro_com = legacy.subsynchro_com;
pub const titrari_ro = legacy.titrari_ro;
pub const subs_sab_bz = legacy.subs_sab_bz;
pub const subtitri_do_am = legacy.subtitri_do_am;
pub const prijevodi_online_org = legacy.prijevodi_online_org;
pub const animekalesi_com = legacy.animekalesi_com;
pub const subcentral_de = legacy.subcentral_de;
pub const subtitulamos_tv = legacy.subtitulamos_tv;
pub const feliratok_eu = legacy.feliratok_eu;
pub const animesub_info = legacy.animesub_info;
pub const animetosho_xyz = legacy.animetosho_xyz;
pub const kitsunekko_net = legacy.kitsunekko_net;
pub const thesubtitledb_org = legacy.thesubtitledb_org;
pub const napisy24_pl = legacy.napisy24_pl;
pub const nyasub_cz = legacy.nyasub_cz;
pub const subhd_tv = legacy.subhd_tv;
pub const fansubs_ru = legacy.fansubs_ru;
pub const legendei_net = legacy.legendei_net;
pub const zoom_lk = legacy.zoom_lk;
pub const justsubtitles_com = legacy.justsubtitles_com;
pub const wizdom_xyz = legacy.wizdom_xyz;
pub const miraianime_net = legacy.miraianime_net;
pub const animesubtitle_ir = legacy.animesubtitle_ir;
pub const grupahatak_pl = legacy.grupahatak_pl;
pub const jimaku_cc = legacy.jimaku_cc;
pub const opensubtitles_com_cf = legacy.opensubtitles_com_cf;

pub const Scraper = legacy.Scraper;
pub const Error = legacy.Error;
pub const SubtitlePath = legacy.SubtitlePath;
pub const MediaType = legacy.MediaType;
pub const SearchItem = legacy.SearchItem;
pub const SearchLanguage = legacy.SearchLanguage;
pub const project_search_languages = legacy.project_search_languages;
pub const SeasonInfo = legacy.SeasonInfo;
pub const TitleInfo = legacy.TitleInfo;
pub const SubtitleItem = legacy.SubtitleItem;
pub const LanguageSubtitles = legacy.LanguageSubtitles;
pub const SearchResponse = legacy.SearchResponse;
pub const MovieSubtitlesResponse = legacy.MovieSubtitlesResponse;
pub const TvSeasonsResponse = legacy.TvSeasonsResponse;
pub const TvSeasonSubtitlesResponse = legacy.TvSeasonSubtitlesResponse;
pub const resolveProjectSearchLanguageCode = legacy.resolveProjectSearchLanguageCode;

test {
    std.testing.refAllDecls(@This());
}
