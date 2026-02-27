const std = @import("std");
const subdl = @import("../scrapers/subdl.zig");
const runtime_alloc = @import("runtime_alloc");

const Allocator = std.mem.Allocator;
const common = subdl.common;
const cf = subdl.opensubtitles_com_cf;
const opensubtitles_remote_prefix = "oscom-remote:";
const subtitlecat_translate_prefix = "subtitlecat-translate:";

pub const DownloadPhase = enum(u8) {
    idle,
    resolving_url,
    fetching_source,
    downloading_file,
    translating,
    translating_fallback,
    writing_output,
    extracting_archive,
};

pub const DownloadProgress = struct {
    user_data: ?*anyopaque = null,
    on_phase: ?*const fn (user_data: ?*anyopaque, phase: DownloadPhase) void = null,
    on_units: ?*const fn (user_data: ?*anyopaque, done: usize, total: usize) void = null,
};

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

pub fn providerSupportsSearchPagination(provider: Provider) bool {
    return switch (provider) {
        .opensubtitles_org, .moviesubtitlesrt_com, .podnapisi_net, .isubtitles_org => true,
        else => false,
    };
}

pub fn providerSupportsSubtitlesPagination(provider: Provider) bool {
    return switch (provider) {
        .opensubtitles_org, .isubtitles_org => true,
        else => false,
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
        seasons: []const subdl.subsource_net.SeasonItem,
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
    page: usize = 1,
    has_prev_page: bool = false,
    has_next_page: bool = false,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubdlSeasonChoice = struct {
    label: []const u8,
    season_slug: []const u8,
    season_name: []const u8,
};

pub const SubdlSeasonsResponse = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    items: []const SubdlSeasonChoice,

    pub fn deinit(self: *SubdlSeasonsResponse) void {
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
    page: usize = 1,
    has_prev_page: bool = false,
    has_next_page: bool = false,

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
            var response = try scraper.search(query);
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
                .auto_cloudflare_session = true,
            });
            defer response.deinit();

            for (response.items) |item| {
                const title = try a.dupe(u8, item.title);
                const link = try a.dupe(u8, item.link);
                const media_type = try a.dupe(u8, item.media_type);
                var seasons: std.ArrayListUnmanaged(subdl.subsource_net.SeasonItem) = .empty;
                for (item.seasons) |season| {
                    try seasons.append(a, .{
                        .season = season.season,
                        .link = try a.dupe(u8, season.link),
                    });
                }
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
                        .seasons = try seasons.toOwnedSlice(a),
                    } },
                });
            }
        },
        .tvsubtitles_net => {
            var scraper = subdl.tvsubtitles_net.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.search(query);
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

pub fn searchPage(allocator: Allocator, client: *std.http.Client, provider: Provider, query: []const u8, page: usize) !SearchResponse {
    const requested_page = if (page == 0) 1 else page;
    if (!providerSupportsSearchPagination(provider)) {
        if (requested_page == 1) {
            var first = try search(allocator, client, provider, query);
            first.page = 1;
            first.has_prev_page = false;
            first.has_next_page = false;
            return first;
        }
        return emptySearchPage(allocator, provider, requested_page);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SearchChoice) = .empty;
    var has_next_page = false;

    switch (provider) {
        .opensubtitles_org => {
            var scraper = subdl.opensubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.searchWithOptions(query, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer response.deinit();
            has_next_page = response.has_next_page;

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
        .moviesubtitlesrt_com => {
            var scraper = subdl.moviesubtitlesrt_com.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.searchWithOptions(query, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer response.deinit();
            has_next_page = response.has_next_page;

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
            var response = try scraper.searchWithOptions(query, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer response.deinit();
            has_next_page = response.has_next_page;

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
        .isubtitles_org => {
            var scraper = subdl.isubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var response = try scraper.searchWithOptions(query, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer response.deinit();
            has_next_page = response.has_next_page;

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
        else => return error.UnsupportedProvider,
    }

    return .{
        .arena = arena,
        .provider = provider,
        .items = try out.toOwnedSlice(a),
        .page = requested_page,
        .has_prev_page = requested_page > 1,
        .has_next_page = has_next_page,
    };
}

pub fn fetchSubdlSeasons(allocator: Allocator, client: *std.http.Client, ref: SearchRef) !SubdlSeasonsResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SubdlSeasonChoice) = .empty;
    var title: []const u8 = "";

    switch (ref) {
        .subdl_com => |item| {
            if (item.media_type != .tv) return error.UnexpectedTitleType;
            var scraper = subdl.subdl_com.Scraper.init(a, client);
            defer scraper.deinit();

            var seasons = try scraper.fetchTvSeasonsByLink(item.link);
            defer seasons.deinit();
            title = try a.dupe(u8, seasons.tv.name);

            for (seasons.seasons) |season| {
                const season_slug = try a.dupe(u8, season.number);
                const season_name = try a.dupe(u8, season.name);
                const label = if (season.name.len == 0 or std.mem.eql(u8, season.name, season.number))
                    try a.dupe(u8, season.number)
                else
                    try std.fmt.allocPrint(a, "{s} ({s})", .{ season.name, season.number });
                try out.append(a, .{
                    .label = label,
                    .season_slug = season_slug,
                    .season_name = season_name,
                });
            }
        },
        else => return error.UnsupportedProvider,
    }

    return .{
        .arena = arena,
        .title = title,
        .items = try out.toOwnedSlice(a),
    };
}

pub fn fetchSubdlSeasonSubtitles(allocator: Allocator, client: *std.http.Client, ref: SearchRef, season_slug: []const u8) !SubtitlesResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SubtitleChoice) = .empty;
    var title: []const u8 = "";

    switch (ref) {
        .subdl_com => |item| {
            if (item.media_type != .tv) return error.UnexpectedTitleType;
            var scraper = subdl.subdl_com.Scraper.init(a, client);
            defer scraper.deinit();

            var season_data = try scraper.fetchTvSeasonByLink(item.link, season_slug);
            defer season_data.deinit();
            title = try std.fmt.allocPrint(a, "{s} | {s}", .{ season_data.tv.name, season_slug });

            for (season_data.languages) |group| {
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
        else => return error.UnsupportedProvider,
    }

    return .{
        .arena = arena,
        .provider = .subdl_com,
        .title = title,
        .items = try out.toOwnedSlice(a),
    };
}

pub fn fetchSubdlSeasonSubtitlesPage(
    allocator: Allocator,
    client: *std.http.Client,
    ref: SearchRef,
    season_slug: []const u8,
    page: usize,
) !SubtitlesResponse {
    const requested_page = if (page == 0) 1 else page;
    if (requested_page == 1) {
        var first = try fetchSubdlSeasonSubtitles(allocator, client, ref, season_slug);
        first.page = 1;
        first.has_prev_page = false;
        first.has_next_page = false;
        return first;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    return .{
        .arena = arena,
        .provider = .subdl_com,
        .title = titleFromRef(ref),
        .items = &.{},
        .page = requested_page,
        .has_prev_page = true,
        .has_next_page = false,
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
                var resolved_download_url: ?[]const u8 = try dupOptional(a, subtitle.download_url);
                if (resolved_download_url == null and subtitle.mode == .translated) {
                    const source_url = subtitle.source_url orelse if (subtitle.translate_spec) |spec|
                        spec.source_url
                    else
                        null;
                    if (source_url) |source| {
                        const target_lang = subtitle.language_code orelse subtitle.language_label orelse "en";
                        resolved_download_url = try makeSubtitlecatTranslateToken(a, source, target_lang, subtitle.filename);
                    }
                }

                var label = try subtitleLabel(a, subtitle.language_code orelse subtitle.language_label, subtitle.filename, resolved_download_url);
                if (subtitle.mode == .translated and resolved_download_url != null) {
                    label = try std.fmt.allocPrint(a, "{s} [translate]", .{label});
                }
                try out.append(a, .{
                    .label = label,
                    .language = try dupOptional(a, subtitle.language_code orelse subtitle.language_label),
                    .filename = try a.dupe(u8, subtitle.filename),
                    .download_url = resolved_download_url,
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
                .seasons = item.seasons,
            };
            var subtitles = try scraper.fetchSubtitlesBySearchItemWithOptions(fake_item, .{
                .include_seasons = true,
                .max_pages = 1,
                .resolve_download_tokens = true,
                .auto_cloudflare_session = true,
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

pub fn fetchSubtitlesPage(allocator: Allocator, client: *std.http.Client, ref: SearchRef, page: usize) !SubtitlesResponse {
    const requested_page = if (page == 0) 1 else page;
    const provider = std.meta.activeTag(ref);
    if (!providerSupportsSubtitlesPagination(provider)) {
        if (requested_page == 1) {
            var first = try fetchSubtitles(allocator, client, ref);
            first.page = 1;
            first.has_prev_page = false;
            first.has_next_page = false;
            return first;
        }
        return emptySubtitlesPage(allocator, ref, requested_page);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayListUnmanaged(SubtitleChoice) = .empty;
    var title = titleFromRef(ref);
    var has_next_page = false;

    switch (ref) {
        .opensubtitles_org => |item| {
            var scraper = subdl.opensubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByMoviePageWithOptions(item.page_url, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer subtitles.deinit();
            has_next_page = subtitles.has_next_page;
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
        .isubtitles_org => |item| {
            var scraper = subdl.isubtitles_org.Scraper.init(a, client);
            defer scraper.deinit();
            var subtitles = try scraper.fetchSubtitlesByMovieLinkWithOptions(item.details_url, .{
                .page_start = requested_page,
                .max_pages = 1,
            });
            defer subtitles.deinit();
            has_next_page = subtitles.has_next_page;
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
        else => return error.UnsupportedProvider,
    }

    return .{
        .arena = arena,
        .provider = provider,
        .title = title,
        .items = try out.toOwnedSlice(a),
        .page = requested_page,
        .has_prev_page = requested_page > 1,
        .has_next_page = has_next_page,
    };
}

fn emptySearchPage(allocator: Allocator, provider: Provider, page: usize) !SearchResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    return .{
        .arena = arena,
        .provider = provider,
        .items = &.{},
        .page = if (page == 0) 1 else page,
        .has_prev_page = page > 1,
        .has_next_page = false,
    };
}

fn emptySubtitlesPage(allocator: Allocator, ref: SearchRef, page: usize) !SubtitlesResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const p = if (page == 0) 1 else page;
    return .{
        .arena = arena,
        .provider = std.meta.activeTag(ref),
        .title = titleFromRef(ref),
        .items = &.{},
        .page = p,
        .has_prev_page = p > 1,
        .has_next_page = false,
    };
}

fn titleFromRef(ref: SearchRef) []const u8 {
    return switch (ref) {
        .subdl_com => |item| item.title,
        .opensubtitles_com => |item| item.title,
        .opensubtitles_org => |item| item.title,
        .moviesubtitles_org => |item| item.title,
        .moviesubtitlesrt_com => |item| item.title,
        .podnapisi_net => |item| item.title,
        .yifysubtitles_ch => |item| item.title,
        .subtitlecat_com => |item| item.title,
        .isubtitles_org => |item| item.title,
        .my_subs_co => |item| item.title,
        .subsource_net => |item| item.title,
        .tvsubtitles_net => |item| item.title,
    };
}

pub fn downloadSubtitle(allocator: Allocator, client: *std.http.Client, subtitle: SubtitleChoice, out_dir: []const u8) !DownloadResult {
    return downloadSubtitleWithProgress(allocator, client, subtitle, out_dir, null);
}

pub fn downloadSubtitleWithProgress(
    allocator: Allocator,
    client: *std.http.Client,
    subtitle: SubtitleChoice,
    out_dir: []const u8,
    progress: ?*const DownloadProgress,
) !DownloadResult {
    const source_url = subtitle.download_url orelse return error.MissingField;

    if (try parseSubtitlecatTranslateToken(allocator, source_url)) |token| {
        defer token.deinit(allocator);
        return downloadSubtitlecatTranslated(allocator, client, subtitle, out_dir, source_url, token, progress);
    }

    emitDownloadPhase(progress, .resolving_url);
    const url = try resolveDownloadUrlIfNeeded(allocator, client, source_url);
    defer allocator.free(url);

    emitDownloadPhase(progress, .downloading_file);
    const response = try fetchDownloadBytes(client, allocator, url);
    defer allocator.free(response.body);
    if (response.status != .ok) return error.UnexpectedHttpStatus;

    const preferred_name = subtitle.filename orelse inferFilenameFromUrl(url) orelse "subtitle";
    const archive_kind = detectArchiveKind(preferred_name, url, response.body);
    const raw_name = try ensureFilenameExtension(allocator, preferred_name, url, archive_kind, ".srt");
    defer allocator.free(raw_name);

    emitDownloadPhase(progress, .writing_output);
    try std.fs.cwd().makePath(out_dir);
    const safe_name = try sanitizeFilename(allocator, raw_name);
    defer allocator.free(safe_name);

    const output_path = try nextAvailableOutputPath(allocator, out_dir, safe_name);
    errdefer allocator.free(output_path);
    var file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(response.body);

    if (archive_kind == .none) {
        return .{
            .file_path = output_path,
            .bytes_written = response.body.len,
            .source_url = source_url,
        };
    }

    emitDownloadPhase(progress, .extracting_archive);
    const archive_copy = try allocator.dupe(u8, output_path);
    errdefer allocator.free(archive_copy);

    return .{
        .file_path = output_path,
        .archive_path = archive_copy,
        .bytes_written = response.body.len,
        .source_url = source_url,
    };
}

fn emitDownloadPhase(progress: ?*const DownloadProgress, phase: DownloadPhase) void {
    const p = progress orelse return;
    if (p.on_phase) |f| f(p.user_data, phase);
}

fn emitDownloadUnits(progress: ?*const DownloadProgress, done: usize, total: usize) void {
    const p = progress orelse return;
    if (p.on_units) |f| f(p.user_data, done, total);
}

const SubtitlecatTranslateToken = struct {
    source_url: []u8,
    target_lang: []u8,
    filename: []u8,

    fn deinit(self: SubtitlecatTranslateToken, allocator: Allocator) void {
        allocator.free(self.source_url);
        allocator.free(self.target_lang);
        allocator.free(self.filename);
    }
};

fn makeSubtitlecatTranslateToken(
    allocator: Allocator,
    source_url: []const u8,
    target_lang: []const u8,
    filename: []const u8,
) ![]const u8 {
    const source_encoded = try common.encodeUriComponent(allocator, source_url);
    defer allocator.free(source_encoded);
    const target_encoded = try common.encodeUriComponent(allocator, target_lang);
    defer allocator.free(target_encoded);
    const name_encoded = try common.encodeUriComponent(allocator, filename);
    defer allocator.free(name_encoded);

    return try std.fmt.allocPrint(
        allocator,
        "{s}source={s}&tl={s}&name={s}",
        .{ subtitlecat_translate_prefix, source_encoded, target_encoded, name_encoded },
    );
}

fn parseSubtitlecatTranslateToken(allocator: Allocator, download_url: []const u8) !?SubtitlecatTranslateToken {
    if (!std.mem.startsWith(u8, download_url, subtitlecat_translate_prefix)) return null;

    const payload = download_url[subtitlecat_translate_prefix.len..];
    if (payload.len == 0) return error.InvalidDownloadUrl;

    var source_url: ?[]u8 = null;
    errdefer if (source_url) |v| allocator.free(v);
    var target_lang: ?[]u8 = null;
    errdefer if (target_lang) |v| allocator.free(v);
    var filename: ?[]u8 = null;
    errdefer if (filename) |v| allocator.free(v);

    var it = std.mem.splitScalar(u8, payload, '&');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        const value = entry[eq + 1 ..];
        const decoded = try decodeUriComponent(allocator, value);
        errdefer allocator.free(decoded);

        if (std.mem.eql(u8, key, "source")) {
            if (source_url) |old| allocator.free(old);
            source_url = decoded;
        } else if (std.mem.eql(u8, key, "tl")) {
            if (target_lang) |old| allocator.free(old);
            target_lang = decoded;
        } else if (std.mem.eql(u8, key, "name")) {
            if (filename) |old| allocator.free(old);
            filename = decoded;
        } else {
            allocator.free(decoded);
        }
    }

    if (source_url == null) return error.InvalidDownloadUrl;
    if (target_lang == null) target_lang = try allocator.dupe(u8, "");
    if (filename == null) filename = try allocator.dupe(u8, "translated.srt");

    return .{
        .source_url = source_url.?,
        .target_lang = target_lang.?,
        .filename = filename.?,
    };
}

fn decodeUriComponent(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        if (ch == '+') {
            try out.append(allocator, ' ');
            continue;
        }
        if (ch == '%') {
            if (i + 2 >= value.len) return error.InvalidField;
            const hi = try fromHexDigit(value[i + 1]);
            const lo = try fromHexDigit(value[i + 2]);
            try out.append(allocator, @as(u8, (hi << 4) | lo));
            i += 2;
            continue;
        }
        try out.append(allocator, ch);
    }

    return try out.toOwnedSlice(allocator);
}

fn fromHexDigit(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => 10 + ch - 'a',
        'A'...'F' => 10 + ch - 'A',
        else => error.InvalidField,
    };
}

const SubtitlecatBatch = struct {
    text: []u8,
    indices: []usize,
};

fn downloadSubtitlecatTranslated(
    allocator: Allocator,
    client: *std.http.Client,
    subtitle: SubtitleChoice,
    out_dir: []const u8,
    source_token: []const u8,
    token: SubtitlecatTranslateToken,
    progress: ?*const DownloadProgress,
) !DownloadResult {
    emitDownloadPhase(progress, .fetching_source);
    const source_response = try common.fetchBytes(client, allocator, token.source_url, .{
        .accept = "text/plain,*/*",
        .allow_non_ok = true,
        .max_attempts = 2,
    });
    defer allocator.free(source_response.body);
    if (source_response.status != .ok) return error.UnexpectedHttpStatus;

    const target_lang = languageToGoogleCode(token.target_lang) orelse "";

    emitDownloadPhase(progress, .translating);
    const translated_text = if (target_lang.len > 0)
        translateSubtitlecatSrt(allocator, client, source_response.body, target_lang, progress) catch
            try allocator.dupe(u8, source_response.body)
    else
        try allocator.dupe(u8, source_response.body);
    defer allocator.free(translated_text);

    emitDownloadPhase(progress, .writing_output);
    try std.fs.cwd().makePath(out_dir);
    const preferred_name = if (subtitle.filename) |name| name else token.filename;
    const raw_name = try ensureFilenameExtension(allocator, preferred_name, token.source_url, .none, ".srt");
    defer allocator.free(raw_name);
    const safe_name = try sanitizeFilename(allocator, raw_name);
    defer allocator.free(safe_name);

    const output_path = try nextAvailableOutputPath(allocator, out_dir, safe_name);
    errdefer allocator.free(output_path);
    var file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(translated_text);

    return .{
        .file_path = output_path,
        .bytes_written = translated_text.len,
        .source_url = source_token,
    };
}

fn languageToGoogleCode(input: []const u8) ?[]const u8 {
    const trimmed = common.trimAscii(input);
    if (trimmed.len == 0) return null;

    if (common.normalizeLanguageCode(trimmed)) |normalized| {
        if (std.mem.eql(u8, normalized, "pt-br")) return "pt";
        if (std.mem.eql(u8, normalized, "zh-tw")) return "zh-TW";
        return normalized;
    }

    var valid = true;
    for (trimmed) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            ch == '-' or
            ch == '_';
        if (!ok) {
            valid = false;
            break;
        }
    }
    if (valid and trimmed.len <= 16) return trimmed;
    return null;
}

fn translateSubtitlecatSrt(
    allocator: Allocator,
    client: *std.http.Client,
    source: []const u8,
    target_lang: []const u8,
    progress: ?*const DownloadProgress,
) ![]u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, source, '\n');
    while (line_it.next()) |line| {
        try lines.append(allocator, line);
    }

    var translated: std.ArrayListUnmanaged(?[]u8) = .empty;
    defer {
        for (translated.items) |entry| {
            if (entry) |line| allocator.free(line);
        }
        translated.deinit(allocator);
    }
    try translated.resize(allocator, lines.items.len);
    @memset(translated.items, null);

    const total_units = countTranslatableLines(lines.items);
    emitDownloadUnits(progress, 0, total_units);
    var done_units: usize = 0;

    var batch_text: std.ArrayListUnmanaged(u8) = .empty;
    defer batch_text.deinit(allocator);
    var batch_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer batch_indices.deinit(allocator);
    const batch_limit: usize = 500;

    for (lines.items, 0..) |line, idx| {
        if (!shouldTranslateSubtitleLine(line)) {
            translated.items[idx] = try allocator.dupe(u8, line);
            continue;
        }

        const sanitized = try sanitizeSubtitlecatTranslateLine(allocator, line);
        defer allocator.free(sanitized);

        const extra_len = sanitized.len + @as(usize, if (batch_indices.items.len > 0) 1 else 0);
        if (batch_indices.items.len > 0 and batch_text.items.len + extra_len > batch_limit) {
            const batch = SubtitlecatBatch{
                .text = try batch_text.toOwnedSlice(allocator),
                .indices = try batch_indices.toOwnedSlice(allocator),
            };
            defer allocator.free(batch.text);
            defer allocator.free(batch.indices);
            batch_text.clearRetainingCapacity();
            batch_indices.clearRetainingCapacity();
            try applySubtitlecatBatch(allocator, client, lines.items, translated.items, batch, target_lang, progress, &done_units, total_units);
        }

        if (batch_indices.items.len > 0) try batch_text.append(allocator, '\n');
        try batch_text.appendSlice(allocator, sanitized);
        try batch_indices.append(allocator, idx);
    }

    if (batch_indices.items.len > 0) {
        const batch = SubtitlecatBatch{
            .text = try batch_text.toOwnedSlice(allocator),
            .indices = try batch_indices.toOwnedSlice(allocator),
        };
        defer allocator.free(batch.text);
        defer allocator.free(batch.indices);
        try applySubtitlecatBatch(allocator, client, lines.items, translated.items, batch, target_lang, progress, &done_units, total_units);
    }

    emitDownloadUnits(progress, total_units, total_units);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    for (translated.items, 0..) |entry, idx| {
        const text = if (entry) |line| line else lines.items[idx];
        try output.appendSlice(allocator, text);
        if (idx + 1 < translated.items.len) try output.append(allocator, '\n');
    }

    return try output.toOwnedSlice(allocator);
}

fn applySubtitlecatBatch(
    allocator: Allocator,
    client: *std.http.Client,
    source_lines: []const []const u8,
    translated_lines: []?[]u8,
    batch: SubtitlecatBatch,
    target_lang: []const u8,
    progress: ?*const DownloadProgress,
    done_units: *usize,
    total_units: usize,
) !void {
    const translated_batch = translateViaGoogle(allocator, client, batch.text, target_lang) catch null;
    if (translated_batch) |batch_text| {
        defer allocator.free(batch_text);
        var out_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer out_lines.deinit(allocator);

        var line_it = std.mem.splitScalar(u8, batch_text, '\n');
        while (line_it.next()) |line| try out_lines.append(allocator, line);

        if (out_lines.items.len == batch.indices.len) {
            for (batch.indices, 0..) |line_idx, i| {
                translated_lines[line_idx] = try allocator.dupe(u8, out_lines.items[i]);
            }
            done_units.* += batch.indices.len;
            emitDownloadUnits(progress, done_units.*, total_units);
            return;
        }
    }

    emitDownloadPhase(progress, .translating_fallback);
    for (batch.indices) |line_idx| {
        const source_line = source_lines[line_idx];
        const translated_line = translateViaGoogle(allocator, client, source_line, target_lang) catch
            try allocator.dupe(u8, source_line);
        translated_lines[line_idx] = translated_line;
        done_units.* += 1;
        emitDownloadUnits(progress, done_units.*, total_units);
    }
    emitDownloadPhase(progress, .translating);
}

fn countTranslatableLines(lines: []const []const u8) usize {
    var count: usize = 0;
    for (lines) |line| {
        if (shouldTranslateSubtitleLine(line)) count += 1;
    }
    return count;
}

fn shouldTranslateSubtitleLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;

    var numeric = true;
    for (trimmed) |ch| {
        if (ch < '0' or ch > '9') {
            numeric = false;
            break;
        }
    }
    if (numeric) return false;

    if (std.mem.indexOf(u8, trimmed, "-->") != null) return false;
    if (std.mem.eql(u8, trimmed, "WEBVTT")) return false;
    return true;
}

fn sanitizeSubtitlecatTranslateLine(allocator: Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        if (asciiStartsWithIgnoreCase(line[i..], "<font")) {
            if (std.mem.indexOfScalarPos(u8, line, i, '>')) |end_idx| {
                i = end_idx + 1;
                continue;
            }
        }
        if (asciiStartsWithIgnoreCase(line[i..], "</font>")) {
            i += "</font>".len;
            continue;
        }
        if (line[i] == '&') {
            try out.appendSlice(allocator, "and");
        } else {
            try out.append(allocator, line[i]);
        }
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn asciiStartsWithIgnoreCase(input: []const u8, prefix: []const u8) bool {
    if (prefix.len > input.len) return false;
    for (input[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn translateViaGoogle(
    allocator: Allocator,
    client: *std.http.Client,
    text: []const u8,
    target_lang: []const u8,
) ![]u8 {
    const encoded_q = try common.encodeUriComponent(allocator, text);
    defer allocator.free(encoded_q);
    const encoded_tl = try common.encodeUriComponent(allocator, target_lang);
    defer allocator.free(encoded_tl);

    const url = try std.fmt.allocPrint(
        allocator,
        "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl={s}&dt=t&q={s}",
        .{ encoded_tl, encoded_q },
    );
    defer allocator.free(url);

    const response = try common.fetchBytes(client, allocator, url, .{
        .accept = "application/json,text/plain,*/*",
        .allow_non_ok = true,
        .max_attempts = 2,
    });
    defer allocator.free(response.body);
    if (response.status != .ok) return error.UnexpectedHttpStatus;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    return googleTranslateResultToString(allocator, parsed.value);
}

fn googleTranslateResultToString(allocator: Allocator, value: std.json.Value) ![]u8 {
    if (value != .array) return error.InvalidFieldType;
    const root_items = value.array.items;
    if (root_items.len == 0) return error.InvalidField;
    if (root_items[0] != .array) return error.InvalidFieldType;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (root_items[0].array.items) |part| {
        if (part != .array) continue;
        if (part.array.items.len == 0) continue;
        if (part.array.items[0] != .string) continue;
        try out.appendSlice(allocator, part.array.items[0].string);
    }

    return try out.toOwnedSlice(allocator);
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
    const yify_referer = yifyRefererForUrl(url);
    const yify_headers = if (yify_referer) |referer|
        &[_]std.http.Header{.{ .name = "referer", .value = referer }}
    else
        &[_]std.http.Header{};

    const primary = try common.fetchBytes(client, allocator, url, .{
        .accept = "*/*",
        .extra_headers = yify_headers,
        .allow_non_ok = true,
        .max_attempts = 2,
    });

    if (primary.status == .ok) return primary;
    const was_forbidden = primary.status == .forbidden;
    allocator.free(primary.body);

    if (was_forbidden) {
        if (cloudflareTargetForUrl(url)) |target| {
            const with_cf = try fetchBytesWithCloudflareSession(client, allocator, url, target.domain, target.challenge_url, "*/*", yify_referer);
            if (with_cf.status == .ok) return with_cf;
            allocator.free(with_cf.body);
        }
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

    return null;
}

fn yifyRefererForUrl(url: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, url, "://yifysubtitles.ch/") != null) {
        return "https://yifysubtitles.ch/";
    }
    return null;
}

fn fetchBytesWithCloudflareSession(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    domain: []const u8,
    challenge_url: []const u8,
    accept: []const u8,
    referer: ?[]const u8,
) !common.HttpResponse {
    var session = try cf.ensureDomainSession(allocator, .{
        .domain = domain,
        .challenge_url = challenge_url,
    });
    defer session.deinit(allocator);

    const first = try fetchBytesUsingSession(client, allocator, url, accept, referer, session);
    if (first.status != .forbidden) return first;
    allocator.free(first.body);

    var refreshed = try cf.ensureDomainSession(allocator, .{
        .domain = domain,
        .challenge_url = challenge_url,
        .force_refresh = true,
    });
    defer refreshed.deinit(allocator);
    return fetchBytesUsingSession(client, allocator, url, accept, referer, refreshed);
}

fn fetchBytesUsingSession(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    accept: []const u8,
    referer: ?[]const u8,
    session: cf.Session,
) !common.HttpResponse {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "cookie", .value = session.cookie_header });
    try headers.append(allocator, .{ .name = "user-agent", .value = session.user_agent });
    if (referer) |value| {
        try headers.append(allocator, .{ .name = "referer", .value = value });
    }

    return common.fetchBytes(client, allocator, url, .{
        .accept = accept,
        .extra_headers = headers.items,
        .allow_non_ok = true,
        .max_attempts = 2,
    });
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

fn toAbsoluteSubdlLink(allocator: Allocator, link: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://")) {
        return try allocator.dupe(u8, link);
    }
    return try std.fmt.allocPrint(allocator, "https://subdl.com{s}", .{link});
}

fn subtitleLabel(allocator: Allocator, language: ?[]const u8, filename: ?[]const u8, download_url: ?[]const u8) ![]const u8 {
    const language_trimmed = nonEmptyTrimmed(language);
    const filename_trimmed = nonEmptyTrimmed(filename) orelse "Without release";
    if (download_url == null) {
        if (language_trimmed) |lang| {
            return try std.fmt.allocPrint(allocator, "{s} | {s} [no direct download]", .{ lang, filename_trimmed });
        }
        return try std.fmt.allocPrint(allocator, "{s} [no direct download]", .{filename_trimmed});
    }

    if (language_trimmed) |lang| {
        return try std.fmt.allocPrint(allocator, "{s} | {s}", .{ lang, filename_trimmed });
    }
    return try allocator.dupe(u8, filename_trimmed);
}

fn nonEmptyTrimmed(value: ?[]const u8) ?[]const u8 {
    if (value) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
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

fn ensureFilenameExtension(
    allocator: Allocator,
    preferred_name: []const u8,
    source_url: []const u8,
    archive_kind: ArchiveKind,
    fallback_ext: []const u8,
) ![]u8 {
    if (filenameExtension(preferred_name) != null) return try allocator.dupe(u8, preferred_name);

    if (inferFilenameFromUrl(source_url)) |url_name| {
        if (filenameExtension(url_name)) |ext| {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ preferred_name, ext });
        }
    }

    const ext = switch (archive_kind) {
        .zip => ".zip",
        .rar => ".rar",
        .none => fallback_ext,
    };
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ preferred_name, ext });
}

fn filenameExtension(name: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(name);
    if (ext.len <= 1) return null;
    return ext;
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

fn isSubtitlecatTranslateTokenUrl(download_url: ?[]const u8) bool {
    const url = download_url orelse return false;
    return std.mem.startsWith(u8, url, subtitlecat_translate_prefix);
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

test "provider pagination support flags" {
    try std.testing.expect(providerSupportsSearchPagination(.opensubtitles_org));
    try std.testing.expect(providerSupportsSearchPagination(.moviesubtitlesrt_com));
    try std.testing.expect(providerSupportsSearchPagination(.podnapisi_net));
    try std.testing.expect(providerSupportsSearchPagination(.isubtitles_org));
    try std.testing.expect(!providerSupportsSearchPagination(.my_subs_co));
    try std.testing.expect(!providerSupportsSearchPagination(.tvsubtitles_net));
    try std.testing.expect(!providerSupportsSearchPagination(.subdl_com));

    try std.testing.expect(providerSupportsSubtitlesPagination(.opensubtitles_org));
    try std.testing.expect(providerSupportsSubtitlesPagination(.isubtitles_org));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.my_subs_co));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.tvsubtitles_net));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.moviesubtitlesrt_com));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.subdl_com));
    try std.testing.expect(!providerSupportsSubtitlesPagination(.opensubtitles_com));
}

