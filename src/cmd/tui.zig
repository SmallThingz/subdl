const std = @import("std");
const scrapers = @import("scrapers");
const vaxis = @import("vaxis");
const builtin = @import("builtin");

const app = scrapers.providers_app;

const hard_cancel_supported = std.Thread.use_pthreads and switch (builtin.os.tag) {
    .linux, .macos, .ios, .watchos, .tvos, .visionos, .freebsd, .openbsd, .netbsd, .dragonfly, .solaris, .illumos => true,
    else => false,
};

const pthread = if (hard_cancel_supported) struct {
    const PTHREAD_CANCEL_ENABLE: c_int = 0;
    const PTHREAD_CANCEL_ASYNCHRONOUS: c_int = 1;

    extern "c" fn pthread_cancel(thread: std.Thread.Handle) c_int;
    extern "c" fn pthread_setcancelstate(state: c_int, old_state: ?*c_int) c_int;
    extern "c" fn pthread_setcanceltype(cancel_type: c_int, old_type: ?*c_int) c_int;
} else struct {};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

const InputResult = union(enum) {
    submit: []u8,
    back,
    quit,
};

const SelectResult = union(enum) {
    selected: usize,
    back,
    to_query,
    page_prev,
    page_next,
    quit,
};

const ConfirmResult = enum {
    confirm,
    back,
    to_query,
    quit,
};

const MessageResult = enum {
    ok,
    to_query,
    quit,
};

const Theme = struct {
    name: []const u8,
    title_fg: u8,
    accent_fg: u8,
    selected_fg: u8,
    selected_bg: u8,
    muted_fg: u8,
    warning_fg: u8,
    error_fg: u8,
    pane_title_fg: u8,
};

const themes = [_]Theme{
    .{
        .name = "Ocean",
        .title_fg = 14,
        .accent_fg = 12,
        .selected_fg = 0,
        .selected_bg = 12,
        .muted_fg = 8,
        .warning_fg = 11,
        .error_fg = 9,
        .pane_title_fg = 10,
    },
    .{
        .name = "Amber",
        .title_fg = 11,
        .accent_fg = 3,
        .selected_fg = 0,
        .selected_bg = 3,
        .muted_fg = 8,
        .warning_fg = 14,
        .error_fg = 9,
        .pane_title_fg = 6,
    },
};

const SubtitleSort = enum {
    relevance,
    language,
    filename,
    available,
    label,
};

const FetchControl = enum {
    completed,
    canceled,
    quit,
};

const PageNav = struct {
    enabled: bool = false,
    page: usize = 1,
    has_prev: bool = false,
    has_next: bool = false,
};

const SearchPageCacheEntry = struct {
    page: usize,
    response: app.SearchResponse,
};

const SubtitlesPageCacheEntry = struct {
    page: usize,
    response: app.SubtitlesResponse,
};

const SearchTask = struct {
    provider: app.Provider,
    query: []const u8,
    page: usize = 1,
    done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    err: ?anyerror = null,
    result: ?app.SearchResponse = null,
};

const SubtitlesTask = struct {
    ref: app.SearchRef,
    page: usize = 1,
    subdl_season_slug: ?[]const u8 = null,
    done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    err: ?anyerror = null,
    result: ?app.SubtitlesResponse = null,
};

const SubdlSeasonsTask = struct {
    ref: app.SearchRef,
    done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    err: ?anyerror = null,
    result: ?app.SubdlSeasonsResponse = null,
};

const DownloadTask = struct {
    subtitle: app.SubtitleChoice,
    out_dir: []const u8,
    done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    err: ?anyerror = null,
    result: ?app.DownloadResult = null,
};

const Ui = struct {
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(Event),
    theme_index: usize = 0,
    skip_confirm: bool = false,
    context_line: ?[]const u8 = null,
    context_owned: ?[]u8 = null,

    fn writer(self: *Ui) *std.Io.Writer {
        return self.tty.writer();
    }

    fn resize(self: *Ui, ws: vaxis.Winsize) !void {
        try self.vx.resize(self.allocator, self.writer(), ws);
    }

    fn render(self: *Ui) !void {
        try self.vx.render(self.writer());
        try self.writer().flush();
    }

    fn theme(self: *Ui) Theme {
        return themes[self.theme_index];
    }

    fn toggleTheme(self: *Ui) void {
        self.theme_index = (self.theme_index + 1) % themes.len;
    }

    fn toggleConfirm(self: *Ui) void {
        self.skip_confirm = !self.skip_confirm;
    }

    fn styleTitle(self: *Ui) vaxis.Style {
        return .{ .fg = .{ .index = self.theme().title_fg }, .bold = true };
    }

    fn styleAccent(self: *Ui) vaxis.Style {
        return .{ .fg = .{ .index = self.theme().accent_fg }, .bold = true };
    }

    fn styleMuted(self: *Ui) vaxis.Style {
        return .{ .fg = .{ .index = self.theme().muted_fg } };
    }

    fn styleWarn(self: *Ui) vaxis.Style {
        return .{ .fg = .{ .index = self.theme().warning_fg }, .bold = true };
    }

    fn styleError(self: *Ui) vaxis.Style {
        return .{ .fg = .{ .index = self.theme().error_fg }, .bold = true };
    }

    fn styleSelected(self: *Ui) vaxis.Style {
        return .{
            .fg = .{ .index = self.theme().selected_fg },
            .bg = .{ .index = self.theme().selected_bg },
            .bold = true,
        };
    }

    fn stylePaneTitle(self: *Ui) vaxis.Style {
        return .{ .fg = .{ .index = self.theme().pane_title_fg }, .bold = true };
    }
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var client: std.http.Client = .{ .allocator = gpa };
    defer client.deinit();

    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(gpa, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .{
        .vaxis = &vx,
        .tty = &tty,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    var ui: Ui = .{
        .allocator = gpa,
        .tty = &tty,
        .vx = &vx,
        .loop = &loop,
    };

    try runTui(&ui, &client);
}

fn searchTaskMain(task: *SearchTask) void {
    configureWorkerHardCancel();
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator };
    defer client.deinit();

    task.result = app.searchPage(std.heap.page_allocator, &client, task.provider, task.query, task.page) catch |err| {
        task.err = err;
        task.done.store(1, .release);
        return;
    };
    task.done.store(1, .release);
}

fn subtitlesTaskMain(task: *SubtitlesTask) void {
    configureWorkerHardCancel();
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator };
    defer client.deinit();

    const fetch_result = if (task.subdl_season_slug) |season_slug|
        app.fetchSubdlSeasonSubtitlesPage(std.heap.page_allocator, &client, task.ref, season_slug, task.page)
    else
        app.fetchSubtitlesPage(std.heap.page_allocator, &client, task.ref, task.page);

    task.result = fetch_result catch |err| {
        task.err = err;
        task.done.store(1, .release);
        return;
    };
    task.done.store(1, .release);
}

fn subdlSeasonsTaskMain(task: *SubdlSeasonsTask) void {
    configureWorkerHardCancel();
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator };
    defer client.deinit();

    task.result = app.fetchSubdlSeasons(std.heap.page_allocator, &client, task.ref) catch |err| {
        task.err = err;
        task.done.store(1, .release);
        return;
    };
    task.done.store(1, .release);
}

fn downloadTaskMain(task: *DownloadTask) void {
    configureWorkerHardCancel();
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator };
    defer client.deinit();

    task.result = app.downloadSubtitle(std.heap.page_allocator, &client, task.subtitle, task.out_dir) catch |err| {
        task.err = err;
        task.done.store(1, .release);
        return;
    };
    task.done.store(1, .release);
}

fn waitForFetch(ui: *Ui, done: *const std.atomic.Value(u8), title: []const u8, detail: []const u8) !FetchControl {
    const spinner = [_][]const u8{ "|", "/", "-", "\\" };
    var spinner_idx: usize = 0;

    while (done.load(.acquire) == 0) {
        var msg_buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&msg_buf, "Fetching... {s}", .{spinner[spinner_idx % spinner.len]}) catch "Fetching...";

        try vaxisStatus(ui, title, message, detail);

        while (ui.loop.tryEvent()) |event| {
            switch (event) {
                .winsize => |ws| try ui.resize(ws),
                .key_press => |key| {
                    if (key.matches(vaxis.Key.f2, .{})) {
                        ui.toggleConfirm();
                        continue;
                    }
                    if (key.matches(vaxis.Key.f3, .{})) {
                        ui.toggleTheme();
                        continue;
                    }
                    if (key.matches('d', .{ .ctrl = true })) {
                        return .quit;
                    }
                    if (key.matches('c', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                        return .canceled;
                    }
                },
                else => {},
            }
        }

        spinner_idx += 1;
        std.Thread.sleep(90 * std.time.ns_per_ms);
    }
    return .completed;
}

fn waitForTask(ui: *Ui, done: *const std.atomic.Value(u8), title: []const u8, detail: []const u8) !FetchControl {
    return waitForFetch(ui, done, title, detail);
}

fn configureWorkerHardCancel() void {
    if (comptime !hard_cancel_supported) return;

    var old_state: i32 = 0;
    _ = pthread.pthread_setcancelstate(pthread.PTHREAD_CANCEL_ENABLE, &old_state);
    var old_type: i32 = 0;
    _ = pthread.pthread_setcanceltype(pthread.PTHREAD_CANCEL_ASYNCHRONOUS, &old_type);
}

