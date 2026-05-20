const std = @import("std");
const scrapers = @import("scrapers");
const vaxis = @import("vaxis");
const builtin = @import("builtin");
const runtime_alloc = @import("runtime_alloc");
const runtime_io = @import("runtime_io");
const oneserial = @import("oneserial");

const app = scrapers.providers_app;

pub const panic = std.debug.FullPanic(tuiPanic);

fn tuiPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    restoreTerminalOnPanic();
    std.debug.defaultPanic(msg, ret_addr);
}

fn restoreTerminalOnPanic() void {
    vaxis.recover();
}

const hard_cancel_supported = std.Thread.use_pthreads and switch (builtin.os.tag) {
    .linux, .macos, .ios, .watchos, .tvos, .visionos, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => true,
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
    mouse: vaxis.Mouse,
    mouse_leave,
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

const OpenResult = enum {
    back,
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

const SearchSource = enum {
    live,
    cache,
};

const CombinedSearchHit = struct {
    provider: app.Provider,
    response_index: usize,
    item_index: usize,
    source: SearchSource = .live,
};

const CachedSearchResponse = struct {
    provider: app.Provider,
    items: []const app.SearchChoice,
    page: u32,
    has_prev_page: bool,
    has_next_page: bool,
};

const QueryCacheEntry = struct {
    provider: app.Provider,
    query_norm: []const u8,
    page: u32,
    fetched_at_unix: i64,
    response: CachedSearchResponse,
};

const KeywordEntry = struct {
    query: []const u8,
    used_at_unix: i64,
    use_count: u32,
};

const TuiSettings = struct {
    providers_enabled: [app.providerCount()]bool,
    cache_enabled: bool,
    cache_ttl_seconds: i64,
    keyword_cache_enabled: bool,
};

const PersistentSearchState = struct {
    version: u32,
    settings: TuiSettings,
    cache_entries: []const QueryCacheEntry,
};

const PersistentKeywordState = struct {
    version: u32,
    keywords: []const KeywordEntry,
};

const TuiRuntimeState = struct {
    arena: std.heap.ArenaAllocator,
    settings: TuiSettings,
    cache_entries: std.ArrayListUnmanaged(QueryCacheEntry) = .empty,
    keywords: std.ArrayListUnmanaged(KeywordEntry) = .empty,
    state_path: []u8,
    keyword_path: []u8,

    fn deinit(self: *TuiRuntimeState, allocator: std.mem.Allocator) void {
        self.cache_entries.deinit(allocator);
        self.keywords.deinit(allocator);
        allocator.free(self.state_path);
        allocator.free(self.keyword_path);
        self.arena.deinit();
        self.* = undefined;
    }
};

const QueryFocus = enum {
    query,
    results,
};

const SearchBundle = struct {
    query_norm: []u8,
    searches: std.ArrayListUnmanaged(app.SearchResponse) = .empty,
    hits: std.ArrayListUnmanaged(CombinedSearchHit) = .empty,
    labels: [][]u8 = &.{},
    live_count: usize = 0,
    cache_count: usize = 0,
    failed_count: usize = 0,

    fn deinit(self: *SearchBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.query_norm);
        for (self.searches.items) |*search| search.deinit();
        self.searches.deinit(allocator);
        self.hits.deinit(allocator);
        if (self.labels.len > 0) freeOwnedStrings(allocator, self.labels);
        self.* = undefined;
    }
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
    phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(app.DownloadPhase.idle)),
    phase_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    phase_total: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    err: ?anyerror = null,
    result: ?app.DownloadResult = null,
};

const Ui = struct {
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(Event),
    frame_arena: std.heap.ArenaAllocator,
    theme_index: usize = 0,
    skip_confirm: bool = false,
    context_line: ?[]const u8 = null,
    context_owned: ?[]u8 = null,
    active_provider: ?app.Provider = null,
    provider_enabled: [app.providerCount()]bool = app.providerSelectionNone(),

    fn writer(self: *Ui) *std.Io.Writer {
        return self.tty.writer();
    }

    fn resize(self: *Ui, ws: vaxis.Winsize) !void {
        try self.vx.resize(self.allocator, self.writer(), ws);
    }

    fn render(self: *Ui) !void {
        try self.vx.render(self.writer());
        try self.writer().flush();
        _ = self.frame_arena.reset(.retain_capacity);
    }

    fn frameAllocator(self: *Ui) std.mem.Allocator {
        return self.frame_arena.allocator();
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

    fn providerPanelVisible(_: *Ui, width: u16) bool {
        return width >= 92;
    }
};

pub fn main(init: std.process.Init) !void {
    var allocator_state = runtime_alloc.RuntimeAllocator.init();
    defer allocator_state.deinit();
    const allocator = allocator_state.allocator();

    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(runtime_io.get(), &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(runtime_io.get(), allocator, init.environ_map, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .init(runtime_io.get(), &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try vx.setMouseMode(tty.writer(), true);
    defer vx.setMouseMode(tty.writer(), false) catch {};

    var ui: Ui = .{
        .allocator = allocator,
        .environ_map = init.environ_map,
        .tty = &tty,
        .vx = &vx,
        .loop = &loop,
        .frame_arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer ui.frame_arena.deinit();

    try runTui(&ui);
}

fn searchTaskMain(task: *SearchTask) void {
    configureWorkerHardCancel();
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = runtime_io.get() };
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
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = runtime_io.get() };
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
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = runtime_io.get() };
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
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = runtime_io.get() };
    defer client.deinit();

    const progress = app.DownloadProgress{
        .user_data = task,
        .on_phase = onDownloadProgressPhase,
        .on_units = onDownloadProgressUnits,
    };

    task.result = app.downloadSubtitleWithProgressAndOptions(std.heap.page_allocator, &client, task.subtitle, task.out_dir, &progress, .{}) catch |err| {
        task.err = err;
        task.done.store(1, .release);
        return;
    };
    task.done.store(1, .release);
}

fn onDownloadProgressPhase(user_data: ?*anyopaque, phase: app.DownloadPhase) void {
    const task_ptr = user_data orelse return;
    const task: *DownloadTask = @ptrCast(@alignCast(task_ptr));
    task.phase.store(@intFromEnum(phase), .release);
    if (phase != .translating and phase != .translating_fallback) {
        task.phase_done.store(0, .release);
        task.phase_total.store(0, .release);
    }
}

fn onDownloadProgressUnits(user_data: ?*anyopaque, done: usize, total: usize) void {
    const task_ptr = user_data orelse return;
    const task: *DownloadTask = @ptrCast(@alignCast(task_ptr));
    task.phase_done.store(toU32Saturating(done), .release);
    task.phase_total.store(toU32Saturating(total), .release);
}

fn toU32Saturating(value: usize) u32 {
    if (value > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(value);
}

fn waitForFetch(ui: *Ui, done: *const std.atomic.Value(u8), title: []const u8, detail: []const u8) !FetchControl {
    const spinner = [_][]const u8{ "|", "/", "-", "\\" };
    var spinner_idx: usize = 0;

    while (done.load(.acquire) == 0) {
        var msg_buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&msg_buf, "Fetching... {s}", .{spinner[spinner_idx % spinner.len]}) catch "Fetching...";

        try vaxisStatus(ui, title, message, detail);

        while (try ui.loop.tryEvent()) |event| {
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
        try runtime_io.get().sleep(.fromMilliseconds(90), .awake);
    }
    return .completed;
}

fn waitForTask(ui: *Ui, done: *const std.atomic.Value(u8), title: []const u8, detail: []const u8) !FetchControl {
    return waitForFetch(ui, done, title, detail);
}

fn waitForDownloadTask(ui: *Ui, task: *const DownloadTask, title: []const u8, detail: []const u8) !FetchControl {
    const spinner = [_][]const u8{ "|", "/", "-", "\\" };
    var spinner_idx: usize = 0;

    while (task.done.load(.acquire) == 0) {
        const phase_raw = task.phase.load(.acquire);
        const phase = downloadPhaseFromRaw(phase_raw);
        const done = task.phase_done.load(.acquire);
        const total = task.phase_total.load(.acquire);

        var message_buf: [256]u8 = undefined;
        var progress_buf: [20]u8 = undefined;
        const progress_bar = formatDownloadProgressBar(&progress_buf, done, total);
        const message = if ((phase == .translating or phase == .translating_fallback) and total > 0)
            std.fmt.bufPrint(
                &message_buf,
                "{s} {d}/{d} {s} {s}",
                .{ downloadPhaseLabel(phase), done, total, progress_bar, spinner[spinner_idx % spinner.len] },
            ) catch "Downloading..."
        else
            std.fmt.bufPrint(
                &message_buf,
                "{s} {s}",
                .{ downloadPhaseLabel(phase), spinner[spinner_idx % spinner.len] },
            ) catch "Downloading...";

        try vaxisStatus(ui, title, message, detail);

        while (try ui.loop.tryEvent()) |event| {
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
        try runtime_io.get().sleep(.fromMilliseconds(90), .awake);
    }

    return .completed;
}

fn downloadPhaseLabel(phase: app.DownloadPhase) []const u8 {
    return switch (phase) {
        .idle => "Preparing",
        .resolving_url => "Resolving URL",
        .fetching_source => "Fetching source",
        .downloading_file => "Downloading file",
        .translating => "Translating",
        .translating_fallback => "Translating fallback",
        .writing_output => "Writing output",
        .extracting_archive => "Extracting archive",
    };
}

fn downloadPhaseFromRaw(raw: u8) app.DownloadPhase {
    return switch (raw) {
        @intFromEnum(app.DownloadPhase.idle) => .idle,
        @intFromEnum(app.DownloadPhase.resolving_url) => .resolving_url,
        @intFromEnum(app.DownloadPhase.fetching_source) => .fetching_source,
        @intFromEnum(app.DownloadPhase.downloading_file) => .downloading_file,
        @intFromEnum(app.DownloadPhase.translating) => .translating,
        @intFromEnum(app.DownloadPhase.translating_fallback) => .translating_fallback,
        @intFromEnum(app.DownloadPhase.writing_output) => .writing_output,
        @intFromEnum(app.DownloadPhase.extracting_archive) => .extracting_archive,
        else => .idle,
    };
}

fn formatDownloadProgressBar(buf: *[20]u8, done: u32, total: u32) []const u8 {
    const width: u32 = 14;
    const filled = if (total == 0) 0 else @min(width, (done * width) / total);
    buf[0] = '[';
    var i: u32 = 0;
    while (i < width) : (i += 1) {
        buf[i + 1] = if (i < filled) '#' else '-';
    }
    buf[width + 1] = ']';
    return buf[0 .. width + 2];
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

fn runTui(ui: *Ui) !void {
    defer setContext(ui, null);

    var state = try loadTuiRuntimeState(ui.allocator, ui.environ_map);
    defer state.deinit(ui.allocator);
    ui.provider_enabled = state.settings.providers_enabled;

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(ui.allocator);
    var cursor_pos: usize = 0;
    var focus: QueryFocus = .query;
    var selected_result: usize = 0;
    var result_scroll: usize = 0;
    var info_open = false;
    var history_pick: ?usize = null;
    var last_searched_norm: []u8 = try ui.allocator.dupe(u8, "");
    defer ui.allocator.free(last_searched_norm);
    var results: ?SearchBundle = null;
    defer if (results) |*bundle| bundle.deinit(ui.allocator);

    while (true) {
        ui.provider_enabled = state.settings.providers_enabled;
        const query_norm_view = normalizeQueryView(query.items);
        const query_dirty = !std.mem.eql(u8, query_norm_view, last_searched_norm);
        try renderQueryHome(ui, &state, query.items, cursor_pos, focus, query_dirty, if (results) |*b| b else null, selected_result, result_scroll, info_open);

        const event = try ui.loop.nextEvent();
        switch (event) {
            .winsize => |ws| try ui.resize(ws),
            .mouse => |mouse| {
                if (results) |*bundle| {
                    if (mouse.type == .press and bundle.hits.items.len > 0) switch (mouse.button) {
                        .wheel_down => {
                            selected_result = @min(bundle.hits.items.len - 1, selected_result + 3);
                            focus = .results;
                        },
                        .wheel_up => {
                            selected_result = selected_result -| 3;
                            focus = .results;
                        },
                        else => {},
                    };
                    if (focus == .results) {
                        focus = .results;
                    }
                }
            },
            .key_press => |key| {
                switch (handleGlobalKey(ui, key, true)) {
                    .none => {},
                    .consumed => continue,
                    .to_query => {},
                    .quit => return,
                }

                if (info_open) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('i', .{}) or key.matches('?', .{})) {
                        info_open = false;
                    }
                    continue;
                }

                if (key.matches('i', .{}) or key.matches('?', .{})) {
                    info_open = true;
                    continue;
                }
                if (key.matches('p', .{})) {
                    try editProviderSettings(ui, &state);
                    try saveTuiRuntimeState(ui.allocator, &state);
                    continue;
                }
                if (key.matches('c', .{})) {
                    state.settings.cache_enabled = !state.settings.cache_enabled;
                    try saveTuiRuntimeState(ui.allocator, &state);
                    continue;
                }
                if (key.matches('t', .{})) {
                    state.settings.cache_ttl_seconds = nextCacheTtlSeconds(state.settings.cache_ttl_seconds);
                    try saveTuiRuntimeState(ui.allocator, &state);
                    continue;
                }
                if (key.matches('k', .{})) {
                    state.settings.keyword_cache_enabled = !state.settings.keyword_cache_enabled;
                    try saveTuiRuntimeState(ui.allocator, &state);
                    continue;
                }
                if (key.matches('K', .{}) or key.matches('k', .{ .shift = true })) {
                    state.keywords.clearRetainingCapacity();
                    try saveKeywordRuntimeState(ui.allocator, &state);
                    continue;
                }
                if (key.matches(vaxis.Key.tab, .{})) {
                    if (results != null and results.?.hits.items.len > 0) {
                        focus = if (focus == .query) .results else .query;
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (focus == .results) {
                        focus = .query;
                    } else if (query.items.len > 0) {
                        query.clearRetainingCapacity();
                        cursor_pos = 0;
                    } else {
                        return;
                    }
                    continue;
                }

                if (focus == .results and !query_dirty) {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        if (results) |*bundle| {
                            if (bundle.hits.items.len > 0) {
                                switch (try openSearchResult(ui, bundle, selected_result)) {
                                    .back, .to_query => focus = .results,
                                    .quit => return,
                                }
                            }
                        }
                        continue;
                    }
                    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                        if (results) |*bundle| {
                            if (selected_result + 1 < bundle.hits.items.len) selected_result += 1;
                        }
                        continue;
                    }
                    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                        if (selected_result > 0) selected_result -= 1;
                        continue;
                    }
                    if (key.matches(vaxis.Key.page_down, .{}) or key.matches(vaxis.Key.space, .{})) {
                        if (results) |*bundle| selected_result = @min(bundle.hits.items.len -| 1, selected_result + 10);
                        continue;
                    }
                    if (key.matches(vaxis.Key.page_up, .{}) or key.matches('b', .{})) {
                        selected_result = selected_result -| 10;
                        continue;
                    }
                    if (key.matches('/', .{})) {
                        focus = .query;
                        continue;
                    }
                }

                focus = .query;
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (query_norm_view.len == 0) continue;
                    if (results) |*bundle| bundle.deinit(ui.allocator);
                    results = null;
                    const owned_query = try ui.allocator.dupe(u8, query_norm_view);
                    defer ui.allocator.free(owned_query);
                    try rememberKeyword(ui.allocator, &state, owned_query);
                    results = executeQuerySearch(ui, &state, owned_query) catch |err| switch (err) {
                        error.TuiQuit => return,
                        else => return err,
                    };
                    ui.allocator.free(last_searched_norm);
                    last_searched_norm = try ui.allocator.dupe(u8, owned_query);
                    selected_result = 0;
                    result_scroll = 0;
                    focus = .results;
                    try saveTuiRuntimeState(ui.allocator, &state);
                    try saveKeywordRuntimeState(ui.allocator, &state);
                    continue;
                }
                if (key.matches(vaxis.Key.up, .{})) {
                    if (try applyHistorySuggestion(ui.allocator, &state, &query, &cursor_pos, .backward, &history_pick)) continue;
                } else if (key.matches(vaxis.Key.down, .{})) {
                    if (try applyHistorySuggestion(ui.allocator, &state, &query, &cursor_pos, .forward, &history_pick)) continue;
                } else if (key.matches(vaxis.Key.left, .{})) {
                    cursor_pos = prevCodepointStart(query.items, cursor_pos);
                } else if (key.matches(vaxis.Key.right, .{})) {
                    cursor_pos = nextCodepointEnd(query.items, cursor_pos);
                } else if (key.matches('a', .{ .ctrl = true })) {
                    cursor_pos = 0;
                } else if (key.matches('e', .{ .ctrl = true })) {
                    cursor_pos = query.items.len;
                } else if (key.matches('u', .{ .ctrl = true })) {
                    query.clearRetainingCapacity();
                    cursor_pos = 0;
                    history_pick = null;
                } else if (key.matches(vaxis.Key.backspace, .{})) {
                    if (cursor_pos > 0) {
                        const prev = prevCodepointStart(query.items, cursor_pos);
                        query.replaceRangeAssumeCapacity(prev, cursor_pos - prev, "");
                        cursor_pos = prev;
                        history_pick = null;
                    }
                } else if (key.matches(vaxis.Key.delete, .{})) {
                    if (cursor_pos < query.items.len) {
                        const next = nextCodepointEnd(query.items, cursor_pos);
                        query.replaceRangeAssumeCapacity(cursor_pos, next - cursor_pos, "");
                        history_pick = null;
                    }
                } else if (isTextKey(key)) {
                    const text = key.text orelse continue;
                    if (query.items.len + text.len <= 180) {
                        try query.insertSlice(ui.allocator, cursor_pos, text);
                        cursor_pos += text.len;
                        history_pick = null;
                    }
                }
            },
            else => {},
        }
    }
}

