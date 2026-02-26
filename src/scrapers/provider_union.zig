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
pub const tvsubtitles_net = @import("tvsubtitles.net.zig");

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
    tvsubtitles_net,
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
    tvsubtitles_net: tvsubtitles_net.SearchItem,
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
    tvsubtitles_net: tvsubtitles_net.SubtitleItem,
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
    tvsubtitles_net: tvsubtitles_net.SearchItem,
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

pub fn fromTvSubtitlesSearch(allocator: std.mem.Allocator, items: []const tvsubtitles_net.SearchItem) ![]SearchItemUnion {
    var out: std.ArrayListUnmanaged(SearchItemUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .tvsubtitles_net = item });
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

pub fn fromTvSubtitlesSubtitles(allocator: std.mem.Allocator, items: []const tvsubtitles_net.SubtitleItem) ![]SubtitleUnion {
    var out: std.ArrayListUnmanaged(SubtitleUnion) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .tvsubtitles_net = item });
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
