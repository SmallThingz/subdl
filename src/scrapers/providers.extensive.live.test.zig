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

test "extensive live suite provider: subdl.com" {
    if (!extensiveProbeEnabled("subdl.com")) return error.SkipZigTest;
    try runExtensiveProbe("subdl.com", runSubdl);
}

test "extensive live suite provider: isubtitles.org" {
    if (!extensiveProbeEnabled("isubtitles.org")) return error.SkipZigTest;
    try runExtensiveProbe("isubtitles.org", runISubtitles);
}

test "extensive live suite provider: moviesubtitles.org" {
    if (!extensiveProbeEnabled("moviesubtitles.org")) return error.SkipZigTest;
    try runExtensiveProbe("moviesubtitles.org", runMovieSubtitlesOrg);
}

test "extensive live suite provider: moviesubtitlesrt.com" {
    if (!extensiveProbeEnabled("moviesubtitlesrt.com")) return error.SkipZigTest;
    try runExtensiveProbe("moviesubtitlesrt.com", runMovieSubtitlesRt);
}

test "extensive live suite provider: my-subs.co" {
    if (!extensiveProbeEnabled("my-subs.co")) return error.SkipZigTest;
    try runExtensiveProbe("my-subs.co", runMySubs);
}

test "extensive live suite provider: podnapisi.net" {
    if (!extensiveProbeEnabled("podnapisi.net")) return error.SkipZigTest;
    try runExtensiveProbe("podnapisi.net", runPodnapisi);
}

test "extensive live suite provider: subtitlecat.com" {
    if (!extensiveProbeEnabled("subtitlecat.com")) return error.SkipZigTest;
    try runExtensiveProbe("subtitlecat.com", runSubtitleCat);
}

test "extensive live suite provider: subsource.net" {
    if (!extensiveProbeEnabled("subsource.net")) return error.SkipZigTest;
    try runExtensiveProbe("subsource.net", runSubsource);
}

test "extensive live suite provider: tvsubtitles.net" {
    if (!extensiveProbeEnabled("tvsubtitles.net")) return error.SkipZigTest;
    try runExtensiveProbe("tvsubtitles.net", runTvSubtitles);
}

fn extensiveProbeEnabled(provider_name: []const u8) bool {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return false;
    if (!suite.shouldRunExtensiveLiveSuite(std.testing.allocator)) return false;
    return common.providerMatchesLiveFilter(common.liveProviderFilter(), provider_name);
}

fn runExtensiveProbe(
    provider_name: []const u8,
    run: *const fn (allocator: std.mem.Allocator, client: *std.http.Client) anyerror!void,
) !void {
    const started_ms = std.time.milliTimestamp();
    std.debug.print("[live][extensive][{s}] test_start\n", .{provider_name});
    defer {
        const elapsed_ms = std.time.milliTimestamp() - started_ms;
        std.debug.print("[live][extensive][{s}] test_end elapsed_ms={d}\n", .{ provider_name, elapsed_ms });
    }

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    try run(allocator, &client);
}

fn phaseStart(provider: []const u8, phase: []const u8) i64 {
    const started_ms = std.time.milliTimestamp();
    std.debug.print("[live][phase][{s}] start {s}\n", .{ provider, phase });
    return started_ms;
}

fn phaseDone(provider: []const u8, phase: []const u8, started_ms: i64) void {
    const elapsed_ms = std.time.milliTimestamp() - started_ms;
    std.debug.print("[live][phase][{s}] done {s} elapsed_ms={d}\n", .{
        provider,
        phase,
        elapsed_ms,
    });
}