fn requestHardThreadCancel(thread: std.Thread) bool {
    if (comptime !hard_cancel_supported) return false;
    return pthread.pthread_cancel(thread.getHandle()) == 0;
}

fn finalizeWorkerThread(thread: std.Thread, control: FetchControl) void {
    switch (control) {
        .completed => thread.join(),
        .canceled, .quit => {
            _ = requestHardThreadCancel(thread);
            thread.join();
        },
    }
}

fn setContext(ui: *Ui, context_line: ?[]const u8) void {
    if (ui.context_owned) |buf| {
        ui.allocator.free(buf);
        ui.context_owned = null;
    }
    ui.context_line = null;

    const src = context_line orelse return;
    const copied = ui.allocator.dupe(u8, src) catch return;
    ui.context_owned = copied;
    ui.context_line = copied;
}

fn providerHomeUrl(provider: app.Provider) []const u8 {
    return switch (provider) {
        .subdl_com => "https://subdl.com",
        .opensubtitles_com => "https://www.opensubtitles.com",
        .opensubtitles_org => "https://www.opensubtitles.org",
        .moviesubtitles_org => "https://www.moviesubtitles.org",
        .moviesubtitlesrt_com => "https://moviesubtitlesrt.com",
        .podnapisi_net => "https://www.podnapisi.net",
        .yifysubtitles_ch => "https://yifysubtitles.ch",
        .subtitlecat_com => "https://www.subtitlecat.com",
        .isubtitles_org => "https://isubtitles.org",
        .my_subs_co => "https://my-subs.co",
        .subsource_net => "https://subsource.net",
        .tvsubtitles_net => "https://www.tvsubtitles.net",
    };
}

fn searchRefUrl(ref: app.SearchRef) []const u8 {
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

fn isSubdlSeriesRef(ref: app.SearchRef) bool {
    return switch (ref) {
        .subdl_com => |item| item.media_type == .tv,
        else => false,
    };
}

fn subdlSeasonUrl(allocator: std.mem.Allocator, title_url: []const u8, season_slug: []const u8) ![]u8 {
    if (season_slug.len == 0) return allocator.dupe(u8, title_url);
    if (std.mem.endsWith(u8, title_url, "/")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ title_url, season_slug });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ title_url, season_slug });
}