test "searchPage returns empty page for unsupported provider page > 1" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    const unsupported_providers = [_]Provider{ .subdl_com, .my_subs_co, .tvsubtitles_net };
    for (unsupported_providers) |provider| {
        var page = try searchPage(std.testing.allocator, &client, provider, "matrix", 2);
        defer page.deinit();

        try std.testing.expectEqual(@as(usize, 0), page.items.len);
        try std.testing.expectEqual(@as(usize, 2), page.page);
        try std.testing.expect(page.has_prev_page);
        try std.testing.expect(!page.has_next_page);
    }
}

test "fetchSubtitlesPage returns empty page for unsupported provider page > 1" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    const ref: SearchRef = .{ .subdl_com = .{
        .title = "The Matrix",
        .media_type = .movie,
        .link = "https://subdl.com/subtitle/the-matrix",
    } };

    const refs = [_]SearchRef{
        ref,
        .{ .my_subs_co = .{
            .title = "The Matrix",
            .details_url = "https://my-subs.co/movie/the-matrix",
            .media_kind = .movie,
        } },
        .{ .tvsubtitles_net = .{
            .title = "Chernobyl",
            .show_url = "https://www.tvsubtitles.net/tvshow-1234-1.html",
        } },
    };

    for (refs) |item_ref| {
        var page = try fetchSubtitlesPage(std.testing.allocator, &client, item_ref, 2);
        defer page.deinit();

        try std.testing.expectEqual(@as(usize, 0), page.items.len);
        try std.testing.expectEqual(@as(usize, 2), page.page);
        try std.testing.expect(page.has_prev_page);
        try std.testing.expect(!page.has_next_page);
        try std.testing.expectEqualStrings(titleFromRef(item_ref), page.title);
    }
}