fn runSubdl(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = subdl_com.Scraper.initWithOptions(allocator, client, .{ .include_empty_subtitle_groups = false });
    defer scraper.deinit();

    const search_started_ms = phaseStart("subdl.com", "search");
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    phaseDone("subdl.com", "search", search_started_ms);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][subdl.com][search][{d}]\n", .{idx});
        std.debug.print("[live] media_type={s}\n", .{@tagName(item.media_type)});
        try common.livePrintField(allocator, "name", item.name);
        try common.livePrintField(allocator, "poster_url", item.poster_url);
        std.debug.print("[live] year={d}\n", .{item.year});
        try common.livePrintField(allocator, "link", item.link);
        try common.livePrintField(allocator, "original_name", item.original_name);
        std.debug.print("[live] subtitles_count={d}\n", .{item.subtitles_count});
    }

    try suite.expectPositive(search.items.len);
    const item = search.items[0];
    try suite.expectNonEmpty(item.name);
    try suite.expectNonEmpty(item.link);

    const movie_started_ms = phaseStart("subdl.com", "fetch_movie");
    var movie = try scraper.fetchMovieByLink(item.link);
    defer movie.deinit();
    phaseDone("subdl.com", "fetch_movie", movie_started_ms);
    std.debug.print("[live][subdl.com][movie]\n", .{});
    std.debug.print("[live] media_type={s}\n", .{@tagName(movie.movie.media_type)});
    std.debug.print("[live] sd_id={d}\n", .{movie.movie.sd_id});
    try common.livePrintField(allocator, "slug", movie.movie.slug);
    try common.livePrintField(allocator, "name", movie.movie.name);
    try common.livePrintField(allocator, "second_name", movie.movie.second_name);
    try common.livePrintField(allocator, "poster_url", movie.movie.poster_url);
    std.debug.print("[live] year={d}\n", .{movie.movie.year});
    std.debug.print("[live] total_seasons={d}\n", .{movie.movie.total_seasons});
    for (movie.languages, 0..) |group, group_idx| {
        std.debug.print("[live][subdl.com][language_group][{d}]\n", .{group_idx});
        try common.livePrintField(allocator, "language", group.language);
        std.debug.print("[live] subtitles_len={d}\n", .{group.subtitles.len});
        for (group.subtitles, 0..) |sub, sub_idx| {
            std.debug.print("[live][subdl.com][subtitle][{d}][{d}]\n", .{ group_idx, sub_idx });
            std.debug.print("[live] id={d}\n", .{sub.id});
            try common.livePrintField(allocator, "language", sub.language);
            try common.livePrintField(allocator, "quality", sub.quality);
            try common.livePrintField(allocator, "link", sub.link);
            try common.livePrintField(allocator, "bucket_link", sub.bucket_link);
            try common.livePrintField(allocator, "author", sub.author);
            std.debug.print("[live] season={d}\n", .{sub.season});
            std.debug.print("[live] episode={d}\n", .{sub.episode});
            try common.livePrintField(allocator, "title", sub.title);
            try common.livePrintField(allocator, "extra", sub.extra);
            std.debug.print("[live] enabled={any}\n", .{sub.enabled});
            try common.livePrintField(allocator, "n_id", sub.n_id);
            std.debug.print("[live] downloads={d}\n", .{sub.downloads});
            std.debug.print("[live] hearing_impaired={any}\n", .{sub.hearing_impaired});
            if (sub.rate) |rate| {
                std.debug.print("[live] rate={d}\n", .{rate});
            } else {
                std.debug.print("[live] rate=<null>\n", .{});
            }
            std.debug.print("[live] date_ms={d}\n", .{sub.date_ms});
            try common.livePrintField(allocator, "comment", sub.comment);
            try common.livePrintOptionalField(allocator, "slug", sub.slug);
            for (sub.releases, 0..) |release, release_idx| {
                std.debug.print("[live][subdl.com][subtitle_release][{d}][{d}][{d}]\n", .{ group_idx, sub_idx, release_idx });
                try common.livePrintField(allocator, "release", release);
            }
        }
    }

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

    const search_started_ms = phaseStart("isubtitles.org", "search");
    var search = try scraper.searchWithOptions("The Matrix", .{ .max_pages = 2 });
    defer search.deinit();
    phaseDone("isubtitles.org", "search", search_started_ms);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][isubtitles.org][search][{d}]\n", .{idx});
        try common.livePrintField(allocator, "title", item.title);
        try common.livePrintOptionalField(allocator, "year", item.year);
        try common.livePrintField(allocator, "details_url", item.details_url);
    }
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(isubtitles_org.SearchItem, search.items, "matrix") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectHttpUrl(match.details_url);

    const subtitles_started_ms = phaseStart("isubtitles.org", "fetch_subtitles");
    var subtitles = try scraper.fetchSubtitlesByMovieLinkWithOptions(match.details_url, .{ .max_pages = 2 });
    defer subtitles.deinit();
    phaseDone("isubtitles.org", "fetch_subtitles", subtitles_started_ms);
    try common.livePrintField(allocator, "subtitles_title", subtitles.title);
    for (subtitles.subtitles, 0..) |sub, idx| {
        std.debug.print("[live][isubtitles.org][subtitle][{d}]\n", .{idx});
        try common.livePrintOptionalField(allocator, "language_raw", sub.language_raw);
        try common.livePrintOptionalField(allocator, "language_code", sub.language_code);
        try common.livePrintOptionalField(allocator, "release", sub.release);
        try common.livePrintOptionalField(allocator, "created_at", sub.created_at);
        try common.livePrintOptionalField(allocator, "file_count", sub.file_count);
        try common.livePrintOptionalField(allocator, "size", sub.size);
        try common.livePrintOptionalField(allocator, "comment", sub.comment);
        try common.livePrintField(allocator, "filename", sub.filename);
        try common.livePrintField(allocator, "details_url", sub.details_url);
        try common.livePrintField(allocator, "download_page_url", sub.download_page_url);
    }
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectNonEmpty(first.filename);
    try suite.expectHttpUrl(first.download_page_url);
}

