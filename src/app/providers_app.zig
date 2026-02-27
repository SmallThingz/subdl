const std = @import("std");
const subdl = @import("../scrapers/subdl.zig");

const Allocator = std.mem.Allocator;
const common = subdl.common;
const cf = subdl.opensubtitles_com_cf;
const opensubtitles_remote_prefix = "oscom-remote:";

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
    tvsubtitles_net,
};

const provider_values = [_]Provider{
    .subdl_com,
    .opensubtitles_com,
    .opensubtitles_org,
    .moviesubtitles_org,
    .moviesubtitlesrt_com,
    .podnapisi_net,
    .yifysubtitles_ch,
    .subtitlecat_com,
    .isubtitles_org,
    .my_subs_co,
    .subsource_net,
    .tvsubtitles_net,
};

pub fn providers() []const Provider {
    return &provider_values;
}

pub fn providerName(provider: Provider) []const u8 {
    return switch (provider) {
        .subdl_com => "subdl_com",
        .opensubtitles_com => "opensubtitles_com",
        .opensubtitles_org => "opensubtitles_org",
        .moviesubtitles_org => "moviesubtitles_org",
        .moviesubtitlesrt_com => "moviesubtitlesrt_com",
        .podnapisi_net => "podnapisi_net",
        .yifysubtitles_ch => "yifysubtitles_ch",
        .subtitlecat_com => "subtitlecat_com",
        .isubtitles_org => "isubtitles_org",
        .my_subs_co => "my_subs_co",
        .subsource_net => "subsource_net",
        .tvsubtitles_net => "tvsubtitles_net",
    };
}

pub fn parseProvider(value: []const u8) ?Provider {
    if (matchesProvider(value, "subdl") or matchesProvider(value, "subdl_com")) return .subdl_com;
    if (matchesProvider(value, "opensubtitles_com")) return .opensubtitles_com;
    if (matchesProvider(value, "opensubtitles_org")) return .opensubtitles_org;
    if (matchesProvider(value, "moviesubtitles_org")) return .moviesubtitles_org;
    if (matchesProvider(value, "moviesubtitlesrt_com")) return .moviesubtitlesrt_com;
    if (matchesProvider(value, "podnapisi_net")) return .podnapisi_net;
    if (matchesProvider(value, "yifysubtitles_ch") or matchesProvider(value, "yify")) return .yifysubtitles_ch;
    if (matchesProvider(value, "subtitlecat_com") or matchesProvider(value, "subtitlecat")) return .subtitlecat_com;
    if (matchesProvider(value, "isubtitles_org") or matchesProvider(value, "isubtitles")) return .isubtitles_org;
    if (matchesProvider(value, "my_subs_co") or matchesProvider(value, "my_subs")) return .my_subs_co;
    if (matchesProvider(value, "subsource_net") or matchesProvider(value, "subsource")) return .subsource_net;
    if (matchesProvider(value, "tvsubtitles_net") or matchesProvider(value, "tvsubtitles")) return .tvsubtitles_net;
    return null;
}

fn matchesProvider(input: []const u8, canonical: []const u8) bool {
    if (input.len == 0) return false;
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len and j < canonical.len) {
        const a = normalizeProviderChar(input[i]);
        const b = normalizeProviderChar(canonical[j]);
        if (a != b) return false;
        i += 1;
        j += 1;
    }
    return i == input.len and j == canonical.len;
}

fn normalizeProviderChar(c: u8) u8 {
    return switch (c) {
        '.', '-' => '_',
        else => std.ascii.toLower(c),
    };
}

pub const SearchRef = union(Provider) {
    subdl_com: struct {
        title: []const u8,
        media_type: subdl.MediaType,
        link: []const u8,
    },
    opensubtitles_com: struct {
        title: []const u8,
        year: ?[]const u8,
        item_type: ?[]const u8,
        path: []const u8,
        subtitles_count: ?i64,
        subtitles_list_url: []const u8,
    },
    opensubtitles_org: struct {
        title: []const u8,
        page_url: []const u8,
    },
    moviesubtitles_org: struct {
        title: []const u8,
        link: []const u8,
    },
    moviesubtitlesrt_com: struct {
        title: []const u8,
        page_url: []const u8,
    },
    podnapisi_net: struct {
        title: []const u8,
        subtitles_page_url: []const u8,
    },
    yifysubtitles_ch: struct {
        title: []const u8,
        movie_page_url: []const u8,
    },
    subtitlecat_com: struct {
        title: []const u8,
        details_url: []const u8,
    },
    isubtitles_org: struct {
        title: []const u8,
        details_url: []const u8,
    },
    my_subs_co: struct {
        title: []const u8,
        details_url: []const u8,
        media_kind: subdl.my_subs_co.MediaKind,
    },
    subsource_net: struct {
        title: []const u8,
        link: []const u8,
        media_type: []const u8,
    },
    tvsubtitles_net: struct {
        title: []const u8,
        show_url: []const u8,
    },
};