test "opensubtitles remote token helpers" {
    const allocator = std.testing.allocator;
    const token = try makeOpenSubtitlesRemoteToken(allocator, "/en/subtitleserve/file/abc");
    defer allocator.free(token);

    const parsed = parseOpenSubtitlesRemoteToken(token) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/en/subtitleserve/file/abc", parsed);
    try std.testing.expect(parseOpenSubtitlesRemoteToken("https://example.com/file.zip") == null);
}

test "subtitlecat translate token helpers" {
    const allocator = std.testing.allocator;

    const token = try makeSubtitlecatTranslateToken(
        allocator,
        "https://www.subtitlecat.com/subs/file-orig.srt",
        "es",
        "movie-es.srt",
    );
    defer allocator.free(token);

    const parsed = (try parseSubtitlecatTranslateToken(allocator, token)) orelse return error.TestUnexpectedResult;
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("https://www.subtitlecat.com/subs/file-orig.srt", parsed.source_url);
    try std.testing.expectEqualStrings("es", parsed.target_lang);
    try std.testing.expectEqualStrings("movie-es.srt", parsed.filename);

    try std.testing.expect((try parseSubtitlecatTranslateToken(allocator, "https://example.com/file.srt")) == null);
}

test "google translate result parser extracts text chunks" {
    const allocator = std.testing.allocator;
    const raw =
        \\[[["hello ","hola ",null,null,10],["world","mundo",null,null,10]],null,"en"]
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const text = try googleTranslateResultToString(allocator, parsed.value);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}