fn runProviderFirstTui(ui: *Ui) !void {
    defer setContext(ui, null);
    const provider_names = try buildProviderNames(ui.allocator);
    defer freeOwnedStrings(ui.allocator, provider_names);

    var provider_default: ?usize = 0;

    provider_loop: while (true) {
        setContext(ui, "Provider list | URL: choose provider");
        const provider_choice = try vaxisSelect(
            ui,
            "Subtitle Downloader",
            "Space toggles providers. Enter opens highlighted enabled provider. Esc quits.",
            provider_names,
            provider_default,
            null,
            null,
            &ui.provider_enabled,
        );

        const provider_idx = switch (provider_choice) {
            .selected => |idx| idx,
            .back, .to_query, .quit => return,
            .page_prev, .page_next => continue :provider_loop,
        };

        provider_default = provider_idx;
        const selected_provider_count = countEnabledFlags(&ui.provider_enabled);
        if (selected_provider_count > 1) {
            // Multiple checked providers means "combined search"; the
            // highlighted row only matters when zero providers are checked.
            switch (try runCombinedSearch(ui, &ui.provider_enabled)) {
                .back => continue :provider_loop,
                .quit => return,
                else => continue :provider_loop,
            }
            continue :provider_loop;
        }

        const provider = if (selected_provider_count == 1)
            firstEnabledProvider(&ui.provider_enabled) orelse app.providers()[provider_idx]
        else
            app.providers()[provider_idx];
        ui.active_provider = provider;
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
                    null,
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
                const title_ref_url = app.searchRefUrl(selected_title.ref);
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
                    const download_url_display = if (isSubtitlecatTranslateToken(selected_subtitle.download_url))
                        "subtitlecat translate request"
                    else
                        download_url;

                    if (!ui.skip_confirm) {
                        var provider_buf: [224]u8 = undefined;
                        const provider_line = std.fmt.bufPrint(&provider_buf, "Provider: {s}", .{app.providerName(provider)}) catch "Provider: (overflow)";

                        const display_title = if (subtitles.title.len > 0) subtitles.title else app.titleFromRef(selected_title.ref);
                        var title_buf: [320]u8 = undefined;
                        const title_line = std.fmt.bufPrint(&title_buf, "Title: {s}", .{display_title}) catch "Title: (overflow)";

                        var subtitle_buf: [384]u8 = undefined;
                        const subtitle_line = std.fmt.bufPrint(&subtitle_buf, "Subtitle: {s}", .{selected_subtitle.label}) catch "Subtitle: (overflow)";
                        var url_buf: [320]u8 = undefined;
                        const url_line = std.fmt.bufPrint(&url_buf, "URL: {s}", .{download_url_display}) catch "URL: (overflow)";

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
                        .{download_url_display},
                    );
                    defer ui.allocator.free(download_context);
                    setContext(ui, download_context);

                    var download_task: DownloadTask = .{
                        .subtitle = selected_subtitle,
                        .out_dir = "downloads",
                    };
                    const download_thread = try std.Thread.spawn(.{}, downloadTaskMain, .{&download_task});
                    const download_control = try waitForDownloadTask(ui, &download_task, "Download", download_detail);
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

const persistent_version = 2;
const default_cache_ttl_seconds: i64 = 12 * 60 * 60;
const search_state_magic = "subdl-tui-search-state-v1\n";
const keyword_state_magic = "subdl-tui-keywords-v1\n";

fn defaultTuiSettings() TuiSettings {
    return .{
        .providers_enabled = app.providerSelectionAll(),
        .cache_enabled = true,
        .cache_ttl_seconds = default_cache_ttl_seconds,
        .keyword_cache_enabled = true,
    };
}

fn loadTuiRuntimeState(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !TuiRuntimeState {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const state_path = try tuiCachePath(allocator, environ_map, "state.oneserial");
    errdefer allocator.free(state_path);
    const keyword_path = try tuiCachePath(allocator, environ_map, "keywords.oneserial");
    errdefer allocator.free(keyword_path);

    var out: TuiRuntimeState = .{
        .arena = arena,
        .settings = defaultTuiSettings(),
        .state_path = state_path,
        .keyword_path = keyword_path,
    };
    errdefer out.deinit(allocator);

    if (try loadPersistentSearchState(out.arena.allocator(), state_path)) |loaded| {
        if (loaded.version == persistent_version) {
            out.settings = sanitizeSettings(loaded.settings);
            try out.cache_entries.appendSlice(allocator, loaded.cache_entries);
        }
    }

    if (try loadPersistentKeywordState(out.arena.allocator(), keyword_path)) |loaded| {
        if (loaded.version == persistent_version) {
            try out.keywords.appendSlice(allocator, loaded.keywords);
        }
    }

    return out;
}

fn sanitizeSettings(settings: TuiSettings) TuiSettings {
    var out = settings;
    if (countEnabledFlags(&out.providers_enabled) == 0) out.providers_enabled = app.providerSelectionAll();
    if (out.cache_ttl_seconds <= 0) out.cache_ttl_seconds = default_cache_ttl_seconds;
    return out;
}

fn loadPersistentSearchState(allocator: std.mem.Allocator, path: []const u8) !?PersistentSearchState {
    const data = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer allocator.free(data);
    if (!std.mem.startsWith(u8, data, search_state_magic)) return null;
    const body = data[search_state_magic.len..];
    const untrusted = oneserial.Untrusted(PersistentSearchState, .{}).init(body);
    return untrusted.toOwned(allocator) catch null;
}

fn loadPersistentKeywordState(allocator: std.mem.Allocator, path: []const u8) !?PersistentKeywordState {
    const data = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer allocator.free(data);
    if (!std.mem.startsWith(u8, data, keyword_state_magic)) return null;
    const body = data[keyword_state_magic.len..];
    const untrusted = oneserial.Untrusted(PersistentKeywordState, .{}).init(body);
    return untrusted.toOwned(allocator) catch null;
}

fn saveTuiRuntimeState(allocator: std.mem.Allocator, state: *const TuiRuntimeState) !void {
    const persist: PersistentSearchState = .{
        .version = persistent_version,
        .settings = state.settings,
        .cache_entries = state.cache_entries.items,
    };
    try saveOneSerial(PersistentSearchState, allocator, state.state_path, search_state_magic, &persist);
}

fn saveKeywordRuntimeState(allocator: std.mem.Allocator, state: *const TuiRuntimeState) !void {
    const persist: PersistentKeywordState = .{
        .version = persistent_version,
        .keywords = state.keywords.items,
    };
    try saveOneSerial(PersistentKeywordState, allocator, state.keyword_path, keyword_state_magic, &persist);
}

fn saveOneSerial(comptime T: type, allocator: std.mem.Allocator, path: []const u8, magic: []const u8, value: *const T) !void {
    try ensureParentDir(path);
    const encoded = try oneserial.serializeAlloc(T, .{}, value, allocator);
    defer allocator.free(encoded);
    var file_data: std.ArrayListUnmanaged(u8) = .empty;
    defer file_data.deinit(allocator);
    try file_data.appendSlice(allocator, magic);
    try file_data.appendSlice(allocator, encoded);
    try std.Io.Dir.cwd().writeFile(runtime_io.get(), .{ .sub_path = path, .data = file_data.items });
}

fn ensureParentDir(path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), path[0..slash]);
}

fn tuiCachePath(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map, basename: []const u8) ![]u8 {
    if (environ_map.get("XDG_CACHE_HOME")) |xdg| {
        if (xdg.len > 0) return std.fmt.allocPrint(allocator, "{s}/subdl/{s}", .{ xdg, basename });
    }
    if (environ_map.get("HOME")) |home| {
        if (home.len > 0) return std.fmt.allocPrint(allocator, "{s}/.cache/subdl/{s}", .{ home, basename });
    }
    return std.fmt.allocPrint(allocator, ".zig-cache/subdl/{s}", .{basename});
}

fn normalizeQueryView(query: []const u8) []const u8 {
    return std.mem.trim(u8, query, " \t\r\n");
}

fn cacheFresh(entry: QueryCacheEntry, now: i64, ttl_seconds: i64) bool {
    if (ttl_seconds <= 0) return false;
    if (entry.fetched_at_unix > now) return false;
    return now - entry.fetched_at_unix <= ttl_seconds;
}

fn findCacheEntry(state: *const TuiRuntimeState, provider: app.Provider, query_norm: []const u8, page: u32, now: i64) ?usize {
    if (!state.settings.cache_enabled) return null;
    for (state.cache_entries.items, 0..) |entry, idx| {
        if (entry.provider == provider and entry.page == page and std.mem.eql(u8, entry.query_norm, query_norm) and cacheFresh(entry, now, state.settings.cache_ttl_seconds)) {
            return idx;
        }
    }
    return null;
}

fn upsertCacheEntry(allocator: std.mem.Allocator, state: *TuiRuntimeState, provider: app.Provider, query_norm: []const u8, page: u32, fetched_at_unix: i64, response: app.SearchResponse) !void {
    if (!state.settings.cache_enabled) return;
    const a = state.arena.allocator();
    const cached_response = try cachedResponseFromSearch(a, response);
    const query_copy = try a.dupe(u8, query_norm);
    const entry: QueryCacheEntry = .{
        .provider = provider,
        .query_norm = query_copy,
        .page = page,
        .fetched_at_unix = fetched_at_unix,
        .response = cached_response,
    };
    for (state.cache_entries.items, 0..) |existing, idx| {
        if (existing.provider == provider and existing.page == page and std.mem.eql(u8, existing.query_norm, query_norm)) {
            state.cache_entries.items[idx] = entry;
            return;
        }
    }
    try state.cache_entries.append(allocator, entry);
}

fn cachedResponseFromSearch(allocator: std.mem.Allocator, response: app.SearchResponse) !CachedSearchResponse {
    const items = try allocator.alloc(app.SearchChoice, response.items.len);
    for (response.items, 0..) |item, idx| {
        items[idx] = try cloneSearchChoice(allocator, item);
    }
    return .{
        .provider = response.provider,
        .items = items,
        .page = @intCast(response.page),
        .has_prev_page = response.has_prev_page,
        .has_next_page = response.has_next_page,
    };
}

fn searchResponseFromCache(allocator: std.mem.Allocator, entry: QueryCacheEntry) !app.SearchResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const items = try a.alloc(app.SearchChoice, entry.response.items.len);
    for (entry.response.items, 0..) |item, idx| {
        items[idx] = try cloneSearchChoice(a, item);
    }
    return .{
        .arena = arena,
        .provider = entry.response.provider,
        .items = items,
        .page = entry.response.page,
        .has_prev_page = entry.response.has_prev_page,
        .has_next_page = entry.response.has_next_page,
    };
}