fn runMovieSubtitlesOrg(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = moviesubtitles_org.Scraper.init(allocator, client);

    const search_started_ms = phaseStart("moviesubtitles.org", "search");
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    phaseDone("moviesubtitles.org", "search", search_started_ms);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][moviesubtitles.org][search][{d}]\n", .{idx});
        try common.livePrintField(allocator, "title", item.title);
        try common.livePrintField(allocator, "link", item.link);
    }
    try suite.expectPositive(search.items.len);

    var validated = false;
    const limit = @min(search.items.len, 8);
    for (search.items[0..limit]) |movie| {
        if (movie.link.len == 0) continue;

        const subtitles_started_ms = phaseStart("moviesubtitles.org", "fetch_subtitles");
        var subtitles = scraper.fetchSubtitlesByMovieLink(movie.link) catch continue;
        defer subtitles.deinit();
        phaseDone("moviesubtitles.org", "fetch_subtitles", subtitles_started_ms);
        if (subtitles.subtitles.len == 0) continue;
        try common.livePrintField(allocator, "subtitles_title", subtitles.title);
        for (subtitles.subtitles, 0..) |sub, idx| {
            std.debug.print("[live][moviesubtitles.org][subtitle][{d}]\n", .{idx});
            try common.livePrintOptionalField(allocator, "language_code", sub.language_code);
            try common.livePrintField(allocator, "filename", sub.filename);
            try common.livePrintField(allocator, "details_url", sub.details_url);
            try common.livePrintField(allocator, "download_url", sub.download_url);
            try common.livePrintOptionalField(allocator, "rating_good", sub.rating_good);
            try common.livePrintOptionalField(allocator, "rating_bad", sub.rating_bad);
        }

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

    const search_started_ms = phaseStart("moviesubtitlesrt.com", "search");
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    phaseDone("moviesubtitlesrt.com", "search", search_started_ms);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][moviesubtitlesrt.com][search][{d}]\n", .{idx});
        try common.livePrintField(allocator, "title", item.title);
        try common.livePrintField(allocator, "page_url", item.page_url);
    }
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(moviesubtitlesrt_com.SearchItem, search.items, "matrix") orelse 0;
    const hit = search.items[chosen_idx];
    try suite.expectNonEmpty(hit.title);
    try suite.expectHttpUrl(hit.page_url);

    const details_started_ms = phaseStart("moviesubtitlesrt.com", "fetch_subtitle_details");
    var details = try scraper.fetchSubtitleByLink(hit.page_url);
    defer details.deinit();
    phaseDone("moviesubtitlesrt.com", "fetch_subtitle_details", details_started_ms);
    std.debug.print("[live][moviesubtitlesrt.com][subtitle]\n", .{});
    try common.livePrintField(allocator, "title", details.subtitle.title);
    try common.livePrintOptionalField(allocator, "language_raw", details.subtitle.language_raw);
    try common.livePrintOptionalField(allocator, "language_code", details.subtitle.language_code);
    try common.livePrintOptionalField(allocator, "release_date", details.subtitle.release_date);
    try common.livePrintOptionalField(allocator, "running_time", details.subtitle.running_time);
    try common.livePrintOptionalField(allocator, "file_type", details.subtitle.file_type);
    try common.livePrintOptionalField(allocator, "author", details.subtitle.author);
    try common.livePrintOptionalField(allocator, "posted_date", details.subtitle.posted_date);
    try common.livePrintField(allocator, "download_url", details.subtitle.download_url);

    try suite.expectNonEmpty(details.subtitle.title);
    try suite.expectHttpUrl(details.subtitle.download_url);
    try suite.expectMaybeNonEmpty(details.subtitle.language_raw);
}