test "yify referer is only added for yifysubtitles hosts" {
    try std.testing.expectEqualStrings("https://yifysubtitles.ch/", yifyRefererForUrl("https://yifysubtitles.ch/subtitle/test.zip").?);
    try std.testing.expect(yifyRefererForUrl("https://www.opensubtitles.com/file.zip") == null);
}

test "cloudflare target excludes yify downloads" {
    try std.testing.expect(cloudflareTargetForUrl("https://yifysubtitles.ch/subtitle/test.zip") == null);
    try std.testing.expect(cloudflareTargetForUrl("https://www.opensubtitles.com/nocache/download/123") != null);
}

test "subtitleLabel uses Without release fallback for missing filename" {
    const allocator = std.testing.allocator;

    const a = try subtitleLabel(allocator, null, null, "https://example.com/sub.zip");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("Without release", a);

    const b = try subtitleLabel(allocator, "English", "", "https://example.com/sub.zip");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("English | Without release", b);

    const c = try subtitleLabel(allocator, "  ", " \t ", null);
    defer allocator.free(c);
    try std.testing.expectEqualStrings("Without release [no direct download]", c);
}

test "ensureFilenameExtension uses url extension when missing in preferred name" {
    const allocator = std.testing.allocator;
    const name = try ensureFilenameExtension(
        allocator,
        "S01E01-13",
        "https://api.subsource.net/v1/subtitle/download/abc.zip",
        .none,
        ".srt",
    );
    defer allocator.free(name);
    try std.testing.expectEqualStrings("S01E01-13.zip", name);
}