fn runTui(ui: *Ui, client: *std.http.Client) !void {
    defer setContext(ui, null);
    _ = client;
    const provider_names = try buildProviderNames(ui.allocator);
    defer freeOwnedStrings(ui.allocator, provider_names);

    var provider_default: ?usize = 0;

    provider_loop: while (true) {
        setContext(ui, "Provider list | URL: choose provider");
        const provider_choice = try vaxisSelect(
            ui,
            "Subtitle Downloader",
            "Select provider. Esc quits.",
            provider_names,
            provider_default,
            null,
            null,
        );

        const provider_idx = switch (provider_choice) {
            .selected => |idx| idx,
            .back, .to_query, .quit => return,
            .page_prev, .page_next => continue :provider_loop,
        };

        provider_default = provider_idx;
        const provider = app.providers()[provider_idx];
        const provider_url = providerHomeUrl(provider);
        const supports_search_pagination = app.providerSupportsSearchPagination(provider);
        const supports_subtitles_pagination = app.providerSupportsSubtitlesPagination(provider);

        query_loop: while (true) {
            var hint_buf: [192]u8 = undefined;
            const query_hint = std.fmt.bufPrint(
                &hint_buf,
                "Provider: {s}. Enter search query. Esc returns to providers.",
                .{app.providerName(provider)},
            ) catch "Enter search query. Esc returns to providers.";

            const query_context = try std.fmt.allocPrint(
                ui.allocator,
                "Provider: {s} | URL: {s}",
                .{ app.providerName(provider), provider_url },
            );
            defer ui.allocator.free(query_context);
            setContext(ui, query_context);

            const input = try vaxisInput(ui, "Subtitle Downloader", query_hint, "Query", 180);
            const query = switch (input) {
                .submit => |q| q,
                .back => continue :provider_loop,
                .quit => return,
            };
            defer ui.allocator.free(query);

            var search_pages: std.ArrayListUnmanaged(SearchPageCacheEntry) = .empty;
            defer deinitSearchPageCache(ui.allocator, &search_pages);
            var search_page_current: usize = 1;

            title_loop: while (true) {
                const search_idx = findSearchPageCacheIndex(search_pages.items, search_page_current) orelse blk_fetch: {
                    const search_detail = if (supports_search_pagination)
                        try std.fmt.allocPrint(
                            ui.allocator,
                            "provider={s} query={s} page={d}",
                            .{ app.providerName(provider), query, search_page_current },
                        )
                    else
                        try std.fmt.allocPrint(
                            ui.allocator,
                            "provider={s} query={s}",
                            .{ app.providerName(provider), query },
                        );
                    defer ui.allocator.free(search_detail);

                    const search_context = if (supports_search_pagination)
                        try std.fmt.allocPrint(
                            ui.allocator,
                            "Search URL base: {s} | page={d}",
                            .{ provider_url, search_page_current },
                        )
                    else
                        try std.fmt.allocPrint(
                            ui.allocator,
                            "Search URL base: {s}",
                            .{provider_url},
                        );
                    defer ui.allocator.free(search_context);
                    setContext(ui, search_context);

                    var search_task: SearchTask = .{
                        .provider = provider,
                        .query = query,
                        .page = search_page_current,
                    };
                    const search_thread = try std.Thread.spawn(.{}, searchTaskMain, .{&search_task});
                    const search_control = try waitForTask(ui, &search_task.done, "Search", search_detail);
                    finalizeWorkerThread(search_thread, search_control);

                    if (search_control == .quit) {
                        if (search_task.result) |*r| r.deinit();
                        return;
                    }
                    if (search_control == .canceled) {
                        if (search_task.result) |*r| r.deinit();
                        const msg_result = try vaxisMessage(
                            ui,
                            "Search Canceled",
                            "Canceled current fetch.",
                            "Press any key to continue.",
                            ui.styleWarn(),
                        );
                        switch (msg_result) {
                            .ok, .to_query => continue :query_loop,
                            .quit => return,
                        }
                    }

                    if (search_task.err) |err| {
                        const msg_result = try showFriendlyError(ui, "Search failed", err);
                        switch (msg_result) {
                            .ok, .to_query => continue :query_loop,
                            .quit => return,
                        }
                    }

                    const search_result = search_task.result orelse return error.UnexpectedHttpStatus;
                    try search_pages.append(ui.allocator, .{
                        .page = search_page_current,
                        .response = search_result,
                    });
                    break :blk_fetch search_pages.items.len - 1;
                };

                const search_result = &search_pages.items[search_idx].response;
                if (search_result.items.len == 0) {
                    const msg_result = try vaxisMessage(
                        ui,
                        "No Results",
                        if (search_page_current == 1)
                            "No titles matched your query."
                        else
                            "No titles were found on this page.",
                        "Press any key to continue.",
                        ui.styleWarn(),
                    );
                    switch (msg_result) {
                        .ok => {
                            if (search_page_current > 1) {
                                search_page_current -= 1;
                                continue :title_loop;
                            }
                            continue :query_loop;
                        },
                        .to_query => continue :query_loop,
                        .quit => return,
                    }
                }

                const title_labels = try borrowSearchLabels(ui.allocator, search_result.items);
                defer ui.allocator.free(title_labels);

                const title_context = if (supports_search_pagination)
                    try std.fmt.allocPrint(
                        ui.allocator,
                        "Provider: {s} | Search base URL: {s} | page={d}",
                        .{ app.providerName(provider), provider_url, search_page_current },
                    )
                else
                    try std.fmt.allocPrint(
                        ui.allocator,
                        "Provider: {s} | Search base URL: {s}",
                        .{ app.providerName(provider), provider_url },
                    );
                defer ui.allocator.free(title_context);
                setContext(ui, title_context);

                const page_nav = PageNav{
                    .enabled = app.providerSupportsSearchPagination(provider),
                    .page = search_page_current,
                    .has_prev = search_result.has_prev_page,
                    .has_next = search_result.has_next_page,
                };
                const page_nav_opt: ?PageNav = if (page_nav.enabled) page_nav else null;
                const title_choice = try vaxisSelect(
                    ui,
                    "Select Title",
                    if (supports_search_pagination)
                        "Use filter/sort keys. [ prev page, ] next page, Esc query."
                    else
                        "Use filter/sort keys. Esc query.",
                    title_labels,
                    null,
                    null,
                    page_nav_opt,
                );

                const title_idx = switch (title_choice) {
                    .selected => |idx| idx,
                    .back, .to_query => continue :query_loop,
                    .page_prev => {
                        if (page_nav.enabled and search_page_current > 1) search_page_current -= 1;
                        continue :title_loop;
                    },
                    .page_next => {
                        if (!page_nav.enabled or !search_result.has_next_page) continue :title_loop;
                        search_page_current += 1;
                        continue :title_loop;
                    },
                    .quit => return,
                };

                const selected_title = search_result.items[title_idx];
                const title_ref_url = searchRefUrl(selected_title.ref);
                var selected_subdl_season_slug: ?[]u8 = null;
                defer if (selected_subdl_season_slug) |slug| ui.allocator.free(slug);
                var selected_subdl_season_label: ?[]u8 = null;
                defer if (selected_subdl_season_label) |label| ui.allocator.free(label);

                if (isSubdlSeriesRef(selected_title.ref)) {
                    const seasons_detail = try std.fmt.allocPrint(
                        ui.allocator,
                        "{s}",
                        .{selected_title.label},
                    );
                    defer ui.allocator.free(seasons_detail);
                    const seasons_context = try std.fmt.allocPrint(
                        ui.allocator,
                        "Series URL: {s}",
                        .{title_ref_url},
                    );
                    defer ui.allocator.free(seasons_context);
                    setContext(ui, seasons_context);

                    var seasons_task: SubdlSeasonsTask = .{
                        .ref = selected_title.ref,
                    };
                    const seasons_thread = try std.Thread.spawn(.{}, subdlSeasonsTaskMain, .{&seasons_task});
                    const seasons_control = try waitForTask(ui, &seasons_task.done, "Seasons", seasons_detail);
                    finalizeWorkerThread(seasons_thread, seasons_control);

                    if (seasons_control == .quit) {
                        if (seasons_task.result) |*r| r.deinit();
                        return;
                    }
                    if (seasons_control == .canceled) {
                        if (seasons_task.result) |*r| r.deinit();
                        const msg_result = try vaxisMessage(
                            ui,
                            "Fetch Canceled",
                            "Canceled season list fetch.",
                            "Press any key to continue.",
                            ui.styleWarn(),
                        );
                        switch (msg_result) {
                            .ok => continue :title_loop,
                            .to_query => continue :query_loop,
                            .quit => return,
                        }
                    }

                    if (seasons_task.err) |err| {
                        const msg_result = try showFriendlyError(ui, "Could not load seasons", err);
                        switch (msg_result) {
                            .ok => continue :title_loop,
                            .to_query => continue :query_loop,
                            .quit => return,
                        }
                    }

                    var seasons = seasons_task.result orelse return error.UnexpectedHttpStatus;
                    defer seasons.deinit();

                    if (seasons.items.len == 0) {
                        const msg_result = try vaxisMessage(
                            ui,
                            "No Seasons",
                            "No season rows were returned.",
                            "Press any key to continue.",
                            ui.styleWarn(),
                        );
                        switch (msg_result) {
                            .ok => continue :title_loop,
                            .to_query => continue :query_loop,
                            .quit => return,
                        }
                    }

                    const season_labels = try borrowSubdlSeasonLabels(ui.allocator, seasons.items);
                    defer ui.allocator.free(season_labels);
                    setContext(ui, seasons_context);

                    const season_choice = try vaxisSelect(
                        ui,
                        "Select Season",
                        "Use filter/sort keys. Esc titles.",
                        season_labels,
                        null,
                        null,
                        null,
                    );

                    const season_idx = switch (season_choice) {
                        .selected => |idx| idx,
                        .back => continue :title_loop,
                        .to_query => continue :query_loop,
                        .page_prev, .page_next => continue :title_loop,
                        .quit => return,
                    };

                    const season = seasons.items[season_idx];
                    selected_subdl_season_slug = try ui.allocator.dupe(u8, season.season_slug);
                    selected_subdl_season_label = try ui.allocator.dupe(u8, season.label);
                }

                const subtitle_ref_url = if (selected_subdl_season_slug) |season_slug|
                    try subdlSeasonUrl(ui.allocator, title_ref_url, season_slug)
                else
                    try ui.allocator.dupe(u8, title_ref_url);
                defer ui.allocator.free(subtitle_ref_url);

                var subtitle_pages: std.ArrayListUnmanaged(SubtitlesPageCacheEntry) = .empty;
                defer deinitSubtitlesPageCache(ui.allocator, &subtitle_pages);
                var subtitle_page_current: usize = 1;

                subtitle_page_loop: while (true) {
                    const subtitles_idx = findSubtitlesPageCacheIndex(subtitle_pages.items, subtitle_page_current) orelse blk_fetch: {
                        const subtitles_detail = if (selected_subdl_season_label) |season_label|
                            if (supports_subtitles_pagination)
                                try std.fmt.allocPrint(
                                    ui.allocator,
                                    "{s} | {s} | page={d}",
                                    .{ selected_title.label, season_label, subtitle_page_current },
                                )
                            else
                                try std.fmt.allocPrint(
                                    ui.allocator,
                                    "{s} | {s}",
                                    .{ selected_title.label, season_label },
                                )
                        else if (supports_subtitles_pagination)
                            try std.fmt.allocPrint(
                                ui.allocator,
                                "{s} | page={d}",
                                .{ selected_title.label, subtitle_page_current },
                            )
                        else
                            try std.fmt.allocPrint(
                                ui.allocator,
                                "{s}",
                                .{selected_title.label},
                            );
                        defer ui.allocator.free(subtitles_detail);

                        const subtitles_context = if (supports_subtitles_pagination)
                            try std.fmt.allocPrint(
                                ui.allocator,
                                "Title URL: {s} | page={d}",
                                .{ subtitle_ref_url, subtitle_page_current },
                            )
                        else
                            try std.fmt.allocPrint(
                                ui.allocator,
                                "Title URL: {s}",
                                .{subtitle_ref_url},
                            );
                        defer ui.allocator.free(subtitles_context);
                        setContext(ui, subtitles_context);

                        var subtitles_task: SubtitlesTask = .{
                            .ref = selected_title.ref,
                            .page = subtitle_page_current,
                            .subdl_season_slug = selected_subdl_season_slug,
                        };
                        const subtitles_thread = try std.Thread.spawn(.{}, subtitlesTaskMain, .{&subtitles_task});
                        const subtitles_control = try waitForTask(ui, &subtitles_task.done, "Subtitles", subtitles_detail);
                        finalizeWorkerThread(subtitles_thread, subtitles_control);

                        if (subtitles_control == .quit) {
                            if (subtitles_task.result) |*r| r.deinit();
                            return;
                        }
                        if (subtitles_control == .canceled) {
                            if (subtitles_task.result) |*r| r.deinit();
                            const msg_result = try vaxisMessage(
                                ui,
                                "Fetch Canceled",
                                "Canceled subtitle list fetch.",
                                "Press any key to continue.",
                                ui.styleWarn(),
                            );
                            switch (msg_result) {
                                .ok => continue :title_loop,
                                .to_query => continue :query_loop,
                                .quit => return,
                            }
                        }

                        if (subtitles_task.err) |err| {
                            const msg_result = try showFriendlyError(ui, "Could not load subtitles", err);
                            switch (msg_result) {
                                .ok => continue :title_loop,
                                .to_query => continue :query_loop,
                                .quit => return,
                            }
                        }

                        const subtitles = subtitles_task.result orelse return error.UnexpectedHttpStatus;
                        try subtitle_pages.append(ui.allocator, .{
                            .page = subtitle_page_current,
                            .response = subtitles,
                        });
                        break :blk_fetch subtitle_pages.items.len - 1;
                    };

                    const subtitles = &subtitle_pages.items[subtitles_idx].response;
                    if (subtitles.items.len == 0) {
                        const msg_result = try vaxisMessage(
                            ui,
                            "No Subtitles",
                            if (subtitle_page_current == 1)
                                "No subtitle rows were returned."
                            else
                                "No subtitle rows were returned on this page.",
                            "Press any key to continue.",
                            ui.styleWarn(),
                        );
                        switch (msg_result) {
                            .ok => {
                                if (subtitle_page_current > 1) {
                                    subtitle_page_current -= 1;
                                    continue :subtitle_page_loop;
                                }
                                continue :title_loop;
                            },
                            .to_query => continue :query_loop,
                            .quit => return,
                        }
                    }

                    const subtitle_enabled = try buildSubtitleEnabled(ui.allocator, subtitles.items);
                    defer ui.allocator.free(subtitle_enabled);

                    const subtitle_context = if (supports_subtitles_pagination)
                        try std.fmt.allocPrint(
                            ui.allocator,
                            "Title URL: {s} | page={d}",
                            .{ subtitle_ref_url, subtitle_page_current },
                        )
                    else
                        try std.fmt.allocPrint(
                            ui.allocator,
                            "Title URL: {s}",
                            .{subtitle_ref_url},
                        );
                    defer ui.allocator.free(subtitle_context);
                    setContext(ui, subtitle_context);

                    const subtitle_page_nav = PageNav{
                        .enabled = app.providerSupportsSubtitlesPagination(provider),
                        .page = subtitle_page_current,
                        .has_prev = subtitles.has_prev_page,
                        .has_next = subtitles.has_next_page,
                    };
                    const subtitle_page_nav_opt: ?PageNav = if (subtitle_page_nav.enabled) subtitle_page_nav else null;
                    const subtitle_choice = try vaxisSelectSubtitle(
                        ui,
                        "Select Subtitle",
                        if (supports_subtitles_pagination)
                            "s sort, / filter, [ prev page, ] next page, Esc titles."
                        else
                            "s sort, / filter, Esc titles.",
                        subtitles.items,
                        subtitle_enabled,
                        subtitle_page_nav_opt,
                    );

                    const subtitle_idx = switch (subtitle_choice) {
                        .selected => |idx| idx,
                        .back => continue :title_loop,
                        .to_query => continue :query_loop,
                        .page_prev => {
                            if (subtitle_page_nav.enabled and subtitle_page_current > 1) subtitle_page_current -= 1;
                            continue :subtitle_page_loop;
                        },
                        .page_next => {
                            if (!subtitle_page_nav.enabled or !subtitles.has_next_page) continue :subtitle_page_loop;
                            subtitle_page_current += 1;
                            continue :subtitle_page_loop;
                        },
                        .quit => return,
                    };

                    const selected_subtitle = subtitles.items[subtitle_idx];
                    const download_url = selected_subtitle.download_url orelse "(no direct URL)";

                    if (!ui.skip_confirm) {
                        var provider_buf: [224]u8 = undefined;
                        const provider_line = std.fmt.bufPrint(&provider_buf, "Provider: {s}", .{app.providerName(provider)}) catch "Provider: (overflow)";

                        const display_title = if (subtitles.title.len > 0) subtitles.title else selected_title.title;
                        var title_buf: [320]u8 = undefined;
                        const title_line = std.fmt.bufPrint(&title_buf, "Title: {s}", .{display_title}) catch "Title: (overflow)";

                        var subtitle_buf: [384]u8 = undefined;
                        const subtitle_line = std.fmt.bufPrint(&subtitle_buf, "Subtitle: {s}", .{selected_subtitle.label}) catch "Subtitle: (overflow)";
                        var url_buf: [320]u8 = undefined;
                        const url_line = std.fmt.bufPrint(&url_buf, "URL: {s}", .{download_url}) catch "URL: (overflow)";

                        const confirm_lines = [_][]const u8{
                            provider_line,
                            title_line,
                            subtitle_line,
                            url_line,
                            "Enter confirms download. Esc goes back.",
                        };

                        setContext(ui, subtitle_ref_url);
                        const confirm_result = try vaxisConfirm(ui, "Confirm Selection", &confirm_lines);
                        switch (confirm_result) {
                            .confirm => {},
                            .back => continue :subtitle_page_loop,
                            .to_query => continue :query_loop,
                            .quit => return,
                        }
                    }

                    const download_detail = try std.fmt.allocPrint(
                        ui.allocator,
                        "{s}",
                        .{selected_subtitle.label},
                    );
                    defer ui.allocator.free(download_detail);
                    const download_context = try std.fmt.allocPrint(
                        ui.allocator,
                        "Download URL: {s}",
                        .{download_url},
                    );
                    defer ui.allocator.free(download_context);
                    setContext(ui, download_context);

                    var download_task: DownloadTask = .{
                        .subtitle = selected_subtitle,
                        .out_dir = "downloads",
                    };
                    const download_thread = try std.Thread.spawn(.{}, downloadTaskMain, .{&download_task});
                    const download_control = try waitForTask(ui, &download_task.done, "Download", download_detail);
                    finalizeWorkerThread(download_thread, download_control);

                    if (download_control == .quit) {
                        if (download_task.result) |*r| r.deinit(std.heap.page_allocator);
                        return;
                    }
                    if (download_control == .canceled) {
                        if (download_task.result) |*r| r.deinit(std.heap.page_allocator);
                        const msg_result = try vaxisMessage(
                            ui,
                            "Download Canceled",
                            "Canceled current download.",
                            "Press any key to continue.",
                            ui.styleWarn(),
                        );
                        switch (msg_result) {
                            .ok => continue :subtitle_page_loop,
                            .to_query => continue :query_loop,
                            .quit => return,
                        }
                    }

                    if (download_task.err) |err| {
                        const msg_result = try showFriendlyError(ui, "Download failed", err);
                        switch (msg_result) {
                            .ok => continue :subtitle_page_loop,
                            .to_query => continue :query_loop,
                            .quit => return,
                        }
                    }

                    var result = download_task.result orelse return error.UnexpectedHttpStatus;
                    defer result.deinit(std.heap.page_allocator);

                    const detail = if (result.extracted_files.len > 0)
                        try std.fmt.allocPrint(ui.allocator, "{s} (+{d} extracted)", .{ result.file_path, result.extracted_files.len })
                    else
                        try std.fmt.allocPrint(ui.allocator, "{s}", .{result.file_path});
                    defer ui.allocator.free(detail);

                    setContext(ui, download_context);
                    const msg_result = try vaxisMessage(
                        ui,
                        "Downloaded",
                        detail,
                        "Press any key to keep browsing subtitles.",
                        ui.styleAccent(),
                    );
                    switch (msg_result) {
                        .ok => continue :subtitle_page_loop,
                        .to_query => continue :query_loop,
                        .quit => return,
                    }
                }
            }
        }
    }
}

