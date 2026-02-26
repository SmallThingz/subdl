const subdl_impl = @import("subdl.com.zig");

pub const common = @import("common.zig");
pub const errors = @import("errors.zig");

pub const subdl_com = subdl_impl;
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
pub const tvsubtitles_net = @import("tvsubtitles.net.zig");
pub const opensubtitles_com_cf = @import("opensubtitles_com_cf.zig");

pub const provider_union = @import("provider_union.zig");

pub const Scraper = subdl_impl.Scraper;
pub const Error = subdl_impl.Error;
pub const SubtitlePath = subdl_impl.SubtitlePath;
pub const MediaType = subdl_impl.MediaType;
pub const SearchItem = subdl_impl.SearchItem;
pub const SearchLanguage = subdl_impl.SearchLanguage;
pub const project_search_languages = subdl_impl.project_search_languages;
pub const SeasonInfo = subdl_impl.SeasonInfo;
pub const TitleInfo = subdl_impl.TitleInfo;
pub const SubtitleItem = subdl_impl.SubtitleItem;
pub const LanguageSubtitles = subdl_impl.LanguageSubtitles;
pub const SearchResponse = subdl_impl.SearchResponse;
pub const MovieSubtitlesResponse = subdl_impl.MovieSubtitlesResponse;
pub const TvSeasonsResponse = subdl_impl.TvSeasonsResponse;
pub const TvSeasonSubtitlesResponse = subdl_impl.TvSeasonSubtitlesResponse;
pub const resolveProjectSearchLanguageCode = subdl_impl.resolveProjectSearchLanguageCode;

test {
    _ = @import("common.zig");
    _ = @import("subdl.com.zig");
    _ = @import("opensubtitles.com.zig");
    _ = @import("opensubtitles.org.zig");
    _ = @import("moviesubtitles.org.zig");
    _ = @import("moviesubtitlesrt.com.zig");
    _ = @import("podnapisi.net.zig");
    _ = @import("yifysubtitles.ch.zig");
    _ = @import("subtitlecat.com.zig");
    _ = @import("isubtitles.org.zig");
    _ = @import("my-subs.co.zig");
    _ = @import("subsource.net.zig");
    _ = @import("tvsubtitles.net.zig");
    _ = @import("opensubtitles_com_cf.zig");
    _ = @import("provider_union.zig");
    _ = @import("test_suite.zig");
    _ = @import("providers.extensive.live.test.zig");
}
