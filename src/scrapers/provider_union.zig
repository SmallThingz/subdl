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