test "ensureFilenameExtension falls back to archive extension from kind" {
    const allocator = std.testing.allocator;
    const name = try ensureFilenameExtension(
        allocator,
        "subtitle_pack",
        "https://api.example.com/download/token",
        .rar,
        ".srt",
    );
    defer allocator.free(name);
    try std.testing.expectEqualStrings("subtitle_pack.rar", name);
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

    var allocator_state = runtime_alloc.RuntimeAllocator.init();
    defer allocator_state.deinit();
    const allocator = allocator_state.allocator();

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

    if (download.bytes_written == 0) return error.TestUnexpectedResult;
    if (download.archive_path != null and download.extracted_files.len == 0) return error.TestUnexpectedResult;
    if (download.extracted_files.len > 0) {
        std.debug.print("[live][providers_app][{s}] extraction_ok idx={d} files={d}\n", .{
            providerName(provider),
            download_idx,
            download.extracted_files.len,
        });
    } else {
        std.debug.print("[live][providers_app][{s}] direct_download_ok idx={d}\n", .{
            providerName(provider),
            download_idx,
        });
    }
}

fn runSubtitlecatTranslateDownloadLive(allocator: std.mem.Allocator, client: *std.http.Client) !void {
    const provider_name = "subtitlecat_com";
    std.debug.print("[live][providers_app][subtitlecat_com][translate] start\n", .{});

    var search_response = try search(allocator, client, .subtitlecat_com, "The Matrix");
    defer search_response.deinit();
    if (search_response.items.len == 0) return error.TestUnexpectedResult;

    var chosen_subtitle: ?SubtitleChoice = null;
    var chosen_listing_idx: ?usize = null;

    const max_listings = @min(search_response.items.len, @as(usize, 8));
    var i: usize = 0;
    while (i < max_listings and chosen_subtitle == null) : (i += 1) {
        const listing = search_response.items[i];
        var subtitles = fetchSubtitles(allocator, client, listing.ref) catch |err| {
            std.debug.print("[live][providers_app][subtitlecat_com][translate] skip listing={d} err={s}\n", .{ i, @errorName(err) });
            continue;
        };
        defer subtitles.deinit();

        for (subtitles.items) |sub| {
            if (!isSubtitlecatTranslateTokenUrl(sub.download_url)) continue;
            chosen_subtitle = .{
                .label = try allocator.dupe(u8, sub.label),
                .language = try dupOptional(allocator, sub.language),
                .filename = try dupOptional(allocator, sub.filename),
                .download_url = try dupOptional(allocator, sub.download_url),
            };
            chosen_listing_idx = i;
            break;
        }
    }

    if (chosen_subtitle == null) return error.TestUnexpectedResult;
    defer {
        const sub = chosen_subtitle.?;
        allocator.free(sub.label);
        if (sub.language) |v| allocator.free(v);
        if (sub.filename) |v| allocator.free(v);
        if (sub.download_url) |v| allocator.free(v);
    }

    std.debug.print("[live][providers_app][subtitlecat_com][translate] chosen_listing={d}\n", .{chosen_listing_idx.?});
    try common.livePrintField(allocator, "provider", provider_name);
    try common.livePrintField(allocator, "subtitle_label", chosen_subtitle.?.label);
    try common.livePrintOptionalField(allocator, "download_url", chosen_subtitle.?.download_url);

    const unique = std.time.nanoTimestamp();
    const out_dir = try std.fmt.allocPrint(allocator, ".zig-cache/live-downloads/subtitlecat-translate-{d}", .{unique});
    defer allocator.free(out_dir);
    try prepareDownloadOutDir(out_dir);
    defer cleanupDownloadOutDir(out_dir);

    var download = try downloadSubtitle(allocator, client, chosen_subtitle.?, out_dir);
    defer download.deinit(allocator);
    std.debug.print("[live][providers_app][subtitlecat_com][translate] download_ok bytes={d}\n", .{download.bytes_written});
    try common.livePrintField(allocator, "download_file_path", download.file_path);
    try std.fs.cwd().access(download.file_path, .{});
    if (download.bytes_written == 0) return error.TestUnexpectedResult;
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

test "live providers_app subtitlecat translated download path" {
    if (!shouldRunTuiLiveSmoke(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subtitlecat_com")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    try runSubtitlecatTranslateDownloadLive(std.testing.allocator, &client);
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