pub const SearchChoice = struct {
    title: []const u8,
    label: []const u8,
    ref: SearchRef,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    provider: Provider,
    items: []const SearchChoice,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitleChoice = struct {
    label: []const u8,
    language: ?[]const u8,
    filename: ?[]const u8,
    download_url: ?[]const u8,
};

pub const SubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    provider: Provider,
    title: []const u8,
    items: []const SubtitleChoice,

    pub fn deinit(self: *SubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const DownloadResult = struct {
    file_path: []const u8,
    archive_path: ?[]const u8 = null,
    extracted_files: []const []const u8 = &.{},
    bytes_written: usize,
    source_url: []const u8,

    pub fn deinit(self: *DownloadResult, allocator: Allocator) void {
        allocator.free(self.file_path);
        if (self.archive_path) |p| allocator.free(p);
        if (self.extracted_files.len > 0) {
            for (self.extracted_files) |p| allocator.free(p);
            allocator.free(self.extracted_files);
        }
        self.* = undefined;
    }
};

pub fn search(allocator: Allocator, client: *std.http.Client, provider: Provider, query: []const u8) !SearchResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SearchChoice) = .empty;

    switch (provider) {
        .subdl_com => {
            var scraper = subdl.subdl_com.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.name);
                const link = try toAbsoluteSubdlLink(a, item.link);
                const label = try std.fmt.allocPrint(a, "[{s}] {s} ({d})", .{ @tagName(item.media_type), title, item.year });
                try out.append(a, .{
                    .title = title,
                    .label = label,
                    .ref = .{ .subdl_com = .{
                        .title = title,
                        .media_type = item.media_type,
                        .link = link,
                    } },
                });
            }
        },
        .opensubtitles_com => {
            var scraper = subdl.opensubtitles_com.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const year = try dupOptional(a, item.year);
                const item_type = try dupOptional(a, item.item_type);
                const path = try a.dupe(u8, item.path);
                const list_url = try a.dupe(u8, item.subtitles_list_url);
                const label = if (year) |y|
                    try std.fmt.allocPrint(a, "{s} ({s})", .{ title, y })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .title = title,
                    .label = label,
                    .ref = .{ .opensubtitles_com = .{
                        .title = title,
                        .year = year,
                        .item_type = item_type,
                        .path = path,
                        .subtitles_count = item.subtitles_count,
                        .subtitles_list_url = list_url,
                    } },
                });
            }
        },
        .opensubtitles_org => {
            var scraper = subdl.opensubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const page_url = try a.dupe(u8, item.page_url);
                try out.append(a, .{
                    .title = title,
                    .label = try a.dupe(u8, title),
                    .ref = .{ .opensubtitles_org = .{
                        .title = title,
                        .page_url = page_url,
                    } },
                });
            }
        },
        .moviesubtitles_org => {
            var scraper = subdl.moviesubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const link = try a.dupe(u8, item.link);
                try out.append(a, .{
                    .title = title,
                    .label = try a.dupe(u8, title),
                    .ref = .{ .moviesubtitles_org = .{
                        .title = title,
                        .link = link,
                    } },
                });
            }
        },
        .moviesubtitlesrt_com => {
            var scraper = subdl.moviesubtitlesrt_com.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const page_url = try a.dupe(u8, item.page_url);
                try out.append(a, .{
                    .title = title,
                    .label = try a.dupe(u8, title),
                    .ref = .{ .moviesubtitlesrt_com = .{
                        .title = title,
                        .page_url = page_url,
                    } },
                });
            }
        },
        .podnapisi_net => {
            var scraper = subdl.podnapisi_net.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const subtitles_page_url = try a.dupe(u8, item.subtitles_page_url);
                const label = if (item.year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d})", .{ title, year })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .title = title,
                    .label = label,
                    .ref = .{ .podnapisi_net = .{
                        .title = title,
                        .subtitles_page_url = subtitles_page_url,
                    } },
                });
            }
        },
        .yifysubtitles_ch => {
            var scraper = subdl.yifysubtitles_ch.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.movie);
                const movie_page_url = try a.dupe(u8, item.movie_page_url);
                try out.append(a, .{
                    .title = title,
                    .label = try a.dupe(u8, title),
                    .ref = .{ .yifysubtitles_ch = .{
                        .title = title,
                        .movie_page_url = movie_page_url,
                    } },
                });
            }
        },
        .subtitlecat_com => {
            var scraper = subdl.subtitlecat_com.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const details_url = try a.dupe(u8, item.details_url);
                try out.append(a, .{
                    .title = title,
                    .label = try a.dupe(u8, title),
                    .ref = .{ .subtitlecat_com = .{
                        .title = title,
                        .details_url = details_url,
                    } },
                });
            }
        },
        .isubtitles_org => {
            var scraper = subdl.isubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.searchWithOptions(query, .{ .max_pages = 3 });
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const details_url = try a.dupe(u8, item.details_url);
                const label = if (item.year) |y|
                    try std.fmt.allocPrint(a, "{s} ({s})", .{ title, y })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .title = title,
                    .label = label,
                    .ref = .{ .isubtitles_org = .{
                        .title = title,
                        .details_url = details_url,
                    } },
                });
            }
        },
        .my_subs_co => {
            var scraper = subdl.my_subs_co.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.searchWithOptions(query, .{ .max_pages = 3 });
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const details_url = try a.dupe(u8, item.details_url);
                const label = try std.fmt.allocPrint(a, "[{s}] {s}", .{ @tagName(item.media_kind), title });
                try out.append(a, .{
                    .title = title,
                    .label = label,
                    .ref = .{ .my_subs_co = .{
                        .title = title,
                        .details_url = details_url,
                        .media_kind = item.media_kind,
                    } },
                });
            }
        },
        .subsource_net => {
            var scraper = subdl.subsource_net.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.searchWithOptions(query, .{
                .max_pages = 3,
                .auto_cloudflare_session = false,
            });
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const link = try a.dupe(u8, item.link);
                const media_type = try a.dupe(u8, item.media_type);
                const label = if (item.release_year) |year|
                    try std.fmt.allocPrint(a, "{s} ({d})", .{ title, year })
                else
                    try a.dupe(u8, title);

                try out.append(a, .{
                    .title = title,
                    .label = label,
                    .ref = .{ .subsource_net = .{
                        .title = title,
                        .link = link,
                        .media_type = media_type,
                    } },
                });
            }
        },
        .tvsubtitles_net => {
            var scraper = subdl.tvsubtitles_net.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.searchWithOptions(query, .{ .max_pages = 3 });
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const show_url = try a.dupe(u8, item.show_url);
                try out.append(a, .{
                    .title = title,
                    .label = try a.dupe(u8, title),
                    .ref = .{ .tvsubtitles_net = .{
                        .title = title,
                        .show_url = show_url,
                    } },
                });
            }
        },
    }

    return .{
        .arena = arena,
        .provider = provider,
        .items = try out.toOwnedSlice(a),
    };
}