fn runMySubs(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = my_subs_co.Scraper.init(allocator, client);

    const search_started_ms = phaseStart("my-subs.co", "search");
    var search = try scraper.searchWithOptions("The Matrix", .{ .max_pages = 2 });
    defer search.deinit();
    phaseDone("my-subs.co", "search", search_started_ms);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][my-subs.co][search][{d}]\n", .{idx});
        try common.livePrintField(allocator, "title", item.title);
        try common.livePrintField(allocator, "details_url", item.details_url);
        std.debug.print("[live] media_kind={s}\n", .{@tagName(item.media_kind)});
    }
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(my_subs_co.SearchItem, search.items, "matrix") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectHttpUrl(match.details_url);

    const subtitles_started_ms = phaseStart("my-subs.co", "fetch_subtitles");
    var subtitles = try scraper.fetchSubtitlesByDetailsLinkWithOptions(match.details_url, match.media_kind, .{
        .include_seasons = true,
        .max_pages_per_entry = 2,
        .resolve_download_links = false,
    });
    defer subtitles.deinit();
    phaseDone("my-subs.co", "fetch_subtitles", subtitles_started_ms);
    for (subtitles.subtitles, 0..) |sub, idx| {
        std.debug.print("[live][my-subs.co][subtitle][{d}]\n", .{idx});
        try common.livePrintOptionalField(allocator, "language_raw", sub.language_raw);
        try common.livePrintOptionalField(allocator, "language_code", sub.language_code);
        try common.livePrintField(allocator, "filename", sub.filename);
        try common.livePrintOptionalField(allocator, "release_version", sub.release_version);
        try common.livePrintField(allocator, "details_url", sub.details_url);
        try common.livePrintField(allocator, "download_page_url", sub.download_page_url);
        try common.livePrintOptionalField(allocator, "resolved_download_url", sub.resolved_download_url);
        if (sub.is_archive) |is_archive| {
            std.debug.print("[live] is_archive={any}\n", .{is_archive});
        } else {
            std.debug.print("[live] is_archive=<null>\n", .{});
        }
    }
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectNonEmpty(first.filename);
    try suite.expectHttpUrl(first.download_page_url);
}

