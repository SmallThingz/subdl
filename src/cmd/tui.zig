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
    if (comptime builtin.os.tag == .windows) return vaxis.recover();
    if (vaxis.tty.global_tty) |tty| {
        std.posix.tcsetattr(tty.fd.handle, .FLUSH, tty.termios) catch {};
        const reset = "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?25h\x1b[?1049l";
        _ = std.c.write(tty.fd.handle, reset.ptr, reset.len);
    }
}

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

const LanguageOption = struct {
    code: []const u8,
    name: []const u8,
};

const language_options = [_]LanguageOption{
    .{ .code = "en", .name = "English" },
    .{ .code = "es", .name = "Spanish" },
    .{ .code = "fr", .name = "French" },
    .{ .code = "de", .name = "German" },
    .{ .code = "it", .name = "Italian" },
    .{ .code = "pt", .name = "Portuguese" },
    .{ .code = "pt-br", .name = "Portuguese (Brazil)" },
    .{ .code = "nl", .name = "Dutch" },
    .{ .code = "ar", .name = "Arabic" },
    .{ .code = "hi", .name = "Hindi" },
    .{ .code = "ja", .name = "Japanese" },
    .{ .code = "ko", .name = "Korean" },
    .{ .code = "zh", .name = "Chinese" },
    .{ .code = "zh-tw", .name = "Chinese (Traditional)" },
    .{ .code = "ru", .name = "Russian" },
    .{ .code = "tr", .name = "Turkish" },
    .{ .code = "fa", .name = "Persian" },
    .{ .code = "sv", .name = "Swedish" },
    .{ .code = "da", .name = "Danish" },
    .{ .code = "fi", .name = "Finnish" },
    .{ .code = "no", .name = "Norwegian" },
    .{ .code = "pl", .name = "Polish" },
    .{ .code = "cs", .name = "Czech" },
    .{ .code = "hu", .name = "Hungarian" },
    .{ .code = "ro", .name = "Romanian" },
    .{ .code = "el", .name = "Greek" },
    .{ .code = "id", .name = "Indonesian" },
    .{ .code = "vi", .name = "Vietnamese" },
    .{ .code = "uk", .name = "Ukrainian" },
    .{ .code = "bg", .name = "Bulgarian" },
    .{ .code = "hr", .name = "Croatian" },
    .{ .code = "sr", .name = "Serbian" },
    .{ .code = "sk", .name = "Slovak" },
    .{ .code = "sl", .name = "Slovenian" },
    .{ .code = "he", .name = "Hebrew" },
    .{ .code = "th", .name = "Thai" },
    .{ .code = "ms", .name = "Malay" },
    .{ .code = "bn", .name = "Bengali" },
    .{ .code = "ta", .name = "Tamil" },
    .{ .code = "te", .name = "Telugu" },
    .{ .code = "ml", .name = "Malayalam" },
    .{ .code = "mr", .name = "Marathi" },
    .{ .code = "ur", .name = "Urdu" },
    .{ .code = "ca", .name = "Catalan" },
    .{ .code = "eu", .name = "Basque" },
    .{ .code = "gl", .name = "Galician" },
    .{ .code = "lt", .name = "Lithuanian" },
    .{ .code = "lv", .name = "Latvian" },
    .{ .code = "et", .name = "Estonian" },
    .{ .code = "is", .name = "Icelandic" },
    .{ .code = "ga", .name = "Irish" },
    .{ .code = "af", .name = "Afrikaans" },
    .{ .code = "sw", .name = "Swahili" },
    .{ .code = "sq", .name = "Albanian" },
    .{ .code = "mk", .name = "Macedonian" },
    .{ .code = "bs", .name = "Bosnian" },
};

fn languageCount() usize {
    return language_options.len;
}

fn languageSelectionAll() [languageCount()]bool {
    return [_]bool{true} ** languageCount();
}

fn languageSelectionEnglish() [languageCount()]bool {
    var out = [_]bool{false} ** languageCount();
    out[0] = true;
    return out;
}

fn languageSelectionOnly(index: usize) [languageCount()]bool {
    var out = [_]bool{false} ** languageCount();
    if (index < out.len) out[index] = true;
    return out;
}

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
    languages_enabled: [languageCount()]bool,
    language_filter_enabled: bool,
    cache_enabled: bool,
    download_cache_enabled: bool,
    cache_ttl_seconds: i64,
    keyword_cache_enabled: bool,
};

const PersistentSearchState = struct {
    version: u32,
    settings: TuiSettings,
    cache_entries: []const QueryCacheEntry,
};

const PersistentSettingsState = struct {
    version: u32,
    settings: TuiSettings,
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
    download_entries: [][]u8 = &.{},
    arena_stale_mutations: usize = 0,
    state_path: []u8,
    settings_path: []u8,
    keyword_path: []u8,
    cache_root_path: []u8,

    fn deinit(self: *TuiRuntimeState, allocator: std.mem.Allocator) void {
        self.cache_entries.deinit(allocator);
        self.keywords.deinit(allocator);
        if (self.download_entries.len > 0) freeOwnedStrings(allocator, self.download_entries);
        allocator.free(self.state_path);
        allocator.free(self.settings_path);
        allocator.free(self.keyword_path);
        allocator.free(self.cache_root_path);
        self.arena.deinit();
        self.* = undefined;
    }
};

const QueryFocus = enum {
    query,
    results,
    downloads,
};

const SearchBundle = struct {
    query_norm: []u8,
    searches: std.ArrayListUnmanaged(app.SearchResponse) = .empty,
    hits: std.ArrayListUnmanaged(CombinedSearchHit) = .empty,
    labels: [][]u8 = &.{},
    display_query_norm: ?[]u8 = null,
    display_hit_count: usize = 0,
    display_order: []usize = &.{},
    live_count: usize = 0,
    cache_count: usize = 0,
    cache_changed: bool = false,
    failed_count: usize = 0,
    unavailable_count: usize = 0,
    pending_count: usize = 0,
    searching: bool = false,
    canceled: bool = false,

    fn deinit(self: *SearchBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.query_norm);
        if (self.display_query_norm) |query| allocator.free(query);
        if (self.display_order.len > 0) allocator.free(self.display_order);
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
    language_code: ?[]const u8 = null,
    page: usize = 1,
    done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    err: ?anyerror = null,
    result: ?app.SearchResponse = null,
};

const ProviderSearchTask = struct {
    provider: app.Provider,
    query: []const u8,
    language_code: ?[]const u8 = null,
    page: usize = 1,
    done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    err: ?anyerror = null,
    result: ?app.SearchResponse = null,
};

const IncrementalSearchWork = struct {
    group: *std.Io.Group,
    tasks: []ProviderSearchTask,
    consumed: []bool,
    query: []u8,
    task_count: usize = 0,
};

const SearchReaperJob = struct {
    work: *IncrementalSearchWork,
    done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
};

const SearchReaperEntry = struct {
    future: std.Io.Future(void),
    job: *SearchReaperJob,
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
    extract_archive: bool = true,
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
    search_reapers: std.ArrayListUnmanaged(SearchReaperEntry) = .empty,

    fn writer(self: *Ui) *std.Io.Writer {
        return self.tty.writer();
    }

    fn hardQuit(self: *Ui) noreturn {
        // Ctrl+D is an explicit process quit, not a graceful "back" action.
        // Restore all terminal modes first, then let the OS reclaim any
        // outstanding provider work instead of waiting on slow cancellation.
        self.loop.stop();
        self.vx.deinit(null, self.writer());
        self.tty.deinit();
        std.process.exit(0);
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

    fn reapSearchWork(self: *Ui, work: *IncrementalSearchWork) bool {
        if (comptime builtin.single_threaded) return false;
        self.collectSearchReapers();
        const job = self.allocator.create(SearchReaperJob) catch return false;
        job.* = .{ .work = work };
        var future = std.Io.concurrent(
            runtime_io.get(),
            runSearchReaper,
            .{job},
        ) catch {
            self.allocator.destroy(job);
            return false;
        };
        self.search_reapers.append(self.allocator, .{ .future = future, .job = job }) catch {
            future.await(runtime_io.get());
            self.allocator.destroy(job);
            return true;
        };
        return true;
    }

    fn collectSearchReapers(self: *Ui) void {
        var idx: usize = 0;
        while (idx < self.search_reapers.items.len) {
            const entry = &self.search_reapers.items[idx];
            if (entry.job.done.load(.acquire) == 0) {
                idx += 1;
                continue;
            }
            entry.future.await(runtime_io.get());
            self.allocator.destroy(entry.job);
            _ = self.search_reapers.orderedRemove(idx);
        }
    }

    fn awaitSearchReapers(self: *Ui) void {
        for (self.search_reapers.items) |*entry| {
            entry.future.await(runtime_io.get());
            self.allocator.destroy(entry.job);
        }
        self.search_reapers.deinit(self.allocator);
        self.search_reapers = .empty;
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

    fn styleMenuBackground(self: *Ui) vaxis.Style {
        _ = self;
        return .{};
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

    var ui: Ui = .{
        .allocator = allocator,
        .environ_map = init.environ_map,
        .tty = &tty,
        .vx = &vx,
        .loop = &loop,
        .frame_arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer ui.frame_arena.deinit();

    {
        defer ui.awaitSearchReapers();
        {
            // Restore the user's terminal before waiting for any slow provider
            // cancellation reapers. Cleanup remains deterministic for normal
            // back/cancel flows.
            defer vx.exitAltScreen(tty.writer()) catch {};
            defer vx.setMouseMode(tty.writer(), false) catch {};
            defer loop.stop();
            try runTui(&ui);
        }
    }
}

fn searchTaskMain(task: *SearchTask) std.Io.Cancelable!void {
    defer task.done.store(1, .release);
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = runtime_io.get() };
    defer client.deinit();

    task.result = app.searchPageWithOptions(std.heap.page_allocator, &client, task.provider, task.query, task.page, .{
        .language_code = task.language_code,
    }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        task.err = err;
        return;
    };
}

fn providerSearchTaskMain(task: *ProviderSearchTask) std.Io.Cancelable!void {
    defer task.done.store(1, .release);
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = runtime_io.get() };
    defer client.deinit();

    task.result = app.searchPageWithOptions(std.heap.page_allocator, &client, task.provider, task.query, task.page, .{
        .language_code = task.language_code,
    }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        task.err = err;
        return;
    };
}

fn isRemoteSearchFailure(err: anyerror) bool {
    return switch (err) {
        error.UnexpectedHttpStatus,
        error.HttpRequestFailed,
        error.RateLimited,
        error.ParseFailed,
        error.MissingField,
        error.InvalidField,
        error.InvalidFieldType,
        error.CloudflareChallenge,
        error.CloudflareSessionUnavailable,
        error.BrowserAutomationFailed,
        error.SessionExpired,
        error.InvalidDownloadUrl,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.TemporaryNameServerFailure,
        error.UnknownHostName,
        error.EndOfStream,
        error.ReadFailed,
        => true,
        else => false,
    };
}

fn recordSearchFailure(bundle: *SearchBundle, err: anyerror) void {
    if (isRemoteSearchFailure(err)) {
        bundle.unavailable_count += 1;
    } else {
        bundle.failed_count += 1;
    }
}

fn subtitlesTaskMain(task: *SubtitlesTask) std.Io.Cancelable!void {
    defer task.done.store(1, .release);
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = runtime_io.get() };
    defer client.deinit();

    const fetch_result = if (task.subdl_season_slug) |season_slug|
        app.fetchSubdlSeasonSubtitlesPage(std.heap.page_allocator, &client, task.ref, season_slug, task.page)
    else
        app.fetchSubtitlesPage(std.heap.page_allocator, &client, task.ref, task.page);

    task.result = fetch_result catch |err| {
        if (err == error.Canceled) return error.Canceled;
        task.err = err;
        return;
    };
}

fn subdlSeasonsTaskMain(task: *SubdlSeasonsTask) std.Io.Cancelable!void {
    defer task.done.store(1, .release);
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = runtime_io.get() };
    defer client.deinit();

    task.result = app.fetchSubdlSeasons(std.heap.page_allocator, &client, task.ref) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        task.err = err;
        return;
    };
}