pub fn fetchSubtitles(allocator: Allocator, client: *std.http.Client, ref: SearchRef) !SubtitlesResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SubtitleChoice) = .empty;
    var title: []const u8 = "";

    switch (ref) {
        .subdl_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subdl_com.Scraper.init(a, client);
            defer scraper.deinit();

            switch (item.media_type) {
                .movie => {
                    var movie = try scraper.fetchMovieByLink(item.link);
                    defer movie.deinit();
                    title = try a.dupe(u8, movie.movie.name);

                    for (movie.languages) |group| {
                        for (group.subtitles) |subtitle| {
                            const download_url = try std.fmt.allocPrint(a, "https://dl.subdl.com/subtitle/{s}", .{subtitle.link});
                            const label = try std.fmt.allocPrint(a, "{s} | {s}", .{ group.language, subtitle.title });
                            try out.append(a, .{
                                .label = label,
                                .language = try a.dupe(u8, group.language),
                                .filename = try a.dupe(u8, subtitle.title),
                                .download_url = download_url,
                            });
                        }
                    }
                },
                .tv => {
                    var seasons = try scraper.fetchTvSeasonsByLink(item.link);
                    defer seasons.deinit();
                    title = try a.dupe(u8, seasons.tv.name);

                    for (seasons.seasons) |season| {
                        var season_data = scraper.fetchTvSeasonByLink(item.link, season.number) catch continue;
                        defer season_data.deinit();

                        for (season_data.languages) |group| {
                            for (group.subtitles) |subtitle| {
                                const download_url = try std.fmt.allocPrint(a, "https://dl.subdl.com/subtitle/{s}", .{subtitle.link});
                                const label = try std.fmt.allocPrint(a, "{s} | {s} | {s}", .{ season.name, group.language, subtitle.title });
                                try out.append(a, .{
                                    .label = label,
                                    .language = try a.dupe(u8, group.language),
                                    .filename = try a.dupe(u8, subtitle.title),
                                    .download_url = download_url,
                                });
                            }
                        }
                    }
                },
            }
        },
        .opensubtitles_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.opensubtitles_com.Scraper.init(a, client);
            defer scraper.deinit();

            const query_item: subdl.opensubtitles_com.SearchItem = .{
                .title = item.title,
                .year = item.year,
                .item_type = item.item_type,
                .path = item.path,
                .subtitles_count = item.subtitles_count,
                .subtitles_list_url = item.subtitles_list_url,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItemWithOptions(query_item, .{
                .resolve_downloads = false,
            });
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const download_url = if (subtitle.verified_download_url) |resolved|
                    resolved
                else
                    try makeOpenSubtitlesRemoteToken(a, subtitle.remote_endpoint);
                const label = try subtitleLabel(a, subtitle.language, subtitle.filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language),
                    .filename = try dupOptional(a, subtitle.filename),
                    .download_url = try a.dupe(u8, download_url),
                });
            }
        },
        .opensubtitles_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.opensubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByMoviePage(item.page_url);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const download_url = if (subtitle.direct_zip_url.len > 0) subtitle.direct_zip_url else null;
                const filename = subtitle.filename orelse subtitle.release;
                const label = try subtitleLabel(a, subtitle.language_code, filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try dupOptional(a, filename),
                    .download_url = try dupOptional(a, download_url),
                });
            }
        },
        .moviesubtitles_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.moviesubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByMovieLink(item.link);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .moviesubtitlesrt_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.moviesubtitlesrt_com.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitle = try scraper.fetchSubtitleByLink(item.page_url);
            defer subtitle.deinit();
            title = try a.dupe(u8, subtitle.subtitle.title);

            const label = try subtitleLabel(a, subtitle.subtitle.language_code, subtitle.subtitle.title, subtitle.subtitle.download_url);
            try out.append(a, .{
                .label = label,
                .language = try dupOptional(a, subtitle.subtitle.language_code),
                .filename = try a.dupe(u8, subtitle.subtitle.title),
                .download_url = try a.dupe(u8, subtitle.subtitle.download_url),
            });
        },
        .podnapisi_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.podnapisi_net.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesBySearchLink(item.subtitles_page_url);
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language, subtitle.release, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language),
                    .filename = try dupOptional(a, subtitle.release),
                    .download_url = try a.dupe(u8, subtitle.download_url),
                });
            }
        },
        .yifysubtitles_ch => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.yifysubtitles_ch.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByMovieLink(item.movie_page_url);
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language, subtitle.release_text, subtitle.zip_url);
                try out.append(a, .{
                    .label = label,
                    .language = try a.dupe(u8, subtitle.language),
                    .filename = try a.dupe(u8, subtitle.release_text),
                    .download_url = try a.dupe(u8, subtitle.zip_url),
                });
            }
        },
        .subtitlecat_com => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subtitlecat_com.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByDetailsLink(item.details_url);
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try dupOptional(a, subtitle.download_url),
                });
            }
        },
        .isubtitles_org => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.isubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByMovieLinkWithOptions(item.details_url, .{ .max_pages = 3 });
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, subtitle.download_page_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, subtitle.download_page_url),
                });
            }
        },
        .my_subs_co => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.my_subs_co.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByDetailsLinkWithOptions(item.details_url, item.media_kind, .{
                .resolve_download_links = false,
                .max_pages_per_entry = 3,
                .include_seasons = true,
            });
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const download_url = subtitle.download_page_url;
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, download_url),
                });
            }
        },
        .subsource_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.subsource_net.Scraper.init(a, client);
            defer scraper.deinit();

            const fake_item: subdl.subsource_net.SearchItem = .{
                .id = 0,
                .title = item.title,
                .media_type = item.media_type,
                .link = item.link,
                .release_year = null,
                .subtitle_count = null,
                .seasons = &[_]subdl.subsource_net.SeasonItem{},
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItemWithOptions(fake_item, .{
                .include_seasons = true,
                .max_pages = 2,
                .resolve_download_tokens = true,
                .auto_cloudflare_session = false,
            });
            defer subtitles.deinit();
            if (subtitles.title.len > 0) title = try a.dupe(u8, subtitles.title);

            for (subtitles.subtitles) |subtitle| {
                const filename = subtitle.release_info orelse subtitle.release_type;
                const label = try subtitleLabel(a, subtitle.language_code, filename, subtitle.download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try dupOptional(a, filename),
                    .download_url = try dupOptional(a, subtitle.download_url),
                });
            }
        },
        .tvsubtitles_net => |item| {
            title = try a.dupe(u8, item.title);
            var scraper = subdl.tvsubtitles_net.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByShowLinkWithOptions(item.show_url, .{
                .include_all_seasons = true,
                .max_pages_per_season = 2,
                .resolve_download_links = false,
            });
            defer subtitles.deinit();

            for (subtitles.subtitles) |subtitle| {
                const download_url = subtitle.download_page_url;
                const label = try subtitleLabel(a, subtitle.language_code, subtitle.filename, download_url);
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = try a.dupe(u8, download_url),
                });
            }
        },
    }

    return .{
        .arena = arena,
        .provider = std.meta.activeTag(ref),
        .title = title,
        .items = try out.toOwnedSlice(a),
    };
}

