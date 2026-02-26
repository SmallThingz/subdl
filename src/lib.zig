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
pub const tvsubtitles_net = subdl.tvsubtitles_net;
pub const provider_union = subdl.provider_union;

pub const Scraper = subdl.Scraper;
pub const Error = subdl.Error;

test {
    std.testing.refAllDecls(@This());
}