fn findSearchPageCacheIndex(pages: []const SearchPageCacheEntry, page: usize) ?usize {
    for (pages, 0..) |entry, idx| {
        if (entry.page == page) return idx;
    }
    return null;
}

fn findSubtitlesPageCacheIndex(pages: []const SubtitlesPageCacheEntry, page: usize) ?usize {
    for (pages, 0..) |entry, idx| {
        if (entry.page == page) return idx;
    }
    return null;
}

fn deinitSearchPageCache(allocator: std.mem.Allocator, pages: *std.ArrayListUnmanaged(SearchPageCacheEntry)) void {
    for (pages.items) |*entry| entry.response.deinit();
    pages.deinit(allocator);
}

fn deinitSubtitlesPageCache(allocator: std.mem.Allocator, pages: *std.ArrayListUnmanaged(SubtitlesPageCacheEntry)) void {
    for (pages.items) |*entry| entry.response.deinit();
    pages.deinit(allocator);
}

fn buildProviderNames(allocator: std.mem.Allocator) ![][]u8 {
    const values = app.providers();
    const out = try allocator.alloc([]u8, values.len);
    errdefer allocator.free(out);

    for (values, 0..) |provider, idx| {
        out[idx] = try std.fmt.allocPrint(allocator, "{s}", .{app.providerName(provider)});
    }

    return out;
}

fn borrowSearchLabels(allocator: std.mem.Allocator, items: []const app.SearchChoice) ![][]const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, idx| {
        out[idx] = item.label;
    }
    return out;
}

fn borrowSubdlSeasonLabels(allocator: std.mem.Allocator, items: []const app.SubdlSeasonChoice) ![][]const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, idx| {
        out[idx] = item.label;
    }
    return out;
}

fn buildSubtitleEnabled(allocator: std.mem.Allocator, items: []const app.SubtitleChoice) ![]bool {
    const out = try allocator.alloc(bool, items.len);
    for (items, 0..) |item, idx| {
        out[idx] = item.download_url != null;
    }
    return out;
}

fn showFriendlyError(ui: *Ui, context: []const u8, err: anyerror) !MessageResult {
    var detail_buf: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "Details: {s}", .{@errorName(err)}) catch "Details: (overflow)";

    return vaxisMessage(ui, context, friendlyErrorMessage(err), detail, ui.styleError());
}

fn friendlyErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnexpectedHttpStatus => "Provider returned an unexpected HTTP status.",
        error.RateLimited => "Provider rate limit hit. Retry in a few moments.",
        error.MissingField, error.InvalidField, error.InvalidFieldType => "Provider response format was not as expected.",
        error.CloudflareChallenge, error.CloudflareSessionUnavailable, error.SessionExpired => "Cloudflare session is missing or expired for this provider.",
        error.BrowserAutomationFailed => "Browser automation failed while acquiring session cookies.",
        error.ArchiveExtractionFailed => "Downloaded archive could not be extracted on this machine.",
        else => "An unexpected error occurred at this step.",
    };
}