pub fn downloadSubtitle(allocator: Allocator, client: *std.http.Client, subtitle: SubtitleChoice, out_dir: []const u8) !DownloadResult {
    const source_url = subtitle.download_url orelse return error.MissingField;
    const url = try resolveDownloadUrlIfNeeded(allocator, client, source_url);
    defer allocator.free(url);
    const response = try fetchDownloadBytes(client, allocator, url);
    defer allocator.free(response.body);
    if (response.status != .ok) return error.UnexpectedHttpStatus;

    try std.fs.cwd().makePath(out_dir);
    const raw_name = subtitle.filename orelse inferFilenameFromUrl(url) orelse "subtitle.bin";
    const safe_name = try sanitizeFilename(allocator, raw_name);
    defer allocator.free(safe_name);

    const output_path = try nextAvailableOutputPath(allocator, out_dir, safe_name);
    errdefer allocator.free(output_path);
    var file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(response.body);

    const archive_kind = detectArchiveKind(safe_name, url, response.body);
    if (archive_kind == .none) {
        return .{
            .file_path = output_path,
            .bytes_written = response.body.len,
            .source_url = source_url,
        };
    }

    const stem = filenameStem(safe_name);
    const extract_base = if (stem.len > 0)
        try std.fmt.allocPrint(allocator, "{s}.files", .{stem})
    else
        try allocator.dupe(u8, "subtitle.files");
    defer allocator.free(extract_base);

    const extract_dir = try nextAvailableOutputPath(allocator, out_dir, extract_base);
    defer allocator.free(extract_dir);
    try std.fs.cwd().makePath(extract_dir);

    try extractArchive(allocator, archive_kind, output_path, extract_dir);
    const extracted_files = try collectExtractedSubtitleFiles(allocator, extract_dir);
    errdefer {
        for (extracted_files) |p| allocator.free(p);
        if (extracted_files.len > 0) allocator.free(extracted_files);
    }

    const primary_path = if (extracted_files.len > 0)
        try allocator.dupe(u8, extracted_files[0])
    else
        try allocator.dupe(u8, output_path);
    errdefer allocator.free(primary_path);

    return .{
        .file_path = primary_path,
        .archive_path = output_path,
        .extracted_files = extracted_files,
        .bytes_written = response.body.len,
        .source_url = source_url,
    };
}

fn resolveDownloadUrlIfNeeded(allocator: Allocator, client: *std.http.Client, download_url: []const u8) ![]const u8 {
    if (parseOpenSubtitlesRemoteToken(download_url)) |remote_endpoint| {
        var scraper = subdl.opensubtitles_com.Scraper.init(allocator, client);
        defer scraper.deinit();
        if (try scraper.resolveVerifiedDownloadUrl(allocator, remote_endpoint)) |resolved| return resolved;
        return error.InvalidDownloadUrl;
    }

    if (std.mem.indexOf(u8, download_url, "my-subs.co/downloads/") != null) {
        var scraper = subdl.my_subs_co.Scraper.init(allocator, client);
        defer scraper.deinit();
        return scraper.resolveDownloadPageUrl(allocator, download_url);
    }

    if (std.mem.indexOf(u8, download_url, "tvsubtitles.net/download-") != null) {
        var scraper = subdl.tvsubtitles_net.Scraper.init(allocator, client);
        defer scraper.deinit();
        return scraper.resolveDownloadPageUrl(allocator, download_url);
    }

    return allocator.dupe(u8, download_url);
}

fn fetchDownloadBytes(client: *std.http.Client, allocator: Allocator, url: []const u8) !common.HttpResponse {
    const primary = common.fetchBytes(client, allocator, url, .{
        .accept = "*/*",
        .allow_non_ok = true,
        .max_attempts = 2,
    }) catch |err| {
        if (try fetchBytesViaCurl(allocator, url, "*/*")) |fallback| {
            return fallback;
        }
        return err;
    };

    if (primary.status == .ok) return primary;
    const was_forbidden = primary.status == .forbidden;
    allocator.free(primary.body);

    if (was_forbidden) {
        if (cloudflareTargetForUrl(url)) |target| {
            if (try fetchBytesViaCurlWithCloudflareSession(allocator, url, target.domain, target.challenge_url, "*/*")) |with_cf| {
                return with_cf;
            }
        }
    }

    if (try fetchBytesViaCurl(allocator, url, "*/*")) |fallback| {
        return fallback;
    }
    return error.UnexpectedHttpStatus;
}

const CloudflareTarget = struct {
    domain: []const u8,
    challenge_url: []const u8,
};

fn cloudflareTargetForUrl(url: []const u8) ?CloudflareTarget {
    if (std.mem.indexOf(u8, url, "opensubtitles.com/") != null) {
        return .{
            .domain = "www.opensubtitles.com",
            .challenge_url = "https://www.opensubtitles.com/",
        };
    }

    if (std.mem.indexOf(u8, url, "://yifysubtitles.ch/") != null) {
        return .{
            .domain = "yifysubtitles.ch",
            .challenge_url = "https://yifysubtitles.ch/",
        };
    }
    return null;
}

fn fetchBytesViaCurl(allocator: Allocator, url: []const u8, accept: []const u8) !?common.HttpResponse {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    var owned_args: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned_args.items) |arg| allocator.free(arg);
        owned_args.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "--location",
        "--max-time",
        "90",
        "--compressed",
        "-A",
        common.default_user_agent,
    });

    const accept_header = try std.fmt.allocPrint(allocator, "Accept: {s}", .{accept});
    try owned_args.append(allocator, accept_header);
    try argv.appendSlice(allocator, &.{ "-H", accept_header });

    try argv.appendSlice(allocator, &.{ "-w", "\n%{http_code}", url });

    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 128 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    switch (run_result.term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    const sep = std.mem.lastIndexOfScalar(u8, run_result.stdout, '\n') orelse return null;
    const status_raw = std.mem.trim(u8, run_result.stdout[sep + 1 ..], " \t\r\n");
    const status_code = std.fmt.parseInt(u10, status_raw, 10) catch return null;
    const body = run_result.stdout[0..sep];

    return .{
        .status = @enumFromInt(status_code),
        .body = try allocator.dupe(u8, body),
    };
}