fn downloadTaskMain(task: *DownloadTask) std.Io.Cancelable!void {
    defer task.done.store(1, .release);
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = runtime_io.get() };
    defer client.deinit();

    const progress = app.DownloadProgress{
        .user_data = task,
        .on_phase = onDownloadProgressPhase,
        .on_units = onDownloadProgressUnits,
    };

    task.result = app.downloadSubtitleWithProgressAndOptions(std.heap.page_allocator, &client, task.subtitle, task.out_dir, &progress, .{
        .extract_archive = task.extract_archive,
    }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        task.err = err;
        return;
    };
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
    const spinner = [_][]const u8{ "-", "\\", "-", "/" };
    var spinner_idx: usize = 0;

    while (done.load(.acquire) == 0) {
        var msg_buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&msg_buf, "Fetching... {s}", .{spinner[spinner_idx % spinner.len]}) catch "Fetching...";

        try vaxisStatus(ui, title, message, detail);

        while (try ui.loop.tryEvent()) |event| {
            switch (event) {
                .winsize => |ws| try ui.resize(ws),
                .key_press => |key| {
                    if (key.isModifier()) continue;
                    if (key.matches(vaxis.Key.f2, .{})) {
                        ui.toggleConfirm();
                        continue;
                    }
                    if (key.matches(vaxis.Key.f3, .{})) {
                        ui.toggleTheme();
                        continue;
                    }
                    if (key.matches('d', .{ .ctrl = true })) {
                        ui.hardQuit();
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
    const spinner = [_][]const u8{ "-", "\\", "-", "/" };
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
                    if (key.isModifier()) continue;
                    if (key.matches(vaxis.Key.f2, .{})) {
                        ui.toggleConfirm();
                        continue;
                    }
                    if (key.matches(vaxis.Key.f3, .{})) {
                        ui.toggleTheme();
                        continue;
                    }
                    if (key.matches('d', .{ .ctrl = true })) {
                        ui.hardQuit();
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

fn finalizeWorkerGroup(group: *std.Io.Group, control: FetchControl) void {
    switch (control) {
        .completed => group.await(runtime_io.get()) catch {},
        .canceled, .quit => group.cancel(runtime_io.get()),
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
    return app.providerSiteUrl(provider);
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
    applyRuntimeCacheSettings(&state);
    ui.provider_enabled = state.settings.providers_enabled;

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(ui.allocator);
    var cursor_pos: usize = 0;
    var focus: QueryFocus = .query;
    var selected_result: usize = 0;
    var result_scroll: usize = 0;
    var selected_download: usize = 0;
    var download_scroll: usize = 0;
    var info_open = false;
    var history_pick: ?usize = null;
    var history_draft: std.ArrayList(u8) = .empty;
    defer history_draft.deinit(ui.allocator);
    var history_draft_cursor: usize = 0;
    var last_searched_norm: []u8 = try ui.allocator.dupe(u8, "");
    defer ui.allocator.free(last_searched_norm);
    var results: ?SearchBundle = null;
    defer if (results) |*bundle| bundle.deinit(ui.allocator);

    while (true) {
        ui.collectSearchReapers();
        ui.provider_enabled = state.settings.providers_enabled;
        if (info_open and !canRenderOverlayMenu(ui.vx.window())) info_open = false;
        const query_norm_view = normalizeQueryView(query.items);
        if (query_norm_view.len == 0 and results != null) {
            if (results) |*bundle| bundle.deinit(ui.allocator);
            results = null;
            ui.allocator.free(last_searched_norm);
            last_searched_norm = try ui.allocator.dupe(u8, "");
            selected_result = 0;
            result_scroll = 0;
            focus = .query;
        }
        const query_dirty = !std.mem.eql(u8, query_norm_view, last_searched_norm);
        const has_current_results = !query_dirty and results != null and results.?.hits.items.len > 0;
        focus = normalizeQueryFocus(
            focus,
            has_current_results,
            state.settings.download_cache_enabled and state.download_entries.len > 0,
        );
        try renderQueryHome(ui, &state, query.items, cursor_pos, focus, query_dirty, if (results) |*b| b else null, &selected_result, &result_scroll, &selected_download, &download_scroll, info_open, true);

        const batch = try readEventBatch(ui, try ui.loop.nextEvent());
        for (batch.slice()) |event| {
            switch (event) {
                .winsize => |ws| try ui.resize(ws),
                .mouse => |mouse| {
                    if (info_open) {
                        if (mouse.type == .press) {
                            info_open = false;
                        } else {
                            continue;
                        }
                    }
                    if (mouse.type == .press and mouse.button == .left) {
                        const win = ui.vx.window();
                        const search_box = homeSearchBoxMetrics(win.width);
                        if (mouse.row >= 0 and mouse.col >= 0) {
                            const row: u16 = @intCast(mouse.row);
                            const col: u16 = @intCast(mouse.col);
                            if (row == search_box.input_row and
                                col >= search_box.input_col and
                                col < search_box.input_col + search_box.input_width)
                            {
                                focus = .query;
                                resetHistoryBrowse(&history_pick, &history_draft, &history_draft_cursor);
                                const viewport = queryViewportForCursor(
                                    win,
                                    query.items,
                                    cursor_pos,
                                    search_box.input_width,
                                );
                                var target_col: usize = @intCast(col - search_box.input_col);
                                if (viewport.start > 0) {
                                    if (target_col == 0) {
                                        cursor_pos = viewport.start;
                                        continue;
                                    }
                                    target_col -= 1;
                                }
                                cursor_pos = viewport.start + queryCursorByteOffsetForDisplayColumn(
                                    win,
                                    query.items[viewport.start..],
                                    target_col,
                                );
                                continue;
                            }
                        }
                        if (focus != .downloads and results == null and
                            state.settings.keyword_cache_enabled and state.keywords.items.len > 0 and
                            mouse.row >= 0)
                        {
                            const row: u16 = @intCast(mouse.row);
                            const first_history_row = homeRecentSearchFirstRow();
                            if (row >= first_history_row and row < homeListBottom(win.height)) {
                                const display_idx: usize = @intCast(row - first_history_row);
                                const suggestions = try sortedKeywordIndexes(ui.frameAllocator(), state.keywords.items);
                                const visible_count = @min(suggestions.len, @as(usize, 6));
                                if (display_idx < visible_count) {
                                    const keyword = state.keywords.items[suggestions[display_idx]];
                                    try captureHistoryDraft(
                                        ui.allocator,
                                        &query,
                                        cursor_pos,
                                        &history_pick,
                                        &history_draft,
                                        &history_draft_cursor,
                                    );
                                    query.clearRetainingCapacity();
                                    try query.appendSlice(ui.allocator, keyword.query);
                                    cursor_pos = query.items.len;
                                    history_pick = display_idx;
                                    focus = .query;
                                    continue;
                                }
                            }
                        }
                    }
                    if (focus == .downloads and state.settings.download_cache_enabled) {
                        const download_count = state.download_entries.len;
                        if (mouse.type == .press and download_count > 0) switch (mouse.button) {
                            .wheel_down => scrollSelection(&selected_download, download_count, .forward, list_mouse_wheel_step),
                            .wheel_up => scrollSelection(&selected_download, download_count, .backward, list_mouse_wheel_step),
                            .left => {
                                const win = ui.vx.window();
                                if (mouseRowIndex(mouse, homeListTop(), homeListBottom(win.height), download_scroll, download_count)) |row_idx| {
                                    const activate = row_idx == selected_download;
                                    selected_download = row_idx;
                                    if (activate) {
                                        switch (try exportHomeCachedDownload(ui, &state, selected_download)) {
                                            .ok => {},
                                            .to_query => focus = .query,
                                            .quit => return,
                                        }
                                    }
                                }
                            },
                            else => {},
                        };
                    } else if (!query_dirty) {
                        if (results) |*bundle| {
                            const visible_count = bundle.display_order.len;
                            if (mouse.type == .press and visible_count > 0) switch (mouse.button) {
                                .wheel_down => {
                                    scrollSelection(&selected_result, visible_count, .forward, list_mouse_wheel_step);
                                    focus = .results;
                                },
                                .wheel_up => {
                                    scrollSelection(&selected_result, visible_count, .backward, list_mouse_wheel_step);
                                    focus = .results;
                                },
                                .left => {
                                    const win = ui.vx.window();
                                    if (mouseRowIndex(mouse, homeListTop(), homeListBottom(win.height), result_scroll, visible_count)) |row_idx| {
                                        const activate = focus == .results and row_idx == selected_result;
                                        selected_result = row_idx;
                                        focus = .results;
                                        if (activate) {
                                            const visible_order = bundle.display_order;
                                            if (selected_result < visible_order.len) {
                                                switch (try openSearchResult(ui, bundle, visible_order[selected_result], &state)) {
                                                    .back => focus = .results,
                                                    .to_query => focus = .query,
                                                    .quit => return,
                                                }
                                            }
                                        }
                                    }
                                },
                                else => {},
                            };
                        }
                    }
                },
                .key_press => |key| {
                    switch (handleGlobalKey(ui, key)) {
                        .none => {},
                        .consumed => continue,
                        .to_query => {
                            info_open = false;
                            focus = .query;
                            continue;
                        },
                        .quit => return,
                    }

                    if (info_open) {
                        if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.f1, .{})) {
                            info_open = false;
                            continue;
                        }
                        // Help is informational, not a modal dialog. Dismiss it
                        // on the next actionable key and process that same key
                        // so typing/navigation is never swallowed.
                        info_open = false;
                    }

                    if (key.matches(vaxis.Key.f1, .{})) {
                        if (canRenderOverlayMenu(ui.vx.window())) info_open = true;
                        continue;
                    }
                    if (key.matches(vaxis.Key.tab, .{})) {
                        focus = nextQueryFocus(focus, has_current_results, state.settings.download_cache_enabled and state.download_entries.len > 0);
                        continue;
                    }
                    if (key.matches(vaxis.Key.escape, .{})) {
                        const current_query_norm = normalizeQueryView(query.items);
                        const current_query_dirty = !std.mem.eql(u8, current_query_norm, last_searched_norm);
                        const search_settings_changed = try editSettingsPopup(ui, &state, query.items, cursor_pos, focus, current_query_dirty, if (results) |*b| b else null, &selected_result, &result_scroll, &selected_download, &download_scroll, &info_open);
                        if (search_settings_changed) {
                            if (results) |*bundle| bundle.deinit(ui.allocator);
                            results = null;
                            selected_result = 0;
                            result_scroll = 0;
                            focus = .query;
                            ui.allocator.free(last_searched_norm);
                            last_searched_norm = try ui.allocator.dupe(u8, "");
                        }
                        continue;
                    }

                    if (focus == .downloads and state.settings.download_cache_enabled) {
                        const download_count = state.download_entries.len;
                        if (key.matches(vaxis.Key.enter, .{}) and download_count > 0) {
                            switch (try exportHomeCachedDownload(ui, &state, selected_download)) {
                                .ok => {},
                                .to_query => focus = .query,
                                .quit => return,
                            }
                            continue;
                        }
                        if (key.matches(vaxis.Key.down, .{})) {
                            if (selected_download + 1 < download_count) selected_download += 1;
                            continue;
                        }
                        if (key.matches(vaxis.Key.up, .{})) {
                            selected_download = selected_download -| 1;
                            continue;
                        }
                        if (key.matches(vaxis.Key.page_down, .{})) {
                            if (download_count > 0) selected_download = @min(download_count - 1, selected_download + queryPageSize(ui));
                            continue;
                        }
                        if (key.matches(vaxis.Key.page_up, .{})) {
                            selected_download = selected_download -| queryPageSize(ui);
                            continue;
                        }
                        if (key.matches(vaxis.Key.end, .{})) {
                            selected_download = download_count -| 1;
                            continue;
                        }
                        if (key.matches(vaxis.Key.home, .{})) {
                            selected_download = 0;
                            continue;
                        }
                    }

                    if (focus == .results) {
                        if (key.matches(vaxis.Key.enter, .{})) {
                            if (results) |*bundle| {
                                const visible_order = bundle.display_order;
                                if (selected_result < visible_order.len) {
                                    switch (try openSearchResult(ui, bundle, visible_order[selected_result], &state)) {
                                        .back => focus = .results,
                                        .to_query => focus = .query,
                                        .quit => return,
                                    }
                                }
                            }
                            continue;
                        }
                        if (key.matches(vaxis.Key.down, .{})) {
                            if (results) |*bundle| {
                                const visible_count = bundle.display_order.len;
                                if (selected_result + 1 < visible_count) selected_result += 1;
                            }
                            continue;
                        }
                        if (key.matches(vaxis.Key.up, .{})) {
                            if (selected_result > 0) selected_result -= 1;
                            continue;
                        }
                        if (key.matches(vaxis.Key.page_down, .{})) {
                            if (results) |*bundle| {
                                const visible_count = bundle.display_order.len;
                                if (visible_count > 0) selected_result = @min(visible_count - 1, selected_result + queryPageSize(ui));
                            }
                            continue;
                        }
                        if (key.matches(vaxis.Key.page_up, .{})) {
                            selected_result = selected_result -| queryPageSize(ui);
                            continue;
                        }
                        if (key.matches(vaxis.Key.end, .{})) {
                            if (results) |*bundle| {
                                const visible_count = bundle.display_order.len;
                                selected_result = visible_count -| 1;
                            }
                            continue;
                        }
                        if (key.matches(vaxis.Key.home, .{})) {
                            selected_result = 0;
                            continue;
                        }
                    }

                    if (key.matches(vaxis.Key.enter, .{})) {
                        const current_query_norm = normalizeQueryView(query.items);
                        if (current_query_norm.len == 0) continue;
                        resetHistoryBrowse(&history_pick, &history_draft, &history_draft_cursor);
                        if (results) |*bundle| bundle.deinit(ui.allocator);
                        results = null;
                        const owned_query = try ui.allocator.dupe(u8, current_query_norm);
                        defer ui.allocator.free(owned_query);
                        try rememberKeyword(ui.allocator, &state, owned_query);
                        const search_outcome = executeQuerySearchIncremental(ui, &state, owned_query, query.items, cursor_pos, &selected_result, &result_scroll, &info_open) catch |err| switch (err) {
                            error.TuiQuit => return,
                            else => return err,
                        };
                        ui.allocator.free(last_searched_norm);
                        if (search_outcome.discard_results) {
                            var stale_bundle = search_outcome.bundle;
                            stale_bundle.deinit(ui.allocator);
                            results = null;
                            last_searched_norm = try ui.allocator.dupe(u8, "");
                        } else {
                            results = search_outcome.bundle;
                            last_searched_norm = try ui.allocator.dupe(
                                u8,
                                if (search_outcome.mark_query_dirty) "" else owned_query,
                            );
                        }
                        selected_result = 0;
                        result_scroll = 0;
                        focus = search_outcome.focus;
                        if (results) |*bundle| {
                            if (bundle.cache_changed) try saveTuiRuntimeState(ui.allocator, &state);
                        }
                        try saveKeywordRuntimeState(ui.allocator, &state);
                        continue;
                    }
                    if (key.matches(vaxis.Key.up, .{})) {
                        if (try applyHistorySuggestion(
                            ui.allocator,
                            &state,
                            &query,
                            &cursor_pos,
                            .backward,
                            &history_pick,
                            &history_draft,
                            &history_draft_cursor,
                        )) continue;
                    } else if (key.matches(vaxis.Key.down, .{})) {
                        if (try applyHistorySuggestion(
                            ui.allocator,
                            &state,
                            &query,
                            &cursor_pos,
                            .forward,
                            &history_pick,
                            &history_draft,
                            &history_draft_cursor,
                        )) continue;
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
                        resetHistoryBrowse(&history_pick, &history_draft, &history_draft_cursor);
                        focus = .query;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (cursor_pos > 0) {
                            const prev = prevCodepointStart(query.items, cursor_pos);
                            query.replaceRangeAssumeCapacity(prev, cursor_pos - prev, "");
                            cursor_pos = prev;
                            resetHistoryBrowse(&history_pick, &history_draft, &history_draft_cursor);
                            focus = .query;
                        }
                    } else if (key.matches(vaxis.Key.delete, .{})) {
                        if (cursor_pos < query.items.len) {
                            const next = nextCodepointEnd(query.items, cursor_pos);
                            query.replaceRangeAssumeCapacity(cursor_pos, next - cursor_pos, "");
                            resetHistoryBrowse(&history_pick, &history_draft, &history_draft_cursor);
                            focus = .query;
                        }
                    } else if (isTextKey(key)) {
                        const text = key.text orelse continue;
                        if (query.items.len + text.len <= 180) {
                            try query.insertSlice(ui.allocator, cursor_pos, text);
                            cursor_pos += text.len;
                            resetHistoryBrowse(&history_pick, &history_draft, &history_draft_cursor);
                            focus = .query;
                        }
                    }
                },
                else => {},
            }
        }
        if (batch.wheel_delta != 0 and !info_open) {
            if (focus == .downloads and state.settings.download_cache_enabled) {
                applyWheelDelta(&selected_download, state.download_entries.len, batch.wheel_delta, list_mouse_wheel_step);
            } else if (!query_dirty) {
                if (results) |*bundle| {
                    const visible_count = bundle.display_order.len;
                    applyWheelDelta(&selected_result, visible_count, batch.wheel_delta, list_mouse_wheel_step);
                    if (visible_count > 0) focus = .results;
                }
            }
        }
    }
}

fn runProviderFirstTui(ui: *Ui) !void {
    defer setContext(ui, null);
    const provider_names = try buildProviderNames(ui.allocator);
    defer freeOwnedStrings(ui.allocator, provider_names);

    var provider_default: ?usize = 0;

    provider_loop: while (true) {
        setContext(ui, "Provider list • URL: choose provider");
        const provider_choice = try vaxisSelect(
            ui,
            "Subtitle Downloader",
            "Space selects providers. Enter searches checked providers; if none are checked, it uses the highlighted provider. Esc quits.",
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
                .{app.providerDisplayName(provider)},
            ) catch "Enter search query. Esc returns to providers.";

            const query_context = try std.fmt.allocPrint(
                ui.allocator,
                "Provider: {s} • URL: {s}",
                .{ app.providerDisplayName(provider), provider_url },
            );
            defer ui.allocator.free(query_context);
            setContext(ui, query_context);

            const input = try vaxisInput(ui, "Subtitle Downloader", query_hint, "Query", .{ .max_len = 180 });
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
                            .{ app.providerDisplayName(provider), query, search_page_current },
                        )
                    else
                        try std.fmt.allocPrint(
                            ui.allocator,
                            "provider={s} query={s}",
                            .{ app.providerDisplayName(provider), query },
                        );
                    defer ui.allocator.free(search_detail);

                    const search_context = if (supports_search_pagination)
                        try std.fmt.allocPrint(
                            ui.allocator,
                            "Search URL base: {s} • page={d}",
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
                    var search_group: std.Io.Group = .init;
                    defer search_group.cancel(runtime_io.get());
                    try search_group.concurrent(runtime_io.get(), searchTaskMain, .{&search_task});
                    const search_control = try waitForTask(ui, &search_task.done, "Search", search_detail);
                    finalizeWorkerGroup(&search_group, search_control);

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
                        "Provider: {s} • Search base URL: {s} • page={d}",
                        .{ app.providerDisplayName(provider), provider_url, search_page_current },
                    )
                else
                    try std.fmt.allocPrint(
                        ui.allocator,
                        "Provider: {s} • Search base URL: {s}",
                        .{ app.providerDisplayName(provider), provider_url },
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
                    var seasons_group: std.Io.Group = .init;
                    defer seasons_group.cancel(runtime_io.get());
                    try seasons_group.concurrent(runtime_io.get(), subdlSeasonsTaskMain, .{&seasons_task});
                    const seasons_control = try waitForTask(ui, &seasons_task.done, "Seasons", seasons_detail);
                    finalizeWorkerGroup(&seasons_group, seasons_control);

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
                var allow_auto_subtitle_select = true;

                subtitle_page_loop: while (true) {
                    const subtitles_idx = findSubtitlesPageCacheIndex(subtitle_pages.items, subtitle_page_current) orelse blk_fetch: {
                        const subtitles_detail = if (selected_subdl_season_label) |season_label|
                            if (supports_subtitles_pagination)
                                try std.fmt.allocPrint(
                                    ui.allocator,
                                    "{s} • {s} • page={d}",
                                    .{ selected_title.label, season_label, subtitle_page_current },
                                )
                            else
                                try std.fmt.allocPrint(
                                    ui.allocator,
                                    "{s} • {s}",
                                    .{ selected_title.label, season_label },
                                )
                        else if (supports_subtitles_pagination)
                            try std.fmt.allocPrint(
                                ui.allocator,
                                "{s} • page={d}",
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
                                "Title URL: {s} • page={d}",
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
                        var subtitles_group: std.Io.Group = .init;
                        defer subtitles_group.cancel(runtime_io.get());
                        try subtitles_group.concurrent(runtime_io.get(), subtitlesTaskMain, .{&subtitles_task});
                        const subtitles_control = try waitForTask(ui, &subtitles_task.done, "Subtitles", subtitles_detail);
                        finalizeWorkerGroup(&subtitles_group, subtitles_control);

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

                    const subtitle_enabled = try buildSubtitleEnabled(ui.allocator, subtitles.items, defaultTuiSettings());
                    defer ui.allocator.free(subtitle_enabled);

                    const subtitle_context = if (supports_subtitles_pagination)
                        try std.fmt.allocPrint(
                            ui.allocator,
                            "Title URL: {s} • page={d}",
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
                    const subtitle_idx = (if (allow_auto_subtitle_select) singleEnabledIndex(subtitle_enabled) else null) orelse blk: {
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

                        break :blk switch (subtitle_choice) {
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
                    };
                    allow_auto_subtitle_select = false;

                    const selected_subtitle = subtitles.items[subtitle_idx];
                    const download_url = selected_subtitle.download_url orelse "(no direct URL)";
                    const download_url_display = if (isSubtitlecatTranslateToken(selected_subtitle.download_url))
                        "subtitlecat translate request"
                    else
                        download_url;

                    if (!ui.skip_confirm) {
                        var provider_buf: [224]u8 = undefined;
                        const provider_line = std.fmt.bufPrint(&provider_buf, "Provider: {s}", .{app.providerDisplayName(provider)}) catch "Provider: (overflow)";

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

                    const download_out_dir = try ui.allocator.dupe(u8, "downloads");
                    defer ui.allocator.free(download_out_dir);

                    var download_task: DownloadTask = .{
                        .subtitle = selected_subtitle,
                        .out_dir = download_out_dir,
                        .extract_archive = true,
                    };
                    var download_group: std.Io.Group = .init;
                    defer download_group.cancel(runtime_io.get());
                    try download_group.concurrent(runtime_io.get(), downloadTaskMain, .{&download_task});
                    const download_control = try waitForDownloadTask(ui, &download_task, "Download", download_detail);
                    finalizeWorkerGroup(&download_group, download_control);

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

const persistent_version = 10;
const default_cache_ttl_seconds: i64 = 12 * 60 * 60;
const search_state_magic = "subdl-tui-search-state-v1\n";
const settings_state_magic = "subdl-tui-settings-v1\n";
const keyword_state_magic = "subdl-tui-keywords-v1\n";

fn defaultTuiSettings() TuiSettings {
    return .{
        .providers_enabled = app.providerSelectionAll(),
        .languages_enabled = languageSelectionEnglish(),
        .language_filter_enabled = true,
        .cache_enabled = true,
        .download_cache_enabled = true,
        .cache_ttl_seconds = default_cache_ttl_seconds,
        .keyword_cache_enabled = true,
    };
}

fn loadTuiRuntimeState(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !TuiRuntimeState {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const state_path = try tuiCachePath(allocator, environ_map, "state.oneserial");
    errdefer allocator.free(state_path);
    const settings_path = try tuiCachePath(allocator, environ_map, "settings.oneserial");
    errdefer allocator.free(settings_path);
    const keyword_path = try tuiCachePath(allocator, environ_map, "keywords.oneserial");
    errdefer allocator.free(keyword_path);
    const cache_root_path = try tuiCachePath(allocator, environ_map, "cache");
    errdefer allocator.free(cache_root_path);

    var out: TuiRuntimeState = .{
        .arena = arena,
        .settings = defaultTuiSettings(),
        .state_path = state_path,
        .settings_path = settings_path,
        .keyword_path = keyword_path,
        .cache_root_path = cache_root_path,
    };
    errdefer out.deinit(allocator);

    if (try loadPersistentSearchState(out.arena.allocator(), state_path)) |loaded| {
        if (loaded.version == persistent_version) {
            out.settings = sanitizeSettings(loaded.settings);
            try out.cache_entries.appendSlice(allocator, loaded.cache_entries);
        }
    }

    if (try loadPersistentSettingsState(out.arena.allocator(), settings_path)) |loaded| {
        if (loaded.version == persistent_version) {
            out.settings = sanitizeSettings(loaded.settings);
        }
    }

    if (try loadPersistentKeywordState(out.arena.allocator(), keyword_path)) |loaded| {
        if (loaded.version == persistent_version) {
            try out.keywords.appendSlice(allocator, loaded.keywords);
        }
    }

    trimRuntimeStateBounds(&out);
    // Repack deserialized state once so temporary decoding allocations and
    // entries evicted by the bounds above do not remain pinned for the TUI lifetime.
    try compactRuntimeArena(allocator, &out);
    out.download_entries = try cachedDownloadLabels(allocator, cache_root_path);

    return out;
}

fn sanitizeSettings(settings: TuiSettings) TuiSettings {
    var out = settings;
    if (countEnabledFlags(&out.providers_enabled) == 0) out.providers_enabled = app.providerSelectionAll();
    if (singleEnabledIndex(&out.languages_enabled) == null) out.languages_enabled = languageSelectionEnglish();
    if (out.cache_ttl_seconds < 0) out.cache_ttl_seconds = default_cache_ttl_seconds;
    return out;
}

fn applyRuntimeCacheSettings(state: *const TuiRuntimeState) void {
    scrapers.common.configureFetchCache(.{
        .enabled = state.settings.cache_enabled,
        .root_dir = state.cache_root_path,
        .ttl_seconds = state.settings.cache_ttl_seconds,
    });
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

fn loadPersistentSettingsState(allocator: std.mem.Allocator, path: []const u8) !?PersistentSettingsState {
    const data = std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer allocator.free(data);
    if (!std.mem.startsWith(u8, data, settings_state_magic)) return null;
    const body = data[settings_state_magic.len..];
    const untrusted = oneserial.Untrusted(PersistentSettingsState, .{}).init(body);
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

fn saveTuiSettingsState(allocator: std.mem.Allocator, state: *const TuiRuntimeState) !void {
    const persist: PersistentSettingsState = .{
        .version = persistent_version,
        .settings = state.settings,
    };
    try saveOneSerial(PersistentSettingsState, allocator, state.settings_path, settings_state_magic, &persist);
}

fn saveOneSerial(comptime T: type, allocator: std.mem.Allocator, path: []const u8, magic: []const u8, value: *const T) !void {
    try ensureParentDir(path);
    const encoded = try oneserial.serializeAlloc(T, .{}, value, allocator);
    defer allocator.free(encoded);
    var file = try std.Io.Dir.cwd().createFile(runtime_io.get(), path, .{});
    defer file.close(runtime_io.get());
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(runtime_io.get(), &buffer);
    try writer.interface.writeAll(magic);
    try writer.interface.writeAll(encoded);
    try writer.interface.flush();
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
    if (ttl_seconds == 0) return true;
    if (ttl_seconds < 0) return false;
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

fn searchCacheKey(allocator: std.mem.Allocator, query_norm: []const u8, language_code: ?[]const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\x1flang={s}",
        .{ query_norm, language_code orelse "*" },
    );
}

const max_query_cache_entries: usize = 512;
const max_keyword_entries: usize = 128;
const arena_compact_after_stale_mutations: usize = 32;

fn trimRuntimeStateBounds(state: *TuiRuntimeState) void {
    while (state.cache_entries.items.len > max_query_cache_entries) {
        const idx = oldestCacheEntryIndex(state.cache_entries.items) orelse break;
        _ = state.cache_entries.orderedRemove(idx);
    }
    while (state.keywords.items.len > max_keyword_entries) {
        var oldest: usize = 0;
        for (state.keywords.items[1..], 1..) |entry, idx| {
            if (entry.used_at_unix < state.keywords.items[oldest].used_at_unix) oldest = idx;
        }
        _ = state.keywords.orderedRemove(oldest);
    }
}

fn compactRuntimeArena(allocator: std.mem.Allocator, state: *TuiRuntimeState) !void {
    var next_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer next_arena.deinit();
    const a = next_arena.allocator();

    const cache_copy = try allocator.alloc(QueryCacheEntry, state.cache_entries.items.len);
    defer allocator.free(cache_copy);
    for (state.cache_entries.items, 0..) |entry, idx| {
        cache_copy[idx] = .{
            .provider = entry.provider,
            .query_norm = try a.dupe(u8, entry.query_norm),
            .page = entry.page,
            .fetched_at_unix = entry.fetched_at_unix,
            .response = try cloneCachedSearchResponse(a, entry.response),
        };
    }

    const keyword_copy = try allocator.alloc(KeywordEntry, state.keywords.items.len);
    defer allocator.free(keyword_copy);
    for (state.keywords.items, 0..) |entry, idx| {
        keyword_copy[idx] = .{
            .query = try a.dupe(u8, entry.query),
            .used_at_unix = entry.used_at_unix,
            .use_count = entry.use_count,
        };
    }

    state.arena.deinit();
    state.arena = next_arena;
    @memcpy(state.cache_entries.items, cache_copy);
    @memcpy(state.keywords.items, keyword_copy);
    state.arena_stale_mutations = 0;
}

fn cloneCachedSearchResponse(allocator: std.mem.Allocator, response: CachedSearchResponse) !CachedSearchResponse {
    const items = try allocator.alloc(app.SearchChoice, response.items.len);
    for (response.items, 0..) |item, idx| {
        items[idx] = try cloneSearchChoice(allocator, item);
    }
    return .{
        .provider = response.provider,
        .items = items,
        .page = response.page,
        .has_prev_page = response.has_prev_page,
        .has_next_page = response.has_next_page,
    };
}

fn oldestCacheEntryIndex(entries: []const QueryCacheEntry) ?usize {
    if (entries.len == 0) return null;
    var oldest: usize = 0;
    for (entries[1..], 1..) |entry, idx| {
        if (entry.fetched_at_unix < entries[oldest].fetched_at_unix) oldest = idx;
    }
    return oldest;
}

fn upsertCacheEntry(allocator: std.mem.Allocator, state: *TuiRuntimeState, provider: app.Provider, query_norm: []const u8, page: u32, fetched_at_unix: i64, response: app.SearchResponse) !void {
    if (!state.settings.cache_enabled) return;
    const a = state.arena.allocator();
    var existing_idx: ?usize = null;
    for (state.cache_entries.items, 0..) |existing, idx| {
        if (existing.provider == provider and existing.page == page and std.mem.eql(u8, existing.query_norm, query_norm)) {
            existing_idx = idx;
            break;
        }
    }
    const cached_response = try cachedResponseFromSearch(a, response);
    const query_copy = try a.dupe(u8, query_norm);
    const entry: QueryCacheEntry = .{
        .provider = provider,
        .query_norm = query_copy,
        .page = page,
        .fetched_at_unix = fetched_at_unix,
        .response = cached_response,
    };
    if (existing_idx) |idx| {
        state.cache_entries.items[idx] = entry;
        state.arena_stale_mutations += 1;
    } else {
        try state.cache_entries.append(allocator, entry);
    }

    while (state.cache_entries.items.len > max_query_cache_entries) {
        const idx = oldestCacheEntryIndex(state.cache_entries.items) orelse break;
        _ = state.cache_entries.orderedRemove(idx);
        state.arena_stale_mutations += 1;
    }
    if (state.arena_stale_mutations >= arena_compact_after_stale_mutations) {
        try compactRuntimeArena(allocator, state);
    }
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
        .sub_scene_com => |item| .{ .sub_scene_com = .{
            .title = try allocator.dupe(u8, item.title),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .tvsubtitles_net => |item| .{ .tvsubtitles_net = .{ .title = try allocator.dupe(u8, item.title), .show_url = try allocator.dupe(u8, item.show_url) } },
        .gestdown_info => |item| .{ .gestdown_info = .{
            .title = try allocator.dupe(u8, item.title),
            .id = try allocator.dupe(u8, item.id),
            .seasons = try allocator.dupe(i64, item.seasons),
        } },
        .greeksubtitles_com => |item| .{ .greeksubtitles_com = .{
            .title = try allocator.dupe(u8, item.title),
            .language_code = try dupOptionalLocal(allocator, item.language_code),
            .page_url = try allocator.dupe(u8, item.page_url),
            .download_url = try allocator.dupe(u8, item.download_url),
        } },
        .subsunacs_net => |item| .{ .subsunacs_net = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .page_url = try allocator.dupe(u8, item.page_url),
            .download_page_url = try allocator.dupe(u8, item.download_page_url),
        } },
        .subtitles_ajatt_top => |item| .{ .subtitles_ajatt_top = .{
            .title = try allocator.dupe(u8, item.title),
            .media_kind = item.media_kind,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .subtis_io => |item| .{ .subtis_io = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .slug = try allocator.dupe(u8, item.slug),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .greeksubs_net => |item| .{ .greeksubs_net = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .media_kind = item.media_kind,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .indexsubtitle_cc => |item| .{ .indexsubtitle_cc = .{
            .title = try allocator.dupe(u8, item.title),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .sous_titres_eu => |item| .{ .sous_titres_eu = .{
            .title = try allocator.dupe(u8, item.title),
            .media_kind = item.media_kind,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .cc_edatribe_com => |item| .{ .cc_edatribe_com = .{
            .title = try allocator.dupe(u8, item.title),
            .media_kind = item.media_kind,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .subtitrari_noi_ro => |item| .{ .subtitrari_noi_ro = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .page_url = try allocator.dupe(u8, item.page_url),
            .download_url = try allocator.dupe(u8, item.download_url),
        } },
        .subs_ro => |item| .{ .subs_ro = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .media_kind = item.media_kind,
            .language_code = try allocator.dupe(u8, item.language_code),
            .release = try allocator.dupe(u8, item.release),
            .page_url = try allocator.dupe(u8, item.page_url),
            .download_url = try allocator.dupe(u8, item.download_url),
        } },
        .subs4free_info => |item| .{ .subs4free_info = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .language_code = try allocator.dupe(u8, item.language_code),
            .release = try allocator.dupe(u8, item.release),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .tsukihime_org => |item| .{ .tsukihime_org = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .media_kind = item.media_kind,
            .torrent_id = item.torrent_id,
            .season = item.season,
            .episode = item.episode,
            .release = try allocator.dupe(u8, item.release),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .subtitri_nekur_net => |item| .{ .subtitri_nekur_net = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .imdb_id = if (item.imdb_id) |v| try allocator.dupe(u8, v) else null,
            .fps = if (item.fps) |v| try allocator.dupe(u8, v) else null,
            .page_url = try allocator.dupe(u8, item.page_url),
            .download_url = try allocator.dupe(u8, item.download_url),
        } },
        .subsynchro_com => |item| .{ .subsynchro_com = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .titrari_ro => |item| .{ .titrari_ro = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .media_kind = item.media_kind,
            .language_code = try allocator.dupe(u8, item.language_code),
            .subtitle_id = try allocator.dupe(u8, item.subtitle_id),
            .page_url = try allocator.dupe(u8, item.page_url),
            .download_url = try allocator.dupe(u8, item.download_url),
        } },
        .subs_sab_bz => |item| .{ .subs_sab_bz = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .media_kind = item.media_kind,
            .language_code = try allocator.dupe(u8, item.language_code),
            .attach_id = try allocator.dupe(u8, item.attach_id),
            .page_url = try allocator.dupe(u8, item.page_url),
            .download_url = try allocator.dupe(u8, item.download_url),
        } },
        .subtitri_do_am => |item| .{ .subtitri_do_am = .{
            .title = try allocator.dupe(u8, item.title),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .prijevodi_online_org => |item| .{ .prijevodi_online_org = .{
            .title = try allocator.dupe(u8, item.title),
            .series_id = item.series_id,
            .slug = try allocator.dupe(u8, item.slug),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .animekalesi_com => |item| .{ .animekalesi_com = .{
            .title = try allocator.dupe(u8, item.title),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .subcentral_de => |item| .{ .subcentral_de = .{
            .title = try allocator.dupe(u8, item.title),
            .season = item.season,
            .board_url = try allocator.dupe(u8, item.board_url),
            .thread_url = try allocator.dupe(u8, item.thread_url),
        } },
        .subtitulamos_tv => |item| .{ .subtitulamos_tv = .{
            .title = try allocator.dupe(u8, item.title),
            .show_id = item.show_id,
            .season = item.season,
            .episode = item.episode,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .feliratok_eu => |item| .{ .feliratok_eu = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .language_code = try allocator.dupe(u8, item.language_code),
            .filename = try allocator.dupe(u8, item.filename),
            .page_url = try allocator.dupe(u8, item.page_url),
            .download_url = try allocator.dupe(u8, item.download_url),
        } },
        .animesub_info => |item| .{ .animesub_info = .{
            .title = try allocator.dupe(u8, item.title),
            .media_kind = item.media_kind,
            .season = item.season,
            .episode = item.episode,
            .subtitle_id = try allocator.dupe(u8, item.subtitle_id),
            .download_hash = try allocator.dupe(u8, item.download_hash),
            .session_cookie = try allocator.dupe(u8, item.session_cookie),
            .search_query = try allocator.dupe(u8, item.search_query),
            .title_type = try allocator.dupe(u8, item.title_type),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .subhd_tv => |item| .{ .subhd_tv = .{
            .title = try allocator.dupe(u8, item.title),
            .release_info = try allocator.dupe(u8, item.release_info),
            .media_kind = item.media_kind,
            .season = item.season,
            .episode = item.episode,
            .language_code = try allocator.dupe(u8, item.language_code),
            .subtitle_id = try allocator.dupe(u8, item.subtitle_id),
            .filename = try allocator.dupe(u8, item.filename),
            .detail_url = try allocator.dupe(u8, item.detail_url),
        } },
        .fansubs_ru => |item| .{ .fansubs_ru = .{
            .title = try allocator.dupe(u8, item.title),
            .media_id = try allocator.dupe(u8, item.media_id),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .legendei_net => |item| .{ .legendei_net = .{
            .title = try allocator.dupe(u8, item.title),
            .post_id = item.post_id,
            .media_kind = item.media_kind,
            .season = item.season,
            .episode = item.episode,
            .language_code = try allocator.dupe(u8, item.language_code),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .zoom_lk => |item| .{ .zoom_lk = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .media_kind = item.media_kind,
            .season = item.season,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .justsubtitles_com => |item| .{ .justsubtitles_com = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .movie_id = item.movie_id,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .wizdom_xyz => |item| .{ .wizdom_xyz = .{
            .title = try allocator.dupe(u8, item.title),
            .year = item.year,
            .media_kind = item.media_kind,
            .imdb_id = try allocator.dupe(u8, item.imdb_id),
            .season = item.season,
            .episode = item.episode,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .miraianime_net => |item| .{ .miraianime_net = .{
            .title = try allocator.dupe(u8, item.title),
            .english_title = try dupOptionalLocal(allocator, item.english_title),
            .anime_id = item.anime_id,
            .media_kind = item.media_kind,
            .episodes = item.episodes,
            .page_url = try allocator.dupe(u8, item.page_url),
            .subtitle_page_url = try allocator.dupe(u8, item.subtitle_page_url),
        } },
        .animesubtitle_ir => |item| .{ .animesubtitle_ir = .{
            .title = try allocator.dupe(u8, item.title),
            .post_id = item.post_id,
            .media_kind = item.media_kind,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .grupahatak_pl => |item| .{ .grupahatak_pl = .{
            .title = try allocator.dupe(u8, item.title),
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
        .jimaku_cc => |item| .{ .jimaku_cc = .{
            .title = try allocator.dupe(u8, item.title),
            .english_name = try dupOptionalLocal(allocator, item.english_name),
            .japanese_name = try dupOptionalLocal(allocator, item.japanese_name),
            .media_kind = item.media_kind,
            .entry_id = item.entry_id,
            .page_url = try allocator.dupe(u8, item.page_url),
        } },
    };
}

fn dupOptionalLocal(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn executeQuerySearch(ui: *Ui, state: *TuiRuntimeState, query_norm: []const u8) !SearchBundle {
    var bundle: SearchBundle = .{ .query_norm = try ui.allocator.dupe(u8, query_norm) };
    errdefer bundle.deinit(ui.allocator);
    const now = scrapers.common.compatUnixTimestamp();
    const language_code = primaryLanguageCode(state.settings);
    const cache_key = try searchCacheKey(ui.allocator, query_norm, language_code);
    defer ui.allocator.free(cache_key);

    for (app.providers()) |provider| {
        if (!state.settings.providers_enabled[app.providerIndex(provider)]) continue;
        ui.active_provider = provider;

        const response_index = bundle.searches.items.len;
        if (findCacheEntry(state, provider, cache_key, 1, now)) |cache_idx| {
            const cached = try searchResponseFromCache(ui.allocator, state.cache_entries.items[cache_idx]);
            try bundle.searches.append(ui.allocator, cached);
            for (bundle.searches.items[response_index].items, 0..) |_, item_index| {
                try bundle.hits.append(ui.allocator, .{ .provider = provider, .response_index = response_index, .item_index = item_index, .source = .cache });
            }
            bundle.cache_count += 1;
            continue;
        }

        const detail = try std.fmt.allocPrint(ui.allocator, "provider={s} query={s}", .{ app.providerDisplayName(provider), query_norm });
        defer ui.allocator.free(detail);
        const context = try std.fmt.allocPrint(ui.allocator, "Search URL: {s}", .{providerHomeUrl(provider)});
        defer ui.allocator.free(context);
        setContext(ui, context);

        var search_task: SearchTask = .{
            .provider = provider,
            .query = query_norm,
            .language_code = language_code,
            .page = 1,
        };
        var search_group: std.Io.Group = .init;
        defer search_group.cancel(runtime_io.get());
        try search_group.concurrent(runtime_io.get(), searchTaskMain, .{&search_task});
        const search_control = try waitForTask(ui, &search_task.done, "Searching", detail);
        finalizeWorkerGroup(&search_group, search_control);

        if (search_control == .quit) {
            if (search_task.result) |*r| r.deinit();
            return error.TuiQuit;
        }
        if (search_control == .canceled) {
            if (search_task.result) |*r| r.deinit();
            return bundle;
        }
        if (search_task.err) |err| {
            recordSearchFailure(&bundle, err);
            continue;
        }
        const search_result = search_task.result orelse {
            bundle.failed_count += 1;
            continue;
        };
        try upsertCacheEntry(ui.allocator, state, provider, cache_key, 1, now, search_result);
        bundle.cache_changed = true;
        try bundle.searches.append(ui.allocator, search_result);
        for (bundle.searches.items[response_index].items, 0..) |_, item_index| {
            try bundle.hits.append(ui.allocator, .{ .provider = provider, .response_index = response_index, .item_index = item_index, .source = .live });
        }
        bundle.live_count += 1;
    }

    bundle.labels = try buildCombinedSearchLabelsWithSource(ui.allocator, bundle.searches.items, bundle.hits.items);
    return bundle;
}

const IncrementalSearchOutcome = struct {
    bundle: SearchBundle,
    focus: QueryFocus,
    discard_results: bool = false,
    mark_query_dirty: bool = false,
};

fn executeQuerySearchIncremental(
    ui: *Ui,
    state: *TuiRuntimeState,
    query_norm: []const u8,
    query_display: []const u8,
    cursor_pos: usize,
    selected_result: *usize,
    result_scroll: *usize,
    info_open: *bool,
) !IncrementalSearchOutcome {
    var bundle: SearchBundle = .{
        .query_norm = try ui.allocator.dupe(u8, query_norm),
        .searching = true,
    };
    errdefer bundle.deinit(ui.allocator);
    var selected_download: usize = 0;
    var download_scroll: usize = 0;

    const search_work = try createIncrementalSearchWork(query_norm);
    var search_work_owned = true;
    defer if (search_work_owned) {
        search_work.group.cancel(runtime_io.get());
        releaseIncrementalSearchWork(search_work);
    };
    const tasks = search_work.tasks;
    const consumed = search_work.consumed;
    const search_group = search_work.group;

    var task_count: usize = 0;
    const language_code = primaryLanguageCode(state.settings);
    const cache_key = try searchCacheKey(ui.allocator, query_norm, language_code);
    defer ui.allocator.free(cache_key);
    const now = scrapers.common.compatUnixTimestamp();
    for (app.providers()) |provider| {
        if (!state.settings.providers_enabled[app.providerIndex(provider)]) continue;
        if (findCacheEntry(state, provider, cache_key, 1, now)) |cache_idx| {
            const response_index = bundle.searches.items.len;
            const cached = try searchResponseFromCache(ui.allocator, state.cache_entries.items[cache_idx]);
            try bundle.searches.append(ui.allocator, cached);
            for (bundle.searches.items[response_index].items, 0..) |_, item_index| {
                try bundle.hits.append(ui.allocator, .{
                    .provider = provider,
                    .response_index = response_index,
                    .item_index = item_index,
                    .source = .cache,
                });
            }
            bundle.cache_count += 1;
            continue;
        }
        tasks[task_count] = .{
            .provider = provider,
            .query = search_work.query,
            .language_code = language_code,
            .page = 1,
        };
        try search_group.concurrent(runtime_io.get(), providerSearchTaskMain, .{&tasks[task_count]});
        task_count += 1;
        search_work.task_count = task_count;
        bundle.pending_count += 1;
    }

    try renderQueryHome(
        ui,
        state,
        query_display,
        cursor_pos,
        if (bundle.hits.items.len > 0) .results else .query,
        false,
        &bundle,
        selected_result,
        result_scroll,
        &selected_download,
        &download_scroll,
        info_open.*,
        true,
    );

    while (bundle.pending_count > 0) {
        var dirty = false;
        var cache_response_indices: [app.providerCount()]usize = undefined;
        var cache_response_count: usize = 0;
        var idx: usize = 0;
        while (idx < task_count) : (idx += 1) {
            if (consumed[idx]) continue;
            if (tasks[idx].done.load(.acquire) == 0) continue;
            consumed[idx] = true;
            bundle.pending_count -= 1;
            dirty = true;
            if (tasks[idx].err) |err| {
                recordSearchFailure(&bundle, err);
                continue;
            }
            const search_result = tasks[idx].result orelse {
                bundle.failed_count += 1;
                continue;
            };
            const response_index = bundle.searches.items.len;
            try bundle.searches.append(ui.allocator, search_result);
            for (bundle.searches.items[response_index].items, 0..) |_, item_index| {
                try bundle.hits.append(ui.allocator, .{ .provider = tasks[idx].provider, .response_index = response_index, .item_index = item_index, .source = .live });
            }
            bundle.live_count += 1;
            cache_response_indices[cache_response_count] = response_index;
            cache_response_count += 1;
        }

        var wheel_delta: i32 = 0;
        while (try ui.loop.tryEvent()) |event| {
            dirty = true;
            switch (event) {
                .winsize => |ws| try ui.resize(ws),
                .mouse => |mouse| {
                    if (info_open.*) {
                        if (mouse.type == .press) info_open.* = false;
                        continue;
                    }
                    if (mouseWheelDelta(mouse)) |delta| {
                        wheel_delta += delta;
                    } else if (mouse.type == .press and bundle.display_order.len > 0) switch (mouse.button) {
                        .left => {
                            const win = ui.vx.window();
                            if (mouseRowIndex(mouse, homeListTop(), homeListBottom(win.height), result_scroll.*, bundle.display_order.len)) |row_idx| {
                                selected_result.* = row_idx;
                            }
                        },
                        else => {},
                    };
                },
                .key_press => |key| {
                    if (key.isModifier()) continue;
                    if (key.matches('d', .{ .ctrl = true })) {
                        ui.hardQuit();
                    }
                    if (key.matches('c', .{ .ctrl = true })) {
                        bundle.searching = false;
                        bundle.pending_count = 0;
                        bundle.canceled = true;
                        if (ui.reapSearchWork(search_work)) {
                            search_work_owned = false;
                        }
                        return .{
                            .bundle = bundle,
                            .focus = .query,
                            .mark_query_dirty = true,
                        };
                    }
                    if (info_open.*) {
                        if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.f1, .{})) {
                            info_open.* = false;
                            continue;
                        }
                        info_open.* = false;
                    }
                    if (key.matches(vaxis.Key.escape, .{})) {
                        const search_settings_changed = try editSettingsPopup(
                            ui,
                            state,
                            query_display,
                            cursor_pos,
                            if (bundle.hits.items.len > 0) .results else .query,
                            false,
                            &bundle,
                            selected_result,
                            result_scroll,
                            &selected_download,
                            &download_scroll,
                            info_open,
                        );
                        if (search_settings_changed) {
                            bundle.searching = false;
                            bundle.pending_count = 0;
                            if (ui.reapSearchWork(search_work)) {
                                search_work_owned = false;
                            }
                            return .{
                                .bundle = bundle,
                                .focus = .query,
                                .discard_results = true,
                            };
                        }
                        continue;
                    }
                    if (key.matches(vaxis.Key.f1, .{})) {
                        if (canRenderOverlayMenu(ui.vx.window())) info_open.* = !info_open.*;
                        continue;
                    }
                    if (bundle.display_order.len > 0 and key.matches(vaxis.Key.down, .{})) {
                        selected_result.* = @min(bundle.display_order.len - 1, selected_result.* + 1);
                        continue;
                    }
                    if (bundle.display_order.len > 0 and key.matches(vaxis.Key.up, .{})) {
                        selected_result.* = selected_result.* -| 1;
                        continue;
                    }
                    if (bundle.display_order.len > 0 and key.matches(vaxis.Key.page_down, .{})) {
                        selected_result.* = @min(bundle.display_order.len - 1, selected_result.* + queryPageSize(ui));
                        continue;
                    }
                    if (key.matches(vaxis.Key.page_up, .{})) {
                        selected_result.* = selected_result.* -| queryPageSize(ui);
                        continue;
                    }
                    if (bundle.display_order.len > 0 and key.matches(vaxis.Key.end, .{})) {
                        selected_result.* = bundle.display_order.len - 1;
                        continue;
                    }
                    if (key.matches(vaxis.Key.home, .{})) {
                        selected_result.* = 0;
                        continue;
                    }
                    if (bundle.display_order.len > 0 and key.matches(vaxis.Key.enter, .{})) {
                        const visible_order = bundle.display_order;
                        if (selected_result.* >= visible_order.len) continue;
                        switch (try openSearchResult(ui, &bundle, visible_order[selected_result.*], state)) {
                            .back => {},
                            .to_query => {
                                bundle.searching = false;
                                bundle.pending_count = 0;
                                bundle.canceled = true;
                                if (ui.reapSearchWork(search_work)) {
                                    search_work_owned = false;
                                }
                                return .{
                                    .bundle = bundle,
                                    .focus = .query,
                                    .mark_query_dirty = true,
                                };
                            },
                            .quit => {
                                if (ui.reapSearchWork(search_work)) {
                                    search_work_owned = false;
                                }
                                return error.TuiQuit;
                            },
                        }
                        continue;
                    }
                },
                else => {},
            }
        }
        if (wheel_delta != 0) {
            applyWheelDelta(selected_result, bundle.display_order.len, wheel_delta, list_mouse_wheel_step);
            dirty = true;
        }
        if (dirty) {
            clampSelection(selected_result, bundle.display_order.len);
            try renderQueryHome(ui, state, query_display, cursor_pos, if (bundle.hits.items.len > 0) .results else .query, false, &bundle, selected_result, result_scroll, &selected_download, &download_scroll, info_open.*, true);
        }
        for (cache_response_indices[0..cache_response_count]) |response_index| {
            const response = bundle.searches.items[response_index];
            try upsertCacheEntry(
                ui.allocator,
                state,
                response.provider,
                cache_key,
                1,
                scrapers.common.compatUnixTimestamp(),
                response,
            );
            bundle.cache_changed = true;
        }
        try runtime_io.get().sleep(.fromMilliseconds(if (dirty) search_active_poll_interval_ms else search_poll_interval_ms), .awake);
    }

    try search_group.await(runtime_io.get());
    bundle.searching = false;
    try renderQueryHome(ui, state, query_display, cursor_pos, if (bundle.hits.items.len > 0) .results else .query, false, &bundle, selected_result, result_scroll, &selected_download, &download_scroll, info_open.*, true);
    return .{
        .bundle = bundle,
        .focus = if (bundle.hits.items.len > 0) .results else .query,
    };
}

fn cleanupUnconsumedProviderTasks(tasks: []ProviderSearchTask, consumed: []const bool) void {
    for (tasks, 0..) |*task, idx| {
        if (consumed[idx]) continue;
        if (task.result) |*result| result.deinit();
    }
}

fn createIncrementalSearchWork(query: []const u8) !*IncrementalSearchWork {
    const allocator = std.heap.page_allocator;
    const work = try allocator.create(IncrementalSearchWork);
    errdefer allocator.destroy(work);
    const group = try allocator.create(std.Io.Group);
    errdefer allocator.destroy(group);
    group.* = .init;
    const tasks = try allocator.alloc(ProviderSearchTask, app.providerCount());
    errdefer allocator.free(tasks);
    const consumed = try allocator.alloc(bool, app.providerCount());
    errdefer allocator.free(consumed);
    @memset(consumed, false);
    const query_copy = try allocator.dupe(u8, query);
    errdefer allocator.free(query_copy);
    work.* = .{
        .group = group,
        .tasks = tasks,
        .consumed = consumed,
        .query = query_copy,
    };
    return work;
}

fn releaseIncrementalSearchWork(work: *IncrementalSearchWork) void {
    const allocator = std.heap.page_allocator;
    std.debug.assert(work.task_count <= work.tasks.len);
    std.debug.assert(work.task_count <= work.consumed.len);
    cleanupUnconsumedProviderTasks(
        work.tasks[0..work.task_count],
        work.consumed[0..work.task_count],
    );
    allocator.free(work.query);
    allocator.free(work.consumed);
    allocator.free(work.tasks);
    allocator.destroy(work.group);
    allocator.destroy(work);
}

fn cancelIncrementalSearchWork(work: *IncrementalSearchWork) void {
    work.group.cancel(runtime_io.get());
    releaseIncrementalSearchWork(work);
}

fn runSearchReaper(job: *SearchReaperJob) void {
    cancelIncrementalSearchWork(job.work);
    job.done.store(1, .release);
}

fn queryPageSize(ui: *Ui) usize {
    const win = ui.vx.window();
    if (win.height <= 12) return 4;
    return @max(@as(usize, 4), @as(usize, @intCast(win.height - 10)));
}

fn nextQueryFocus(current: QueryFocus, has_results: bool, has_downloads: bool) QueryFocus {
    return switch (current) {
        .query => if (has_results) .results else if (has_downloads) .downloads else .query,
        .results => if (has_downloads) .downloads else .query,
        .downloads => .query,
    };
}

fn normalizeQueryFocus(current: QueryFocus, has_results: bool, has_downloads: bool) QueryFocus {
    return switch (current) {
        .query => .query,
        .results => if (has_results) .results else .query,
        .downloads => if (has_downloads) .downloads else if (has_results) .results else .query,
    };
}

test "query focus cannot stay on hidden panes" {
    try std.testing.expectEqual(QueryFocus.query, normalizeQueryFocus(.results, false, false));
    try std.testing.expectEqual(QueryFocus.results, normalizeQueryFocus(.results, true, false));
    try std.testing.expectEqual(QueryFocus.query, normalizeQueryFocus(.downloads, false, false));
    try std.testing.expectEqual(QueryFocus.results, normalizeQueryFocus(.downloads, true, false));
    try std.testing.expectEqual(QueryFocus.downloads, normalizeQueryFocus(.downloads, true, true));
}

fn cleanSearchTitle(label: []const u8) []const u8 {
    var text = std.mem.trim(u8, label, " \t\r\n");
    while (std.mem.startsWith(u8, text, "[")) {
        const end = std.mem.indexOfScalar(u8, text, ']') orelse break;
        if (end > 24) break;
        if (!isSearchMetadataTag(text[1..end])) break;
        text = std.mem.trim(u8, text[end + 1 ..], " \t");
    }
    return text;
}

fn isSearchMetadataTag(tag: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(tag, "movie") or std.ascii.eqlIgnoreCase(tag, "tv")) return true;
    for (language_options) |language| {
        if (std.ascii.eqlIgnoreCase(tag, language.code)) return true;
    }
    return false;
}

fn formatHomeTopLine(
    buf: []u8,
    focus: QueryFocus,
    enabled_provider_count: usize,
    provider_count: usize,
    download_count: usize,
    maybe_bundle: ?*const SearchBundle,
    visible_result_count: ?usize,
) ![]const u8 {
    var pos: usize = 0;
    const search_tab = if (focus == .downloads) "Search" else "SEARCH";
    const downloads_tab = if (focus == .downloads) "DOWNLOADS" else "Downloads";
    pos += (try std.fmt.bufPrint(buf[pos..], "F1 Help · Esc Settings · {s}", .{search_tab})).len;
    if (download_count > 0) pos += (try std.fmt.bufPrint(buf[pos..], " · {s} {d}", .{ downloads_tab, download_count })).len;
    pos += (try std.fmt.bufPrint(buf[pos..], " · {d}/{d} providers", .{ enabled_provider_count, provider_count })).len;
    if (maybe_bundle) |bundle| {
        if (bundle.hits.items.len > 0) {
            const visible_count = visible_result_count orelse bundle.hits.items.len;
            if (visible_count == bundle.hits.items.len) {
                pos += (try std.fmt.bufPrint(buf[pos..], " · {d} results", .{bundle.hits.items.len})).len;
            } else {
                pos += (try std.fmt.bufPrint(buf[pos..], " · {d}/{d} results", .{ visible_count, bundle.hits.items.len })).len;
            }
        }
        if (bundle.live_count > 0) pos += (try std.fmt.bufPrint(buf[pos..], " · {d} live", .{bundle.live_count})).len;
        if (bundle.cache_count > 0) pos += (try std.fmt.bufPrint(buf[pos..], " · {d} cached", .{bundle.cache_count})).len;
        if (bundle.failed_count > 0) pos += (try std.fmt.bufPrint(buf[pos..], " · {d} failed", .{bundle.failed_count})).len;
        if (bundle.unavailable_count > 0) pos += (try std.fmt.bufPrint(buf[pos..], " · {d} unavailable", .{bundle.unavailable_count})).len;
        if (bundle.pending_count > 0) pos += (try std.fmt.bufPrint(buf[pos..], " · {d} pending", .{bundle.pending_count})).len;
        if (bundle.canceled) pos += (try std.fmt.bufPrint(buf[pos..], " · canceled", .{})).len;
    }
    return buf[0..pos];
}

fn buildQueryHitOrder(
    allocator: std.mem.Allocator,
    bundle: *const SearchBundle,
    query_norm: []const u8,
) ![]usize {
    const hit_count = bundle.hits.items.len;
    if (hit_count == 0) return allocator.alloc(usize, 0);

    const scores = try allocator.alloc(u32, hit_count);
    defer allocator.free(scores);
    var match_count: usize = 0;
    for (scores, 0..) |*score, idx| {
        score.* = queryHitScore(bundle, idx, query_norm);
        if (score.* > 0) match_count += 1;
    }

    const include_all = query_norm.len == 0;
    const visible_count = if (include_all) hit_count else match_count;
    const out = try allocator.alloc(usize, visible_count);
    var out_len: usize = 0;
    for (bundle.hits.items, 0..) |_, idx| {
        if (include_all or scores[idx] > 0) {
            out[out_len] = idx;
            out_len += 1;
        }
    }

    const Ctx = struct {
        scores: []const u32,

        fn less(ctx: @This(), lhs: usize, rhs: usize) bool {
            const lhs_score = ctx.scores[lhs];
            const rhs_score = ctx.scores[rhs];
            if (lhs_score != rhs_score) return lhs_score > rhs_score;
            return lhs < rhs;
        }
    };
    std.mem.sort(usize, out, Ctx{ .scores = scores }, Ctx.less);
    return out;
}

fn ensureQueryHitOrder(
    allocator: std.mem.Allocator,
    bundle: *SearchBundle,
    query_norm: []const u8,
) ![]const usize {
    if (bundle.display_query_norm) |cached_query| {
        if (bundle.display_hit_count == bundle.hits.items.len and
            std.mem.eql(u8, cached_query, query_norm))
        {
            return bundle.display_order;
        }
    }

    const new_order = try buildQueryHitOrder(allocator, bundle, query_norm);
    errdefer allocator.free(new_order);
    const new_query = try allocator.dupe(u8, query_norm);
    errdefer allocator.free(new_query);

    if (bundle.display_query_norm) |cached_query| allocator.free(cached_query);
    if (bundle.display_order.len > 0) allocator.free(bundle.display_order);
    bundle.display_query_norm = new_query;
    bundle.display_hit_count = bundle.hits.items.len;
    bundle.display_order = new_order;
    return bundle.display_order;
}

test "search title cleanup strips only known metadata prefixes" {
    try std.testing.expectEqualStrings("The Matrix (1999)", cleanSearchTitle("[movie] The Matrix (1999)"));
    try std.testing.expectEqualStrings("The Matrix", cleanSearchTitle("[en] The Matrix"));
    try std.testing.expectEqualStrings("[REC] (2007)", cleanSearchTitle("[REC] (2007)"));
    try std.testing.expectEqualStrings("[REC] 2", cleanSearchTitle("[REC] 2"));
    try std.testing.expectEqualStrings("[REC]", cleanSearchTitle("[tv] [en] [REC]"));
}

test "query display order cache reuses stable hit sets and invalidates on changes" {
    const allocator = std.testing.allocator;
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    const a = response_arena.allocator();
    const items = try a.alloc(app.SearchChoice, 3);
    items[0] = .{
        .label = "Matrix Revolutions (2003)",
        .ref = .{ .subdl_com = .{ .title = "Matrix Revolutions", .media_type = .movie, .link = "https://example.test/0" } },
    };
    items[1] = .{
        .label = "The Matrix (1999)",
        .ref = .{ .subdl_com = .{ .title = "The Matrix", .media_type = .movie, .link = "https://example.test/1" } },
    };
    items[2] = .{
        .label = "Matrix Reloaded (2003)",
        .ref = .{ .subdl_com = .{ .title = "Matrix Reloaded", .media_type = .movie, .link = "https://example.test/2" } },
    };

    var bundle: SearchBundle = .{ .query_norm = try allocator.dupe(u8, "matrix") };
    defer bundle.deinit(allocator);
    try bundle.searches.append(allocator, .{
        .arena = response_arena,
        .provider = .subdl_com,
        .items = items,
    });
    try bundle.hits.append(allocator, .{ .provider = .subdl_com, .response_index = 0, .item_index = 0 });
    try bundle.hits.append(allocator, .{ .provider = .subdl_com, .response_index = 0, .item_index = 1 });

    const first = try ensureQueryHitOrder(allocator, &bundle, "matrix");
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, first);
    const cached_ptr = first.ptr;
    const second = try ensureQueryHitOrder(allocator, &bundle, "matrix");
    try std.testing.expectEqual(cached_ptr, second.ptr);

    try bundle.hits.append(allocator, .{ .provider = .subdl_com, .response_index = 0, .item_index = 2 });
    const expanded = try ensureQueryHitOrder(allocator, &bundle, "matrix");
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 1 }, expanded);
    try std.testing.expectEqual(@as(usize, 3), bundle.display_hit_count);

    const narrowed = try ensureQueryHitOrder(allocator, &bundle, "the matrix");
    try std.testing.expectEqualSlices(usize, &.{1}, narrowed);
    try std.testing.expectEqualStrings("the matrix", bundle.display_query_norm.?);

    const no_match = try ensureQueryHitOrder(allocator, &bundle, "blade runner");
    try std.testing.expectEqual(@as(usize, 0), no_match.len);
    try std.testing.expectEqualStrings("blade runner", bundle.display_query_norm.?);

    var top_buf: [320]u8 = undefined;
    const top = try formatHomeTopLine(&top_buf, .query, 1, 1, 0, &bundle, no_match.len);
    try std.testing.expect(std.mem.indexOf(u8, top, "0/3 results") != null);
}

fn queryHitScore(bundle: *const SearchBundle, hit_idx: usize, query_norm: []const u8) u32 {
    if (query_norm.len == 0 or hit_idx >= bundle.hits.items.len) return 1;
    const hit = bundle.hits.items[hit_idx];
    const item = bundle.searches.items[hit.response_index].items[hit.item_index];
    const title = cleanSearchTitle(item.label);
    var score: u32 = 0;
    if (startsWithCaseInsensitive(title, query_norm)) {
        score += 1000;
    } else if (containsCaseInsensitive(title, query_norm)) {
        score += 700;
    }
    if (containsCaseInsensitive(app.providerDisplayName(hit.provider), query_norm) or containsCaseInsensitive(app.providerName(hit.provider), query_norm)) {
        score += 100;
    }
    var terms = std.mem.tokenizeAny(u8, query_norm, " \t\r\n._-");
    while (terms.next()) |term| {
        if (term.len < 2) continue;
        if (containsCaseInsensitive(title, term)) score += 50;
    }
    return score;
}

fn startsWithCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[i])) return false;
    }
    return true;
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
    if (state.keywords.items.len > max_keyword_entries) {
        var oldest: usize = 0;
        for (state.keywords.items[1..], 1..) |entry, idx| {
            if (entry.used_at_unix < state.keywords.items[oldest].used_at_unix) oldest = idx;
        }
        _ = state.keywords.orderedRemove(oldest);
        state.arena_stale_mutations += 1;
        if (state.arena_stale_mutations >= arena_compact_after_stale_mutations) {
            try compactRuntimeArena(allocator, state);
        }
    }
}

const HistoryDirection = enum { backward, forward };

fn resetHistoryBrowse(
    history_pick: *?usize,
    history_draft: *std.ArrayList(u8),
    history_draft_cursor: *usize,
) void {
    history_pick.* = null;
    history_draft.clearRetainingCapacity();
    history_draft_cursor.* = 0;
}

fn captureHistoryDraft(
    allocator: std.mem.Allocator,
    query: *const std.ArrayList(u8),
    cursor_pos: usize,
    history_pick: *const ?usize,
    history_draft: *std.ArrayList(u8),
    history_draft_cursor: *usize,
) !void {
    if (history_pick.* != null) return;
    history_draft.clearRetainingCapacity();
    try history_draft.appendSlice(allocator, query.items);
    history_draft_cursor.* = @min(cursor_pos, query.items.len);
}

fn applyHistorySuggestion(
    allocator: std.mem.Allocator,
    state: *const TuiRuntimeState,
    query: *std.ArrayList(u8),
    cursor_pos: *usize,
    direction: HistoryDirection,
    history_pick: *?usize,
    history_draft: *std.ArrayList(u8),
    history_draft_cursor: *usize,
) !bool {
    if (!state.settings.keyword_cache_enabled or state.keywords.items.len == 0) return false;
    const next = switch (direction) {
        .backward => blk: {
            if (history_pick.*) |idx| break :blk idx + 1;
            try captureHistoryDraft(
                allocator,
                query,
                cursor_pos.*,
                history_pick,
                history_draft,
                history_draft_cursor,
            );
            break :blk 0;
        },
        .forward => blk: {
            const idx = history_pick.* orelse return false;
            if (idx == 0) {
                query.clearRetainingCapacity();
                try query.appendSlice(allocator, history_draft.items);
                cursor_pos.* = @min(history_draft_cursor.*, query.items.len);
                resetHistoryBrowse(history_pick, history_draft, history_draft_cursor);
                return true;
            }
            break :blk idx - 1;
        },
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

test "history navigation restores the original draft" {
    const allocator = std.testing.allocator;
    var state: TuiRuntimeState = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .settings = defaultTuiSettings(),
        .state_path = try allocator.dupe(u8, "state.test"),
        .settings_path = try allocator.dupe(u8, "settings.test"),
        .keyword_path = try allocator.dupe(u8, "keywords.test"),
        .cache_root_path = try allocator.dupe(u8, "cache.test"),
    };
    defer state.deinit(allocator);

    const a = state.arena.allocator();
    try state.keywords.append(allocator, .{
        .query = try a.dupe(u8, "older"),
        .used_at_unix = 10,
        .use_count = 1,
    });
    try state.keywords.append(allocator, .{
        .query = try a.dupe(u8, "newer"),
        .used_at_unix = 20,
        .use_count = 1,
    });

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(allocator);
    try query.appendSlice(allocator, "draft");
    var cursor_pos: usize = 2;
    var history_pick: ?usize = null;
    var history_draft: std.ArrayList(u8) = .empty;
    defer history_draft.deinit(allocator);
    var history_draft_cursor: usize = 0;

    try std.testing.expect(!try applyHistorySuggestion(
        allocator,
        &state,
        &query,
        &cursor_pos,
        .forward,
        &history_pick,
        &history_draft,
        &history_draft_cursor,
    ));
    try std.testing.expectEqualStrings("draft", query.items);
    try std.testing.expectEqual(@as(?usize, null), history_pick);

    try std.testing.expect(try applyHistorySuggestion(
        allocator,
        &state,
        &query,
        &cursor_pos,
        .backward,
        &history_pick,
        &history_draft,
        &history_draft_cursor,
    ));
    try std.testing.expectEqualStrings("newer", query.items);
    try std.testing.expectEqualStrings("draft", history_draft.items);
    try std.testing.expectEqual(@as(usize, 2), history_draft_cursor);
    try std.testing.expectEqual(@as(?usize, 0), history_pick);

    try std.testing.expect(try applyHistorySuggestion(
        allocator,
        &state,
        &query,
        &cursor_pos,
        .backward,
        &history_pick,
        &history_draft,
        &history_draft_cursor,
    ));
    try std.testing.expectEqualStrings("older", query.items);
    try std.testing.expectEqual(@as(?usize, 1), history_pick);

    try std.testing.expect(try applyHistorySuggestion(
        allocator,
        &state,
        &query,
        &cursor_pos,
        .forward,
        &history_pick,
        &history_draft,
        &history_draft_cursor,
    ));
    try std.testing.expectEqualStrings("newer", query.items);
    try std.testing.expectEqual(@as(?usize, 0), history_pick);

    try std.testing.expect(try applyHistorySuggestion(
        allocator,
        &state,
        &query,
        &cursor_pos,
        .forward,
        &history_pick,
        &history_draft,
        &history_draft_cursor,
    ));
    try std.testing.expectEqualStrings("draft", query.items);
    try std.testing.expectEqual(@as(usize, 2), cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), history_pick);
}

const SettingsPanel = enum { main, providers, languages, cache_ttl };

const SettingsPopupMetrics = struct {
    width: u16,
    height: u16,
    x: u16,
    y: u16,
    row_start: u16,
    row_end: u16,
};

fn settingsPopupMetrics(win_width: u16, win_height: u16) SettingsPopupMetrics {
    const width: u16 = @min(if (win_width > 8) win_width - 8 else win_width, 68);
    const height: u16 = @min(if (win_height > 6) win_height - 4 else win_height, 22);
    const x: u16 = if (win_width > width) (win_width - width) / 2 else 0;
    const y: u16 = if (win_height > height) (win_height - height) / 2 else 0;
    return .{
        .width = width,
        .height = height,
        .x = x,
        .y = y,
        .row_start = y + 3,
        .row_end = y + height -| 2,
    };
}

fn settingsPageSize(metrics: SettingsPopupMetrics) usize {
    return if (metrics.row_end > metrics.row_start) @intCast(metrics.row_end - metrics.row_start) else 1;
}

fn activateSettingsMainRow(
    ui: *Ui,
    state: *TuiRuntimeState,
    selected: usize,
    panel: *SettingsPanel,
    ttl_input: *std.ArrayList(u8),
    ttl_cursor: *usize,
    ttl_error: *?[]const u8,
    redraw_background: *bool,
) !void {
    var persist_settings = false;
    var apply_cache_settings = false;
    switch (selected) {
        0 => panel.* = .providers,
        1 => panel.* = .languages,
        2 => {
            state.settings.cache_enabled = !state.settings.cache_enabled;
            persist_settings = true;
            apply_cache_settings = true;
        },
        3 => {
            ttl_input.clearRetainingCapacity();
            const text = try cacheTtlInputText(ui.allocator, state.settings.cache_ttl_seconds);
            defer ui.allocator.free(text);
            try ttl_input.appendSlice(ui.allocator, text);
            ttl_cursor.* = ttl_input.items.len;
            ttl_error.* = null;
            panel.* = .cache_ttl;
        },
        4 => {
            state.settings.download_cache_enabled = !state.settings.download_cache_enabled;
            persist_settings = true;
        },
        5 => {
            state.settings.keyword_cache_enabled = !state.settings.keyword_cache_enabled;
            persist_settings = true;
        },
        6 => {
            state.keywords.clearRetainingCapacity();
            try saveKeywordRuntimeState(ui.allocator, state);
            redraw_background.* = true;
        },
        else => {},
    }
    if (apply_cache_settings) applyRuntimeCacheSettings(state);
    if (persist_settings) {
        try saveTuiSettingsState(ui.allocator, state);
        redraw_background.* = true;
    }
}

fn editSettingsPopup(
    ui: *Ui,
    state: *TuiRuntimeState,
    query: []const u8,
    cursor_pos: usize,
    focus: QueryFocus,
    query_dirty: bool,
    results: ?*SearchBundle,
    selected_result: *usize,
    result_scroll: *usize,
    selected_download: *usize,
    download_scroll: *usize,
    info_open: *bool,
) !bool {
    const initial_settings = state.settings;
    var panel: SettingsPanel = .main;
    var main_selected: usize = 0;
    var provider_selected: usize = 0;
    var language_selected: usize = 0;
    var provider_scroll: usize = 0;
    var language_scroll: usize = 0;
    var ttl_input: std.ArrayList(u8) = .empty;
    defer ttl_input.deinit(ui.allocator);
    var ttl_cursor: usize = 0;
    var ttl_error: ?[]const u8 = null;
    var redraw_background = true;
    var settings_dirty = false;
    var help_open = false;
    info_open.* = false;
    language_selected = if (state.settings.language_filter_enabled)
        (singleEnabledIndex(&state.settings.languages_enabled) orelse 0) + 1
    else
        0;

    while (true) {
        const win = ui.vx.window();
        if (help_open and !canRenderOverlayMenu(win)) {
            help_open = false;
            redraw_background = true;
        }
        const metrics = settingsPopupMetrics(win.width, win.height);
        const page_size = settingsPageSize(metrics);
        ensureVisible(provider_selected, &provider_scroll, page_size);
        ensureVisible(language_selected, &language_scroll, page_size);

        if (redraw_background) {
            try renderQueryHome(ui, state, query, cursor_pos, focus, query_dirty, results, selected_result, result_scroll, selected_download, download_scroll, false, false);
            redraw_background = false;
        }
        try renderSettingsPopup(ui, win, state, panel, main_selected, provider_selected, language_selected, provider_scroll, language_scroll, ttl_input.items, ttl_cursor, ttl_error);
        if (help_open) {
            const panel_name = switch (panel) {
                .main => "Main",
                .providers => "Providers",
                .languages => "Language",
                .cache_ttl => "Cache retention",
            };
            const primary_help = switch (panel) {
                .main => "Enter or a second click opens/toggles the highlighted setting",
                .providers => "Enter/Space toggles the highlighted provider",
                .languages => "Enter/Space chooses the highlighted language",
                .cache_ttl => "Type hours; Enter saves the retention value",
            };
            const secondary_help = switch (panel) {
                .main => "Up/Down moves · Esc/Ctrl+C closes Settings",
                .providers, .languages => "Up/Down moves · Esc/Ctrl+C returns to Settings",
                .cache_ttl => "Left/Right edit · Esc/Ctrl+C returns without saving",
            };
            var panel_buf: [96]u8 = undefined;
            const panel_line = std.fmt.bufPrint(&panel_buf, "panel: {s}", .{panel_name}) catch "panel: Settings";
            const lines = [_][]const u8{
                panel_line,
                primary_help,
                secondary_help,
                "F2 confirmations · F3 theme · Ctrl+D quit",
            };
            try renderOverlayMenu(ui, win, "Settings Help", &lines);
        }
        try ui.render();

        const batch = try readEventBatch(ui, try ui.loop.nextEvent());
        for (batch.slice()) |event| {
            switch (event) {
                .winsize => |ws| {
                    try ui.resize(ws);
                    redraw_background = true;
                },
                .mouse => |mouse| {
                    if (mouse.type != .press) continue;
                    if (help_open) {
                        help_open = false;
                        redraw_background = true;
                    }
                    const win_now = ui.vx.window();
                    const metrics_now = settingsPopupMetrics(win_now.width, win_now.height);
                    switch (panel) {
                        .main => {
                            const item_count: usize = 7;
                            switch (mouse.button) {
                                .wheel_down => scrollSelection(&main_selected, item_count, .forward, 1),
                                .wheel_up => scrollSelection(&main_selected, item_count, .backward, 1),
                                .left => {
                                    if (mouseRowIndex(mouse, metrics_now.row_start, metrics_now.row_end, 0, item_count)) |idx| {
                                        const activate = idx == main_selected;
                                        main_selected = idx;
                                        if (activate) {
                                            try activateSettingsMainRow(
                                                ui,
                                                state,
                                                main_selected,
                                                &panel,
                                                &ttl_input,
                                                &ttl_cursor,
                                                &ttl_error,
                                                &redraw_background,
                                            );
                                        }
                                    }
                                },
                                else => {},
                            }
                        },
                        .providers => {
                            switch (mouse.button) {
                                .wheel_down => scrollSelection(&provider_selected, app.providerCount(), .forward, list_mouse_wheel_step),
                                .wheel_up => scrollSelection(&provider_selected, app.providerCount(), .backward, list_mouse_wheel_step),
                                .left => {
                                    if (mouseRowIndex(mouse, metrics_now.row_start, metrics_now.row_end, provider_scroll, app.providerCount())) |idx| {
                                        provider_selected = idx;
                                        state.settings.providers_enabled[idx] = !state.settings.providers_enabled[idx];
                                        if (countEnabledFlags(&state.settings.providers_enabled) == 0) state.settings.providers_enabled[idx] = true;
                                        settings_dirty = true;
                                        redraw_background = true;
                                    }
                                },
                                else => {},
                            }
                        },
                        .languages => {
                            const language_items = languageCount() + 1;
                            switch (mouse.button) {
                                .wheel_down => scrollSelection(&language_selected, language_items, .forward, list_mouse_wheel_step),
                                .wheel_up => scrollSelection(&language_selected, language_items, .backward, list_mouse_wheel_step),
                                .left => {
                                    if (mouseRowIndex(mouse, metrics_now.row_start, metrics_now.row_end, language_scroll, language_items)) |idx| {
                                        language_selected = idx;
                                        if (idx == 0) {
                                            state.settings.language_filter_enabled = false;
                                        } else {
                                            state.settings.language_filter_enabled = true;
                                            state.settings.languages_enabled = languageSelectionOnly(idx - 1);
                                        }
                                        settings_dirty = true;
                                        redraw_background = true;
                                    }
                                },
                                else => {},
                            }
                        },
                        .cache_ttl => {},
                    }
                },
                .key_press => |key| {
                    if (key.isModifier()) continue;
                    if (help_open) {
                        if (key.matches(vaxis.Key.f1, .{}) or key.matches(vaxis.Key.escape, .{})) {
                            help_open = false;
                            redraw_background = true;
                            continue;
                        }
                        help_open = false;
                        redraw_background = true;
                    }
                    if (key.matches(vaxis.Key.f1, .{})) {
                        if (canRenderOverlayMenu(ui.vx.window())) help_open = true;
                        continue;
                    }
                    if (key.matches(vaxis.Key.f2, .{})) {
                        ui.toggleConfirm();
                        redraw_background = true;
                        continue;
                    }
                    if (key.matches(vaxis.Key.f3, .{})) {
                        ui.toggleTheme();
                        redraw_background = true;
                        continue;
                    }
                    if (key.matches('d', .{ .ctrl = true })) {
                        if (settings_dirty) try saveTuiSettingsState(ui.allocator, state);
                        ui.hardQuit();
                    }
                    if (key.matches('c', .{ .ctrl = true })) {
                        if (settings_dirty) {
                            try saveTuiSettingsState(ui.allocator, state);
                            settings_dirty = false;
                        }
                        switch (panel) {
                            .main => return searchSettingsChanged(initial_settings, state.settings),
                            .providers, .languages, .cache_ttl => {
                                panel = .main;
                                ttl_error = null;
                                continue;
                            },
                        }
                    }
                    switch (panel) {
                        .main => {
                            const item_count: usize = 7;
                            if (key.matches(vaxis.Key.escape, .{})) return searchSettingsChanged(initial_settings, state.settings);
                            if (key.matches(vaxis.Key.down, .{})) {
                                if (main_selected + 1 < item_count) main_selected += 1;
                                continue;
                            }
                            if (key.matches(vaxis.Key.up, .{})) {
                                main_selected = main_selected -| 1;
                                continue;
                            }
                            if (!key.matches(vaxis.Key.enter, .{})) continue;
                            try activateSettingsMainRow(
                                ui,
                                state,
                                main_selected,
                                &panel,
                                &ttl_input,
                                &ttl_cursor,
                                &ttl_error,
                                &redraw_background,
                            );
                        },
                        .providers => {
                            if (key.matches(vaxis.Key.escape, .{})) {
                                if (settings_dirty) {
                                    try saveTuiSettingsState(ui.allocator, state);
                                    settings_dirty = false;
                                }
                                panel = .main;
                                continue;
                            }
                            if (key.matches(vaxis.Key.down, .{})) {
                                if (provider_selected + 1 < app.providerCount()) provider_selected += 1;
                                continue;
                            }
                            if (key.matches(vaxis.Key.up, .{})) {
                                provider_selected = provider_selected -| 1;
                                continue;
                            }
                            if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
                                state.settings.providers_enabled[provider_selected] = !state.settings.providers_enabled[provider_selected];
                                if (countEnabledFlags(&state.settings.providers_enabled) == 0) state.settings.providers_enabled[provider_selected] = true;
                                settings_dirty = true;
                                redraw_background = true;
                                continue;
                            }
                        },
                        .languages => {
                            const language_items = languageCount() + 1;
                            if (key.matches(vaxis.Key.escape, .{})) {
                                if (settings_dirty) {
                                    try saveTuiSettingsState(ui.allocator, state);
                                    settings_dirty = false;
                                }
                                panel = .main;
                                continue;
                            }
                            if (key.matches(vaxis.Key.down, .{})) {
                                if (language_selected + 1 < language_items) language_selected += 1;
                                continue;
                            }
                            if (key.matches(vaxis.Key.up, .{})) {
                                language_selected = language_selected -| 1;
                                continue;
                            }
                            if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
                                if (language_selected == 0) {
                                    state.settings.language_filter_enabled = false;
                                } else {
                                    state.settings.language_filter_enabled = true;
                                    state.settings.languages_enabled = languageSelectionOnly(language_selected - 1);
                                }
                                settings_dirty = true;
                                redraw_background = true;
                                continue;
                            }
                        },
                        .cache_ttl => {
                            if (key.matches(vaxis.Key.escape, .{})) {
                                panel = .main;
                                ttl_error = null;
                                continue;
                            }
                            if (key.matches(vaxis.Key.enter, .{})) {
                                const ttl = parseCacheTtlSeconds(ttl_input.items) orelse {
                                    ttl_error = "Enter decimal hours, 0, or inf.";
                                    continue;
                                };
                                state.settings.cache_ttl_seconds = ttl;
                                applyRuntimeCacheSettings(state);
                                try saveTuiSettingsState(ui.allocator, state);
                                redraw_background = true;
                                panel = .main;
                                ttl_error = null;
                                continue;
                            }
                            if (key.matches(vaxis.Key.left, .{})) {
                                ttl_cursor = ttl_cursor -| 1;
                                continue;
                            }
                            if (key.matches(vaxis.Key.right, .{})) {
                                if (ttl_cursor < ttl_input.items.len) ttl_cursor += 1;
                                continue;
                            }
                            if (key.matches(vaxis.Key.backspace, .{})) {
                                if (ttl_cursor > 0) {
                                    _ = ttl_input.orderedRemove(ttl_cursor - 1);
                                    ttl_cursor -= 1;
                                }
                                ttl_error = null;
                                continue;
                            }
                            if (key.matches(vaxis.Key.delete, .{})) {
                                if (ttl_cursor < ttl_input.items.len) _ = ttl_input.orderedRemove(ttl_cursor);
                                ttl_error = null;
                                continue;
                            }
                            if (isTextKey(key)) {
                                const text = key.text orelse continue;
                                for (text) |ch| {
                                    const ok = std.ascii.isDigit(ch) or ch == '.' or std.ascii.isAlphabetic(ch);
                                    if (!ok) continue;
                                    if (ttl_input.items.len < 32) {
                                        try ttl_input.insert(ui.allocator, ttl_cursor, ch);
                                        ttl_cursor += 1;
                                    }
                                }
                                ttl_error = null;
                            }
                        },
                    }
                },
                else => {},
            }
        }
        if (batch.wheel_delta != 0) {
            switch (panel) {
                .main => applyWheelDelta(&main_selected, 7, batch.wheel_delta, 1),
                .providers => applyWheelDelta(&provider_selected, app.providerCount(), batch.wheel_delta, list_mouse_wheel_step),
                .languages => applyWheelDelta(&language_selected, languageCount() + 1, batch.wheel_delta, list_mouse_wheel_step),
                .cache_ttl => {},
            }
        }
    }
}

fn renderSettingsPopup(
    ui: *Ui,
    win: anytype,
    state: *const TuiRuntimeState,
    panel: SettingsPanel,
    main_selected: usize,
    provider_selected: usize,
    language_selected: usize,
    provider_scroll: usize,
    language_scroll: usize,
    ttl_input: []const u8,
    ttl_cursor: usize,
    ttl_error: ?[]const u8,
) !void {
    std.debug.assert(main_selected < 7);
    std.debug.assert(provider_selected < app.providerCount());
    std.debug.assert(language_selected <= languageCount());
    const metrics = settingsPopupMetrics(win.width, win.height);
    const width = metrics.width;
    const height = metrics.height;
    const x = metrics.x;
    const y = metrics.y;
    try fillBoxBackground(ui, win, x, y, width, height);
    try renderBox(ui, win, x, y, width, height, ui.styleAccent());
    try printFitted(ui, win, y + 1, x + 2, "Settings", ui.stylePaneTitle(), width -| 4);

    const row_start = metrics.row_start;
    const row_end = metrics.row_end;
    switch (panel) {
        .main => {
            var provider_buf: [64]u8 = undefined;
            var language_buf: [64]u8 = undefined;
            var cache_buf: [64]u8 = undefined;
            var download_cache_buf: [64]u8 = undefined;
            var ttl_buf: [64]u8 = undefined;
            var history_buf: [64]u8 = undefined;
            var rows: [7][]const u8 = undefined;
            rows[0] = std.fmt.bufPrint(&provider_buf, "Providers  {d}/{d}", .{ countEnabledFlags(&state.settings.providers_enabled), app.providerCount() }) catch "Providers";
            rows[1] = formatLanguageSetting(&language_buf, state.settings) catch "Language";
            rows[2] = std.fmt.bufPrint(&cache_buf, "URL cache  {s}", .{if (state.settings.cache_enabled) "on" else "off"}) catch "URL cache";
            rows[3] = formatCacheTtlSetting(&ttl_buf, state.settings.cache_ttl_seconds) catch "Retention";
            rows[4] = std.fmt.bufPrint(&download_cache_buf, "Download cache  {s}", .{if (state.settings.download_cache_enabled) "on" else "off"}) catch "Download cache";
            var row_count: usize = 5;
            rows[row_count] = std.fmt.bufPrint(&history_buf, "History  {s}", .{if (state.settings.keyword_cache_enabled) "on" else "off"}) catch "History";
            row_count += 1;
            rows[row_count] = "Clear history";
            row_count += 1;
            const visible_rows = rows[0..row_count];
            var row = row_start;
            for (visible_rows, 0..) |line, idx| {
                if (row >= row_end) break;
                const style = if (idx == main_selected) ui.styleSelected() else vaxis.Style{};
                try printFitted(ui, win, row, x + 2, if (idx == main_selected) "›" else " ", style, 1);
                try printFitted(ui, win, row, x + 4, line, style, width -| 6);
                row += 1;
            }
        },
        .providers => {
            try printFitted(ui, win, y + 2, x + 2, "Enter/Space toggles. Esc/Ctrl+C returns.", ui.styleMuted(), width -| 4);
            var row = row_start;
            var idx = provider_scroll;
            while (idx < app.providerCount() and row < row_end) : (idx += 1) {
                const provider = app.providers()[idx];
                if (row >= row_end) break;
                const checked = if (state.settings.providers_enabled[idx]) "[x]" else "[ ]";
                const style = if (idx == provider_selected) ui.styleSelected() else vaxis.Style{};
                var line_buf: [128]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "{s}  {s}", .{ checked, app.providerDisplayName(provider) }) catch app.providerDisplayName(provider);
                try printFitted(ui, win, row, x + 2, if (idx == provider_selected) "›" else " ", style, 1);
                try printFitted(ui, win, row, x + 4, line, style, width -| 6);
                row += 1;
            }
        },
        .languages => {
            try printFitted(ui, win, y + 2, x + 2, "Enter/Space chooses. Esc/Ctrl+C returns.", ui.styleMuted(), width -| 4);
            var row = row_start;
            var idx = language_scroll;
            const language_items = language_options.len + 1;
            while (idx < language_items and row < row_end) : (idx += 1) {
                if (row >= row_end) break;
                const selected = if (idx == 0)
                    !state.settings.language_filter_enabled
                else
                    state.settings.language_filter_enabled and state.settings.languages_enabled[idx - 1];
                const checked = if (selected) "[x]" else "[ ]";
                const style = if (idx == language_selected) ui.styleSelected() else vaxis.Style{};
                var line_buf: [192]u8 = undefined;
                const line = if (idx == 0)
                    std.fmt.bufPrint(&line_buf, "{s}  No language filter", .{checked}) catch "No language filter"
                else blk: {
                    const lang = language_options[idx - 1];
                    break :blk std.fmt.bufPrint(&line_buf, "{s}  {s}  {s}", .{ checked, lang.code, lang.name }) catch lang.name;
                };
                try printFitted(ui, win, row, x + 2, if (idx == language_selected) "›" else " ", style, 1);
                try printFitted(ui, win, row, x + 4, line, style, width -| 6);
                row += 1;
            }
        },
        .cache_ttl => {
            try printFitted(ui, win, y + 2, x + 2, "Hours; decimals allowed. 0 or inf keeps forever.", ui.styleMuted(), width -| 4);
            try printFitted(ui, win, row_start, x + 2, "Hours", ui.styleAccent(), 8);
            try printFitted(ui, win, row_start, x + 10, ttl_input, vaxis.Style{ .bold = true }, width -| 12);
            if (ttl_error) |err| try printFitted(ui, win, row_start + 2, x + 2, err, ui.styleWarn(), width -| 4);
            const col = x + 10 + @as(u16, @intCast(@min(ttl_cursor, @as(usize, width -| 12))));
            win.showCursor(@min(col, win.width -| 1), row_start);
        },
    }
}

fn primaryLanguageIndex(settings: TuiSettings) ?usize {
    if (!settings.language_filter_enabled) return null;
    return singleEnabledIndex(&settings.languages_enabled) orelse 0;
}

fn searchSettingsChanged(before: TuiSettings, after: TuiSettings) bool {
    if (before.language_filter_enabled != after.language_filter_enabled) return true;
    if (!std.mem.eql(bool, before.providers_enabled[0..], after.providers_enabled[0..])) return true;
    return !std.mem.eql(bool, before.languages_enabled[0..], after.languages_enabled[0..]);
}

fn primaryLanguageCode(settings: TuiSettings) ?[]const u8 {
    const idx = primaryLanguageIndex(settings) orelse return null;
    return language_options[@min(idx, language_options.len - 1)].code;
}

fn formatLanguageSetting(buf: []u8, settings: TuiSettings) ![]const u8 {
    const idx = primaryLanguageIndex(settings) orelse return std.fmt.bufPrint(buf, "Language  off", .{});
    const lang = language_options[@min(idx, language_options.len - 1)];
    return std.fmt.bufPrint(buf, "Language  {s} {s}", .{ lang.code, lang.name });
}

fn formatCacheTtlSetting(buf: []u8, ttl_seconds: i64) ![]const u8 {
    if (ttl_seconds == 0) return std.fmt.bufPrint(buf, "Retention  inf", .{});
    const hours = @as(f64, @floatFromInt(ttl_seconds)) / 3600.0;
    if (@mod(ttl_seconds, 3600) == 0) return std.fmt.bufPrint(buf, "Retention  {d}h", .{@divTrunc(ttl_seconds, 3600)});
    return std.fmt.bufPrint(buf, "Retention  {d:.2}h", .{hours});
}

fn cacheTtlInputText(allocator: std.mem.Allocator, ttl_seconds: i64) ![]u8 {
    if (ttl_seconds == 0) return try allocator.dupe(u8, "inf");
    if (@mod(ttl_seconds, 3600) == 0) return try std.fmt.allocPrint(allocator, "{d}", .{@divTrunc(ttl_seconds, 3600)});
    return try std.fmt.allocPrint(allocator, "{d:.4}", .{@as(f64, @floatFromInt(ttl_seconds)) / 3600.0});
}

fn parseCacheTtlSeconds(input: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "inf") or
        std.ascii.eqlIgnoreCase(trimmed, "infinite") or
        std.ascii.eqlIgnoreCase(trimmed, "infinity"))
    {
        return 0;
    }
    const hours = std.fmt.parseFloat(f64, trimmed) catch return null;
    if (!std.math.isFinite(hours) or hours < 0) return null;
    if (hours == 0) return 0;
    const seconds_f = hours * 3600.0;
    if (!std.math.isFinite(seconds_f) or seconds_f >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
    return @intFromFloat(@round(seconds_f));
}

fn renderQueryHome(
    ui: *Ui,
    state: *const TuiRuntimeState,
    query: []const u8,
    cursor_pos: usize,
    focus: QueryFocus,
    query_dirty: bool,
    results: ?*SearchBundle,
    selected_result: *usize,
    scroll: *usize,
    selected_download: *usize,
    download_scroll: *usize,
    info_open: bool,
    flush: bool,
) !void {
    const win = ui.vx.window();
    win.clear();
    win.hideCursor();
    win.setCursorShape(.beam);

    const provider_count = countEnabledFlags(&state.settings.providers_enabled);
    const download_count = if (state.settings.download_cache_enabled) state.download_entries.len else 0;
    const query_norm = normalizeQueryView(query);
    const visible_order: ?[]const usize = if (results) |bundle|
        if (query_dirty)
            &.{}
        else
            try ensureQueryHitOrder(ui.allocator, bundle, query_norm)
    else
        null;
    var top_buf: [320]u8 = undefined;
    const top = try formatHomeTopLine(
        &top_buf,
        focus,
        provider_count,
        app.providerCount(),
        download_count,
        if (query_dirty) null else results,
        if (query_dirty) null else if (visible_order) |order| order.len else null,
    );
    try renderCompactTopLine(ui, win, top, ui.styleTitle());

    const search_box = homeSearchBoxMetrics(win.width);
    const box_w = search_box.width;
    const box_x = search_box.x;
    const box_y = search_box.y;
    const border_style = if (query_dirty) ui.styleWarn() else if (focus == .query) ui.styleAccent() else ui.styleMuted();
    try renderBox(ui, win, box_x, box_y, box_w, 3, border_style);
    try printFitted(ui, win, box_y, box_x + 2, " Search ", border_style, 10);
    const input_width: usize = search_box.input_width;
    const query_style = if (query.len == 0) ui.styleMuted() else vaxis.Style{ .bold = true };
    const viewport = queryViewportForCursor(win, query, cursor_pos, input_width);
    if (query.len == 0) {
        try printFitted(ui, win, search_box.input_row, search_box.input_col, "Search films and series", query_style, input_width);
    } else if (viewport.start > 0 and input_width > 0) {
        try printFitted(ui, win, search_box.input_row, search_box.input_col, "‹", ui.styleMuted(), 1);
        try printFitted(
            ui,
            win,
            search_box.input_row,
            search_box.input_col + 1,
            query[viewport.start..],
            query_style,
            input_width -| 1,
        );
    } else {
        try printFitted(ui, win, search_box.input_row, search_box.input_col, query, query_style, input_width);
    }
    if (focus == .query and win.width > 0) {
        const col = search_box.input_col + @as(u16, @intCast(@min(viewport.cursor_col, input_width)));
        win.showCursor(@min(col, win.width -| 1), search_box.input_row);
    }

    const list_top = homeListTop();
    const list_bottom = homeListBottom(win.height);

    if (focus == .downloads and state.settings.download_cache_enabled) {
        const entries = state.download_entries;
        clampSelection(selected_download, entries.len);
        const page_size: usize = if (list_bottom > list_top) @intCast(list_bottom - list_top) else 1;
        ensureVisible(selected_download.*, download_scroll, page_size);
        if (entries.len == 0) {
            try printFitted(ui, win, list_top, 4, "No cached downloads.", ui.styleMuted(), if (win.width > 8) @intCast(win.width - 8) else 0);
        } else {
            var row = list_top;
            var i = download_scroll.*;
            while (i < entries.len and row < list_bottom) : (i += 1) {
                const active = i == selected_download.*;
                const style = if (active) ui.styleSelected() else vaxis.Style{};
                try printFitted(ui, win, row, 2, if (active) "› " else "  ", style, 2);
                try printFitted(ui, win, row, 4, entries[i], style, if (win.width > 8) @intCast(win.width - 8) else 0);
                row += 1;
            }
        }
    } else if (results) |bundle| {
        const order = visible_order.?;
        clampSelection(selected_result, order.len);
        const page_size: usize = if (list_bottom > list_top) @intCast(list_bottom - list_top) else 1;
        ensureVisible(selected_result.*, scroll, page_size);
        if (order.len == 0) {
            var message_buf: [160]u8 = undefined;
            const message = if (bundle.searching and bundle.pending_count > 0)
                std.fmt.bufPrint(
                    &message_buf,
                    "Searching… {d} provider{s} remaining.",
                    .{ bundle.pending_count, if (bundle.pending_count == 1) "" else "s" },
                ) catch "Searching…"
            else if (bundle.canceled)
                "Search canceled. Press Enter to search again."
            else if (query_dirty and bundle.hits.items.len > 0)
                "Existing results do not match the edited query. Press Enter to search."
            else if (bundle.failed_count > 0)
                "No results. Some providers failed; edit the query/settings and search again."
            else if (bundle.unavailable_count > 0)
                std.fmt.bufPrint(
                    &message_buf,
                    "No results. {d} provider{s} unavailable; retry or adjust providers.",
                    .{ bundle.unavailable_count, if (bundle.unavailable_count == 1) "" else "s" },
                ) catch "No results. Providers are currently unavailable."
            else
                "No results. Edit the query or provider/language settings and search again.";
            try printFitted(
                ui,
                win,
                list_top,
                4,
                message,
                if (bundle.searching and bundle.pending_count > 0)
                    ui.styleAccent()
                else if (bundle.canceled)
                    ui.styleWarn()
                else if (query_dirty and bundle.hits.items.len > 0)
                    ui.styleMuted()
                else if (bundle.failed_count > 0)
                    ui.styleWarn()
                else if (bundle.unavailable_count > 0)
                    ui.styleWarn()
                else
                    ui.styleMuted(),
                if (win.width > 8) @intCast(win.width - 8) else 0,
            );
        }
        var row = list_top;
        var i = scroll.*;
        while (i < order.len and row < list_bottom) : (i += 1) {
            const active = focus == .results and i == selected_result.*;
            const style = if (active) ui.styleSelected() else vaxis.Style{};
            const prefix = if (active) "› " else "  ";
            const hit = bundle.hits.items[order[i]];
            const item = bundle.searches.items[hit.response_index].items[hit.item_index];
            const title = cleanSearchTitle(item.label);
            const provider_tag = app.providerDisplayName(hit.provider);
            const source_tag = if (hit.source == .cache) "cached" else "live";
            try printFitted(ui, win, row, 2, prefix, style, 2);
            const title_width = if (win.width > 40) @as(usize, @intCast(win.width - 34)) else if (win.width > 6) @as(usize, @intCast(win.width - 6)) else 0;
            try printFitted(ui, win, row, 4, title, style, title_width);
            if (win.width > 48) {
                const tag_col: u16 = @intCast(@min(@as(usize, 4) + title_width + 2, @as(usize, win.width - 1)));
                var tag_buf: [128]u8 = undefined;
                const tag_line = std.fmt.bufPrint(&tag_buf, "{s}  {s}", .{ provider_tag, source_tag }) catch provider_tag;
                try printFitted(ui, win, row, tag_col, tag_line, if (hit.source == .live) ui.styleAccent() else ui.styleMuted(), if (win.width > tag_col) @intCast(win.width - tag_col - 1) else 0);
            }
            row += 1;
        }
    } else {
        const suggestions = try sortedKeywordIndexes(ui.frameAllocator(), state.keywords.items);
        var row = list_top;
        if (state.settings.keyword_cache_enabled and suggestions.len > 0) {
            try printFitted(ui, win, row, 4, "Recent searches", ui.stylePaneTitle(), if (win.width > 8) @intCast(win.width - 8) else 0);
            row += 1;
            var i: usize = 0;
            while (i < suggestions.len and i < 6 and row < list_bottom) : (i += 1) {
                const keyword = state.keywords.items[suggestions[i]];
                try printFitted(ui, win, row, 4, keyword.query, ui.styleMuted(), if (win.width > 8) @intCast(win.width - 8) else 0);
                row += 1;
            }
        }
    }

    const footer = switch (focus) {
        .query => "Enter search · ↑/↓ or click history · Tab focus",
        .results => "↑/↓ select · Enter open · Tab focus",
        .downloads => "↑/↓ select · Enter export · Tab focus",
    };
    try renderCompactBottomLine(ui, win, footer);

    if (info_open) {
        const lines = [_][]const u8{
            "Enter search/open",
            "Tab query/results/downloads",
            "Up/Down move through history or results",
            "PageUp/PageDown scroll faster",
            "Esc settings",
            "Ctrl+C cancel/back, Ctrl+D quit",
        };
        try renderOverlayMenu(ui, win, "Info", &lines);
    }

    if (flush) try ui.render();
}

const HomeSearchBoxMetrics = struct {
    width: u16,
    x: u16,
    y: u16,
    input_row: u16,
    input_col: u16,
    input_width: u16,
};

const home_search_box_y: u16 = 1;

fn homeSearchBoxMetrics(win_width: u16) HomeSearchBoxMetrics {
    const width: u16 = @min(if (win_width > 6) win_width - 6 else win_width, 86);
    const x: u16 = if (win_width > width) (win_width - width) / 2 else 0;
    const y = home_search_box_y;
    return .{
        .width = width,
        .x = x,
        .y = y,
        .input_row = y + 1,
        .input_col = x + 2,
        .input_width = if (width > 4) width - 4 else 0,
    };
}

fn homeListBottom(height: u16) u16 {
    return height -| 1;
}

fn homeListTop() u16 {
    return home_search_box_y + 3;
}

fn homeRecentSearchFirstRow() u16 {
    return homeListTop() + 1;
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

fn fillBoxBackground(ui: *Ui, win: anytype, x: u16, y: u16, width: u16, height: u16) !void {
    const spaces = try frameRepeatByte(ui, ' ', width);
    for (0..height) |offset| {
        _ = win.print(&[_]vaxis.Segment{.{ .text = spaces, .style = ui.styleMenuBackground() }}, .{
            .row_offset = y + @as(u16, @intCast(offset)),
            .col_offset = x,
            .wrap = .none,
        });
    }
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
        out[idx] = try std.fmt.allocPrint(allocator, "[{s}] [{s}] {s}", .{ app.providerDisplayName(hit.provider), source, item.label });
        initialized += 1;
    }
    return out;
}

fn openSearchResult(ui: *Ui, bundle: *SearchBundle, hit_idx: usize, state: *TuiRuntimeState) !OpenResult {
    if (hit_idx >= bundle.hits.items.len) return .back;
    const settings = state.settings;
    const cache_root_path = state.cache_root_path;
    const hit = bundle.hits.items[hit_idx];
    const selected_title = bundle.searches.items[hit.response_index].items[hit.item_index];
    const selected_provider = hit.provider;
    ui.active_provider = selected_provider;
    const title_ref_url = app.searchRefUrl(selected_title.ref);

    var subtitle_pages: std.ArrayListUnmanaged(SubtitlesPageCacheEntry) = .empty;
    defer deinitSubtitlesPageCache(ui.allocator, &subtitle_pages);
    var subtitle_page_current: usize = 1;
    var allow_auto_subtitle_select = true;
    const supports_subtitles_pagination = app.providerSupportsSubtitlesPagination(selected_provider);

    subtitle_page_loop: while (true) {
        const subtitles_idx = findSubtitlesPageCacheIndex(subtitle_pages.items, subtitle_page_current) orelse blk_fetch: {
            const detail = if (supports_subtitles_pagination)
                try std.fmt.allocPrint(ui.allocator, "{s} • page={d}", .{ selected_title.label, subtitle_page_current })
            else
                try ui.allocator.dupe(u8, selected_title.label);
            defer ui.allocator.free(detail);
            const context = if (supports_subtitles_pagination)
                try std.fmt.allocPrint(ui.allocator, "Provider: {s} • Title URL: {s} • page={d}", .{ app.providerDisplayName(selected_provider), title_ref_url, subtitle_page_current })
            else
                try std.fmt.allocPrint(ui.allocator, "Provider: {s} • Title URL: {s}", .{ app.providerDisplayName(selected_provider), title_ref_url });
            defer ui.allocator.free(context);
            setContext(ui, context);

            var subtitles_task: SubtitlesTask = .{
                .ref = selected_title.ref,
                .page = subtitle_page_current,
            };
            var subtitles_group: std.Io.Group = .init;
            defer subtitles_group.cancel(runtime_io.get());
            try subtitles_group.concurrent(runtime_io.get(), subtitlesTaskMain, .{&subtitles_task});
            const subtitles_control = try waitForTask(ui, &subtitles_task.done, "Subtitles", detail);
            finalizeWorkerGroup(&subtitles_group, subtitles_control);
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

        const subtitle_enabled = try buildSubtitleEnabled(ui.allocator, subtitles.items, settings);
        defer ui.allocator.free(subtitle_enabled);
        const page_nav = PageNav{
            .enabled = supports_subtitles_pagination,
            .page = subtitle_page_current,
            .has_prev = subtitles.has_prev_page,
            .has_next = subtitles.has_next_page,
        };
        const page_nav_opt: ?PageNav = if (page_nav.enabled) page_nav else null;
        const subtitle_idx = (if (allow_auto_subtitle_select) singleEnabledIndex(subtitle_enabled) else null) orelse blk: {
            const subtitle_choice = try vaxisSelectSubtitle(
                ui,
                "Select Subtitle",
                if (supports_subtitles_pagination) "s sort, / filter, [ prev, ] next, Esc titles." else "s sort, / filter, Esc titles.",
                subtitles.items,
                subtitle_enabled,
                page_nav_opt,
            );
            break :blk switch (subtitle_choice) {
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
        };
        allow_auto_subtitle_select = false;

        const selected_subtitle = subtitles.items[subtitle_idx];
        const download_url = selected_subtitle.download_url orelse "(no direct URL)";
        const download_url_display = if (isSubtitlecatTranslateToken(selected_subtitle.download_url)) "subtitlecat translate request" else download_url;
        if (!ui.skip_confirm) {
            const lines = [_][]const u8{
                try frameFmt(ui, "Provider: {s}", .{app.providerDisplayName(selected_provider)}),
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
        const download_out_dir = if (settings.download_cache_enabled)
            try std.fmt.allocPrint(ui.allocator, "{s}/downloads", .{cache_root_path})
        else
            try ui.allocator.dupe(u8, "downloads");
        defer ui.allocator.free(download_out_dir);

        var download_task: DownloadTask = .{
            .subtitle = selected_subtitle,
            .out_dir = download_out_dir,
            .extract_archive = true,
        };
        var download_group: std.Io.Group = .init;
        defer download_group.cancel(runtime_io.get());
        try download_group.concurrent(runtime_io.get(), downloadTaskMain, .{&download_task});
        const download_control = try waitForDownloadTask(ui, &download_task, "Download", download_detail);
        finalizeWorkerGroup(&download_group, download_control);
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
        if (settings.download_cache_enabled) {
            try refreshCachedDownloads(ui.allocator, state);
            const export_result = try exportCachedDownload(ui, result);
            switch (export_result) {
                .ok => continue :subtitle_page_loop,
                .to_query => return .to_query,
                .quit => return .quit,
            }
        } else {
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
}

fn runCombinedSearch(ui: *Ui, provider_enabled: []const bool) !SelectResult {
    query_loop: while (true) {
        ui.active_provider = null;
        setContext(ui, "Combined search • selected providers");
        const input = try vaxisInput(ui, "Combined Search", "Searches every selected provider. Esc returns to providers.", "Query", .{ .max_len = 180 });
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

            const detail = try std.fmt.allocPrint(ui.allocator, "provider={s} query={s}", .{ app.providerDisplayName(provider), query });
            defer ui.allocator.free(detail);
            const context = try std.fmt.allocPrint(ui.allocator, "Combined search • provider: {s}", .{app.providerDisplayName(provider)});
            defer ui.allocator.free(context);
            setContext(ui, context);

            var search_task: SearchTask = .{
                .provider = provider,
                .query = query,
                .page = 1,
            };
            var search_group: std.Io.Group = .init;
            defer search_group.cancel(runtime_io.get());
            try search_group.concurrent(runtime_io.get(), searchTaskMain, .{&search_task});
            const search_control = try waitForTask(ui, &search_task.done, "Combined Search", detail);
            finalizeWorkerGroup(&search_group, search_control);

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
            setContext(ui, "Combined search results • first page per provider");
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
            const context = try std.fmt.allocPrint(ui.allocator, "Provider: {s} • Title URL: {s}", .{ app.providerDisplayName(selected_provider), title_ref_url });
            defer ui.allocator.free(context);
            setContext(ui, context);

            var subtitles_task: SubtitlesTask = .{
                .ref = selected_title.ref,
                .page = 1,
            };
            var subtitles_group: std.Io.Group = .init;
            defer subtitles_group.cancel(runtime_io.get());
            try subtitles_group.concurrent(runtime_io.get(), subtitlesTaskMain, .{&subtitles_task});
            const subtitles_control = try waitForTask(ui, &subtitles_task.done, "Subtitles", detail);
            finalizeWorkerGroup(&subtitles_group, subtitles_control);

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

            const subtitle_enabled = try buildSubtitleEnabled(ui.allocator, subtitles.items, defaultTuiSettings());
            defer ui.allocator.free(subtitle_enabled);

            var allow_auto_subtitle_select = true;
            subtitle_loop: while (true) {
                setContext(ui, context);
                const subtitle_idx = (if (allow_auto_subtitle_select) singleEnabledIndex(subtitle_enabled) else null) orelse blk: {
                    const subtitle_choice = try vaxisSelectSubtitle(
                        ui,
                        "Combined Search: Select Subtitle",
                        "s sort, / filter, Esc titles.",
                        subtitles.items,
                        subtitle_enabled,
                        null,
                    );

                    break :blk switch (subtitle_choice) {
                        .selected => |idx| idx,
                        .back => continue :title_loop,
                        .to_query => continue :query_loop,
                        .page_prev, .page_next => continue :subtitle_loop,
                        .quit => return .quit,
                    };
                };
                allow_auto_subtitle_select = false;

                const selected_subtitle = subtitles.items[subtitle_idx];
                const download_url = selected_subtitle.download_url orelse "(no direct URL)";
                const download_url_display = if (isSubtitlecatTranslateToken(selected_subtitle.download_url))
                    "subtitlecat translate request"
                else
                    download_url;

                if (!ui.skip_confirm) {
                    var provider_buf: [224]u8 = undefined;
                    const provider_line = std.fmt.bufPrint(&provider_buf, "Provider: {s}", .{app.providerDisplayName(selected_provider)}) catch "Provider: (overflow)";
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
                var download_group: std.Io.Group = .init;
                defer download_group.cancel(runtime_io.get());
                try download_group.concurrent(runtime_io.get(), downloadTaskMain, .{&download_task});
                const download_control = try waitForDownloadTask(ui, &download_task, "Download", download_detail);
                finalizeWorkerGroup(&download_group, download_control);

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
        out[idx] = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ app.providerDisplayName(hit.provider), item.label });
        initialized += 1;
    }

    return out;
}

fn buildProviderNames(allocator: std.mem.Allocator) ![][]u8 {
    const values = app.providers();
    const out = try allocator.alloc([]u8, values.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer freeInitializedStrings(allocator, out, initialized);
    for (values, 0..) |provider, idx| {
        out[idx] = try std.fmt.allocPrint(allocator, "{s}", .{app.providerDisplayName(provider)});
        initialized += 1;
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

fn buildSubtitleEnabled(allocator: std.mem.Allocator, items: []const app.SubtitleChoice, settings: TuiSettings) ![]bool {
    const out = try allocator.alloc(bool, items.len);
    for (items, 0..) |item, idx| {
        out[idx] = item.download_url != null and subtitleLanguageAllowed(item, settings);
    }
    return out;
}

fn singleEnabledIndex(flags: []const bool) ?usize {
    var found: ?usize = null;
    for (flags, 0..) |enabled, idx| {
        if (!enabled) continue;
        if (found != null) return null;
        found = idx;
    }
    return found;
}

fn exportCachedDownload(ui: *Ui, result: app.DownloadResult) !MessageResult {
    const files = if (result.extracted_files.len > 0) result.extracted_files else blk: {
        const one = try ui.frameAllocator().alloc([]const u8, 1);
        one[0] = result.file_path;
        break :blk one;
    };

    const labels = try ui.allocator.alloc([]const u8, files.len);
    defer ui.allocator.free(labels);
    for (files, 0..) |path, idx| labels[idx] = pathBaseName(path);

    while (true) {
        const choice = try vaxisSelect(
            ui,
            "Cached Download",
            "Enter exports selected subtitle file. Esc keeps it cached.",
            labels,
            null,
            null,
            null,
            null,
        );
        const idx = switch (choice) {
            .selected => |i| i,
            .back, .page_prev, .page_next => return .ok,
            .to_query => return .to_query,
            .quit => return .quit,
        };
        const source = selectedCachedFile(files, idx) catch |err| return showFriendlyError(ui, "Could not export subtitle", err);
        const exported = exportCachedFile(ui.allocator, source, "downloads") catch |err| return showFriendlyError(ui, "Could not export subtitle", err);
        defer ui.allocator.free(exported);
        const msg = try vaxisMessage(ui, "Exported", exported, "Press any key to continue.", ui.styleAccent());
        switch (msg) {
            .ok => return .ok,
            .to_query => return .to_query,
            .quit => return .quit,
        }
    }
}

fn selectedCachedFile(files: []const []const u8, idx: usize) ![]const u8 {
    if (idx >= files.len) return error.InvalidSelection;
    return files[idx];
}

fn exportCachedFile(allocator: std.mem.Allocator, source_path: []const u8, out_dir: []const u8) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), out_dir);
    const safe = try sanitizeExportFilename(allocator, pathBaseName(source_path));
    defer allocator.free(safe);
    const out_path = try nextAvailableExportPath(allocator, out_dir, safe);
    errdefer allocator.free(out_path);
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        source_path,
        std.Io.Dir.cwd(),
        out_path,
        runtime_io.get(),
        .{ .replace = false },
    );
    return out_path;
}

fn cachedDownloadLabels(allocator: std.mem.Allocator, cache_root_path: []const u8) ![][]u8 {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/downloads", .{cache_root_path});
    defer allocator.free(dir_path);
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |label| allocator.free(label);
        out.deinit(allocator);
    }
    try cachedDownloadLabelsRecursive(allocator, dir_path, "", &out);
    return try out.toOwnedSlice(allocator);
}

fn cachedDownloadLabelsRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    rel_prefix: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(runtime_io.get(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return,
    };
    defer dir.close(runtime_io.get());

    var it = dir.iterate();
    while (try it.next(runtime_io.get())) |entry| {
        const rel = if (rel_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, entry.name });
        errdefer allocator.free(rel);
        switch (entry.kind) {
            .file => try out.append(allocator, rel),
            .directory => {
                const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer allocator.free(child);
                try cachedDownloadLabelsRecursive(allocator, child, rel, out);
                allocator.free(rel);
            },
            else => allocator.free(rel),
        }
    }
}

fn refreshCachedDownloads(allocator: std.mem.Allocator, state: *TuiRuntimeState) !void {
    const next = try cachedDownloadLabels(allocator, state.cache_root_path);
    if (state.download_entries.len > 0) freeOwnedStrings(allocator, state.download_entries);
    state.download_entries = next;
}

fn exportHomeCachedDownload(ui: *Ui, state: *TuiRuntimeState, selected_download: usize) !MessageResult {
    if (selected_download >= state.download_entries.len) return .ok;

    const input = try vaxisInput(
        ui,
        "Export Download",
        "Destination directory (blank = downloads)",
        "Directory",
        .{ .max_len = 240, .allow_empty = true },
    );
    const out_dir = switch (input) {
        .submit => |dir| dir,
        .back => return .ok,
        .quit => return .quit,
    };
    defer ui.allocator.free(out_dir);

    const trimmed_dir = std.mem.trim(u8, out_dir, " \t\r\n");
    const exported = exportCachedDownloadEntry(
        ui.allocator,
        state.cache_root_path,
        state.download_entries[selected_download],
        if (trimmed_dir.len == 0) "downloads" else trimmed_dir,
    ) catch |err| {
        if (err == error.FileNotFound) refreshCachedDownloads(ui.allocator, state) catch {};
        return showFriendlyError(ui, "Could not export cached download", err);
    };
    defer ui.allocator.free(exported);

    return vaxisMessage(ui, "Exported", exported, "Press any key to continue.", ui.styleAccent());
}

fn exportCachedDownloadEntry(
    allocator: std.mem.Allocator,
    cache_root_path: []const u8,
    relative_path: []const u8,
    out_dir: []const u8,
) ![]u8 {
    const source = try std.fmt.allocPrint(allocator, "{s}/downloads/{s}", .{ cache_root_path, relative_path });
    defer allocator.free(source);
    return exportCachedFile(allocator, source, out_dir);
}

fn pathBaseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[slash + 1 ..];
}

fn sanitizeExportFilename(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |ch| {
        const safe = switch (ch) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => '_',
            0...31 => '_',
            else => ch,
        };
        try out.append(allocator, safe);
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "subtitle.srt");
    return try out.toOwnedSlice(allocator);
}

fn nextAvailableExportPath(allocator: std.mem.Allocator, out_dir: []const u8, filename: []const u8) ![]u8 {
    var candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, filename });
    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        std.Io.Dir.cwd().access(runtime_io.get(), candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => return candidate,
            else => return err,
        };
        allocator.free(candidate);
        candidate = try std.fmt.allocPrint(allocator, "{s}/{d}-{s}", .{ out_dir, suffix, filename });
    }
}

fn subtitleLanguageAllowed(item: app.SubtitleChoice, settings: TuiSettings) bool {
    if (!settings.language_filter_enabled) return true;
    const raw = item.language orelse return true;
    const normalized = scrapers.common.normalizeLanguageCode(raw) orelse return true;
    for (language_options, 0..) |option, idx| {
        if (std.mem.eql(u8, option.code, normalized)) return settings.languages_enabled[idx];
    }
    const short = languageCode2(normalized);
    for (language_options, 0..) |option, idx| {
        if (std.mem.eql(u8, option.code, short)) return settings.languages_enabled[idx];
    }
    return true;
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
        error.ArchiveExtractionUnavailable => "Archive extraction is not available for this archive format in this build.",
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

const InputOptions = struct {
    max_len: usize,
    allow_empty: bool = false,
};

fn vaxisInput(
    ui: *Ui,
    title: []const u8,
    hint: []const u8,
    label: []const u8,
    options: InputOptions,
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

        const prompt_segments = [_]vaxis.Segment{
            .{ .text = label, .style = ui.styleAccent() },
            .{ .text = ": " },
        };
        _ = win.print(&prompt_segments, .{ .row_offset = 3, .col_offset = 1, .wrap = .none });

        const prompt_width: usize = @intCast(win.gwidth(label) + 2);
        const input_col_usize = @as(usize, 1) + prompt_width;
        const input_col: u16 = @intCast(@min(input_col_usize, @as(usize, win.width)));
        const input_width: usize = if (win.width > input_col) @intCast(win.width - input_col) else 0;
        const viewport = queryViewportForCursor(win, query.items, cursor_pos, input_width);
        if (viewport.start > 0 and input_width > 0) {
            try printFitted(ui, win, 3, input_col, "‹", ui.styleMuted(), 1);
            try printFitted(ui, win, 3, input_col + 1, query.items[viewport.start..], vaxis.Style{}, input_width -| 1);
        } else {
            try printFitted(ui, win, 3, input_col, query.items, vaxis.Style{}, input_width);
        }

        if (win.width > 0) {
            const desired_col = input_col + @as(u16, @intCast(@min(viewport.cursor_col, input_width)));
            win.showCursor(@min(desired_col, win.width -| 1), 3);
        }

        try renderBottomBar(ui, win, .{ .left = "Enter submit • Esc back • Ctrl+U clear" });

        if (error_text) |txt| {
            const err_segments = [_]vaxis.Segment{.{ .text = txt, .style = ui.styleError() }};
            _ = win.print(&err_segments, .{ .row_offset = 6, .col_offset = 1, .wrap = .none });
        }

        try ui.render();

        const batch = try readEventBatch(ui, try ui.loop.nextEvent());
        for (batch.slice()) |event| {
            switch (event) {
                .winsize => |ws| try ui.resize(ws),
                .mouse => |mouse| {
                    if (mouse.type != .press or mouse.button != .left or mouse.row < 0 or mouse.col < 0) continue;
                    const row: u16 = @intCast(mouse.row);
                    const col: u16 = @intCast(mouse.col);
                    if (row != 3 or col < input_col or col >= input_col + @as(u16, @intCast(input_width))) continue;
                    var target_col: usize = @intCast(col - input_col);
                    if (viewport.start > 0) {
                        if (target_col == 0) {
                            cursor_pos = viewport.start;
                            continue;
                        }
                        target_col -= 1;
                    }
                    cursor_pos = viewport.start + queryCursorByteOffsetForDisplayColumn(
                        win,
                        query.items[viewport.start..],
                        target_col,
                    );
                },
                .key_press => |key| {
                    switch (handleGlobalKey(ui, key)) {
                        .none => {},
                        .consumed => continue,
                        .to_query => return .back,
                        .quit => return .quit,
                    }

                    if (key.matches(vaxis.Key.escape, .{})) {
                        return .back;
                    }

                    if (key.matches(vaxis.Key.enter, .{})) {
                        if (query.items.len == 0 and !options.allow_empty) {
                            error_text = "Input cannot be empty.";
                        } else {
                            return .{ .submit = try query.toOwnedSlice(ui.allocator) };
                        }
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
                        error_text = null;
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
                        if (query.items.len + text.len <= options.max_len) {
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
        if (info_menu_open and !canRenderOverlayMenu(win)) info_menu_open = false;
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

            try printFitted(ui, win, row, 1, cursor_prefix, style, cursor_prefix.len);
            if (toggle_prefix.len > 0) {
                try printFitted(ui, win, row, 1 + @as(u16, @intCast(cursor_prefix.len)), toggle_prefix, style, toggle_prefix.len);
            }
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
            "F1 info · type Enter/Esc BS"
        else if (provider_toggles != null)
            "F1 info · j/k Space select Enter search Esc"
        else if (can_page)
            "F1 info · j/k Enter / [ ] Esc"
        else
            "F1 info · j/k Enter / Esc";

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
            "{s} • {s}:{s} • {s}",
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
            const close_help = if (filter_mode) "close: F1/Esc" else "close: F1/m/?/Esc";
            const lines = [_][]const u8{
                l1,
                l2,
                l3,
                l4,
                l5,
                close_help,
            };
            try renderOverlayMenu(ui, win, "Menu", &lines);
        }

        try ui.render();

        const batch = try readEventBatch(ui, try ui.loop.nextEvent());
        for (batch.slice()) |event| {
            switch (event) {
                .winsize => |ws| try ui.resize(ws),
                .key_press => |key| {
                    switch (handleGlobalKey(ui, key)) {
                        .none => {},
                        .consumed => continue,
                        .to_query => return .to_query,
                        .quit => return .quit,
                    }
                    if (key.matches(vaxis.Key.f1, .{}) or
                        (!filter_mode and (key.matches('m', .{}) or key.matches('?', .{}))))
                    {
                        if (canRenderOverlayMenu(ui.vx.window())) info_menu_open = !info_menu_open;
                        continue;
                    }
                    if (info_menu_open and key.matches(vaxis.Key.escape, .{})) {
                        info_menu_open = false;
                        continue;
                    }
                    if (info_menu_open) info_menu_open = false;

                    if (filter_mode) {
                        if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.enter, .{})) {
                            filter_mode = false;
                            continue;
                        }
                        if (key.matches(vaxis.Key.backspace, .{})) {
                            popLastUtf8Codepoint(&filter);
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
                    if (key.matches(vaxis.Key.end, .{})) {
                        if (matches.items.len > 0) selected_row = matches.items.len - 1;
                        moveSelectionToEnabled(matches.items, enabled, &selected_row, .backward);
                        continue;
                    }
                },
                .mouse => |mouse| {
                    if (info_menu_open) {
                        if (mouse.type == .press) {
                            info_menu_open = false;
                        } else {
                            continue;
                        }
                    }
                    if (handleMouseWheel(mouse, matches.items.len, &selected_row, provider_toggles == null, matches.items, enabled)) continue;
                    if (mouse.type == .press and mouse.button == .left) {
                        if (mouseRowIndex(mouse, list_top, list_bottom, scroll, matches.items.len)) |row_idx| {
                            const already_selected = row_idx == selected_row;
                            selected_row = row_idx;
                            if (provider_toggles) |flags| {
                                // Rows render as: cursor at col 1..2, checkbox
                                // at col 3..5, then a separating space.
                                if (mouseColumnInRange(mouse, 3, 6)) {
                                    const option_idx = matches.items[selected_row];
                                    flags[option_idx] = !flags[option_idx];
                                    continue;
                                }
                            }
                            if (provider_toggles == null) {
                                moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
                            }
                            if (already_selected and selected_row < matches.items.len) {
                                const option_idx = matches.items[selected_row];
                                if (provider_toggles != null or isOptionEnabled(enabled, option_idx)) {
                                    return .{ .selected = option_idx };
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
        if (batch.wheel_delta != 0) {
            applyWheelDelta(&selected_row, matches.items.len, batch.wheel_delta, list_mouse_wheel_step);
            if (provider_toggles == null) {
                moveSelectionToEnabled(matches.items, enabled, &selected_row, if (batch.wheel_delta > 0) .forward else .backward);
            }
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
        if (info_menu_open and !canRenderOverlayMenu(win)) info_menu_open = false;
        win.clear();
        win.hideCursor();

        const show_pane = win.width >= 96;
        const left_width: u16 = if (show_pane) @max(@as(u16, 36), (win.width * 56) / 100) else win.width;
        const pane_col: u16 = left_width + 3;
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
        const text_width = list_width -| 10;

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
            const prefix = if (active) "› " else "  ";
            const lang = subtitleLanguageCodeForDisplay(subtitles[sub_idx]);

            try printFitted(ui, win, row, 1, prefix, style, 2);
            try printFitted(ui, win, row, 3, lang, ui.styleMuted(), 5);
            try printFitted(ui, win, row, 9, subtitleFilenameForDisplay(subtitles[sub_idx]), style, text_width);
            row += 1;
        }

        if (matches.items.len == 0) {
            const empty_segments = [_]vaxis.Segment{.{ .text = "No subtitle matches for current filter.", .style = ui.styleWarn() }};
            _ = win.print(&empty_segments, .{ .row_offset = list_top, .col_offset = 1, .wrap = .none });
        }

        if (show_pane) {
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
            "F1 info · type Enter/Esc BS"
        else if (can_page)
            "F1 info · j/k Enter s / [ ] Esc"
        else
            "F1 info · j/k Enter s / Esc";

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
            "{s}  •  {s}  •  {s}",
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
            const close_help = if (filter_mode) "close: F1/Esc" else "close: F1/m/?/Esc";
            const lines = [_][]const u8{
                l1,
                l2,
                l3,
                l4,
                l5,
                close_help,
            };
            try renderOverlayMenu(ui, win, "Menu", &lines);
        }

        try ui.render();

        const batch = try readEventBatch(ui, try ui.loop.nextEvent());
        for (batch.slice()) |event| {
            switch (event) {
                .winsize => |ws| try ui.resize(ws),
                .key_press => |key| {
                    switch (handleGlobalKey(ui, key)) {
                        .none => {},
                        .consumed => continue,
                        .to_query => return .to_query,
                        .quit => return .quit,
                    }
                    if (key.matches(vaxis.Key.f1, .{}) or
                        (!filter_mode and (key.matches('m', .{}) or key.matches('?', .{}))))
                    {
                        if (canRenderOverlayMenu(ui.vx.window())) info_menu_open = !info_menu_open;
                        continue;
                    }
                    if (info_menu_open and key.matches(vaxis.Key.escape, .{})) {
                        info_menu_open = false;
                        continue;
                    }
                    if (info_menu_open) info_menu_open = false;

                    if (filter_mode) {
                        if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.enter, .{})) {
                            filter_mode = false;
                            continue;
                        }
                        if (key.matches(vaxis.Key.backspace, .{})) {
                            popLastUtf8Codepoint(&filter);
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
                    if (key.matches(vaxis.Key.end, .{})) {
                        if (matches.items.len > 0) selected_row = matches.items.len - 1;
                        moveSelectionToEnabled(matches.items, enabled, &selected_row, .backward);
                        continue;
                    }
                },
                .mouse => |mouse| {
                    if (info_menu_open) {
                        if (mouse.type == .press) {
                            info_menu_open = false;
                        } else {
                            continue;
                        }
                    }
                    if (handleMouseWheel(mouse, matches.items.len, &selected_row, true, matches.items, enabled)) continue;
                    if (mouse.type == .press and mouse.button == .left) {
                        if (mouseRowIndex(mouse, list_top, list_bottom, scroll, matches.items.len)) |row_idx| {
                            const already_selected = row_idx == selected_row;
                            selected_row = row_idx;
                            moveSelectionToEnabled(matches.items, enabled, &selected_row, .forward);
                            if (already_selected and selected_row < matches.items.len and enabled[matches.items[selected_row]]) {
                                return .{ .selected = matches.items[selected_row] };
                            }
                        }
                    }
                },
                else => {},
            }
        }
        if (batch.wheel_delta != 0) {
            applyWheelDelta(&selected_row, matches.items.len, batch.wheel_delta, list_mouse_wheel_step);
            moveSelectionToEnabled(matches.items, enabled, &selected_row, if (batch.wheel_delta > 0) .forward else .backward);
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

        try renderBottomBar(ui, win, .{ .left = "Enter confirm • Esc back" });
        try ui.render();

        const batch = try readEventBatch(ui, try ui.loop.nextEvent());
        for (batch.slice()) |event| {
            switch (event) {
                .winsize => |ws| try ui.resize(ws),
                .key_press => |key| {
                    switch (handleGlobalKey(ui, key)) {
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

        const batch = try readEventBatch(ui, try ui.loop.nextEvent());
        for (batch.slice()) |event| {
            switch (event) {
                .winsize => |ws| try ui.resize(ws),
                .key_press => |key| {
                    switch (handleGlobalKey(ui, key)) {
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
        "{s}:{s} {s}:{s} {s}",
        .{ BarLayout.confirm_key, confirm_text, BarLayout.theme_key, ui.theme().name, BarLayout.quit_hint },
    );
    const status_width: usize = @intCast(win.gwidth(status));
    if (status_width >= width) {
        try printFitted(ui, win, row, 1, status, ui.styleMuted(), width);
        return;
    }

    const status_col: u16 = @intCast(1 + width - status_width);
    const separator_width: usize = @intCast(win.gwidth(BarLayout.separator));
    if (width > status_width + separator_width) {
        const left_width = width - status_width - separator_width;
        try printFitted(ui, win, row, 1, left, ui.styleMuted(), left_width);
        const separator_col: u16 = @intCast(@as(usize, status_col) - separator_width);
        try printFitted(ui, win, row, separator_col, BarLayout.separator, ui.styleMuted(), separator_width);
    }
    try printFitted(ui, win, row, status_col, status, ui.styleMuted(), status_width);
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
            .{ marker, checkbox, app.providerDisplayName(provider), caps },
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
    if (!canRenderOverlayMenu(win)) return;

    const max_box_w: u16 = @min(win.width - 2, 80);
    if (max_box_w < 12) return;
    const box_h: u16 = @min(win.height - 2, @as(u16, @intCast(lines.len + 3)));
    if (box_h < 5) return;

    const x0: u16 = (win.width - max_box_w) / 2;
    const y0: u16 = (win.height - box_h) / 2;
    const inner_w: usize = @intCast(max_box_w - 2);

    try fillBoxBackground(ui, win, x0, y0, max_box_w, box_h);
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

fn canRenderOverlayMenu(win: anytype) bool {
    return win.width >= 20 and win.height >= 8;
}

test "overlay menu requires enough terminal space" {
    const Tiny = struct { width: u16, height: u16 };
    try std.testing.expect(!canRenderOverlayMenu(Tiny{ .width = 19, .height = 8 }));
    try std.testing.expect(!canRenderOverlayMenu(Tiny{ .width = 20, .height = 7 }));
    try std.testing.expect(canRenderOverlayMenu(Tiny{ .width = 20, .height = 8 }));
}

const KeyAction = enum {
    none,
    consumed,
    to_query,
    quit,
};

fn handleGlobalKey(ui: *Ui, key: vaxis.Key) KeyAction {
    if (key.isModifier()) return .consumed;
    if (key.matches('d', .{ .ctrl = true })) ui.hardQuit();
    if (key.matches('c', .{ .ctrl = true })) return .to_query;
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

fn popLastUtf8Codepoint(text: *std.ArrayList(u8)) void {
    if (text.items.len == 0) return;
    const prev = prevCodepointStart(text.items, text.items.len);
    text.items = text.items[0..prev];
}

test "filter backspace removes complete utf8 codepoints" {
    var filter: std.ArrayList(u8) = .empty;
    defer filter.deinit(std.testing.allocator);
    try filter.appendSlice(std.testing.allocator, "aé界");

    popLastUtf8Codepoint(&filter);
    try std.testing.expectEqualStrings("aé", filter.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(filter.items));

    popLastUtf8Codepoint(&filter);
    try std.testing.expectEqualStrings("a", filter.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(filter.items));

    popLastUtf8Codepoint(&filter);
    try std.testing.expectEqualStrings("", filter.items);
    popLastUtf8Codepoint(&filter);
    try std.testing.expectEqualStrings("", filter.items);
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

const list_mouse_wheel_step: usize = 3;
const search_active_poll_interval_ms: u64 = 1;
const search_poll_interval_ms: u64 = 8;
const event_batch_capacity: usize = 1;

const EventBatch = struct {
    items: [event_batch_capacity]Event = undefined,
    len: usize = 0,
    wheel_delta: i32 = 0,

    fn append(self: *EventBatch, event: Event) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = event;
        self.len += 1;
    }

    fn slice(self: *const EventBatch) []const Event {
        return self.items[0..self.len];
    }

    fn collect(self: *EventBatch, event: Event) void {
        if (eventWheelDelta(event)) |delta| {
            self.wheel_delta += delta;
        } else {
            self.append(event);
        }
    }
};

fn readEventBatch(ui: *Ui, first: Event) !EventBatch {
    _ = ui;
    var batch: EventBatch = .{};
    batch.collect(first);
    // Do not eagerly drain keyboard events. Many TUI handlers intentionally
    // return or change screens on Enter/Esc/Ctrl+C; draining ahead would drop
    // any immediately-following keystrokes from the same terminal burst.
    // Rendering is sub-millisecond in optimized builds, so one event per frame
    // keeps input lossless without sacrificing navigation responsiveness.
    return batch;
}

fn eventWheelDelta(event: Event) ?i32 {
    return switch (event) {
        .mouse => |mouse| mouseWheelDelta(mouse),
        else => null,
    };
}

fn mouseWheelDelta(mouse: vaxis.Mouse) ?i32 {
    if (mouse.type != .press) return null;
    return switch (mouse.button) {
        .wheel_down => 1,
        .wheel_up => -1,
        else => null,
    };
}

fn applyWheelDelta(selected_row: *usize, item_count: usize, delta: i32, step: usize) void {
    if (delta == 0 or item_count == 0) return;
    const units: usize = @intCast(if (delta > 0) delta else -delta);
    const rows = units * step;
    if (delta > 0) {
        scrollSelection(selected_row, item_count, .forward, rows);
    } else {
        scrollSelection(selected_row, item_count, .backward, rows);
    }
}

fn mouseRowIndex(mouse: vaxis.Mouse, list_top: u16, list_bottom: u16, scroll: usize, total: usize) ?usize {
    if (mouse.row < 0) return null;
    const row: u16 = @intCast(mouse.row);
    if (row < list_top or row >= list_bottom) return null;
    const idx = scroll + @as(usize, @intCast(row - list_top));
    if (idx >= total) return null;
    return idx;
}

fn mouseColumnInRange(mouse: vaxis.Mouse, start: u16, end_exclusive: u16) bool {
    if (mouse.col < 0) return false;
    const col: u16 = @intCast(mouse.col);
    return col >= start and col < end_exclusive;
}

test "mouse checkbox hitbox excludes provider label" {
    const base: vaxis.Mouse = .{
        .col = 3,
        .row = 1,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    try std.testing.expect(mouseColumnInRange(base, 3, 6));
    var edge = base;
    edge.col = 5;
    try std.testing.expect(mouseColumnInRange(edge, 3, 6));
    var label = base;
    label.col = 6;
    try std.testing.expect(!mouseColumnInRange(label, 3, 6));
    var invalid = base;
    invalid.col = -1;
    try std.testing.expect(!mouseColumnInRange(invalid, 3, 6));
}

fn scrollSelection(selected_row: *usize, item_count: usize, direction: SearchDirection, step: usize) void {
    if (item_count == 0) return;
    switch (direction) {
        .forward => selected_row.* = @min(item_count - 1, selected_row.* + step),
        .backward => selected_row.* = selected_row.* -| step,
    }
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

    switch (mouse.button) {
        .wheel_down => {
            scrollSelection(selected_row, item_count, .forward, list_mouse_wheel_step);
            if (skip_disabled) moveSelectionToEnabled(matches, enabled, selected_row, .forward);
            return true;
        },
        .wheel_up => {
            scrollSelection(selected_row, item_count, .backward, list_mouse_wheel_step);
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

    var display_text = text;
    var text_class = classifyDisplayText(display_text);
    if (text_class == .needs_sanitize) {
        display_text = try sanitizeUtf8ForDisplay(ui.frameAllocator(), display_text);
        text_class = classifyDisplayText(display_text);
        std.debug.assert(text_class != .needs_sanitize);
    }

    if (text_class == .simple_ascii) {
        if (display_text.len <= max_width) {
            writeAsciiCells(win, row, col, display_text, style);
            return;
        }
        if (max_width <= 3) {
            writeAsciiCells(win, row, col, display_text[0..max_width], style);
            return;
        }
        const prefix = display_text[0 .. max_width - 3];
        writeAsciiCells(win, row, col, prefix, style);
        writeAsciiCells(win, row, col + @as(u16, @intCast(prefix.len)), "...", style);
        return;
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

const ascii_graphemes = blk: {
    var table: [128][1]u8 = undefined;
    for (0..table.len) |idx| table[idx][0] = @intCast(idx);
    break :blk table;
};

fn writeAsciiCells(win: anytype, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
    var x = col;
    for (text) |byte| {
        std.debug.assert(byte < 0x80);
        if (x >= win.width) break;
        win.writeCell(x, row, .{
            .char = .{
                .grapheme = ascii_graphemes[byte][0..1],
                .width = 1,
            },
            .style = style,
            .wrapped = x + 1 >= win.width,
        });
        x += 1;
    }
}

const DisplayTextClass = enum {
    simple_ascii,
    valid_utf8,
    needs_sanitize,
};

fn classifyDisplayText(text: []const u8) DisplayTextClass {
    var simple_ascii = true;
    var has_non_ascii = false;
    for (text) |byte| {
        if (byte < 0x20) {
            if (byte != '\n' and byte != '\r' and byte != '\t') return .needs_sanitize;
            simple_ascii = false;
            continue;
        }
        if (byte == 0x7f) return .needs_sanitize;
        if (byte >= 0x80) {
            simple_ascii = false;
            has_non_ascii = true;
        }
    }
    if (simple_ascii) return .simple_ascii;
    if (has_non_ascii and !std.unicode.utf8ValidateSlice(text)) return .needs_sanitize;
    return .valid_utf8;
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

fn queryCursorByteOffsetForDisplayColumn(win: anytype, text: []const u8, column: usize) usize {
    if (text.len == 0 or column == 0) return 0;

    var idx: usize = 0;
    var previous_width: usize = 0;
    while (idx < text.len) {
        const next = nextCodepointEnd(text, idx);
        if (next <= idx or next > text.len) break;
        const next_width: usize = @intCast(win.gwidth(text[0..next]));
        if (next_width > column) {
            const before_distance = column -| previous_width;
            const after_distance = next_width - column;
            return if (after_distance < before_distance) next else idx;
        }
        previous_width = next_width;
        idx = next;
    }
    return text.len;
}

const QueryViewport = struct {
    start: usize,
    cursor_col: usize,
};

fn queryViewportForCursor(win: anytype, text: []const u8, cursor_pos: usize, max_width: usize) QueryViewport {
    const cursor = @min(cursor_pos, text.len);
    if (max_width == 0 or text.len == 0) return .{ .start = 0, .cursor_col = 0 };

    const prefix_width: usize = @intCast(win.gwidth(text[0..cursor]));
    if (prefix_width <= max_width) return .{ .start = 0, .cursor_col = prefix_width };

    const content_width = max_width -| 1;
    var start = cursor;
    while (start > 0) {
        const prev = prevCodepointStart(text, start);
        const width: usize = @intCast(win.gwidth(text[prev..cursor]));
        if (width > content_width) break;
        start = prev;
    }
    const visible_prefix_width: usize = @intCast(win.gwidth(text[start..cursor]));
    return .{
        .start = start,
        .cursor_col = 1 + @min(visible_prefix_width, content_width),
    };
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

test "query mouse cursor placement stays on utf8 boundaries" {
    const FakeWin = struct {
        pub fn gwidth(_: @This(), s: []const u8) usize {
            return std.unicode.utf8CountCodepoints(s) catch s.len;
        }
    };

    const win = FakeWin{};
    const text = "aé界z";
    try std.testing.expectEqual(@as(usize, 0), queryCursorByteOffsetForDisplayColumn(win, text, 0));
    try std.testing.expectEqual(@as(usize, 1), queryCursorByteOffsetForDisplayColumn(win, text, 1));
    try std.testing.expectEqual(@as(usize, 3), queryCursorByteOffsetForDisplayColumn(win, text, 2));
    try std.testing.expectEqual(@as(usize, 6), queryCursorByteOffsetForDisplayColumn(win, text, 3));
    try std.testing.expectEqual(text.len, queryCursorByteOffsetForDisplayColumn(win, text, 99));
}

test "query viewport follows cursor without splitting utf8" {
    const FakeWin = struct {
        pub fn gwidth(_: @This(), s: []const u8) usize {
            return std.unicode.utf8CountCodepoints(s) catch s.len;
        }
    };

    const win = FakeWin{};
    const ascii = "abcdefghij";
    const tail = queryViewportForCursor(win, ascii, ascii.len, 5);
    try std.testing.expectEqual(@as(usize, 6), tail.start);
    try std.testing.expectEqual(@as(usize, 5), tail.cursor_col);
    try std.testing.expectEqualStrings("ghij", ascii[tail.start..]);

    const WideFakeWin = struct {
        pub fn gwidth(_: @This(), s: []const u8) usize {
            var view = std.unicode.Utf8View.init(s) catch return s.len;
            var it = view.iterator();
            var width: usize = 0;
            while (it.nextCodepoint()) |cp| width += if (cp == '界') 2 else 1;
            return width;
        }
    };

    const unicode = "aé界z";
    const after_cjk = "aé界".len;
    const viewport = queryViewportForCursor(WideFakeWin{}, unicode, after_cjk, 3);
    try std.testing.expect(std.unicode.utf8ValidateSlice(unicode[viewport.start..]));
    try std.testing.expectEqual(@as(usize, 3), viewport.cursor_col);
    try std.testing.expectEqualStrings("界z", unicode[viewport.start..]);
}

test "sanitizeUtf8ForDisplay escapes invalid bytes" {
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 'A', 0xAA, 'B', 0xFF };
    const safe = try sanitizeUtf8ForDisplay(allocator, &raw);
    defer allocator.free(safe);

    try std.testing.expectEqualStrings("A\\xAAB\\xFF", safe);
    try std.testing.expect(std.unicode.utf8ValidateSlice(safe));
}

test "remote search failures do not count as application failures" {
    try std.testing.expect(isRemoteSearchFailure(error.UnexpectedHttpStatus));
    try std.testing.expect(isRemoteSearchFailure(error.InvalidFieldType));
    try std.testing.expect(isRemoteSearchFailure(error.CloudflareSessionUnavailable));
    try std.testing.expect(!isRemoteSearchFailure(error.OutOfMemory));

    const allocator = std.testing.allocator;
    var bundle: SearchBundle = .{ .query_norm = try allocator.dupe(u8, "matrix") };
    defer bundle.deinit(allocator);

    recordSearchFailure(&bundle, error.UnexpectedHttpStatus);
    try std.testing.expectEqual(@as(usize, 1), bundle.unavailable_count);
    try std.testing.expectEqual(@as(usize, 0), bundle.failed_count);

    recordSearchFailure(&bundle, error.OutOfMemory);
    try std.testing.expectEqual(@as(usize, 1), bundle.unavailable_count);
    try std.testing.expectEqual(@as(usize, 1), bundle.failed_count);
}

test "cached export rejects stale selection index" {
    const files = [_][]const u8{"subtitle.srt"};
    try std.testing.expectEqualStrings("subtitle.srt", try selectedCachedFile(&files, 0));
    try std.testing.expectError(error.InvalidSelection, selectedCachedFile(&files, 1));
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
    try std.testing.expectEqual(@as(usize, 1), countEnabledFlags(&settings.languages_enabled));
    try std.testing.expect(settings.languages_enabled[0]);
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
    try std.testing.expect(cacheFresh(entry, 100 + 365 * 24 * 60 * 60, 0));
    try std.testing.expectEqual(@as(?i64, 0), parseCacheTtlSeconds("inf"));
    try std.testing.expectEqual(@as(?i64, 0), parseCacheTtlSeconds("0"));
    try std.testing.expectEqual(@as(?i64, 5400), parseCacheTtlSeconds("1.5"));
}

test "runtime cache replacement stays bounded and compacts stale arena data" {
    const allocator = std.testing.allocator;
    var state: TuiRuntimeState = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .settings = defaultTuiSettings(),
        .state_path = try allocator.dupe(u8, "state.test"),
        .settings_path = try allocator.dupe(u8, "settings.test"),
        .keyword_path = try allocator.dupe(u8, "keywords.test"),
        .cache_root_path = try allocator.dupe(u8, "cache.test"),
    };
    defer state.deinit(allocator);

    var replacement: usize = 0;
    while (replacement < arena_compact_after_stale_mutations * 2 + 3) : (replacement += 1) {
        var response: app.SearchResponse = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .provider = .subdl_com,
            .items = &.{},
        };
        defer response.deinit();
        try upsertCacheEntry(allocator, &state, .subdl_com, "matrix", 1, @intCast(replacement), response);
    }
    try std.testing.expectEqual(@as(usize, 1), state.cache_entries.items.len);
    try std.testing.expectEqualStrings("matrix", state.cache_entries.items[0].query_norm);
    try std.testing.expect(state.arena_stale_mutations < arena_compact_after_stale_mutations);

    var keyword_idx: usize = 0;
    while (keyword_idx < max_keyword_entries + arena_compact_after_stale_mutations + 5) : (keyword_idx += 1) {
        const query = try std.fmt.allocPrint(allocator, "query-{d}", .{keyword_idx});
        defer allocator.free(query);
        try rememberKeyword(allocator, &state, query);
    }
    try std.testing.expectEqual(max_keyword_entries, state.keywords.items.len);
    try std.testing.expect(state.arena_stale_mutations < arena_compact_after_stale_mutations);
}

test "download cache refresh discovers new files and exports the selected entry" {
    const allocator = std.testing.allocator;
    const unique = scrapers.common.compatNanoTimestamp();
    const test_root = try std.fmt.allocPrint(allocator, ".zig-cache/tui-runtime-download-test-{d}", .{unique});
    defer allocator.free(test_root);
    defer std.Io.Dir.cwd().deleteTree(runtime_io.get(), test_root) catch {};
    const cache_root = try std.fmt.allocPrint(allocator, "{s}/cache", .{test_root});
    defer allocator.free(cache_root);
    const export_root = try std.fmt.allocPrint(allocator, "{s}/export", .{test_root});
    defer allocator.free(export_root);
    const downloads_root = try std.fmt.allocPrint(allocator, "{s}/downloads", .{cache_root});
    defer allocator.free(downloads_root);
    try std.Io.Dir.cwd().createDirPath(runtime_io.get(), downloads_root);

    const first_path = try std.fmt.allocPrint(allocator, "{s}/first.srt", .{downloads_root});
    defer allocator.free(first_path);
    {
        var file = try std.Io.Dir.cwd().createFile(runtime_io.get(), first_path, .{});
        defer file.close(runtime_io.get());
        var buffer: [64]u8 = undefined;
        var writer = file.writer(runtime_io.get(), &buffer);
        try writer.interface.writeAll("first subtitle\n");
        try writer.interface.flush();
    }

    var state: TuiRuntimeState = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .settings = defaultTuiSettings(),
        .state_path = try std.fmt.allocPrint(allocator, "{s}/state.oneserial", .{cache_root}),
        .settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.oneserial", .{cache_root}),
        .keyword_path = try std.fmt.allocPrint(allocator, "{s}/keywords.oneserial", .{cache_root}),
        .cache_root_path = try allocator.dupe(u8, cache_root),
    };
    defer state.deinit(allocator);

    try refreshCachedDownloads(allocator, &state);
    try std.testing.expectEqual(@as(usize, 1), state.download_entries.len);
    try std.testing.expectEqualStrings("first.srt", state.download_entries[0]);

    const second_path = try std.fmt.allocPrint(allocator, "{s}/second.srt", .{downloads_root});
    defer allocator.free(second_path);
    {
        var file = try std.Io.Dir.cwd().createFile(runtime_io.get(), second_path, .{});
        defer file.close(runtime_io.get());
        var buffer: [64]u8 = undefined;
        var writer = file.writer(runtime_io.get(), &buffer);
        try writer.interface.writeAll("second subtitle\n");
        try writer.interface.flush();
    }
    try refreshCachedDownloads(allocator, &state);
    try std.testing.expectEqual(@as(usize, 2), state.download_entries.len);

    var second_index: ?usize = null;
    for (state.download_entries, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry, "second.srt")) {
            second_index = idx;
            break;
        }
    }
    try std.testing.expect(second_index != null);

    const exported = try exportCachedDownloadEntry(
        allocator,
        state.cache_root_path,
        state.download_entries[second_index.?],
        export_root,
    );
    defer allocator.free(exported);
    const copied = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), exported, allocator, .limited(1024));
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("second subtitle\n", copied);
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

test "search settings invalidation only tracks provider and language scope" {
    const original = defaultTuiSettings();

    var changed = original;
    changed.providers_enabled[0] = !changed.providers_enabled[0];
    try std.testing.expect(searchSettingsChanged(original, changed));

    changed = original;
    changed.language_filter_enabled = !changed.language_filter_enabled;
    try std.testing.expect(searchSettingsChanged(original, changed));

    changed = original;
    changed.languages_enabled[0] = !changed.languages_enabled[0];
    try std.testing.expect(searchSettingsChanged(original, changed));

    changed = original;
    changed.cache_enabled = !changed.cache_enabled;
    changed.download_cache_enabled = !changed.download_cache_enabled;
    changed.cache_ttl_seconds += 60;
    changed.keyword_cache_enabled = !changed.keyword_cache_enabled;
    try std.testing.expect(!searchSettingsChanged(original, changed));
}

test "search cache key isolates language scope" {
    const allocator = std.testing.allocator;
    const english = try searchCacheKey(allocator, "matrix", "en");
    defer allocator.free(english);
    const spanish = try searchCacheKey(allocator, "matrix", "es");
    defer allocator.free(spanish);
    const unfiltered = try searchCacheKey(allocator, "matrix", null);
    defer allocator.free(unfiltered);

    try std.testing.expectEqualStrings("matrix\x1flang=en", english);
    try std.testing.expect(!std.mem.eql(u8, english, spanish));
    try std.testing.expect(!std.mem.eql(u8, english, unfiltered));
    try std.testing.expect(!std.mem.eql(u8, spanish, unfiltered));
}

test "incremental search work only releases initialized task slots" {
    const work = try createIncrementalSearchWork("matrix");
    work.tasks[0] = .{
        .provider = .subdl_com,
        .query = work.query,
    };
    work.task_count = 1;
    releaseIncrementalSearchWork(work);
}

test "settings persist independently from search cache state" {
    const allocator = std.testing.allocator;
    const unique = scrapers.common.compatNanoTimestamp();
    const test_root = try std.fmt.allocPrint(allocator, ".zig-cache/tui-settings-state-test-{d}", .{unique});
    defer allocator.free(test_root);
    defer std.Io.Dir.cwd().deleteTree(runtime_io.get(), test_root) catch {};

    var state: TuiRuntimeState = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .settings = defaultTuiSettings(),
        .state_path = try std.fmt.allocPrint(allocator, "{s}/state.oneserial", .{test_root}),
        .settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.oneserial", .{test_root}),
        .keyword_path = try std.fmt.allocPrint(allocator, "{s}/keywords.oneserial", .{test_root}),
        .cache_root_path = try std.fmt.allocPrint(allocator, "{s}/cache", .{test_root}),
    };
    defer state.deinit(allocator);

    state.settings.cache_enabled = false;
    state.settings.download_cache_enabled = false;
    state.settings.keyword_cache_enabled = false;
    state.settings.language_filter_enabled = false;
    state.settings.providers_enabled[0] = false;
    try saveTuiSettingsState(allocator, &state);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(runtime_io.get(), state.settings_path, allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len < 1024);
    try std.testing.expect(std.mem.startsWith(u8, bytes, settings_state_magic));

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const loaded = (try loadPersistentSettingsState(decode_arena.allocator(), state.settings_path)).?;
    try std.testing.expectEqual(@as(u32, persistent_version), loaded.version);
    try std.testing.expect(!loaded.settings.cache_enabled);
    try std.testing.expect(!loaded.settings.download_cache_enabled);
    try std.testing.expect(!loaded.settings.keyword_cache_enabled);
    try std.testing.expect(!loaded.settings.language_filter_enabled);
    try std.testing.expect(!loaded.settings.providers_enabled[0]);
}

test "independent settings override legacy settings embedded in search state" {
    const allocator = std.testing.allocator;
    const unique = scrapers.common.compatNanoTimestamp();
    const test_root = try std.fmt.allocPrint(allocator, ".zig-cache/tui-settings-precedence-test-{d}", .{unique});
    defer allocator.free(test_root);
    defer std.Io.Dir.cwd().deleteTree(runtime_io.get(), test_root) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/subdl/state.oneserial", .{test_root});
    defer allocator.free(state_path);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/subdl/settings.oneserial", .{test_root});
    defer allocator.free(settings_path);

    var legacy_settings = defaultTuiSettings();
    legacy_settings.cache_enabled = true;
    legacy_settings.providers_enabled[0] = true;
    const legacy_state: PersistentSearchState = .{
        .version = persistent_version,
        .settings = legacy_settings,
        .cache_entries = &.{},
    };
    try saveOneSerial(PersistentSearchState, allocator, state_path, search_state_magic, &legacy_state);

    var current_settings = legacy_settings;
    current_settings.cache_enabled = false;
    current_settings.providers_enabled[0] = false;
    const current_state: PersistentSettingsState = .{
        .version = persistent_version,
        .settings = current_settings,
    };
    try saveOneSerial(PersistentSettingsState, allocator, settings_path, settings_state_magic, &current_state);

    var env_map = try std.testing.environ.createMap(allocator);
    defer env_map.deinit();
    try env_map.put("XDG_CACHE_HOME", test_root);

    var loaded = try loadTuiRuntimeState(allocator, &env_map);
    defer loaded.deinit(allocator);
    try std.testing.expect(!loaded.settings.cache_enabled);
    try std.testing.expect(!loaded.settings.providers_enabled[0]);
    try std.testing.expectEqual(@as(usize, 0), loaded.cache_entries.items.len);
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

    var row: u16 = 3;
    const max_row: u16 = if (win.height > 4) win.height - 4 else win.height;
    const is_translate = isSubtitlecatTranslateToken(subtitle.download_url);

    try printFitted(ui, win, row, col, subtitleFilenameForDisplay(subtitle), ui.stylePaneTitle(), pane_width);
    row += 2;

    if (row >= max_row) return;
    try printLabelValue(ui, win, row, col, pane_width, "Lang ", subtitleLanguageNameForDisplay(subtitle));
    row += 1;

    if (row >= max_row) return;
    try printLabelValue(
        ui,
        win,
        row,
        col,
        pane_width,
        "Mode ",
        if (subtitle.download_url == null)
            "unavailable"
        else if (is_translate)
            "translate"
        else
            "direct",
    );
    row += 1;

    if (row >= max_row) return;
    try printLabelValue(ui, win, row, col, pane_width, "Code ", subtitleLanguageCodeForDisplay(subtitle));
    row += 1;

    if (row >= max_row) return;
    try printFitted(ui, win, row, col, "URL", ui.styleAccent(), pane_width);
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

fn subtitleLanguageCodeForDisplay(subtitle: app.SubtitleChoice) []const u8 {
    const raw = subtitle.language orelse return "--";
    const normalized = scrapers.common.normalizeLanguageCode(raw) orelse raw;
    for (language_options) |option| {
        if (std.mem.eql(u8, option.code, normalized)) return option.code;
    }
    return languageCode2(normalized);
}

fn subtitleLanguageNameForDisplay(subtitle: app.SubtitleChoice) []const u8 {
    const raw = subtitle.language orelse return "Unknown";
    const normalized = scrapers.common.normalizeLanguageCode(raw) orelse raw;
    for (language_options) |option| {
        if (std.mem.eql(u8, option.code, normalized)) return option.name;
    }
    const short = languageCode2(normalized);
    for (language_options) |option| {
        if (std.mem.eql(u8, option.code, short)) return option.name;
    }
    return raw;
}

fn languageCode2(code: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, code, " \t\r\n");
    if (trimmed.len >= 2) return trimmed[0..2];
    return "--";
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