fn vaxisStatus(ui: *Ui, title: []const u8, message: []const u8, detail: []const u8) !void {
    const win = ui.vx.window();
    win.clear();
    win.hideCursor();

    const title_segments = [_]vaxis.Segment{.{ .text = title, .style = ui.styleTitle() }};
    _ = win.print(&title_segments, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    try renderContextLine(ui, win, 1);

    const msg_segments = [_]vaxis.Segment{.{ .text = message, .style = ui.styleWarn() }};
    _ = win.print(&msg_segments, .{ .row_offset = 2, .col_offset = 1, .wrap = .none });

    const detail_segments = [_]vaxis.Segment{.{ .text = detail, .style = ui.styleMuted() }};
    _ = win.print(&detail_segments, .{ .row_offset = 4, .col_offset = 1, .wrap = .none });

    try renderGlobalFooter(ui, win, "Ctrl+C/Esc/q cancel fetch | Ctrl+D quit", null);
    try ui.render();
}

fn vaxisInput(
    ui: *Ui,
    title: []const u8,
    hint: []const u8,
    label: []const u8,
    max_len: usize,
) !InputResult {
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(ui.allocator);
    var cursor_pos: usize = 0;

    var error_text: ?[]const u8 = null;

    while (true) {
        const win = ui.vx.window();
        win.clear();
        win.hideCursor();
        win.setCursorShape(.beam);

        const title_segments = [_]vaxis.Segment{.{ .text = title, .style = ui.styleTitle() }};
        _ = win.print(&title_segments, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });

        const hint_segments = [_]vaxis.Segment{.{ .text = hint }};
        _ = win.print(&hint_segments, .{ .row_offset = 1, .col_offset = 1, .wrap = .none });
        try renderContextLine(ui, win, 2);

        const before_cursor = query.items[0..cursor_pos];
        const after_cursor = query.items[cursor_pos..];
        const input_segments = [_]vaxis.Segment{
            .{ .text = label, .style = ui.styleAccent() },
            .{ .text = ": " },
            .{ .text = before_cursor },
            .{ .text = after_cursor },
        };
        _ = win.print(&input_segments, .{ .row_offset = 3, .col_offset = 1, .wrap = .none });

        if (win.width > 0) {
            const prompt_width = win.gwidth(label) + 2;
            const before_width = win.gwidth(before_cursor);
            const desired_col: u16 = 1 + prompt_width + before_width;
            const max_col = win.width -| 1;
            win.showCursor(@min(desired_col, max_col), 3);
        }

        try renderGlobalFooter(ui, win, "Enter search | Esc back", null);

        if (error_text) |txt| {
            const err_segments = [_]vaxis.Segment{.{ .text = txt, .style = ui.styleError() }};
            _ = win.print(&err_segments, .{ .row_offset = 7, .col_offset = 1, .wrap = .none });
        }

        try ui.render();

        const event = ui.loop.nextEvent();
        switch (event) {
            .winsize => |ws| try ui.resize(ws),
            .key_press => |key| {
                switch (handleGlobalKey(ui, key, true)) {
                    .none => {},
                    .consumed => continue,
                    .to_query => {},
                    .quit => return .quit,
                }

                if (key.matches(vaxis.Key.escape, .{})) {
                    return .back;
                }

                if (key.matches(vaxis.Key.enter, .{})) {
                    if (query.items.len == 0) {
                        error_text = "Query cannot be empty.";
                    } else {
                        return .{ .submit = try query.toOwnedSlice(ui.allocator) };
                    }
                } else if (key.matches(vaxis.Key.left, .{})) {
                    cursor_pos = prevCodepointStart(query.items, cursor_pos);
                } else if (key.matches(vaxis.Key.right, .{})) {
                    cursor_pos = nextCodepointEnd(query.items, cursor_pos);
                } else if (key.matches(vaxis.Key.backspace, .{})) {
                    if (cursor_pos > 0) {
                        const prev = prevCodepointStart(query.items, cursor_pos);
                        query.replaceRangeAssumeCapacity(prev, cursor_pos - prev, "");
                        cursor_pos = prev;
                    }
                    error_text = null;
                } else if (key.matches(vaxis.Key.delete, .{})) {
                    if (cursor_pos < query.items.len) {
                        const next = nextCodepointEnd(query.items, cursor_pos);
                        query.replaceRangeAssumeCapacity(cursor_pos, next - cursor_pos, "");
                    }
                    error_text = null;
                } else if (isTextKey(key)) {
                    const text = key.text.?;
                    if (query.items.len + text.len <= max_len) {
                        try query.insertSlice(ui.allocator, cursor_pos, text);
                        cursor_pos += text.len;
                        error_text = null;
                    }
                }
            },
            else => {},
        }
    }
}

fn vaxisSelect(
    ui: *Ui,
    title: []const u8,
    hint: []const u8,
    options: []const []const u8,
    default_idx: ?usize,
    enabled: ?[]const bool,
    page_nav: ?PageNav,
) !SelectResult {
    if (options.len == 0) return error.NoData;
    if (enabled) |flags| {
        if (flags.len != options.len) return error.InvalidFieldType;
    }

    var filter: std.ArrayList(u8) = .empty;
    defer filter.deinit(ui.allocator);

    var matches: std.ArrayList(usize) = .empty;
    defer matches.deinit(ui.allocator);

    try rebuildOptionMatches(ui.allocator, options, filter.items, &matches);

    var selected_row: usize = 0;
    if (default_idx) |idx| {
        if (idx < options.len) {
            selected_row = findIndexInMatches(matches.items, idx) orelse 0;
        }
    }

    var scroll: usize = 0;
    var filter_mode = false;

    while (true) {
        const win = ui.vx.window();
        win.clear();
        win.hideCursor();

        const title_segments = [_]vaxis.Segment{.{ .text = title, .style = ui.styleTitle() }};
        _ = win.print(&title_segments, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });

        const hint_segments = [_]vaxis.Segment{.{ .text = hint }};
        _ = win.print(&hint_segments, .{ .row_offset = 1, .col_offset = 1, .wrap = .none });
        try renderContextLine(ui, win, 2);

        const list_top: u16 = if (ui.context_line != null) 4 else 3;
        const footer_rows: u16 = 4;
        const list_bottom: u16 = if (win.height > footer_rows) win.height - footer_rows else win.height;
        const page_size: usize = if (list_bottom > list_top)
            @intCast(list_bottom - list_top)
        else
            1;

        clampSelection(&selected_row, matches.items.len);
        moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
        ensureVisible(selected_row, &scroll, page_size);

        var row = list_top;
        var i = scroll;
        while (i < matches.items.len and row < list_bottom) : (i += 1) {
            const option_idx = matches.items[i];
            const active = i == selected_row;
            const is_enabled = isOptionEnabled(enabled, option_idx);
            const style = if (!is_enabled)
                ui.styleMuted()
            else if (active)
                ui.styleSelected()
            else
                vaxis.Style{};
            const prefix = if (active) "> " else "  ";

            const list_width: usize = if (win.width > 2) @intCast(win.width - 2) else 0;
            const prefix_width: usize = 2;
            const text_width = list_width -| prefix_width;

            try printFitted(ui, win, row, 1, prefix, style, prefix_width);
            try printFitted(ui, win, row, 3, options[option_idx], style, text_width);

            row += 1;
        }

        if (matches.items.len == 0) {
            const empty_segments = [_]vaxis.Segment{.{ .text = "No matches. Edit filter and try again.", .style = ui.styleWarn() }};
            _ = win.print(&empty_segments, .{ .row_offset = list_top, .col_offset = 1, .wrap = .none });
        }

        const mode_text = if (filter_mode) "FILTER MODE" else "NAV MODE";
        var filter_buf: [384]u8 = undefined;
        const filter_line = std.fmt.bufPrint(&filter_buf, "Filter: {s}  [{s}]", .{ filter.items, mode_text }) catch "Filter: (overflow)";

        const can_page = if (page_nav) |pn| pn.enabled else false;
        const help_line = if (filter_mode)
            "Type to filter | Enter done | Esc exit | Backspace delete"
        else if (can_page)
            "j/k move | Enter select | [ prev page | ] next page | / filter | Esc back"
        else
            "j/k or arrows move | Enter select | / filter | Esc back";

        var count_buf: [96]u8 = undefined;
        const count_line = if (can_page)
            std.fmt.bufPrint(&count_buf, "Visible: {d}/{d} | Page: {d}", .{ matches.items.len, options.len, page_nav.?.page }) catch "Visible: ?"
        else
            std.fmt.bufPrint(&count_buf, "Visible: {d}/{d}", .{ matches.items.len, options.len }) catch "Visible: ?";

        try renderGlobalFooter(ui, win, help_line, count_line);

        const filter_segments = [_]vaxis.Segment{.{ .text = filter_line, .style = ui.styleMuted() }};
        const filter_row: u16 = if (win.height > 2) win.height - 2 else 0;
        _ = win.print(&filter_segments, .{ .row_offset = filter_row, .col_offset = 1, .wrap = .none });

        try ui.render();

        const event = ui.loop.nextEvent();
        switch (event) {
            .winsize => |ws| try ui.resize(ws),
            .key_press => |key| {
                switch (handleGlobalKey(ui, key, false)) {
                    .none => {},
                    .consumed => continue,
                    .to_query => return .to_query,
                    .quit => return .quit,
                }

                if (filter_mode) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.enter, .{})) {
                        filter_mode = false;
                        continue;
                    }
                    if (key.matches(vaxis.Key.backspace, .{})) {
                        _ = filter.pop();
                        try rebuildOptionMatches(ui.allocator, options, filter.items, &matches);
                        selected_row = 0;
                        scroll = 0;
                        continue;
                    }
                    if (key.matches('u', .{ .ctrl = true })) {
                        filter.clearRetainingCapacity();
                        try rebuildOptionMatches(ui.allocator, options, filter.items, &matches);
                        selected_row = 0;
                        scroll = 0;
                        continue;
                    }
                    if (isTextKey(key)) {
                        try filter.appendSlice(ui.allocator, key.text.?);
                        try rebuildOptionMatches(ui.allocator, options, filter.items, &matches);
                        selected_row = 0;
                        scroll = 0;
                    }
                    continue;
                }

                if (key.matches(vaxis.Key.escape, .{})) return .back;
                if (can_page and key.matches('[', .{})) return .page_prev;
                if (can_page and key.matches(']', .{})) return .page_next;
                if (key.matches('/', .{})) {
                    filter_mode = true;
                    continue;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (matches.items.len > 0 and isOptionEnabled(enabled, matches.items[selected_row])) {
                        return .{ .selected = matches.items[selected_row] };
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                    if (selected_row + 1 < matches.items.len) selected_row += 1;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
                    continue;
                }
                if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                    if (selected_row > 0) selected_row -= 1;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .backward);
                    continue;
                }
                if (key.matches(vaxis.Key.page_down, .{}) or key.matches(vaxis.Key.space, .{})) {
                    const win_now = ui.vx.window();
                    const page_now: usize = if (win_now.height > 7) @intCast(win_now.height - 7) else 1;
                    if (matches.items.len > 0) {
                        selected_row = @min(matches.items.len - 1, selected_row + page_now);
                        moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.page_up, .{}) or key.matches('b', .{})) {
                    const win_now = ui.vx.window();
                    const page_now: usize = if (win_now.height > 7) @intCast(win_now.height - 7) else 1;
                    selected_row = selected_row -| page_now;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .backward);
                    continue;
                }
                if (key.matches('g', .{})) {
                    selected_row = 0;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
                    continue;
                }
                if (key.matches('G', .{}) or key.matches('g', .{ .shift = true })) {
                    if (matches.items.len > 0) selected_row = matches.items.len - 1;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .backward);
                    continue;
                }
            },
            else => {},
        }
    }
}