fn fetchBytesViaCurlWithCloudflareSession(
    allocator: Allocator,
    url: []const u8,
    domain: []const u8,
    challenge_url: []const u8,
    accept: []const u8,
) !?common.HttpResponse {
    var session = try cf.ensureDomainSession(allocator, .{
        .domain = domain,
        .challenge_url = challenge_url,
    });
    defer session.deinit(allocator);

    if (try fetchBytesViaCurlUsingSession(allocator, url, accept, session)) |first| {
        if (first.status != .forbidden) return first;
        allocator.free(first.body);
    } else {
        return null;
    }

    var refreshed = try cf.ensureDomainSession(allocator, .{
        .domain = domain,
        .challenge_url = challenge_url,
        .force_refresh = true,
    });
    defer refreshed.deinit(allocator);
    return fetchBytesViaCurlUsingSession(allocator, url, accept, refreshed);
}

fn fetchBytesViaCurlUsingSession(
    allocator: Allocator,
    url: []const u8,
    accept: []const u8,
    session: cf.Session,
) !?common.HttpResponse {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    var owned_args: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned_args.items) |arg| allocator.free(arg);
        owned_args.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "--location",
        "--max-time",
        "90",
        "--compressed",
        "-A",
        session.user_agent,
    });

    const cookie_header = try std.fmt.allocPrint(allocator, "Cookie: {s}", .{session.cookie_header});
    try owned_args.append(allocator, cookie_header);
    try argv.appendSlice(allocator, &.{ "-H", cookie_header });

    const accept_header = try std.fmt.allocPrint(allocator, "Accept: {s}", .{accept});
    try owned_args.append(allocator, accept_header);
    try argv.appendSlice(allocator, &.{ "-H", accept_header });

    try argv.appendSlice(allocator, &.{ "-w", "\n%{http_code}", url });

    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 128 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    switch (run_result.term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    const sep = std.mem.lastIndexOfScalar(u8, run_result.stdout, '\n') orelse return null;
    const status_raw = std.mem.trim(u8, run_result.stdout[sep + 1 ..], " \t\r\n");
    const status_code = std.fmt.parseInt(u10, status_raw, 10) catch return null;
    const body = run_result.stdout[0..sep];

    return .{
        .status = @enumFromInt(status_code),
        .body = try allocator.dupe(u8, body),
    };
}

const ArchiveKind = enum {
    none,
    zip,
    rar,
};

fn detectArchiveKind(file_name: []const u8, url: []const u8, body: []const u8) ArchiveKind {
    if (asciiEndsWithIgnoreCase(file_name, ".zip") or asciiEndsWithIgnoreCase(url, ".zip")) return .zip;
    if (asciiEndsWithIgnoreCase(file_name, ".rar") or asciiEndsWithIgnoreCase(url, ".rar")) return .rar;
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "PK\x03\x04")) return .zip;
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "PK\x05\x06")) return .zip;
    if (body.len >= 4 and std.mem.eql(u8, body[0..4], "PK\x07\x08")) return .zip;
    if (body.len >= 7 and std.mem.eql(u8, body[0..7], "Rar!\x1A\x07\x00")) return .rar;
    if (body.len >= 8 and std.mem.eql(u8, body[0..8], "Rar!\x1A\x07\x01\x00")) return .rar;
    return .none;
}

fn filenameStem(file_name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return file_name;
    if (dot == 0) return file_name;
    return file_name[0..dot];
}

fn extractArchive(allocator: Allocator, kind: ArchiveKind, archive_path: []const u8, extract_dir: []const u8) !void {
    if (try runExtractor(allocator, &.{ "bsdtar", "-xf", archive_path, "-C", extract_dir })) return;

    switch (kind) {
        .zip => {
            if (try runExtractor(allocator, &.{ "unzip", "-o", archive_path, "-d", extract_dir })) return;
            return error.ArchiveExtractionFailed;
        },
        .rar => {
            if (try runExtractor(allocator, &.{ "unrar", "x", "-o+", archive_path, extract_dir })) return;
            const seven_zip_out = try std.fmt.allocPrint(allocator, "-o{s}", .{extract_dir});
            defer allocator.free(seven_zip_out);
            if (try runExtractor(allocator, &.{ "7z", "x", "-y", seven_zip_out, archive_path })) return;
            return error.ArchiveExtractionFailed;
        },
        .none => return,
    }
}

fn runExtractor(allocator: Allocator, argv: []const []const u8) !bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 128 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn collectExtractedSubtitleFiles(allocator: Allocator, extract_dir: []const u8) ![]const []const u8 {
    var dir = try std.fs.cwd().openDir(extract_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isSubtitleArchiveEntry(entry.path)) continue;
        const full = try std.fs.path.join(allocator, &.{ extract_dir, entry.path });
        try out.append(allocator, full);
    }

    if (out.items.len == 0) return &.{};
    return try out.toOwnedSlice(allocator);
}

fn isSubtitleArchiveEntry(path: []const u8) bool {
    const exts = [_][]const u8{
        ".srt",
        ".str",
        ".sub",
        ".ass",
        ".ssa",
        ".vtt",
        ".smi",
        ".idx",
        ".txt",
    };
    for (exts) |ext| {
        if (asciiEndsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

fn toAbsoluteSubdlLink(allocator: Allocator, link: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://")) {
        return try allocator.dupe(u8, link);
    }
    return try std.fmt.allocPrint(allocator, "https://subdl.com{s}", .{link});
}

fn subtitleLabel(allocator: Allocator, language: ?[]const u8, filename: ?[]const u8, download_url: ?[]const u8) ![]const u8 {
    const base = if (language) |lang|
        if (filename) |name|
            try std.fmt.allocPrint(allocator, "{s} | {s}", .{ lang, name })
        else
            try allocator.dupe(u8, lang)
    else if (filename) |name|
        try allocator.dupe(u8, name)
    else
        try allocator.dupe(u8, "subtitle");

    if (download_url == null) return try std.fmt.allocPrint(allocator, "{s} [no direct download]", .{base});
    return base;
}

fn makeOpenSubtitlesRemoteToken(allocator: Allocator, remote_endpoint: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ opensubtitles_remote_prefix, remote_endpoint });
}

fn parseOpenSubtitlesRemoteToken(download_url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, download_url, opensubtitles_remote_prefix)) return null;
    const endpoint = download_url[opensubtitles_remote_prefix.len..];
    if (endpoint.len == 0) return null;
    return endpoint;
}

fn dupOptional(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
}