fn cloneSearchChoice(allocator: std.mem.Allocator, item: app.SearchChoice) !app.SearchChoice {
    return .{
        .label = try allocator.dupe(u8, item.label),
        .ref = try cloneSearchRef(allocator, item.ref),
    };
}

fn cloneSearchRef(allocator: std.mem.Allocator, ref: app.SearchRef) !app.SearchRef {
    return switch (ref) {
        .subdl_com => |item| .{ .subdl_com = .{
            .title = try allocator.dupe(u8, item.title),
            .media_type = item.media_type,
            .link = try allocator.dupe(u8, item.link),
        } },
        .opensubtitles_com => |item| .{ .opensubtitles_com = .{
            .title = try allocator.dupe(u8, item.title),
            .year = try dupOptionalLocal(allocator, item.year),
            .item_type = try dupOptionalLocal(allocator, item.item_type),
            .path = try allocator.dupe(u8, item.path),
            .subtitles_count = item.subtitles_count,
            .subtitles_list_url = try allocator.dupe(u8, item.subtitles_list_url),
        } },
        .opensubtitles_org => |item| .{ .opensubtitles_org = .{ .title = try allocator.dupe(u8, item.title), .page_url = try allocator.dupe(u8, item.page_url) } },
        .moviesubtitles_org => |item| .{ .moviesubtitles_org = .{ .title = try allocator.dupe(u8, item.title), .link = try allocator.dupe(u8, item.link) } },
        .moviesubtitlesrt_com => |item| .{ .moviesubtitlesrt_com = .{ .title = try allocator.dupe(u8, item.title), .page_url = try allocator.dupe(u8, item.page_url) } },
        .podnapisi_net => |item| .{ .podnapisi_net = .{ .title = try allocator.dupe(u8, item.title), .subtitles_page_url = try allocator.dupe(u8, item.subtitles_page_url) } },
        .yifysubtitles_ch => |item| .{ .yifysubtitles_ch = .{ .title = try allocator.dupe(u8, item.title), .movie_page_url = try allocator.dupe(u8, item.movie_page_url) } },
        .subtitlecat_com => |item| .{ .subtitlecat_com = .{ .title = try allocator.dupe(u8, item.title), .details_url = try allocator.dupe(u8, item.details_url) } },
        .isubtitles_org => |item| .{ .isubtitles_org = .{ .title = try allocator.dupe(u8, item.title), .details_url = try allocator.dupe(u8, item.details_url) } },
        .my_subs_co => |item| .{ .my_subs_co = .{
            .title = try allocator.dupe(u8, item.title),
            .details_url = try allocator.dupe(u8, item.details_url),
            .media_kind = item.media_kind,
        } },
        .subsource_net => |item| blk: {
            const seasons = try allocator.alloc(scrapers.subsource_net.SeasonItem, item.seasons.len);
            for (item.seasons, 0..) |season, idx| {
                seasons[idx] = .{ .season = season.season, .link = try allocator.dupe(u8, season.link) };
            }
            break :blk .{ .subsource_net = .{
                .title = try allocator.dupe(u8, item.title),
                .link = try allocator.dupe(u8, item.link),
                .media_type = try allocator.dupe(u8, item.media_type),
                .seasons = seasons,
            } };
        },
        .tvsubtitles_net => |item| .{ .tvsubtitles_net = .{ .title = try allocator.dupe(u8, item.title), .show_url = try allocator.dupe(u8, item.show_url) } },
    };
}

