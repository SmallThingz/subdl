const std = @import("std");

const common = @import("common.zig");
const suite = @import("test_suite.zig");

const subdl_com = @import("subdl.com.zig");
const isubtitles_org = @import("isubtitles.org.zig");
const moviesubtitles_org = @import("moviesubtitles.org.zig");
const moviesubtitlesrt_com = @import("moviesubtitlesrt.com.zig");
const my_subs_co = @import("my-subs.co.zig");
const podnapisi_net = @import("podnapisi.net.zig");
const subtitlecat_com = @import("subtitlecat.com.zig");
const subsource_net = @import("subsource.net.zig");
const tvsubtitles_net = @import("tvsubtitles.net.zig");

test "extensive live suite: non-captcha providers" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!suite.shouldRunExtensiveLiveSuite(std.testing.allocator)) return error.SkipZigTest;

    const probes = [_]suite.ProviderProbe{
        .{ .name = "subdl.com", .run = runSubdl },
        .{ .name = "isubtitles.org", .run = runISubtitles },
        .{ .name = "moviesubtitles.org", .run = runMovieSubtitlesOrg },
        .{ .name = "moviesubtitlesrt.com", .run = runMovieSubtitlesRt },
        .{ .name = "my-subs.co", .run = runMySubs },
        .{ .name = "podnapisi.net", .run = runPodnapisi },
        .{ .name = "subtitlecat.com", .run = runSubtitleCat },
        .{ .name = "subsource.net", .run = runSubsource },
        .{ .name = "tvsubtitles.net", .run = runTvSubtitles },
    };

    try suite.runSuite(std.testing.allocator, &probes);
}

fn runSubdl(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = subdl_com.Scraper.initWithOptions(allocator, client, .{ .include_empty_subtitle_groups = false });
    defer scraper.deinit();

    var search = try scraper.search("The Matrix");
    defer search.deinit();

    try suite.expectPositive(search.items.len);
    const item = search.items[0];
    try suite.expectNonEmpty(item.name);
    try suite.expectNonEmpty(item.link);

    var movie = try scraper.fetchMovieByLink(item.link);
    defer movie.deinit();

    try suite.expectNonEmpty(movie.movie.name);
    try suite.expectPositive(movie.languages.len);

    const first_group = movie.languages[0];
    try suite.expectNonEmpty(first_group.language);
    try suite.expectPositive(first_group.subtitles.len);

    const first_sub = first_group.subtitles[0];
    try suite.expectNonEmpty(first_sub.language);
    try suite.expectNonEmpty(first_sub.link);
    try std.testing.expect(first_sub.id > 0);
}

fn runISubtitles(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = isubtitles_org.Scraper.init(allocator, client);

    var search = try scraper.searchWithOptions("The Matrix", .{ .max_pages = 2 });
    defer search.deinit();
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(isubtitles_org.SearchItem, search.items, "matrix") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectHttpUrl(match.details_url);

    var subtitles = try scraper.fetchSubtitlesByMovieLinkWithOptions(match.details_url, .{ .max_pages = 2 });
    defer subtitles.deinit();
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectNonEmpty(first.filename);
    try suite.expectHttpUrl(first.download_page_url);
}