fn vaxisSelectSubtitle(
    ui: *Ui,
    title: []const u8,
    hint: []const u8,
    subtitles: []const app.SubtitleChoice,
    enabled: []const bool,
    page_nav: ?PageNav,
) !SelectResult {
    if (subtitles.len == 0) return error.NoData;
    if (enabled.len != subtitles.len) return error.InvalidFieldType;

    var sort_mode: SubtitleSort = .relevance;
    var order = try buildSubtitleOrder(ui.allocator, subtitles, sort_mode);
    defer ui.allocator.free(order);

    var filter: std.ArrayList(u8) = .empty;
    defer filter.deinit(ui.allocator);

    var matches: std.ArrayList(usize) = .empty;
    defer matches.deinit(ui.allocator);

    try rebuildSubtitleMatches(ui.allocator, subtitles, order, filter.items, &matches);

    var selected_row: usize = 0;
    var scroll: usize = 0;
    var filter_mode = false;

    while (true) {
        const win = ui.vx.window();
        win.clear();
        win.hideCursor();

        const show_pane = win.width >= 96;
        const left_width: u16 = if (show_pane) @max(@as(u16, 36), (win.width * 58) / 100) else win.width;
        const pane_col: u16 = left_width + 2;
        const pane_width: usize = if (show_pane and win.width > pane_col + 1) @intCast(win.width - pane_col - 1) else 0;

        const title_segments = [_]vaxis.Segment{.{ .text = title, .style = ui.styleTitle() }};
        _ = win.print(&title_segments, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });

        const hint_segments = [_]vaxis.Segment{.{ .text = hint }};
        _ = win.print(&hint_segments, .{ .row_offset = 1, .col_offset = 1, .wrap = .none });
        try renderContextLine(ui, win, 2);

        const list_top: u16 = if (ui.context_line != null) 4 else 3;
        const footer_rows: u16 = 4;
        const list_bottom: u16 = if (win.height > footer_rows) win.height - footer_rows else win.height;
        const page_size: usize = if (list_bottom > list_top)
            @intCast(list_bottom - list_top)
        else
            1;

        clampSelection(&selected_row, matches.items.len);
        moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
        ensureVisible(selected_row, &scroll, page_size);

        const list_width: usize = if (left_width > 2) @intCast(left_width - 2) else 0;
        const text_width = list_width -| 2;

        var row = list_top;
        var i = scroll;
        while (i < matches.items.len and row < list_bottom) : (i += 1) {
            const sub_idx = matches.items[i];
            const active = i == selected_row;
            const style = if (!enabled[sub_idx])
                ui.styleMuted()
            else if (active)
                ui.styleSelected()
            else
                vaxis.Style{};
            const prefix = if (active) "> " else "  ";

            try printFitted(ui, win, row, 1, prefix, style, 2);
            try printFitted(ui, win, row, 3, subtitles[sub_idx].label, style, text_width);
            row += 1;
        }

        if (matches.items.len == 0) {
            const empty_segments = [_]vaxis.Segment{.{ .text = "No subtitle matches for current filter.", .style = ui.styleWarn() }};
            _ = win.print(&empty_segments, .{ .row_offset = list_top, .col_offset = 1, .wrap = .none });
        }

        if (show_pane) {
            var sep_row: u16 = 0;
            while (sep_row < win.height) : (sep_row += 1) {
                const sep_segments = [_]vaxis.Segment{.{ .text = "|", .style = ui.styleMuted() }};
                _ = win.print(&sep_segments, .{ .row_offset = sep_row, .col_offset = left_width + 1, .wrap = .none });
            }

            const pane_header = [_]vaxis.Segment{.{ .text = "Details", .style = ui.stylePaneTitle() }};
            _ = win.print(&pane_header, .{ .row_offset = 0, .col_offset = pane_col, .wrap = .none });

            if (matches.items.len > 0) {
                const selected_subtitle = subtitles[matches.items[selected_row]];
                try renderSubtitleDetails(ui, win, pane_col, pane_width, selected_subtitle);
            }
        }

        const mode_text = if (filter_mode) "FILTER MODE" else "NAV MODE";
        var sort_buf: [512]u8 = undefined;
        const sort_line = std.fmt.bufPrint(
            &sort_buf,
            "Sort: {s} | Filter: {s}  [{s}]",
            .{ subtitleSortName(sort_mode), filter.items, mode_text },
        ) catch "Sort/Filter: (overflow)";

        const can_page = if (page_nav) |pn| pn.enabled else false;
        const help_line = if (filter_mode)
            "Type to filter | Enter done | Esc exit | Backspace delete"
        else if (can_page)
            "j/k move | Enter select | s sort | [ prev page | ] next page | / filter | Esc back"
        else
            "j/k or arrows move | Enter select | s sort | / filter | Esc back";

        var count_buf: [96]u8 = undefined;
        const count_line = if (can_page)
            std.fmt.bufPrint(&count_buf, "Visible: {d}/{d} | Page: {d}", .{ matches.items.len, subtitles.len, page_nav.?.page }) catch "Visible: ?"
        else
            std.fmt.bufPrint(&count_buf, "Visible: {d}/{d}", .{ matches.items.len, subtitles.len }) catch "Visible: ?";

        try renderGlobalFooter(ui, win, help_line, count_line);

        const filter_segments = [_]vaxis.Segment{.{ .text = sort_line, .style = ui.styleMuted() }};
        const filter_row: u16 = if (win.height > 2) win.height - 2 else 0;
        _ = win.print(&filter_segments, .{ .row_offset = filter_row, .col_offset = 1, .wrap = .none });

        try ui.render();

        const event = ui.loop.nextEvent();
        switch (event) {
            .winsize => |ws| try ui.resize(ws),
            .key_press => |key| {
                switch (handleGlobalKey(ui, key, false)) {
                    .none => {},
                    .consumed => continue,
                    .to_query => return .to_query,
                    .quit => return .quit,
                }

                if (filter_mode) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.enter, .{})) {
                        filter_mode = false;
                        continue;
                    }
                    if (key.matches(vaxis.Key.backspace, .{})) {
                        _ = filter.pop();
                        try rebuildSubtitleMatches(ui.allocator, subtitles, order, filter.items, &matches);
                        selected_row = 0;
                        scroll = 0;
                        continue;
                    }
                    if (key.matches('u', .{ .ctrl = true })) {
                        filter.clearRetainingCapacity();
                        try rebuildSubtitleMatches(ui.allocator, subtitles, order, filter.items, &matches);
                        selected_row = 0;
                        scroll = 0;
                        continue;
                    }
                    if (isTextKey(key)) {
                        try filter.appendSlice(ui.allocator, key.text.?);
                        try rebuildSubtitleMatches(ui.allocator, subtitles, order, filter.items, &matches);
                        selected_row = 0;
                        scroll = 0;
                    }
                    continue;
                }

                if (key.matches(vaxis.Key.escape, .{})) return .back;
                if (can_page and key.matches('[', .{})) return .page_prev;
                if (can_page and key.matches(']', .{})) return .page_next;
                if (key.matches('/', .{})) {
                    filter_mode = true;
                    continue;
                }
                if (key.matches('s', .{})) {
                    sort_mode = nextSortMode(sort_mode);
                    ui.allocator.free(order);
                    order = try buildSubtitleOrder(ui.allocator, subtitles, sort_mode);
                    try rebuildSubtitleMatches(ui.allocator, subtitles, order, filter.items, &matches);
                    selected_row = 0;
                    scroll = 0;
                    continue;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (matches.items.len > 0 and enabled[matches.items[selected_row]]) {
                        return .{ .selected = matches.items[selected_row] };
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                    if (selected_row + 1 < matches.items.len) selected_row += 1;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
                    continue;
                }
                if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                    if (selected_row > 0) selected_row -= 1;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .backward);
                    continue;
                }
                if (key.matches(vaxis.Key.page_down, .{}) or key.matches(vaxis.Key.space, .{})) {
                    const win_now = ui.vx.window();
                    const page_now: usize = if (win_now.height > 7) @intCast(win_now.height - 7) else 1;
                    if (matches.items.len > 0) {
                        selected_row = @min(matches.items.len - 1, selected_row + page_now);
                        moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.page_up, .{}) or key.matches('b', .{})) {
                    const win_now = ui.vx.window();
                    const page_now: usize = if (win_now.height > 7) @intCast(win_now.height - 7) else 1;
                    selected_row = selected_row -| page_now;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .backward);
                    continue;
                }
                if (key.matches('g', .{})) {
                    selected_row = 0;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
                    continue;
                }
                if (key.matches('G', .{}) or key.matches('g', .{ .shift = true })) {
                    if (matches.items.len > 0) selected_row = matches.items.len - 1;
                    moveSelectionToEnabled(matches.items, enabled, &selected_row, .backward);
                    continue;
                }
            },
            else => {},
        }
    }
}