fn dupOptionalLocal(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn executeQuerySearch(ui: *Ui, state: *TuiRuntimeState, query_norm: []const u8) !SearchBundle {
    var bundle: SearchBundle = .{ .query_norm = try ui.allocator.dupe(u8, query_norm) };
    errdefer bundle.deinit(ui.allocator);
    const now = scrapers.common.compatUnixTimestamp();

    for (app.providers()) |provider| {
        if (!state.settings.providers_enabled[app.providerIndex(provider)]) continue;
        ui.active_provider = provider;

        const response_index = bundle.searches.items.len;
        if (findCacheEntry(state, provider, query_norm, 1, now)) |cache_idx| {
            const cached = try searchResponseFromCache(ui.allocator, state.cache_entries.items[cache_idx]);
            try bundle.searches.append(ui.allocator, cached);
            for (bundle.searches.items[response_index].items, 0..) |_, item_index| {
                try bundle.hits.append(ui.allocator, .{ .provider = provider, .response_index = response_index, .item_index = item_index, .source = .cache });
            }
            bundle.cache_count += 1;
            continue;
        }

        const detail = try std.fmt.allocPrint(ui.allocator, "provider={s} query={s}", .{ app.providerName(provider), query_norm });
        defer ui.allocator.free(detail);
        const context = try std.fmt.allocPrint(ui.allocator, "Search URL: {s}", .{providerHomeUrl(provider)});
        defer ui.allocator.free(context);
        setContext(ui, context);

        var search_task: SearchTask = .{
            .provider = provider,
            .query = query_norm,
            .page = 1,
        };
        const search_thread = try std.Thread.spawn(.{}, searchTaskMain, .{&search_task});
        const search_control = try waitForTask(ui, &search_task.done, "Searching", detail);
        finalizeWorkerThread(search_thread, search_control);

        if (search_control == .quit) {
            if (search_task.result) |*r| r.deinit();
            return error.TuiQuit;
        }
        if (search_control == .canceled) {
            if (search_task.result) |*r| r.deinit();
            return bundle;
        }
        if (search_task.err) |_| {
            bundle.failed_count += 1;
            continue;
        }
        const search_result = search_task.result orelse {
            bundle.failed_count += 1;
            continue;
        };
        try upsertCacheEntry(ui.allocator, state, provider, query_norm, 1, now, search_result);
        try bundle.searches.append(ui.allocator, search_result);
        for (bundle.searches.items[response_index].items, 0..) |_, item_index| {
            try bundle.hits.append(ui.allocator, .{ .provider = provider, .response_index = response_index, .item_index = item_index, .source = .live });
        }
        bundle.live_count += 1;
    }

    bundle.labels = try buildCombinedSearchLabelsWithSource(ui.allocator, bundle.searches.items, bundle.hits.items);
    return bundle;
}

fn rememberKeyword(allocator: std.mem.Allocator, state: *TuiRuntimeState, query_norm: []const u8) !void {
    if (!state.settings.keyword_cache_enabled or query_norm.len == 0) return;
    const now = scrapers.common.compatUnixTimestamp();
    for (state.keywords.items) |*entry| {
        if (std.mem.eql(u8, entry.query, query_norm)) {
            entry.used_at_unix = now;
            entry.use_count +|= 1;
            return;
        }
    }
    try state.keywords.append(allocator, .{
        .query = try state.arena.allocator().dupe(u8, query_norm),
        .used_at_unix = now,
        .use_count = 1,
    });
}

const HistoryDirection = enum { backward, forward };

fn applyHistorySuggestion(
    allocator: std.mem.Allocator,
    state: *const TuiRuntimeState,
    query: *std.ArrayList(u8),
    cursor_pos: *usize,
    direction: HistoryDirection,
    history_pick: *?usize,
) !bool {
    if (!state.settings.keyword_cache_enabled or state.keywords.items.len == 0) return false;
    const next = switch (direction) {
        .backward => if (history_pick.*) |idx| idx + 1 else 0,
        .forward => if (history_pick.*) |idx| idx -| 1 else 0,
    };
    if (next >= state.keywords.items.len) return false;
    const sorted = try sortedKeywordIndexes(allocator, state.keywords.items);
    defer allocator.free(sorted);
    const idx = sorted[next];
    query.clearRetainingCapacity();
    try query.appendSlice(allocator, state.keywords.items[idx].query);
    cursor_pos.* = query.items.len;
    history_pick.* = next;
    return true;
}

fn sortedKeywordIndexes(allocator: std.mem.Allocator, keywords: []const KeywordEntry) ![]usize {
    const order = try allocator.alloc(usize, keywords.len);
    for (order, 0..) |*slot, idx| slot.* = idx;
    const Ctx = struct { keywords: []const KeywordEntry };
    const less = struct {
        fn f(ctx: Ctx, lhs: usize, rhs: usize) bool {
            return ctx.keywords[lhs].used_at_unix > ctx.keywords[rhs].used_at_unix;
        }
    }.f;
    std.mem.sort(usize, order, Ctx{ .keywords = keywords }, less);
    return order;
}

fn nextCacheTtlSeconds(current: i64) i64 {
    if (current <= 60 * 60) return 6 * 60 * 60;
    if (current <= 6 * 60 * 60) return 12 * 60 * 60;
    if (current <= 12 * 60 * 60) return 24 * 60 * 60;
    return 60 * 60;
}

fn editProviderSettings(ui: *Ui, state: *TuiRuntimeState) !void {
    const provider_names = try buildProviderNames(ui.allocator);
    defer freeOwnedStrings(ui.allocator, provider_names);
    setContext(ui, "Settings: providers");
    const result = try vaxisSelect(
        ui,
        "Providers",
        "Space toggles providers. Enter closes with highlighted provider active.",
        provider_names,
        null,
        null,
        null,
        &state.settings.providers_enabled,
    );
    switch (result) {
        .selected, .back, .to_query, .page_prev, .page_next => {},
        .quit => return error.TuiQuit,
    }
}

fn renderQueryHome(
    ui: *Ui,
    state: *const TuiRuntimeState,
    query: []const u8,
    cursor_pos: usize,
    focus: QueryFocus,
    query_dirty: bool,
    results: ?*SearchBundle,
    selected_result: usize,
    scroll: usize,
    info_open: bool,
) !void {
    const win = ui.vx.window();
    win.clear();
    win.hideCursor();
    win.setCursorShape(.beam);

    const provider_count = countEnabledFlags(&state.settings.providers_enabled);
    const ttl_hours = @divTrunc(state.settings.cache_ttl_seconds, 60 * 60);
    const cache_status = if (state.settings.cache_enabled) "cache" else "no-cache";
    const history_status = if (state.settings.keyword_cache_enabled) "history" else "no-history";
    var top_buf: [256]u8 = undefined;
    const top = std.fmt.bufPrint(
        &top_buf,
        "p {d}/{d}  •  c {s} {d}h  •  k {s}  •  i",
        .{ provider_count, app.providerCount(), cache_status, ttl_hours, history_status },
    ) catch "i";
    try renderCompactTopLine(ui, win, top, ui.styleTitle());

    const box_w: u16 = @min(if (win.width > 6) win.width - 6 else win.width, 86);
    const box_x: u16 = if (win.width > box_w) (win.width - box_w) / 2 else 0;
    const box_y: u16 = if (win.height > 18) 4 else 2;
    const border_style = if (query_dirty) ui.styleWarn() else if (focus == .query) ui.styleAccent() else ui.styleMuted();
    try renderBox(ui, win, box_x, box_y, box_w, 3, border_style);
    const query_text = if (query.len == 0) "" else query;
    const query_style = if (query.len == 0) ui.styleMuted() else vaxis.Style{ .bold = true };
    try printFitted(ui, win, box_y + 1, box_x + 2, query_text, query_style, if (box_w > 4) @intCast(box_w - 4) else 0);
    if (focus == .query and win.width > 0) {
        const before = query[0..@min(cursor_pos, query.len)];
        const col = box_x + 2 + @as(u16, @intCast(@min(win.gwidth(before), if (box_w > 4) box_w - 4 else 0)));
        win.showCursor(@min(col, win.width -| 1), box_y + 1);
    }

    if (query_dirty) {
        try printFitted(ui, win, box_y + 4, box_x, "edited", ui.styleWarn(), @intCast(box_w));
    }

    const list_top = box_y + 6;
    const list_bottom: u16 = win.height;

    if (results) |bundle| {
        var summary_buf: [256]u8 = undefined;
        const summary = std.fmt.bufPrint(
            &summary_buf,
            "{d} results  •  live {d}  •  cache {d}  •  failed {d}",
            .{ bundle.hits.items.len, bundle.live_count, bundle.cache_count, bundle.failed_count },
        ) catch "";
        try printFitted(ui, win, list_top, 2, summary, ui.stylePaneTitle(), if (win.width > 4) @intCast(win.width - 4) else 0);

        const page_size: usize = if (list_bottom > list_top + 1) @intCast(list_bottom - list_top - 1) else 1;
        var local_scroll = scroll;
        ensureVisible(selected_result, &local_scroll, page_size);
        var row = list_top + 2;
        var i = local_scroll;
        while (i < bundle.labels.len and row < list_bottom) : (i += 1) {
            const active = focus == .results and i == selected_result;
            const style = if (active) ui.styleSelected() else vaxis.Style{};
            const prefix = if (active) "› " else "  ";
            try printFitted(ui, win, row, 2, prefix, style, 2);
            try printFitted(ui, win, row, 4, bundle.labels[i], style, if (win.width > 6) @intCast(win.width - 6) else 0);
            row += 1;
        }
    } else {
        const suggestions = try sortedKeywordIndexes(ui.frameAllocator(), state.keywords.items);
        var row = list_top;
        if (state.settings.keyword_cache_enabled and suggestions.len > 0) {
            var i: usize = 0;
            while (i < suggestions.len and i < 6 and row < list_bottom) : (i += 1) {
                const keyword = state.keywords.items[suggestions[i]];
                try printFitted(ui, win, row, 4, keyword.query, ui.styleMuted(), if (win.width > 8) @intCast(win.width - 8) else 0);
                row += 1;
            }
        }
    }

    if (info_open) {
        const lines = [_][]const u8{
            "Enter search/open",
            "Tab query/results",
            "Up/Down history or result movement",
            "p providers",
            "c cache, t ttl",
            "k history, Shift+K clear history",
            "Ctrl+C query, Ctrl+D quit",
        };
        try renderOverlayMenu(ui, win, "Info", &lines);
    }

    try ui.render();
}

fn renderBox(ui: *Ui, win: anytype, x: u16, y: u16, width: u16, height: u16, style: vaxis.Style) !void {
    if (width < 2 or height < 2) return;
    const inner_w = width - 2;
    const h = try frameRepeatText(ui, "─", inner_w);
    _ = win.print(&[_]vaxis.Segment{ .{ .text = "╭", .style = style }, .{ .text = h, .style = style }, .{ .text = "╮", .style = style } }, .{ .row_offset = y, .col_offset = x, .wrap = .none });
    var row: u16 = y + 1;
    while (row < y + height - 1) : (row += 1) {
        _ = win.print(&[_]vaxis.Segment{.{ .text = "│", .style = style }}, .{ .row_offset = row, .col_offset = x, .wrap = .none });
        _ = win.print(&[_]vaxis.Segment{.{ .text = "│", .style = style }}, .{ .row_offset = row, .col_offset = x + width - 1, .wrap = .none });
    }
    _ = win.print(&[_]vaxis.Segment{ .{ .text = "╰", .style = style }, .{ .text = h, .style = style }, .{ .text = "╯", .style = style } }, .{ .row_offset = y + height - 1, .col_offset = x, .wrap = .none });
}

fn frameRepeatText(ui: *Ui, text: []const u8, count: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(ui.frameAllocator(), text.len * count);
    var i: usize = 0;
    while (i < count) : (i += 1) out.appendSliceAssumeCapacity(text);
    return out.items;
}

fn buildCombinedSearchLabelsWithSource(
    allocator: std.mem.Allocator,
    searches: []const app.SearchResponse,
    hits: []const CombinedSearchHit,
) ![][]u8 {
    const out = try allocator.alloc([]u8, hits.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer freeInitializedStrings(allocator, out, initialized);
    for (hits, 0..) |hit, idx| {
        const item = searches[hit.response_index].items[hit.item_index];
        const source = switch (hit.source) {
            .live => "live",
            .cache => "cache",
        };
        out[idx] = try std.fmt.allocPrint(allocator, "[{s}] [{s}] {s}", .{ app.providerName(hit.provider), source, item.label });
        initialized += 1;
    }
    return out;
}

fn openSearchResult(ui: *Ui, bundle: *SearchBundle, hit_idx: usize) !OpenResult {
    if (hit_idx >= bundle.hits.items.len) return .back;
    const hit = bundle.hits.items[hit_idx];
    const selected_title = bundle.searches.items[hit.response_index].items[hit.item_index];
    const selected_provider = hit.provider;
    ui.active_provider = selected_provider;
    const title_ref_url = app.searchRefUrl(selected_title.ref);

    var subtitle_pages: std.ArrayListUnmanaged(SubtitlesPageCacheEntry) = .empty;
    defer deinitSubtitlesPageCache(ui.allocator, &subtitle_pages);
    var subtitle_page_current: usize = 1;
    const supports_subtitles_pagination = app.providerSupportsSubtitlesPagination(selected_provider);

    subtitle_page_loop: while (true) {
        const subtitles_idx = findSubtitlesPageCacheIndex(subtitle_pages.items, subtitle_page_current) orelse blk_fetch: {
            const detail = if (supports_subtitles_pagination)
                try std.fmt.allocPrint(ui.allocator, "{s} • page={d}", .{ selected_title.label, subtitle_page_current })
            else
                try ui.allocator.dupe(u8, selected_title.label);
            defer ui.allocator.free(detail);
            const context = if (supports_subtitles_pagination)
                try std.fmt.allocPrint(ui.allocator, "Provider: {s} • Title URL: {s} • page={d}", .{ app.providerName(selected_provider), title_ref_url, subtitle_page_current })
            else
                try std.fmt.allocPrint(ui.allocator, "Provider: {s} • Title URL: {s}", .{ app.providerName(selected_provider), title_ref_url });
            defer ui.allocator.free(context);
            setContext(ui, context);

            var subtitles_task: SubtitlesTask = .{
                .ref = selected_title.ref,
                .page = subtitle_page_current,
            };
            const subtitles_thread = try std.Thread.spawn(.{}, subtitlesTaskMain, .{&subtitles_task});
            const subtitles_control = try waitForTask(ui, &subtitles_task.done, "Subtitles", detail);
            finalizeWorkerThread(subtitles_thread, subtitles_control);
            if (subtitles_control == .quit) {
                if (subtitles_task.result) |*r| r.deinit();
                return .quit;
            }
            if (subtitles_control == .canceled) {
                if (subtitles_task.result) |*r| r.deinit();
                return .back;
            }
            if (subtitles_task.err) |err| {
                const msg = try showFriendlyError(ui, "Could not load subtitles", err);
                return switch (msg) {
                    .ok => .back,
                    .to_query => .to_query,
                    .quit => .quit,
                };
            }
            const subtitles = subtitles_task.result orelse return error.UnexpectedHttpStatus;
            try subtitle_pages.append(ui.allocator, .{ .page = subtitle_page_current, .response = subtitles });
            break :blk_fetch subtitle_pages.items.len - 1;
        };

        const subtitles = &subtitle_pages.items[subtitles_idx].response;
        if (subtitles.items.len == 0) {
            const msg = try vaxisMessage(ui, "No Subtitles", "No subtitle rows were returned.", "Press any key to continue.", ui.styleWarn());
            return switch (msg) {
                .ok => .back,
                .to_query => .to_query,
                .quit => .quit,
            };
        }

        const subtitle_enabled = try buildSubtitleEnabled(ui.allocator, subtitles.items);
        defer ui.allocator.free(subtitle_enabled);
        const page_nav = PageNav{
            .enabled = supports_subtitles_pagination,
            .page = subtitle_page_current,
            .has_prev = subtitles.has_prev_page,
            .has_next = subtitles.has_next_page,
        };
        const page_nav_opt: ?PageNav = if (page_nav.enabled) page_nav else null;
        const subtitle_choice = try vaxisSelectSubtitle(
            ui,
            "Select Subtitle",
            if (supports_subtitles_pagination) "s sort, / filter, [ prev, ] next, Esc titles." else "s sort, / filter, Esc titles.",
            subtitles.items,
            subtitle_enabled,
            page_nav_opt,
        );
        const subtitle_idx = switch (subtitle_choice) {
            .selected => |idx| idx,
            .back => return .back,
            .to_query => return .to_query,
            .page_prev => {
                if (subtitle_page_current > 1) subtitle_page_current -= 1;
                continue :subtitle_page_loop;
            },
            .page_next => {
                if (subtitles.has_next_page) subtitle_page_current += 1;
                continue :subtitle_page_loop;
            },
            .quit => return .quit,
        };

        const selected_subtitle = subtitles.items[subtitle_idx];
        const download_url = selected_subtitle.download_url orelse "(no direct URL)";
        const download_url_display = if (isSubtitlecatTranslateToken(selected_subtitle.download_url)) "subtitlecat translate request" else download_url;
        if (!ui.skip_confirm) {
            const lines = [_][]const u8{
                try frameFmt(ui, "Provider: {s}", .{app.providerName(selected_provider)}),
                try frameFmt(ui, "Title: {s}", .{if (subtitles.title.len > 0) subtitles.title else app.titleFromRef(selected_title.ref)}),
                try frameFmt(ui, "Subtitle: {s}", .{selected_subtitle.label}),
                try frameFmt(ui, "URL: {s}", .{download_url_display}),
                "Enter confirms download. Esc goes back.",
            };
            const confirm_result = try vaxisConfirm(ui, "Confirm Selection", &lines);
            switch (confirm_result) {
                .confirm => {},
                .back => continue :subtitle_page_loop,
                .to_query => return .to_query,
                .quit => return .quit,
            }
        }

        const download_detail = try ui.allocator.dupe(u8, selected_subtitle.label);
        defer ui.allocator.free(download_detail);
        const download_context = try std.fmt.allocPrint(ui.allocator, "Download URL: {s}", .{download_url_display});
        defer ui.allocator.free(download_context);
        setContext(ui, download_context);
        var download_task: DownloadTask = .{ .subtitle = selected_subtitle, .out_dir = "downloads" };
        const download_thread = try std.Thread.spawn(.{}, downloadTaskMain, .{&download_task});
        const download_control = try waitForDownloadTask(ui, &download_task, "Download", download_detail);
        finalizeWorkerThread(download_thread, download_control);
        if (download_control == .quit) {
            if (download_task.result) |*r| r.deinit(std.heap.page_allocator);
            return .quit;
        }
        if (download_control == .canceled) {
            if (download_task.result) |*r| r.deinit(std.heap.page_allocator);
            continue :subtitle_page_loop;
        }
        if (download_task.err) |err| {
            const msg = try showFriendlyError(ui, "Download failed", err);
            return switch (msg) {
                .ok => .back,
                .to_query => .to_query,
                .quit => .quit,
            };
        }
        var result = download_task.result orelse return error.UnexpectedHttpStatus;
        defer result.deinit(std.heap.page_allocator);
        const detail = if (result.extracted_files.len > 0)
            try std.fmt.allocPrint(ui.allocator, "{s} (+{d} extracted)", .{ result.file_path, result.extracted_files.len })
        else
            try ui.allocator.dupe(u8, result.file_path);
        defer ui.allocator.free(detail);
        const msg = try vaxisMessage(ui, "Downloaded", detail, "Press any key to keep browsing.", ui.styleAccent());
        switch (msg) {
            .ok => continue :subtitle_page_loop,
            .to_query => return .to_query,
            .quit => return .quit,
        }
    }
}

fn runCombinedSearch(ui: *Ui, provider_enabled: []const bool) !SelectResult {
    query_loop: while (true) {
        ui.active_provider = null;
        setContext(ui, "Combined search | selected providers");
        const input = try vaxisInput(ui, "Combined Search", "Searches every selected provider. Esc returns to providers.", "Query", 180);
        const query = switch (input) {
            .submit => |q| q,
            .back => return .back,
            .quit => return .quit,
        };
        defer ui.allocator.free(query);

        var searches: std.ArrayListUnmanaged(app.SearchResponse) = .empty;
        defer {
            for (searches.items) |*search| search.deinit();
            searches.deinit(ui.allocator);
        }

        var hits: std.ArrayListUnmanaged(CombinedSearchHit) = .empty;
        defer hits.deinit(ui.allocator);

        // Keep each provider response alive while the merged hit list borrows
        // individual SearchChoice rows from those response arenas.
        for (app.providers()) |provider| {
            if (!provider_enabled[app.providerIndex(provider)]) continue;

            const detail = try std.fmt.allocPrint(ui.allocator, "provider={s} query={s}", .{ app.providerName(provider), query });
            defer ui.allocator.free(detail);
            const context = try std.fmt.allocPrint(ui.allocator, "Combined search | provider: {s}", .{app.providerName(provider)});
            defer ui.allocator.free(context);
            setContext(ui, context);

            var search_task: SearchTask = .{
                .provider = provider,
                .query = query,
                .page = 1,
            };
            const search_thread = try std.Thread.spawn(.{}, searchTaskMain, .{&search_task});
            const search_control = try waitForTask(ui, &search_task.done, "Combined Search", detail);
            finalizeWorkerThread(search_thread, search_control);

            if (search_control == .quit) {
                if (search_task.result) |*r| r.deinit();
                return .quit;
            }
            if (search_control == .canceled) {
                if (search_task.result) |*r| r.deinit();
                const msg_result = try vaxisMessage(ui, "Search Canceled", "Canceled current provider fetch.", "Press any key to continue.", ui.styleWarn());
                switch (msg_result) {
                    .ok, .to_query => continue :query_loop,
                    .quit => return .quit,
                }
            }
            if (search_task.err) |_| {
                continue;
            }

            const search_result = search_task.result orelse continue;
            const response_index = searches.items.len;
            try searches.append(ui.allocator, search_result);
            for (searches.items[response_index].items, 0..) |_, item_index| {
                try hits.append(ui.allocator, .{
                    .provider = provider,
                    .response_index = response_index,
                    .item_index = item_index,
                });
            }
        }

        if (hits.items.len == 0) {
            const msg_result = try vaxisMessage(ui, "No Results", "No selected provider returned titles.", "Press any key to continue.", ui.styleWarn());
            switch (msg_result) {
                .ok, .to_query => continue :query_loop,
                .quit => return .quit,
            }
        }

        const title_labels = try buildCombinedSearchLabels(ui.allocator, searches.items, hits.items);
        defer freeOwnedStrings(ui.allocator, title_labels);

        title_loop: while (true) {
            setContext(ui, "Combined search results | first page per provider");
            const title_choice = try vaxisSelect(
                ui,
                "Combined Search Results",
                "Results include every selected provider. Esc returns to query.",
                title_labels,
                null,
                null,
                null,
                null,
            );

            const hit_idx = switch (title_choice) {
                .selected => |idx| idx,
                .back, .to_query => continue :query_loop,
                .page_prev, .page_next => continue :title_loop,
                .quit => return .quit,
            };

            const hit = hits.items[hit_idx];
            const selected_title = searches.items[hit.response_index].items[hit.item_index];
            const selected_provider = hit.provider;
            ui.active_provider = selected_provider;

            const title_ref_url = app.searchRefUrl(selected_title.ref);
            const detail = try std.fmt.allocPrint(ui.allocator, "{s}", .{selected_title.label});
            defer ui.allocator.free(detail);
            const context = try std.fmt.allocPrint(ui.allocator, "Provider: {s} | Title URL: {s}", .{ app.providerName(selected_provider), title_ref_url });
            defer ui.allocator.free(context);
            setContext(ui, context);

            var subtitles_task: SubtitlesTask = .{
                .ref = selected_title.ref,
                .page = 1,
            };
            const subtitles_thread = try std.Thread.spawn(.{}, subtitlesTaskMain, .{&subtitles_task});
            const subtitles_control = try waitForTask(ui, &subtitles_task.done, "Subtitles", detail);
            finalizeWorkerThread(subtitles_thread, subtitles_control);

            if (subtitles_control == .quit) {
                if (subtitles_task.result) |*r| r.deinit();
                return .quit;
            }
            if (subtitles_control == .canceled) {
                if (subtitles_task.result) |*r| r.deinit();
                const msg_result = try vaxisMessage(ui, "Fetch Canceled", "Canceled subtitle list fetch.", "Press any key to continue.", ui.styleWarn());
                switch (msg_result) {
                    .ok => continue :title_loop,
                    .to_query => continue :query_loop,
                    .quit => return .quit,
                }
            }
            if (subtitles_task.err) |err| {
                const msg_result = try showFriendlyError(ui, "Could not load subtitles", err);
                switch (msg_result) {
                    .ok => continue :title_loop,
                    .to_query => continue :query_loop,
                    .quit => return .quit,
                }
            }

            var subtitles = subtitles_task.result orelse return error.UnexpectedHttpStatus;
            defer subtitles.deinit();

            if (subtitles.items.len == 0) {
                const msg_result = try vaxisMessage(ui, "No Subtitles", "No subtitle rows were returned.", "Press any key to continue.", ui.styleWarn());
                switch (msg_result) {
                    .ok => continue :title_loop,
                    .to_query => continue :query_loop,
                    .quit => return .quit,
                }
            }

            const subtitle_enabled = try buildSubtitleEnabled(ui.allocator, subtitles.items);
            defer ui.allocator.free(subtitle_enabled);

            subtitle_loop: while (true) {
                setContext(ui, context);
                const subtitle_choice = try vaxisSelectSubtitle(
                    ui,
                    "Combined Search: Select Subtitle",
                    "s sort, / filter, Esc titles.",
                    subtitles.items,
                    subtitle_enabled,
                    null,
                );

                const subtitle_idx = switch (subtitle_choice) {
                    .selected => |idx| idx,
                    .back => continue :title_loop,
                    .to_query => continue :query_loop,
                    .page_prev, .page_next => continue :subtitle_loop,
                    .quit => return .quit,
                };

                const selected_subtitle = subtitles.items[subtitle_idx];
                const download_url = selected_subtitle.download_url orelse "(no direct URL)";
                const download_url_display = if (isSubtitlecatTranslateToken(selected_subtitle.download_url))
                    "subtitlecat translate request"
                else
                    download_url;

                if (!ui.skip_confirm) {
                    var provider_buf: [224]u8 = undefined;
                    const provider_line = std.fmt.bufPrint(&provider_buf, "Provider: {s}", .{app.providerName(selected_provider)}) catch "Provider: (overflow)";
                    const display_title = if (subtitles.title.len > 0) subtitles.title else app.titleFromRef(selected_title.ref);
                    var title_buf: [320]u8 = undefined;
                    const title_line = std.fmt.bufPrint(&title_buf, "Title: {s}", .{display_title}) catch "Title: (overflow)";
                    var subtitle_buf: [384]u8 = undefined;
                    const subtitle_line = std.fmt.bufPrint(&subtitle_buf, "Subtitle: {s}", .{selected_subtitle.label}) catch "Subtitle: (overflow)";
                    var url_buf: [320]u8 = undefined;
                    const url_line = std.fmt.bufPrint(&url_buf, "URL: {s}", .{download_url_display}) catch "URL: (overflow)";

                    const confirm_lines = [_][]const u8{
                        provider_line,
                        title_line,
                        subtitle_line,
                        url_line,
                        "Enter confirms download. Esc goes back.",
                    };

                    const confirm_result = try vaxisConfirm(ui, "Confirm Selection", &confirm_lines);
                    switch (confirm_result) {
                        .confirm => {},
                        .back => continue :subtitle_loop,
                        .to_query => continue :query_loop,
                        .quit => return .quit,
                    }
                }

                const download_detail = try std.fmt.allocPrint(ui.allocator, "{s}", .{selected_subtitle.label});
                defer ui.allocator.free(download_detail);
                const download_context = try std.fmt.allocPrint(ui.allocator, "Download URL: {s}", .{download_url_display});
                defer ui.allocator.free(download_context);
                setContext(ui, download_context);

                var download_task: DownloadTask = .{
                    .subtitle = selected_subtitle,
                    .out_dir = "downloads",
                };
                const download_thread = try std.Thread.spawn(.{}, downloadTaskMain, .{&download_task});
                const download_control = try waitForDownloadTask(ui, &download_task, "Download", download_detail);
                finalizeWorkerThread(download_thread, download_control);

                if (download_control == .quit) {
                    if (download_task.result) |*r| r.deinit(std.heap.page_allocator);
                    return .quit;
                }
                if (download_control == .canceled) {
                    if (download_task.result) |*r| r.deinit(std.heap.page_allocator);
                    const msg_result = try vaxisMessage(ui, "Download Canceled", "Canceled current download.", "Press any key to continue.", ui.styleWarn());
                    switch (msg_result) {
                        .ok => continue :subtitle_loop,
                        .to_query => continue :query_loop,
                        .quit => return .quit,
                    }
                }
                if (download_task.err) |err| {
                    const msg_result = try showFriendlyError(ui, "Download failed", err);
                    switch (msg_result) {
                        .ok => continue :subtitle_loop,
                        .to_query => continue :query_loop,
                        .quit => return .quit,
                    }
                }

                var result = download_task.result orelse return error.UnexpectedHttpStatus;
                defer result.deinit(std.heap.page_allocator);

                const result_detail = if (result.extracted_files.len > 0)
                    try std.fmt.allocPrint(ui.allocator, "{s} (+{d} extracted)", .{ result.file_path, result.extracted_files.len })
                else
                    try std.fmt.allocPrint(ui.allocator, "{s}", .{result.file_path});
                defer ui.allocator.free(result_detail);

                const msg_result = try vaxisMessage(ui, "Downloaded", result_detail, "Press any key to keep browsing subtitles.", ui.styleAccent());
                switch (msg_result) {
                    .ok => continue :subtitle_loop,
                    .to_query => continue :query_loop,
                    .quit => return .quit,
                }
            }
        }
    }
}

fn buildCombinedSearchLabels(
    allocator: std.mem.Allocator,
    searches: []const app.SearchResponse,
    hits: []const CombinedSearchHit,
) ![][]u8 {
    const out = try allocator.alloc([]u8, hits.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer freeInitializedStrings(allocator, out, initialized);

    for (hits, 0..) |hit, idx| {
        const item = searches[hit.response_index].items[hit.item_index];
        out[idx] = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ app.providerName(hit.provider), item.label });
        initialized += 1;
    }

    return out;
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

    try renderTopBar(ui, win, .{ .title = title });

    const msg_segments = [_]vaxis.Segment{.{ .text = message, .style = ui.styleWarn() }};
    _ = win.print(&msg_segments, .{ .row_offset = 2, .col_offset = 1, .wrap = .none });

    const detail_segments = [_]vaxis.Segment{.{ .text = detail, .style = ui.styleMuted() }};
    _ = win.print(&detail_segments, .{ .row_offset = 3, .col_offset = 1, .wrap = .none });

    try renderBottomBar(ui, win, .{ .left = "Ctrl+C/Esc/q cancel fetch" });
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

        try renderTopBar(ui, win, .{ .title = title });

        const hint_segments = [_]vaxis.Segment{.{ .text = hint }};
        _ = win.print(&hint_segments, .{ .row_offset = 1, .col_offset = 1, .wrap = .none });

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

        try renderBottomBar(ui, win, .{ .left = "Enter search | Esc back" });

        if (error_text) |txt| {
            const err_segments = [_]vaxis.Segment{.{ .text = txt, .style = ui.styleError() }};
            _ = win.print(&err_segments, .{ .row_offset = 6, .col_offset = 1, .wrap = .none });
        }

        try ui.render();

        const event = try ui.loop.nextEvent();
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
                    const text = key.text orelse continue;
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
    provider_toggles: ?[]bool,
) !SelectResult {
    if (options.len == 0) return error.NoData;
    if (enabled) |flags| {
        if (flags.len != options.len) return error.InvalidFieldType;
    }
    if (provider_toggles) |flags| {
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
    var info_menu_open = false;

    while (true) {
        const win = ui.vx.window();
        win.clear();
        win.hideCursor();

        try renderCompactTopLine(ui, win, title, ui.styleTitle());

        const show_provider_panel = ui.providerPanelVisible(win.width);
        const provider_panel_width: u16 = if (show_provider_panel) 30 else 0;
        const content_width: u16 = if (show_provider_panel and win.width > provider_panel_width + 2)
            win.width - provider_panel_width - 2
        else
            win.width;

        const list_top: u16 = 1;
        const footer_rows: u16 = 1;
        const list_bottom: u16 = if (win.height > footer_rows) win.height - footer_rows else win.height;
        const page_size: usize = if (list_bottom > list_top)
            @intCast(list_bottom - list_top)
        else
            1;

        clampSelection(&selected_row, matches.items.len);
        if (provider_toggles == null) {
            moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
        }
        ensureVisible(selected_row, &scroll, page_size);

        var row = list_top;
        var i = scroll;
        while (i < matches.items.len and row < list_bottom) : (i += 1) {
            const option_idx = matches.items[i];
            const active = i == selected_row;
            const is_enabled = if (provider_toggles) |flags| flags[option_idx] else isOptionEnabled(enabled, option_idx);
            const style = if (active)
                ui.styleSelected()
            else if (!is_enabled)
                ui.styleMuted()
            else
                vaxis.Style{};
            const cursor_prefix = if (active) "> " else "  ";
            const toggle_prefix = if (provider_toggles) |flags| if (flags[option_idx]) "[x] " else "[ ] " else "";

            const list_width: usize = if (content_width > 2) @intCast(content_width - 2) else 0;
            const prefix_width: usize = cursor_prefix.len + toggle_prefix.len;
            const text_width = list_width -| prefix_width;
            const option_col: u16 = @intCast(1 + prefix_width);

            const prefix = try frameFmt(ui, "{s}{s}", .{ cursor_prefix, toggle_prefix });
            try printFitted(ui, win, row, 1, prefix, style, prefix_width);
            try printFitted(ui, win, row, option_col, options[option_idx], style, text_width);

            row += 1;
        }

        if (matches.items.len == 0) {
            const empty_segments = [_]vaxis.Segment{.{ .text = "No matches. Edit filter and try again.", .style = ui.styleWarn() }};
            _ = win.print(&empty_segments, .{ .row_offset = list_top, .col_offset = 1, .wrap = .none });
        }

        if (show_provider_panel) {
            try renderProviderPanel(ui, win, content_width + 1, provider_panel_width);
        }

        const mode_text = if (filter_mode) "FILTER" else "NAV";
        const filter_display = if (filter.items.len == 0) "-" else filter.items;

        const can_page = if (page_nav) |pn| pn.enabled else false;
        const help_line = if (filter_mode)
            "type Enter/Esc BS"
        else if (provider_toggles != null)
            "j/k Space toggle Enter open Esc"
        else if (can_page)
            "j/k Enter / [ ] Esc"
        else
            "j/k Enter / Esc";

        var count_buf: [128]u8 = undefined;
        const count_line = if (can_page)
            std.fmt.bufPrint(
                &count_buf,
                "{d}/{d} p{d}",
                .{ matches.items.len, options.len, if (page_nav) |pn| pn.page else 1 },
            ) catch "?/? p?"
        else if (provider_toggles) |flags|
            std.fmt.bufPrint(&count_buf, "{d}/{d} selected", .{ countEnabledFlags(flags), options.len }) catch "?/? selected"
        else
            std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ matches.items.len, options.len }) catch "?/?";

        var compact_buf: [768]u8 = undefined;
        const compact_line = std.fmt.bufPrint(
            &compact_buf,
            "{s} | {s}:{s} | {s}",
            .{ help_line, mode_text, filter_display, count_line },
        ) catch "j/k Enter / Esc";
        try renderCompactBottomLine(ui, win, compact_line);

        if (info_menu_open) {
            var m1: [256]u8 = undefined;
            var m2: [320]u8 = undefined;
            var m3: [640]u8 = undefined;
            var m4: [320]u8 = undefined;
            var m5: [320]u8 = undefined;
            const l1 = std.fmt.bufPrint(&m1, "screen: {s}", .{title}) catch "screen";
            const l2 = std.fmt.bufPrint(&m2, "hint: {s}", .{hint}) catch "hint";
            const l3 = std.fmt.bufPrint(&m3, "ctx: {s}", .{ui.context_line orelse "-"}) catch "ctx";
            const l4 = std.fmt.bufPrint(&m4, "controls: {s}", .{help_line}) catch "controls";
            const l5 = std.fmt.bufPrint(&m5, "state: mode={s} filter={s} count={s}", .{ mode_text, filter_display, count_line }) catch "state";
            const lines = [_][]const u8{
                l1,
                l2,
                l3,
                l4,
                l5,
                "close: m/?/Esc",
            };
            try renderOverlayMenu(ui, win, "Menu", &lines);
        }

        try ui.render();

        const event = try ui.loop.nextEvent();
        switch (event) {
            .winsize => |ws| try ui.resize(ws),
            .key_press => |key| {
                switch (handleGlobalKey(ui, key, false)) {
                    .none => {},
                    .consumed => continue,
                    .to_query => return .to_query,
                    .quit => return .quit,
                }
                if (key.matches('m', .{}) or key.matches('?', .{})) {
                    info_menu_open = !info_menu_open;
                    continue;
                }
                if (info_menu_open and key.matches(vaxis.Key.escape, .{})) {
                    info_menu_open = false;
                    continue;
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
                        const text = key.text orelse continue;
                        try filter.appendSlice(ui.allocator, text);
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
                    if (matches.items.len > 0) {
                        const option_idx = matches.items[selected_row];
                        if (provider_toggles) |flags| {
                            _ = flags;
                            return .{ .selected = option_idx };
                        } else if (isOptionEnabled(enabled, option_idx)) {
                            return .{ .selected = option_idx };
                        }
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                    if (selected_row + 1 < matches.items.len) selected_row += 1;
                    if (provider_toggles == null) {
                        moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
                    }
                    continue;
                }
                if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                    if (selected_row > 0) selected_row -= 1;
                    if (provider_toggles == null) {
                        moveSelectionToEnabled(matches.items, enabled, &selected_row, .backward);
                    }
                    continue;
                }
                if (provider_toggles) |flags| {
                    if (key.matches(vaxis.Key.space, .{})) {
                        if (matches.items.len == 0) continue;
                        const option_idx = matches.items[selected_row];
                        flags[option_idx] = !flags[option_idx];
                        continue;
                    }
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
                if (key.matches(vaxis.Key.page_up, .{}) or (provider_toggles == null and key.matches('b', .{}))) {
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
            .mouse => |mouse| {
                if (handleMouseWheel(mouse, matches.items.len, &selected_row, provider_toggles == null, matches.items, enabled)) continue;
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
    var info_menu_open = false;

    while (true) {
        const win = ui.vx.window();
        win.clear();
        win.hideCursor();

        const show_pane = win.width >= 96;
        const left_width: u16 = if (show_pane) @max(@as(u16, 36), (win.width * 58) / 100) else win.width;
        const pane_col: u16 = left_width + 2;
        const pane_width: usize = if (show_pane and win.width > pane_col + 1) @intCast(win.width - pane_col - 1) else 0;

        try renderCompactTopLine(ui, win, title, ui.styleTitle());

        const list_top: u16 = 1;
        const footer_rows: u16 = 1;
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
            var sep_row: u16 = 1;
            while (sep_row < win.height) : (sep_row += 1) {
                const sep_segments = [_]vaxis.Segment{.{ .text = "|", .style = ui.styleMuted() }};
                _ = win.print(&sep_segments, .{ .row_offset = sep_row, .col_offset = left_width + 1, .wrap = .none });
            }

            const pane_header = [_]vaxis.Segment{.{ .text = "Details", .style = ui.stylePaneTitle() }};
            _ = win.print(&pane_header, .{ .row_offset = 1, .col_offset = pane_col, .wrap = .none });

            if (matches.items.len > 0) {
                const selected_subtitle = subtitles[matches.items[selected_row]];
                try renderSubtitleDetails(ui, win, pane_col, pane_width, selected_subtitle);
            }
        }

        const mode_text = if (filter_mode) "FILTER" else "NAV";
        const filter_display = if (filter.items.len == 0) "-" else filter.items;
        var sort_buf: [512]u8 = undefined;
        const sort_line = std.fmt.bufPrint(
            &sort_buf,
            "s:{s} {s}:{s}",
            .{ subtitleSortName(sort_mode), mode_text, filter_display },
        ) catch "s:?";

        const can_page = if (page_nav) |pn| pn.enabled else false;
        const help_line = if (filter_mode)
            "type Enter/Esc BS"
        else if (can_page)
            "j/k Enter s / [ ] Esc"
        else
            "j/k Enter s / Esc";

        var count_buf: [128]u8 = undefined;
        const count_line = if (can_page)
            std.fmt.bufPrint(
                &count_buf,
                "{d}/{d} p{d}",
                .{ matches.items.len, subtitles.len, if (page_nav) |pn| pn.page else 1 },
            ) catch "?/? p?"
        else
            std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ matches.items.len, subtitles.len }) catch "?/?";

        var compact_buf: [768]u8 = undefined;
        const compact_line = std.fmt.bufPrint(
            &compact_buf,
            "{s} | {s} | {s}",
            .{ help_line, sort_line, count_line },
        ) catch "j/k Enter s / Esc";
        try renderCompactBottomLine(ui, win, compact_line);

        if (info_menu_open) {
            var m1: [256]u8 = undefined;
            var m2: [320]u8 = undefined;
            var m3: [640]u8 = undefined;
            var m4: [320]u8 = undefined;
            var m5: [320]u8 = undefined;
            const l1 = std.fmt.bufPrint(&m1, "screen: {s}", .{title}) catch "screen";
            const l2 = std.fmt.bufPrint(&m2, "hint: {s}", .{hint}) catch "hint";
            const l3 = std.fmt.bufPrint(&m3, "ctx: {s}", .{ui.context_line orelse "-"}) catch "ctx";
            const l4 = std.fmt.bufPrint(&m4, "controls: {s}", .{help_line}) catch "controls";
            const l5 = std.fmt.bufPrint(&m5, "state: {s} count={s}", .{ sort_line, count_line }) catch "state";
            const lines = [_][]const u8{
                l1,
                l2,
                l3,
                l4,
                l5,
                "close: m/?/Esc",
            };
            try renderOverlayMenu(ui, win, "Menu", &lines);
        }

        try ui.render();

        const event = try ui.loop.nextEvent();
        switch (event) {
            .winsize => |ws| try ui.resize(ws),
            .key_press => |key| {
                switch (handleGlobalKey(ui, key, false)) {
                    .none => {},
                    .consumed => continue,
                    .to_query => return .to_query,
                    .quit => return .quit,
                }
                if (key.matches('m', .{}) or key.matches('?', .{})) {
                    info_menu_open = !info_menu_open;
                    continue;
                }
                if (info_menu_open and key.matches(vaxis.Key.escape, .{})) {
                    info_menu_open = false;
                    continue;
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
                        const text = key.text orelse continue;
                        try filter.appendSlice(ui.allocator, text);
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
            .mouse => |mouse| {
                if (handleMouseWheel(mouse, matches.items.len, &selected_row, true, matches.items, enabled)) continue;
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

        try renderTopBar(ui, win, .{ .title = title });

        var row: u16 = 2;
        for (lines) |line| {
            const segs = [_]vaxis.Segment{.{ .text = line }};
            _ = win.print(&segs, .{ .row_offset = row, .col_offset = 1, .wrap = .none });
            row += 1;
        }

        try renderBottomBar(ui, win, .{ .left = "Enter confirm | Esc back" });
        try ui.render();

        const event = try ui.loop.nextEvent();
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

        try renderTopBar(ui, win, .{ .title = title, .style = title_style });

        const message_segments = [_]vaxis.Segment{.{ .text = message }};
        _ = win.print(&message_segments, .{ .row_offset = 2, .col_offset = 1, .wrap = .none });

        const detail_segments = [_]vaxis.Segment{.{ .text = detail, .style = ui.styleMuted() }};
        _ = win.print(&detail_segments, .{ .row_offset = 3, .col_offset = 1, .wrap = .none });

        try renderBottomBar(ui, win, .{ .left = "Press any key to continue" });
        try ui.render();

        const event = try ui.loop.nextEvent();
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

const TopBarConfig = struct {
    title: []const u8,
    style: ?vaxis.Style = null,
};

const BottomBarConfig = struct {
    left: []const u8,
};

const BarLayout = struct {
    // Centralized bar text so future tweaks are one-place edits.
    pub const separator = "  •  ";
    pub const menu_hint = "m:info";
    pub const confirm_key = "F2";
    pub const theme_key = "F3";
    pub const quit_hint = "^D";
};

fn renderTopBar(ui: *Ui, win: anytype, cfg: TopBarConfig) !void {
    try renderCompactTopLine(ui, win, cfg.title, cfg.style orelse ui.styleTitle());
}

fn renderBottomBar(ui: *Ui, win: anytype, cfg: BottomBarConfig) !void {
    try renderCompactBottomLine(ui, win, cfg.left);
}

fn renderCompactTopLine(ui: *Ui, win: anytype, title: []const u8, style: vaxis.Style) !void {
    const width: usize = if (win.width > 2) @intCast(win.width - 2) else 0;
    if (width == 0) return;

    const line = if (ui.context_line) |ctx|
        try frameFmt(ui, "{s}{s}{s}", .{ title, BarLayout.separator, ctx })
    else
        title;
    try printFitted(ui, win, 0, 1, line, style, width);
}

fn renderCompactBottomLine(ui: *Ui, win: anytype, left: []const u8) !void {
    if (win.height == 0) return;
    const row: u16 = win.height - 1;
    const width: usize = if (win.width > 2) @intCast(win.width - 2) else 0;
    if (width == 0) return;

    const confirm_text = if (ui.skip_confirm) "off" else "on";
    const status = try frameFmt(
        ui,
        "{s} {s}:{s} {s}:{s} {s}",
        .{ BarLayout.menu_hint, BarLayout.confirm_key, confirm_text, BarLayout.theme_key, ui.theme().name, BarLayout.quit_hint },
    );
    const line = try frameFmt(ui, "{s}{s}{s}", .{ left, BarLayout.separator, status });
    try printFitted(ui, win, row, 1, line, ui.styleMuted(), width);
}

fn renderProviderPanel(ui: *Ui, win: anytype, col: u16, width: u16) !void {
    if (width < 18 or win.height < 4) return;

    const title_segments = [_]vaxis.Segment{.{ .text = "Providers", .style = ui.stylePaneTitle() }};
    _ = win.print(&title_segments, .{ .row_offset = 1, .col_offset = col, .wrap = .none });

    var row: u16 = 3;
    const max_width: usize = @intCast(width - 1);
    for (app.providers()) |provider| {
        if (row >= win.height -| 1) break;
        const idx = app.providerIndex(provider);
        const active = if (ui.active_provider) |current| current == provider else false;
        const enabled = ui.provider_enabled[idx];
        const marker = if (active) ">" else " ";
        const checkbox = if (enabled) "[x]" else "[ ]";
        const media = if (app.providerSupportsMovies(provider) and app.providerSupportsTv(provider))
            "M+TV"
        else if (app.providerSupportsMovies(provider))
            "M"
        else if (app.providerSupportsTv(provider))
            "TV"
        else
            "-";
        const paging = if (app.providerSupportsSearchPagination(provider) or app.providerSupportsSubtitlesPagination(provider)) " pages" else "";
        const browser = if (app.providerRequiresBrowserSession(provider)) " browser" else "";
        const caps = try frameFmt(ui, "{s}{s}{s}", .{ media, paging, browser });
        const line = try frameFmt(
            ui,
            "{s} {s} {s} {s}",
            .{ marker, checkbox, app.providerName(provider), caps },
        );
        const style = if (active)
            ui.styleSelected()
        else if (enabled)
            vaxis.Style{}
        else
            ui.styleMuted();
        try printFitted(ui, win, row, col, line, style, max_width);
        row += 1;
    }
}

fn frameFmt(ui: *Ui, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(ui.frameAllocator(), fmt, args);
}

fn frameRepeatByte(ui: *Ui, byte: u8, count: usize) ![]const u8 {
    const out = try ui.frameAllocator().alloc(u8, count);
    @memset(out, byte);
    return out;
}

fn renderOverlayMenu(ui: *Ui, win: anytype, title: []const u8, lines: []const []const u8) !void {
    if (win.width < 20 or win.height < 8) return;

    const max_box_w: u16 = @min(win.width - 2, 80);
    if (max_box_w < 12) return;
    const box_h: u16 = @min(win.height - 2, @as(u16, @intCast(lines.len + 3)));
    if (box_h < 5) return;

    const x0: u16 = (win.width - max_box_w) / 2;
    const y0: u16 = (win.height - box_h) / 2;
    const inner_w: usize = @intCast(max_box_w - 2);

    try renderBox(ui, win, x0, y0, max_box_w, box_h, ui.stylePaneTitle());

    try printFitted(ui, win, y0 + 1, x0 + 1, title, ui.styleAccent(), inner_w);
    var line_row: u16 = y0 + 2;
    var i: usize = 0;
    while (i < lines.len and line_row < y0 + box_h - 1) : ({
        i += 1;
        line_row += 1;
    }) {
        try printFitted(ui, win, line_row, x0 + 1, lines[i], ui.styleMuted(), inner_w);
    }
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
    const text = key.text orelse return false;
    if (key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.meta or key.mods.hyper) return false;
    if (key.matches(vaxis.Key.enter, .{})) return false;
    if (key.matches(vaxis.Key.tab, .{})) return false;
    return text.len > 0;
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

fn countEnabledFlags(flags: []const bool) usize {
    var count: usize = 0;
    for (flags) |enabled| {
        if (enabled) count += 1;
    }
    return count;
}

fn firstEnabledProvider(flags: []const bool) ?app.Provider {
    for (app.providers()) |provider| {
        if (flags[app.providerIndex(provider)]) return provider;
    }
    return null;
}

fn handleMouseWheel(
    mouse: vaxis.Mouse,
    item_count: usize,
    selected_row: *usize,
    skip_disabled: bool,
    matches: []const usize,
    enabled: anytype,
) bool {
    if (mouse.type != .press or item_count == 0) return false;

    // Wheel events should be cheap: adjust the selected row only. Rendering
    // happens once when the event loop iterates, avoiding page-sized jumps that
    // make high-resolution scroll wheels feel laggy.
    const step: usize = 3;
    switch (mouse.button) {
        .wheel_down => {
            selected_row.* = @min(item_count - 1, selected_row.* + step);
            if (skip_disabled) moveSelectionToEnabled(matches, enabled, selected_row, .forward);
            return true;
        },
        .wheel_up => {
            selected_row.* = selected_row.* -| step;
            if (skip_disabled) moveSelectionToEnabled(matches, enabled, selected_row, .backward);
            return true;
        },
        else => return false,
    }
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

    var display_text = try ui.frameAllocator().dupe(u8, text);

    if (needsUtfSanitizeForDisplay(display_text)) {
        display_text = try sanitizeUtf8ForDisplay(ui.frameAllocator(), display_text);
    }

    // Never call gwidth on the full string: vaxis currently accumulates into u16
    // and can overflow on very long untrusted strings.
    const fitted = utf8PrefixForDisplayWidth(win, display_text, max_width);
    if (fitted.len == display_text.len) {
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

test "subtitleFilenameForDisplay uses Without release fallback" {
    const with_name: app.SubtitleChoice = .{
        .label = "x",
        .language = null,
        .filename = "  Matrix.Release  ",
        .download_url = null,
    };
    try std.testing.expectEqualStrings("Matrix.Release", subtitleFilenameForDisplay(with_name));

    const missing: app.SubtitleChoice = .{
        .label = "x",
        .language = null,
        .filename = null,
        .download_url = null,
    };
    try std.testing.expectEqualStrings("Without release", subtitleFilenameForDisplay(missing));
}

test "query cache helpers trim and expire predictably" {
    try std.testing.expectEqualStrings("The Matrix", normalizeQueryView(" \tThe Matrix \n"));

    const settings = defaultTuiSettings();
    try std.testing.expect(settings.cache_enabled);
    try std.testing.expect(settings.keyword_cache_enabled);
    try std.testing.expectEqual(@as(usize, app.providerCount()), countEnabledFlags(&settings.providers_enabled));
    try std.testing.expectEqual(@as(i64, 12 * 60 * 60), settings.cache_ttl_seconds);

    const entry: QueryCacheEntry = .{
        .provider = .subdl_com,
        .query_norm = "The Matrix",
        .page = 1,
        .fetched_at_unix = 100,
        .response = .{
            .provider = .subdl_com,
            .items = &.{},
            .page = 1,
            .has_prev_page = false,
            .has_next_page = false,
        },
    };
    try std.testing.expect(cacheFresh(entry, 100 + 60, 120));
    try std.testing.expect(!cacheFresh(entry, 100 + 121, 120));
    try std.testing.expectEqual(@as(i64, 6 * 60 * 60), nextCacheTtlSeconds(60 * 60));
    try std.testing.expectEqual(@as(i64, 12 * 60 * 60), nextCacheTtlSeconds(6 * 60 * 60));
    try std.testing.expectEqual(@as(i64, 24 * 60 * 60), nextCacheTtlSeconds(12 * 60 * 60));
}

test "keyword state serializes through oneserial" {
    const allocator = std.testing.allocator;
    const state: PersistentKeywordState = .{
        .version = persistent_version,
        .keywords = &.{
            .{ .query = "matrix", .used_at_unix = 10, .use_count = 2 },
            .{ .query = "alien", .used_at_unix = 20, .use_count = 1 },
        },
    };
    const encoded = try oneserial.serializeAlloc(PersistentKeywordState, .{}, &state, allocator);
    defer allocator.free(encoded);

    const decoded = try oneserial.Untrusted(PersistentKeywordState, .{}).init(encoded).toOwned(allocator);
    defer {
        for (decoded.keywords) |entry| allocator.free(entry.query);
        allocator.free(decoded.keywords);
    }

    try std.testing.expectEqual(@as(u32, persistent_version), decoded.version);
    try std.testing.expectEqual(@as(usize, 2), decoded.keywords.len);
    try std.testing.expectEqualStrings("matrix", decoded.keywords[0].query);
    try std.testing.expectEqual(@as(u32, 2), decoded.keywords[0].use_count);
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
    const is_translate = isSubtitlecatTranslateToken(subtitle.download_url);

    try printFitted(ui, win, row, col, subtitle.label, ui.stylePaneTitle(), pane_width);
    row += 2;

    if (row >= max_row) return;
    try printLabelValue(
        ui,
        win,
        row,
        col,
        pane_width,
        "Download: ",
        if (subtitle.download_url == null)
            "no direct url"
        else if (is_translate)
            "translate"
        else
            "direct",
    );
    row += 1;

    if (row >= max_row) return;
    try printLabelValue(ui, win, row, col, pane_width, "Language: ", subtitle.language orelse "(unknown)");
    row += 1;

    if (row >= max_row) return;
    try printLabelValue(ui, win, row, col, pane_width, "Filename: ", subtitleFilenameForDisplay(subtitle));
    row += 1;

    if (row >= max_row) return;
    try printFitted(ui, win, row, col, "URL:", ui.styleAccent(), pane_width);
    row += 1;

    if (row >= max_row) return;
    try printFitted(
        ui,
        win,
        row,
        col,
        if (subtitle.download_url) |url|
            if (is_translate)
                "subtitlecat translate request"
            else
                url
        else
            "(not available)",
        .{},
        pane_width,
    );
}

fn subtitleFilenameForDisplay(subtitle: app.SubtitleChoice) []const u8 {
    if (subtitle.filename) |name| {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return "Without release";
}

fn isSubtitlecatTranslateToken(download_url: ?[]const u8) bool {
    const url = download_url orelse return false;
    return std.mem.startsWith(u8, url, "subtitlecat-translate:");
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

fn freeInitializedStrings(allocator: std.mem.Allocator, strings: [][]u8, initialized: usize) void {
    for (strings[0..initialized]) |s| allocator.free(s);
}