fn runMovieSubtitlesOrg(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = moviesubtitles_org.Scraper.init(allocator, client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try suite.expectPositive(search.items.len);

    var validated = false;
    const limit = @min(search.items.len, 8);
    for (search.items[0..limit]) |movie| {
        if (movie.link.len == 0) continue;

        var subtitles = scraper.fetchSubtitlesByMovieLink(movie.link) catch continue;
        defer subtitles.deinit();
        if (subtitles.subtitles.len == 0) continue;

        const first = subtitles.subtitles[0];
        try suite.expectNonEmpty(first.filename);
        try suite.expectHttpUrl(first.details_url);
        try suite.expectHttpUrl(first.download_url);
        validated = true;
        break;
    }

    try std.testing.expect(validated);
}

fn runMovieSubtitlesRt(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = moviesubtitlesrt_com.Scraper.init(allocator, client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(moviesubtitlesrt_com.SearchItem, search.items, "matrix") orelse 0;
    const hit = search.items[chosen_idx];
    try suite.expectNonEmpty(hit.title);
    try suite.expectHttpUrl(hit.page_url);

    var details = try scraper.fetchSubtitleByLink(hit.page_url);
    defer details.deinit();

    try suite.expectNonEmpty(details.subtitle.title);
    try suite.expectHttpUrl(details.subtitle.download_url);
    try suite.expectMaybeNonEmpty(details.subtitle.language_raw);
}

fn runMySubs(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = my_subs_co.Scraper.init(allocator, client);

    var search = try scraper.searchWithOptions("The Matrix", .{ .max_pages = 2 });
    defer search.deinit();
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(my_subs_co.SearchItem, search.items, "matrix") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectHttpUrl(match.details_url);

    var subtitles = try scraper.fetchSubtitlesByDetailsLinkWithOptions(match.details_url, match.media_kind, .{
        .include_seasons = true,
        .max_pages_per_entry = 2,
        .resolve_download_links = false,
    });
    defer subtitles.deinit();
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectNonEmpty(first.filename);
    try suite.expectHttpUrl(first.download_page_url);
}

fn runPodnapisi(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = podnapisi_net.Scraper.init(allocator, client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(podnapisi_net.SearchItem, search.items, "matrix") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectHttpUrl(match.subtitles_page_url);

    var subtitles = try scraper.fetchSubtitlesBySearchLink(match.subtitles_page_url);
    defer subtitles.deinit();
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectHttpUrl(first.download_url);
    try suite.expectMaybeNonEmpty(first.language);
}

fn runSubtitleCat(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = subtitlecat_com.Scraper.init(allocator, client);

    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(subtitlecat_com.SearchItem, search.items, "matrix") orelse 0;
    const entry = search.items[chosen_idx];
    try suite.expectNonEmpty(entry.title);
    try suite.expectHttpUrl(entry.details_url);

    var subtitles = try scraper.fetchSubtitlesByDetailsLink(entry.details_url);
    defer subtitles.deinit();
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectNonEmpty(first.filename);
    if (first.source_url) |source| try suite.expectHttpUrl(source);
}

fn runSubsource(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = subsource_net.Scraper.init(allocator, client);

    var search = try scraper.searchWithOptions("The Matrix", .{
        .include_seasons = true,
        .max_pages = 1,
        .auto_cloudflare_session = false,
    });
    defer search.deinit();
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(subsource_net.SearchItem, search.items, "matrix") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectUrlOrAbsolutePath(match.link);

    var subtitles = try scraper.fetchSubtitlesBySearchItemWithOptions(match, .{
        .include_seasons = true,
        .max_pages = 1,
        .resolve_download_tokens = false,
        .auto_cloudflare_session = false,
    });
    defer subtitles.deinit();
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectNonEmpty(first.details_path);
}

fn runTvSubtitles(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = tvsubtitles_net.Scraper.init(allocator, client);

    var search = try scraper.searchWithOptions("Friends", .{ .max_pages = 2 });
    defer search.deinit();
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(tvsubtitles_net.SearchItem, search.items, "friends") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectHttpUrl(match.show_url);

    var subtitles = try scraper.fetchSubtitlesByShowLinkWithOptions(match.show_url, .{
        .include_all_seasons = true,
        .max_pages_per_season = 2,
        .resolve_download_links = false,
    });
    defer subtitles.deinit();
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectNonEmpty(first.filename);
    try suite.expectHttpUrl(first.download_page_url);
}

fn pickFirstContaining(comptime T: type, items: []const T, needle: []const u8) ?usize {
    for (items, 0..) |item, idx| {
        if (containsIgnoreCase(@field(item, "title"), needle)) return idx;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