fn vaxisConfirm(ui: *Ui, title: []const u8, lines: []const []const u8) !ConfirmResult {
    while (true) {
        const win = ui.vx.window();
        win.clear();
        win.hideCursor();

        const title_segments = [_]vaxis.Segment{.{ .text = title, .style = ui.styleTitle() }};
        _ = win.print(&title_segments, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
        try renderContextLine(ui, win, 1);

        var row: u16 = 2;
        for (lines) |line| {
            const segs = [_]vaxis.Segment{.{ .text = line }};
            _ = win.print(&segs, .{ .row_offset = row, .col_offset = 1, .wrap = .none });
            row += 1;
        }

        try renderGlobalFooter(ui, win, "Enter confirm | Esc back", null);
        try ui.render();

        const event = ui.loop.nextEvent();
        switch (event) {
            .winsize => |ws| try ui.resize(ws),
            .key_press => |key| {
                switch (handleGlobalKey(ui, key, false)) {
                    .none => {},
                    .consumed => continue,
                    .to_query => return .to_query,
                    .quit => return .quit,
                }

                if (key.matches(vaxis.Key.enter, .{})) return .confirm;
                if (key.matches(vaxis.Key.escape, .{})) return .back;
            },
            else => {},
        }
    }
}

fn vaxisMessage(
    ui: *Ui,
    title: []const u8,
    message: []const u8,
    detail: []const u8,
    title_style: vaxis.Style,
) !MessageResult {
    while (true) {
        const win = ui.vx.window();
        win.clear();
        win.hideCursor();

        const title_segments = [_]vaxis.Segment{.{ .text = title, .style = title_style }};
        _ = win.print(&title_segments, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
        try renderContextLine(ui, win, 1);

        const message_segments = [_]vaxis.Segment{.{ .text = message }};
        _ = win.print(&message_segments, .{ .row_offset = 2, .col_offset = 1, .wrap = .none });

        const detail_segments = [_]vaxis.Segment{.{ .text = detail, .style = ui.styleMuted() }};
        _ = win.print(&detail_segments, .{ .row_offset = 4, .col_offset = 1, .wrap = .none });

        try renderGlobalFooter(ui, win, "Press any key to continue", null);
        try ui.render();

        const event = ui.loop.nextEvent();
        switch (event) {
            .winsize => |ws| try ui.resize(ws),
            .key_press => |key| {
                switch (handleGlobalKey(ui, key, false)) {
                    .none => {},
                    .consumed => continue,
                    .to_query => return .to_query,
                    .quit => return .quit,
                }
                return .ok;
            },
            else => {},
        }
    }
}

fn renderGlobalFooter(ui: *Ui, win: anytype, help_line: []const u8, extra_right: ?[]const u8) !void {
    const row_help: u16 = if (win.height > 3) win.height - 3 else 0;
    const row_status: u16 = if (win.height > 1) win.height - 1 else 0;

    const help_segments = [_]vaxis.Segment{.{ .text = help_line, .style = ui.styleMuted() }};
    _ = win.print(&help_segments, .{ .row_offset = row_help, .col_offset = 1, .wrap = .none });

    const confirm_text = if (ui.skip_confirm) "F2 confirm:off" else "F2 confirm:on";
    const status_segments = [_]vaxis.Segment{
        .{ .text = confirm_text, .style = ui.styleMuted() },
        .{ .text = "  ", .style = ui.styleMuted() },
        .{ .text = "F3 theme:", .style = ui.styleMuted() },
        .{ .text = ui.theme().name, .style = ui.styleMuted() },
        .{ .text = "  Ctrl+D quit", .style = ui.styleMuted() },
    };
    _ = win.print(&status_segments, .{ .row_offset = row_status, .col_offset = 1, .wrap = .none });

    if (extra_right) |text| {
        const base_len = confirm_text.len + "  F3 theme:".len + ui.theme().name.len + "  Ctrl+D quit".len + 2;
        const col: u16 = if (win.width > base_len + 1) @intCast(base_len) else 1;
        const right_segments = [_]vaxis.Segment{.{ .text = text, .style = ui.styleMuted() }};
        _ = win.print(&right_segments, .{ .row_offset = row_status, .col_offset = col, .wrap = .none });
    }
}

fn renderContextLine(ui: *Ui, win: anytype, row: u16) !void {
    const context = ui.context_line orelse return;
    const width: usize = if (win.width > 2) @intCast(win.width - 2) else 0;
    try printFitted(ui, win, row, 1, context, ui.styleMuted(), width);
}

const KeyAction = enum {
    none,
    consumed,
    to_query,
    quit,
};

fn handleGlobalKey(ui: *Ui, key: vaxis.Key, is_query_screen: bool) KeyAction {
    if (key.matches('d', .{ .ctrl = true })) return .quit;
    if (key.matches('c', .{ .ctrl = true })) {
        return if (is_query_screen) .quit else .to_query;
    }
    if (key.matches(vaxis.Key.f2, .{})) {
        ui.toggleConfirm();
        return .consumed;
    }
    if (key.matches(vaxis.Key.f3, .{})) {
        ui.toggleTheme();
        return .consumed;
    }
    return .none;
}

fn isTextKey(key: vaxis.Key) bool {
    if (key.text == null) return false;
    if (key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.meta or key.mods.hyper) return false;
    if (key.matches(vaxis.Key.enter, .{})) return false;
    if (key.matches(vaxis.Key.tab, .{})) return false;
    return key.text.?.len > 0;
}

fn prevCodepointStart(text: []const u8, cursor_pos: usize) usize {
    if (cursor_pos == 0) return 0;
    var i = cursor_pos - 1;
    while (i > 0 and (text[i] & 0b1100_0000) == 0b1000_0000) : (i -= 1) {}
    return i;
}

fn nextCodepointEnd(text: []const u8, cursor_pos: usize) usize {
    if (cursor_pos >= text.len) return text.len;
    const byte = text[cursor_pos];
    const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
    const next = cursor_pos + seq_len;
    return if (next <= text.len) next else cursor_pos + 1;
}

fn clampSelection(selected: *usize, total: usize) void {
    if (total == 0) {
        selected.* = 0;
        return;
    }
    if (selected.* >= total) selected.* = total - 1;
}

fn ensureVisible(selected: usize, scroll: *usize, page_size: usize) void {
    if (selected < scroll.*) scroll.* = selected;
    if (selected >= scroll.* + page_size) {
        scroll.* = selected - page_size + 1;
    }
}

fn isOptionEnabled(enabled: anytype, option_idx: usize) bool {
    if (@TypeOf(enabled) == ?[]const bool) {
        if (enabled) |flags| return flags[option_idx];
        return true;
    }
    if (@TypeOf(enabled) == []const bool) {
        return enabled[option_idx];
    }
    return true;
}

const SearchDirection = enum {
    forward,
    backward,
};

fn moveSelectionToEnabled(
    matches: []const usize,
    enabled: anytype,
    selected_row: *usize,
    direction: SearchDirection,
) void {
    if (matches.len == 0) return;

    if (isOptionEnabled(enabled, matches[selected_row.*])) return;

    switch (direction) {
        .forward => {
            var i = selected_row.* + 1;
            while (i < matches.len) : (i += 1) {
                if (isOptionEnabled(enabled, matches[i])) {
                    selected_row.* = i;
                    return;
                }
            }
            var j: usize = selected_row.*;
            while (j > 0) {
                j -= 1;
                if (isOptionEnabled(enabled, matches[j])) {
                    selected_row.* = j;
                    return;
                }
            }
        },
        .backward => {
            var i: usize = selected_row.*;
            while (i > 0) {
                i -= 1;
                if (isOptionEnabled(enabled, matches[i])) {
                    selected_row.* = i;
                    return;
                }
            }
            var j = selected_row.* + 1;
            while (j < matches.len) : (j += 1) {
                if (isOptionEnabled(enabled, matches[j])) {
                    selected_row.* = j;
                    return;
                }
            }
        },
    }
}

fn rebuildOptionMatches(
    allocator: std.mem.Allocator,
    options: []const []const u8,
    filter: []const u8,
    out: *std.ArrayList(usize),
) !void {
    out.clearRetainingCapacity();
    for (options, 0..) |opt, idx| {
        if (filter.len == 0 or containsCaseInsensitive(opt, filter)) {
            try out.append(allocator, idx);
        }
    }
}

fn findIndexInMatches(matches: []const usize, target: usize) ?usize {
    for (matches, 0..) |idx, row| {
        if (idx == target) return row;
    }
    return null;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var ok = true;
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn printFitted(
    ui: *Ui,
    win: anytype,
    row: u16,
    col: u16,
    text: []const u8,
    style: vaxis.Style,
    max_width: usize,
) !void {
    if (max_width == 0) return;

    var display_text = text;
    var owned_sanitized: ?[]u8 = null;
    defer if (owned_sanitized) |buf| ui.allocator.free(buf);

    if (needsUtfSanitizeForDisplay(text)) {
        const sanitized = try sanitizeUtf8ForDisplay(ui.allocator, text);
        owned_sanitized = sanitized;
        display_text = sanitized;
    }

    if (win.gwidth(display_text) <= max_width) {
        const segs = [_]vaxis.Segment{.{ .text = display_text, .style = style }};
        _ = win.print(&segs, .{ .row_offset = row, .col_offset = col, .wrap = .none });
        return;
    }

    if (max_width <= 3) {
        const prefix = utf8PrefixForDisplayWidth(win, display_text, max_width);
        const segs = [_]vaxis.Segment{.{ .text = prefix, .style = style }};
        _ = win.print(&segs, .{ .row_offset = row, .col_offset = col, .wrap = .none });
        return;
    }

    const prefix = utf8PrefixForDisplayWidth(win, display_text, max_width - 3);
    const segs = [_]vaxis.Segment{
        .{ .text = prefix, .style = style },
        .{ .text = "...", .style = style },
    };
    _ = win.print(&segs, .{ .row_offset = row, .col_offset = col, .wrap = .none });
}

fn needsUtfSanitizeForDisplay(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return true;
    for (text) |b| {
        if ((b < 0x20 and b != '\n' and b != '\r' and b != '\t') or b == 0x7F) return true;
    }
    return false;
}

fn sanitizeUtf8ForDisplay(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const first = input[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(first) catch {
            try appendHexEscape(allocator, &out, first);
            i += 1;
            continue;
        };
        if (i + seq_len > input.len) {
            try appendHexEscape(allocator, &out, first);
            i += 1;
            continue;
        }

        const segment = input[i .. i + seq_len];
        _ = std.unicode.utf8Decode(segment) catch {
            try appendHexEscape(allocator, &out, first);
            i += 1;
            continue;
        };

        if (seq_len == 1 and (first < 0x20 or first == 0x7F)) {
            switch (first) {
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => try appendHexEscape(allocator, &out, first),
            }
            i += 1;
            continue;
        }

        try out.appendSlice(allocator, segment);
        i += seq_len;
    }

    return try out.toOwnedSlice(allocator);
}

fn appendHexEscape(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: u8) !void {
    const hex = "0123456789ABCDEF";
    try out.appendSlice(allocator, &.{ '\\', 'x', hex[value >> 4], hex[value & 0x0F] });
}

fn utf8PrefixForDisplayWidth(win: anytype, text: []const u8, max_width: usize) []const u8 {
    if (max_width == 0 or text.len == 0) return text[0..0];

    var idx: usize = 0;
    var best: usize = 0;

    while (idx < text.len) {
        const seq_len_raw = std.unicode.utf8ByteSequenceLength(text[idx]) catch break;
        const seq_len: usize = @intCast(seq_len_raw);
        if (idx + seq_len > text.len) break;

        _ = std.unicode.utf8Decode(text[idx .. idx + seq_len]) catch break;

        const next = idx + seq_len;
        if (win.gwidth(text[0..next]) > max_width) break;

        best = next;
        idx = next;
    }

    return text[0..best];
}

test "utf8PrefixForDisplayWidth does not split utf8 sequences" {
    const FakeWin = struct {
        pub fn gwidth(_: @This(), s: []const u8) usize {
            return std.unicode.utf8CountCodepoints(s) catch s.len;
        }
    };

    const win = FakeWin{};
    const text = "Српски Matrix";

    const prefix = utf8PrefixForDisplayWidth(win, text, 3);
    try std.testing.expect(std.unicode.utf8ValidateSlice(prefix));
    try std.testing.expectEqual(@as(usize, 3), std.unicode.utf8CountCodepoints(prefix) catch 0);

    const full = utf8PrefixForDisplayWidth(win, text, 64);
    try std.testing.expectEqualStrings(text, full);
}

test "sanitizeUtf8ForDisplay escapes invalid bytes" {
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 'A', 0xAA, 'B', 0xFF };
    const safe = try sanitizeUtf8ForDisplay(allocator, &raw);
    defer allocator.free(safe);

    try std.testing.expectEqualStrings("A\\xAAB\\xFF", safe);
    try std.testing.expect(std.unicode.utf8ValidateSlice(safe));
}

fn subtitleSortName(mode: SubtitleSort) []const u8 {
    return switch (mode) {
        .relevance => "relevance",
        .language => "language",
        .filename => "filename",
        .available => "available",
        .label => "label",
    };
}

fn nextSortMode(mode: SubtitleSort) SubtitleSort {
    return switch (mode) {
        .relevance => .language,
        .language => .filename,
        .filename => .available,
        .available => .label,
        .label => .relevance,
    };
}

fn buildSubtitleOrder(
    allocator: std.mem.Allocator,
    subtitles: []const app.SubtitleChoice,
    mode: SubtitleSort,
) ![]usize {
    const order = try allocator.alloc(usize, subtitles.len);
    for (order, 0..) |*slot, idx| slot.* = idx;

    if (mode == .relevance) return order;

    const Ctx = struct {
        subtitles: []const app.SubtitleChoice,
        mode: SubtitleSort,
    };

    const lessThan = struct {
        fn f(ctx: Ctx, lhs: usize, rhs: usize) bool {
            const a = ctx.subtitles[lhs];
            const b = ctx.subtitles[rhs];

            switch (ctx.mode) {
                .language => {
                    const ord = compareOptionalCaseInsensitive(a.language, b.language);
                    if (ord == .eq) return compareCaseInsensitive(a.label, b.label) == .lt;
                    return ord == .lt;
                },
                .filename => {
                    const ord = compareOptionalCaseInsensitive(a.filename, b.filename);
                    if (ord == .eq) return compareCaseInsensitive(a.label, b.label) == .lt;
                    return ord == .lt;
                },
                .available => {
                    const a_direct = a.download_url != null;
                    const b_direct = b.download_url != null;
                    if (a_direct != b_direct) return a_direct and !b_direct;
                    return compareCaseInsensitive(a.label, b.label) == .lt;
                },
                .label => return compareCaseInsensitive(a.label, b.label) == .lt,
                .relevance => return lhs < rhs,
            }
        }
    }.f;

    std.mem.sort(usize, order, Ctx{ .subtitles = subtitles, .mode = mode }, lessThan);
    return order;
}

fn compareOptionalCaseInsensitive(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    return compareCaseInsensitive(a orelse "", b orelse "");
}

fn compareCaseInsensitive(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca < cb) return .lt;
        if (ca > cb) return .gt;
    }
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

fn rebuildSubtitleMatches(
    allocator: std.mem.Allocator,
    subtitles: []const app.SubtitleChoice,
    order: []const usize,
    filter: []const u8,
    out: *std.ArrayList(usize),
) !void {
    out.clearRetainingCapacity();

    for (order) |idx| {
        const subtitle = subtitles[idx];
        if (filter.len == 0 or subtitleMatchesFilter(subtitle, filter)) {
            try out.append(allocator, idx);
        }
    }
}

fn subtitleMatchesFilter(subtitle: app.SubtitleChoice, filter: []const u8) bool {
    if (containsCaseInsensitive(subtitle.label, filter)) return true;
    if (subtitle.language) |lang| {
        if (containsCaseInsensitive(lang, filter)) return true;
    }
    if (subtitle.filename) |name| {
        if (containsCaseInsensitive(name, filter)) return true;
    }
    if (subtitle.download_url) |url| {
        if (containsCaseInsensitive(url, filter)) return true;
    }
    return false;
}

fn renderSubtitleDetails(
    ui: *Ui,
    win: anytype,
    col: u16,
    pane_width: usize,
    subtitle: app.SubtitleChoice,
) !void {
    if (pane_width == 0) return;

    var row: u16 = 2;
    const max_row: u16 = if (win.height > 4) win.height - 4 else win.height;

    try printFitted(ui, win, row, col, subtitle.label, ui.stylePaneTitle(), pane_width);
    row += 2;

    if (row >= max_row) return;
    try printLabelValue(ui, win, row, col, pane_width, "Download: ", if (subtitle.download_url != null) "direct" else "no direct url");
    row += 1;

    if (row >= max_row) return;
    try printLabelValue(ui, win, row, col, pane_width, "Language: ", subtitle.language orelse "(unknown)");
    row += 1;

    if (row >= max_row) return;
    try printLabelValue(ui, win, row, col, pane_width, "Filename: ", subtitle.filename orelse "(unknown)");
    row += 1;

    if (row >= max_row) return;
    try printFitted(ui, win, row, col, "URL:", ui.styleAccent(), pane_width);
    row += 1;

    if (row >= max_row) return;
    try printFitted(ui, win, row, col, subtitle.download_url orelse "(not available)", .{}, pane_width);
}

fn printLabelValue(
    ui: *Ui,
    win: anytype,
    row: u16,
    col: u16,
    max_width: usize,
    label: []const u8,
    value: []const u8,
) !void {
    if (max_width == 0) return;
    if (label.len >= max_width) {
        try printFitted(ui, win, row, col, label, .{}, max_width);
        return;
    }

    try printFitted(ui, win, row, col, label, .{}, label.len);
    const value_col: u16 = col + @as(u16, @intCast(label.len));
    const remaining = max_width - label.len;
    try printFitted(ui, win, row, value_col, value, .{}, remaining);
}

fn freeOwnedStrings(allocator: std.mem.Allocator, strings: [][]u8) void {
    for (strings) |s| allocator.free(s);
    allocator.free(strings);
}