fn runPodnapisi(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = podnapisi_net.Scraper.init(allocator, client);

    const search_started_ms = phaseStart("podnapisi.net", "search");
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    phaseDone("podnapisi.net", "search", search_started_ms);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][podnapisi.net][search][{d}]\n", .{idx});
        try common.livePrintField(allocator, "id", item.id);
        try common.livePrintField(allocator, "title", item.title);
        try common.livePrintField(allocator, "media_type", item.media_type);
        if (item.year) |year| {
            std.debug.print("[live] year={d}\n", .{year});
        } else {
            std.debug.print("[live] year=<null>\n", .{});
        }
        try common.livePrintField(allocator, "subtitles_page_url", item.subtitles_page_url);
    }
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(podnapisi_net.SearchItem, search.items, "matrix") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectHttpUrl(match.subtitles_page_url);

    const subtitles_started_ms = phaseStart("podnapisi.net", "fetch_subtitles");
    var subtitles = try scraper.fetchSubtitlesBySearchLink(match.subtitles_page_url);
    defer subtitles.deinit();
    phaseDone("podnapisi.net", "fetch_subtitles", subtitles_started_ms);
    for (subtitles.subtitles, 0..) |sub, idx| {
        std.debug.print("[live][podnapisi.net][subtitle][{d}]\n", .{idx});
        try common.livePrintOptionalField(allocator, "language", sub.language);
        try common.livePrintOptionalField(allocator, "release", sub.release);
        try common.livePrintOptionalField(allocator, "fps", sub.fps);
        try common.livePrintOptionalField(allocator, "cds", sub.cds);
        try common.livePrintOptionalField(allocator, "rating", sub.rating);
        try common.livePrintOptionalField(allocator, "uploader", sub.uploader);
        try common.livePrintOptionalField(allocator, "uploaded_at", sub.uploaded_at);
        try common.livePrintField(allocator, "download_url", sub.download_url);
    }
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectHttpUrl(first.download_url);
    try suite.expectMaybeNonEmpty(first.language);
}

fn runSubtitleCat(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = subtitlecat_com.Scraper.init(allocator, client);

    const search_started_ms = phaseStart("subtitlecat.com", "search");
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    phaseDone("subtitlecat.com", "search", search_started_ms);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][subtitlecat.com][search][{d}]\n", .{idx});
        try common.livePrintField(allocator, "title", item.title);
        try common.livePrintField(allocator, "details_url", item.details_url);
        try common.livePrintOptionalField(allocator, "source_language", item.source_language);
    }
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(subtitlecat_com.SearchItem, search.items, "matrix") orelse 0;
    const entry = search.items[chosen_idx];
    try suite.expectNonEmpty(entry.title);
    try suite.expectHttpUrl(entry.details_url);

    const subtitles_started_ms = phaseStart("subtitlecat.com", "fetch_subtitles");
    var subtitles = try scraper.fetchSubtitlesByDetailsLink(entry.details_url);
    defer subtitles.deinit();
    phaseDone("subtitlecat.com", "fetch_subtitles", subtitles_started_ms);
    for (subtitles.subtitles, 0..) |sub, idx| {
        std.debug.print("[live][subtitlecat.com][subtitle][{d}]\n", .{idx});
        try common.livePrintOptionalField(allocator, "language_code", sub.language_code);
        try common.livePrintOptionalField(allocator, "language_label", sub.language_label);
        try common.livePrintField(allocator, "filename", sub.filename);
        std.debug.print("[live] mode={s}\n", .{@tagName(sub.mode)});
        try common.livePrintOptionalField(allocator, "source_url", sub.source_url);
        try common.livePrintOptionalField(allocator, "download_url", sub.download_url);
        if (sub.translate_spec) |spec| {
            try common.livePrintOptionalField(allocator, "translate_spec.source_url", spec.source_url);
        } else {
            std.debug.print("[live] translate_spec=<null>\n", .{});
        }
    }
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectNonEmpty(first.filename);
    if (first.source_url) |source| try suite.expectHttpUrl(source);
}