fn inferFilenameFromUrl(url: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const trimmed = url[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
    if (slash + 1 >= trimmed.len) return null;
    return trimmed[slash + 1 ..];
}

fn sanitizeFilename(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '-' or c == '_' or c == ' ' or c == '(' or c == ')';
        if (ok) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '_');
        }
    }

    const owned = try out.toOwnedSlice(allocator);
    errdefer allocator.free(owned);

    const trimmed = std.mem.trim(u8, owned, " .");
    if (trimmed.len == 0) return try allocator.dupe(u8, "subtitle.bin");
    if (trimmed.len == owned.len) return owned;

    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return duped;
}

fn nextAvailableOutputPath(allocator: Allocator, out_dir: []const u8, base_name: []const u8) ![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const file_name = if (attempt == 0)
            try allocator.dupe(u8, base_name)
        else
            try appendNumericSuffix(allocator, base_name, attempt);
        defer allocator.free(file_name);

        const full_path = try std.fs.path.join(allocator, &.{ out_dir, file_name });
        errdefer allocator.free(full_path);
        std.fs.cwd().access(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return full_path,
            else => return err,
        };
        allocator.free(full_path);
    }
}

fn appendNumericSuffix(allocator: Allocator, base_name: []const u8, suffix: usize) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, base_name, '.');
    if (dot) |idx| {
        if (idx == 0) return std.fmt.allocPrint(allocator, "{s}-{d}", .{ base_name, suffix });
        const stem = base_name[0..idx];
        const ext = base_name[idx..];
        return std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ stem, suffix, ext });
    }
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ base_name, suffix });
}