fn runSubsource(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = subsource_net.Scraper.init(allocator, client);

    const search_started_ms = phaseStart("subsource.net", "search");
    var search = try scraper.searchWithOptions("The Matrix", .{
        .include_seasons = true,
        .max_pages = 1,
        .auto_cloudflare_session = false,
    });
    defer search.deinit();
    phaseDone("subsource.net", "search", search_started_ms);
    try common.livePrintField(allocator, "query_used", search.query_used);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][subsource.net][search][{d}]\n", .{idx});
        std.debug.print("[live] id={d}\n", .{item.id});
        try common.livePrintField(allocator, "title", item.title);
        try common.livePrintField(allocator, "media_type", item.media_type);
        try common.livePrintField(allocator, "link", item.link);
        if (item.release_year) |release_year| {
            std.debug.print("[live] release_year={d}\n", .{release_year});
        } else {
            std.debug.print("[live] release_year=<null>\n", .{});
        }
        if (item.subtitle_count) |subtitle_count| {
            std.debug.print("[live] subtitle_count={d}\n", .{subtitle_count});
        } else {
            std.debug.print("[live] subtitle_count=<null>\n", .{});
        }
        for (item.seasons, 0..) |season, season_idx| {
            std.debug.print("[live][subsource.net][season][{d}][{d}]\n", .{ idx, season_idx });
            std.debug.print("[live] season={d}\n", .{season.season});
            try common.livePrintField(allocator, "link", season.link);
        }
    }
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(subsource_net.SearchItem, search.items, "matrix") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectUrlOrAbsolutePath(match.link);

    const subtitles_started_ms = phaseStart("subsource.net", "fetch_subtitles");
    var subtitles = try scraper.fetchSubtitlesBySearchItemWithOptions(match, .{
        .include_seasons = true,
        .max_pages = 1,
        .resolve_download_tokens = false,
        .auto_cloudflare_session = false,
    });
    defer subtitles.deinit();
    phaseDone("subsource.net", "fetch_subtitles", subtitles_started_ms);
    try common.livePrintField(allocator, "subtitles_title", subtitles.title);
    for (subtitles.subtitles, 0..) |sub, idx| {
        std.debug.print("[live][subsource.net][subtitle][{d}]\n", .{idx});
        std.debug.print("[live] id={d}\n", .{sub.id});
        try common.livePrintOptionalField(allocator, "language_raw", sub.language_raw);
        try common.livePrintOptionalField(allocator, "language_code", sub.language_code);
        try common.livePrintOptionalField(allocator, "release_info", sub.release_info);
        try common.livePrintOptionalField(allocator, "release_type", sub.release_type);
        try common.livePrintField(allocator, "details_path", sub.details_path);
        try common.livePrintOptionalField(allocator, "download_token", sub.download_token);
        try common.livePrintOptionalField(allocator, "download_url", sub.download_url);
    }
    try suite.expectPositive(subtitles.subtitles.len);

    const first = subtitles.subtitles[0];
    try suite.expectNonEmpty(first.details_path);
}

fn runTvSubtitles(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    var scraper = tvsubtitles_net.Scraper.init(allocator, client);

    const search_started_ms = phaseStart("tvsubtitles.net", "search");
    var search = try scraper.searchWithOptions("Chernobyl", .{ .max_pages = 1 });
    defer search.deinit();
    phaseDone("tvsubtitles.net", "search", search_started_ms);
    for (search.items, 0..) |item, idx| {
        std.debug.print("[live][tvsubtitles.net][search][{d}]\n", .{idx});
        try common.livePrintField(allocator, "title", item.title);
        try common.livePrintField(allocator, "show_url", item.show_url);
    }
    try suite.expectPositive(search.items.len);

    const chosen_idx = pickFirstContaining(tvsubtitles_net.SearchItem, search.items, "chernobyl") orelse 0;
    const match = search.items[chosen_idx];
    try suite.expectNonEmpty(match.title);
    try suite.expectHttpUrl(match.show_url);

    const subtitles_started_ms = phaseStart("tvsubtitles.net", "fetch_subtitles");
    var subtitles = try scraper.fetchSubtitlesByShowLinkWithOptions(match.show_url, .{
        .include_all_seasons = false,
        .max_pages_per_season = 1,
        .resolve_download_links = false,
    });
    defer subtitles.deinit();
    phaseDone("tvsubtitles.net", "fetch_subtitles", subtitles_started_ms);
    for (subtitles.subtitles, 0..) |sub, idx| {
        std.debug.print("[live][tvsubtitles.net][subtitle][{d}]\n", .{idx});
        try common.livePrintOptionalField(allocator, "language_code", sub.language_code);
        try common.livePrintOptionalField(allocator, "episode_title", sub.episode_title);
        try common.livePrintField(allocator, "filename", sub.filename);
        try common.livePrintField(allocator, "season_page_url", sub.season_page_url);
        try common.livePrintField(allocator, "subtitle_page_url", sub.subtitle_page_url);
        try common.livePrintField(allocator, "download_page_url", sub.download_page_url);
        try common.livePrintOptionalField(allocator, "direct_zip_url", sub.direct_zip_url);
    }
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