fn asciiEndsWithIgnoreCase(input: []const u8, suffix: []const u8) bool {
    if (suffix.len > input.len) return false;
    const tail = input[input.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn shouldRunTuiLiveSmoke(allocator: Allocator) bool {
    return common.shouldRunLiveTests(allocator) and common.liveTuiSuiteEnabled();
}

fn validateUtfNoReplacement(value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8Data;
    var i: usize = 0;
    while (i < value.len) {
        const seq_len_raw = std.unicode.utf8ByteSequenceLength(value[i]) catch return error.InvalidUtf8Data;
        const seq_len: usize = @intCast(seq_len_raw);
        if (i + seq_len > value.len) return error.InvalidUtf8Data;
        const cp = std.unicode.utf8Decode(value[i .. i + seq_len]) catch return error.InvalidUtf8Data;
        if (cp == 0xFFFD) return error.InvalidUtf8Data;
        i += seq_len;
    }
}

fn liveQueryForProvider(provider: Provider) []const u8 {
    return switch (provider) {
        .tvsubtitles_net => "Chernobyl",
        .subtitlecat_com => "The Matrix Revolutions 2003",
        else => "The Matrix",
    };
}

fn searchRefLogUrl(ref: SearchRef) []const u8 {
    return switch (ref) {
        .subdl_com => |item| item.link,
        .opensubtitles_com => |item| item.subtitles_list_url,
        .opensubtitles_org => |item| item.page_url,
        .moviesubtitles_org => |item| item.link,
        .moviesubtitlesrt_com => |item| item.page_url,
        .podnapisi_net => |item| item.subtitles_page_url,
        .yifysubtitles_ch => |item| item.movie_page_url,
        .subtitlecat_com => |item| item.details_url,
        .isubtitles_org => |item| item.details_url,
        .my_subs_co => |item| item.details_url,
        .subsource_net => |item| item.link,
        .tvsubtitles_net => |item| item.show_url,
    };
}

fn firstDownloadCandidate(subtitles: []const SubtitleChoice) ?usize {
    for (subtitles, 0..) |sub, idx| {
        const url = sub.download_url orelse continue;
        if (likelyArchiveSource(url, sub.filename)) return idx;
    }
    for (subtitles, 0..) |sub, idx| {
        if (sub.download_url != null) return idx;
    }
    return null;
}

fn iterDownloadCandidates(subtitles: []const SubtitleChoice, prefer_archive: bool, cursor: usize) ?usize {
    var seen: usize = 0;
    for (subtitles, 0..) |sub, idx| {
        const url = sub.download_url orelse continue;
        const is_archive_hint = likelyArchiveSource(url, sub.filename);
        if (prefer_archive and !is_archive_hint) continue;
        if (!prefer_archive and is_archive_hint) continue;
        if (seen == cursor) return idx;
        seen += 1;
    }
    return null;
}

fn likelyArchiveSource(url: []const u8, filename: ?[]const u8) bool {
    if (asciiEndsWithIgnoreCase(url, ".zip") or asciiEndsWithIgnoreCase(url, ".rar") or asciiEndsWithIgnoreCase(url, ".7z")) return true;
    if (std.mem.indexOf(u8, url, ".zip?") != null or std.mem.indexOf(u8, url, ".rar?") != null or std.mem.indexOf(u8, url, ".7z?") != null) return true;
    if (filename) |name| {
        if (asciiEndsWithIgnoreCase(name, ".zip") or asciiEndsWithIgnoreCase(name, ".rar") or asciiEndsWithIgnoreCase(name, ".7z")) return true;
    }
    return false;
}

fn prepareDownloadOutDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn cleanupDownloadOutDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

test "provider registry covers all subdl_js providers" {
    const expected = [_][]const u8{
        "subdl_com",
        "opensubtitles_com",
        "opensubtitles_org",
        "moviesubtitles_org",
        "moviesubtitlesrt_com",
        "podnapisi_net",
        "yifysubtitles_ch",
        "subtitlecat_com",
        "isubtitles_org",
        "my_subs_co",
        "subsource_net",
        "tvsubtitles_net",
    };

    const actual = providers();
    try std.testing.expectEqual(expected.len, actual.len);

    for (expected) |name| {
        var found = false;
        for (actual) |provider| {
            if (std.mem.eql(u8, providerName(provider), name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "parseProvider accepts dotted/hyphenated js provider names" {
    try std.testing.expect(parseProvider("subdl.com") == .subdl_com);
    try std.testing.expect(parseProvider("opensubtitles.com") == .opensubtitles_com);
    try std.testing.expect(parseProvider("opensubtitles.org") == .opensubtitles_org);
    try std.testing.expect(parseProvider("moviesubtitles.org") == .moviesubtitles_org);
    try std.testing.expect(parseProvider("moviesubtitlesrt.com") == .moviesubtitlesrt_com);
    try std.testing.expect(parseProvider("podnapisi.net") == .podnapisi_net);
    try std.testing.expect(parseProvider("yifysubtitles.ch") == .yifysubtitles_ch);
    try std.testing.expect(parseProvider("subtitlecat.com") == .subtitlecat_com);
    try std.testing.expect(parseProvider("isubtitles.org") == .isubtitles_org);
    try std.testing.expect(parseProvider("my-subs.co") == .my_subs_co);
    try std.testing.expect(parseProvider("subsource.net") == .subsource_net);
    try std.testing.expect(parseProvider("tvsubtitles.net") == .tvsubtitles_net);
}

test "opensubtitles remote token helpers" {
    const allocator = std.testing.allocator;
    const token = try makeOpenSubtitlesRemoteToken(allocator, "/en/subtitleserve/file/abc");
    defer allocator.free(token);

    const parsed = parseOpenSubtitlesRemoteToken(token) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/en/subtitleserve/file/abc", parsed);
    try std.testing.expect(parseOpenSubtitlesRemoteToken("https://example.com/file.zip") == null);
}

const ProviderSmokeState = struct {
    provider: Provider,
    err: ?anyerror = null,
};

fn runProviderSmokeWorker(state: *ProviderSmokeState) void {
    const start_ms = std.time.milliTimestamp();
    std.debug.print("[live][providers_app][{s}] worker_start state=0x{x}\n", .{
        providerName(state.provider),
        @intFromPtr(state),
    });
    defer {
        const elapsed_ms = std.time.milliTimestamp() - start_ms;
        if (state.err) |err| {
            std.debug.print("[live][providers_app][{s}] worker_end status=err err={s} elapsed_ms={d}\n", .{
                providerName(state.provider),
                @errorName(err),
                elapsed_ms,
            });
        } else {
            std.debug.print("[live][providers_app][{s}] worker_end status=ok elapsed_ms={d}\n", .{
                providerName(state.provider),
                elapsed_ms,
            });
        }
    }

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var phase = common.LivePhase.init(providerName(state.provider), "providers_app_tui_smoke");
    phase.start();
    runProviderTuiSmoke(allocator, &client, state.provider) catch |err| {
        phase.finish();
        state.err = err;
        return;
    };
    phase.finish();
}

fn runProviderTuiSmoke(allocator: std.mem.Allocator, client: *std.http.Client, provider: Provider) !void {
    const query = liveQueryForProvider(provider);
    std.debug.print("[live][providers_app][{s}] query={s}\n", .{ providerName(provider), query });

    std.debug.print("[live][providers_app][{s}] phase=search_start\n", .{providerName(provider)});
    var search_response = try search(allocator, client, provider, query);
    defer search_response.deinit();
    std.debug.print("[live][providers_app][{s}] phase=search_done items={d}\n", .{
        providerName(provider),
        search_response.items.len,
    });

    if (search_response.items.len == 0) return error.TestUnexpectedResult;
    std.debug.print("[live][providers_app][{s}] search_items={d}\n", .{ providerName(provider), search_response.items.len });

    const chosen_idx: usize = 0;
    const picked_search = search_response.items[chosen_idx];
    std.debug.print("[live][providers_app][{s}][search][0]\n", .{providerName(provider)});
    try validateUtfNoReplacement(picked_search.title);
    try validateUtfNoReplacement(picked_search.label);
    try common.livePrintField(allocator, "title", picked_search.title);
    try common.livePrintField(allocator, "label", picked_search.label);
    try common.livePrintField(allocator, "url", searchRefLogUrl(picked_search.ref));
    std.debug.print("[live][providers_app][{s}] chosen_search={d}\n", .{ providerName(provider), chosen_idx });
    try common.livePrintField(allocator, "chosen_search_title", picked_search.title);
    try common.livePrintField(allocator, "chosen_search_url", searchRefLogUrl(picked_search.ref));

    std.debug.print("[live][providers_app][{s}] phase=fetch_chosen_subtitles_start idx={d}\n", .{
        providerName(provider),
        chosen_idx,
    });
    var subtitles = try fetchSubtitles(allocator, client, picked_search.ref);
    defer subtitles.deinit();
    std.debug.print("[live][providers_app][{s}] phase=fetch_chosen_subtitles_done items={d}\n", .{
        providerName(provider),
        subtitles.items.len,
    });

    if (subtitles.items.len == 0) return error.TestUnexpectedResult;
    try validateUtfNoReplacement(subtitles.title);
    try common.livePrintField(allocator, "subtitles_title", subtitles.title);
    std.debug.print("[live][providers_app][{s}] subtitles_items={d}\n", .{ providerName(provider), subtitles.items.len });
    const download_idx = firstDownloadCandidate(subtitles.items) orelse return error.TestUnexpectedResult;
    const chosen_subtitle = subtitles.items[download_idx];
    std.debug.print("[live][providers_app][{s}][subtitle][{d}]\n", .{ providerName(provider), download_idx });
    try validateUtfNoReplacement(chosen_subtitle.label);
    try common.livePrintField(allocator, "label", chosen_subtitle.label);
    try common.livePrintOptionalField(allocator, "language", chosen_subtitle.language);
    try common.livePrintOptionalField(allocator, "filename", chosen_subtitle.filename);
    try common.livePrintOptionalField(allocator, "download_url", chosen_subtitle.download_url);
    if (chosen_subtitle.language) |v| try validateUtfNoReplacement(v);
    if (chosen_subtitle.filename) |v| try validateUtfNoReplacement(v);
    if (chosen_subtitle.download_url) |v| try validateUtfNoReplacement(v);

    const unique = std.time.nanoTimestamp();
    const out_dir = try std.fmt.allocPrint(allocator, ".zig-cache/live-downloads/{s}-{d}-{d}", .{ providerName(provider), chosen_idx, unique });
    defer allocator.free(out_dir);
    try prepareDownloadOutDir(out_dir);
    defer cleanupDownloadOutDir(out_dir);

    std.debug.print("[live][providers_app][{s}] download_attempt idx={d} mode=single\n", .{ providerName(provider), download_idx });
    var download = try downloadSubtitle(allocator, client, chosen_subtitle, out_dir);
    defer download.deinit(allocator);

    std.debug.print("[live][providers_app][{s}] download_ok idx={d} bytes={d}\n", .{ providerName(provider), download_idx, download.bytes_written });
    try common.livePrintField(allocator, "download_file_path", download.file_path);
    if (download.archive_path) |p| try common.livePrintField(allocator, "download_archive_path", p);
    for (download.extracted_files) |path| {
        try common.livePrintField(allocator, "extracted_file", path);
        try std.fs.cwd().access(path, .{});
    }

    if (!(download.bytes_written > 0 and download.extracted_files.len > 0)) return error.TestUnexpectedResult;
    std.debug.print("[live][providers_app][{s}] extraction_ok idx={d} files={d}\n", .{
        providerName(provider),
        download_idx,
        download.extracted_files.len,
    });
}

const tui_smoke_providers = [_]Provider{
    .subdl_com,
    .isubtitles_org,
    .moviesubtitles_org,
    .moviesubtitlesrt_com,
    .my_subs_co,
    .podnapisi_net,
    .subtitlecat_com,
    .subsource_net,
    .tvsubtitles_net,
};

fn runProvidersSmokeBatch(allocator: std.mem.Allocator, selected: []const Provider) !void {
    if (selected.len == 0) return error.SkipZigTest;
    std.debug.print("[live][providers_app] starting threaded smoke batch count={d}\n", .{selected.len});

    const states = try allocator.alloc(ProviderSmokeState, selected.len);
    defer allocator.free(states);
    for (selected, 0..) |provider, idx| {
        states[idx] = .{ .provider = provider };
    }

    const threads = try allocator.alloc(std.Thread, selected.len);
    defer allocator.free(threads);
    for (threads, states) |*thread, *state| {
        thread.* = try std.Thread.spawn(.{}, runProviderSmokeWorker, .{state});
    }
    for (threads) |thread| thread.join();
    std.debug.print("[live][providers_app] threaded smoke batch complete count={d}\n", .{selected.len});

    var first_err: ?anyerror = null;
    for (states) |state| {
        if (state.err) |err| {
            std.log.err("providers_app live smoke failed for {s}: {s}", .{
                providerName(state.provider),
                @errorName(err),
            });
            if (first_err == null) first_err = err;
        }
    }
    if (first_err) |err| return err;
}

fn isWholeSelection(filter: ?[]const u8) bool {
    const f = filter orelse return true;
    const trimmed = std.mem.trim(u8, f, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (std.mem.indexOfScalar(u8, trimmed, ',') != null) return true;
    if (std.mem.eql(u8, trimmed, "*")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return true;
    return false;
}

fn liveBatchEnabled() bool {
    const value = std.posix.getenv("SCRAPERS_LIVE_BATCH") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn isCaptchaProvider(provider: Provider) bool {
    return switch (provider) {
        .opensubtitles_com, .opensubtitles_org, .yifysubtitles_ch => true,
        else => false,
    };
}

fn shouldRunSingleProviderSmoke(provider: Provider) bool {
    if (!shouldRunTuiLiveSmoke(std.testing.allocator)) return false;
    if (isCaptchaProvider(provider) and !common.liveIncludeCaptchaEnabled()) return false;
    return common.providerMatchesLiveFilter(common.liveProviderFilter(), providerName(provider));
}

fn runSingleProviderSmokeTest(provider: Provider) !void {
    if (!shouldRunSingleProviderSmoke(provider)) return error.SkipZigTest;
    std.debug.print("[live][providers_app][{s}] test_start\n", .{providerName(provider)});
    defer std.debug.print("[live][providers_app][{s}] test_end\n", .{providerName(provider)});
    const selected = [_]Provider{provider};
    try runProvidersSmokeBatch(std.testing.allocator, &selected);
}

test "live providers_app tui-path smoke: non-captcha providers" {
    if (!shouldRunTuiLiveSmoke(std.testing.allocator)) return error.SkipZigTest;
    if (!liveBatchEnabled()) return error.SkipZigTest;
    std.debug.print("[live][providers_app] tui-path smoke enabled\n", .{});

    const filter = common.liveProviderFilter();
    const whole_selection = isWholeSelection(filter);
    if (filter) |f| {
        std.debug.print("[live][providers_app] filter={s} is_whole={any}\n", .{ f, whole_selection });
    } else {
        std.debug.print("[live][providers_app] filter=<null> is_whole={any}\n", .{whole_selection});
    }
    if (!whole_selection) return error.SkipZigTest;

    var selected: std.ArrayListUnmanaged(Provider) = .empty;
    defer selected.deinit(std.testing.allocator);
    for (tui_smoke_providers) |provider| {
        if (isCaptchaProvider(provider) and !common.liveIncludeCaptchaEnabled()) continue;
        if (!common.providerMatchesLiveFilter(filter, providerName(provider))) continue;
        try selected.append(std.testing.allocator, provider);
    }
    if (selected.items.len == 0) return error.SkipZigTest;
    try runProvidersSmokeBatch(std.testing.allocator, selected.items);
}

test "live providers_app tui-path smoke provider: subdl.com" {
    try runSingleProviderSmokeTest(.subdl_com);
}

test "live providers_app tui-path smoke provider: isubtitles.org" {
    try runSingleProviderSmokeTest(.isubtitles_org);
}

test "live providers_app tui-path smoke provider: moviesubtitles.org" {
    try runSingleProviderSmokeTest(.moviesubtitles_org);
}

test "live providers_app tui-path smoke provider: moviesubtitlesrt.com" {
    try runSingleProviderSmokeTest(.moviesubtitlesrt_com);
}

test "live providers_app tui-path smoke provider: my-subs.co" {
    try runSingleProviderSmokeTest(.my_subs_co);
}

test "live providers_app tui-path smoke provider: podnapisi.net" {
    try runSingleProviderSmokeTest(.podnapisi_net);
}

test "live providers_app tui-path smoke provider: subtitlecat.com" {
    try runSingleProviderSmokeTest(.subtitlecat_com);
}

test "live providers_app tui-path smoke provider: subsource.net" {
    try runSingleProviderSmokeTest(.subsource_net);
}

test "live providers_app tui-path smoke provider: tvsubtitles.net" {
    try runSingleProviderSmokeTest(.tvsubtitles_net);
}

test "live providers_app tui-path smoke provider: opensubtitles.com" {
    try runSingleProviderSmokeTest(.opensubtitles_com);
}

test "live providers_app tui-path smoke provider: opensubtitles.org" {
    try runSingleProviderSmokeTest(.opensubtitles_org);
}

test "live providers_app tui-path smoke provider: yifysubtitles.ch" {
    try runSingleProviderSmokeTest(.yifysubtitles_ch);
}
