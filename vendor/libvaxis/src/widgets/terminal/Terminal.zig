//! A virtual terminal widget
const Terminal = @This();

const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
pub const Command = @import("Command.zig");
const Parser = @import("Parser.zig");
const Pty = @import("Pty.zig");
const vaxis = @import("../../main.zig");
const Winsize = vaxis.Winsize;
const Screen = @import("Screen.zig");
const Key = vaxis.Key;
const key = @import("key.zig");

pub const Event = union(enum) {
    exited,
    redraw,
    bell,
    title_change: []const u8,
    pwd_change: []const u8,
};

const QueuedEvent = union(enum) {
    exited,
    redraw,
    bell,
    title_change: []u8,
    pwd_change: []u8,
};
const Queue = vaxis.Queue(QueuedEvent, 16);

fn createDefaultTabStops(allocator: std.mem.Allocator, width: u16) !std.ArrayList(u16) {
    const capacity = (@as(usize, width) + 7) / 8;
    var tab_stops: std.ArrayList(u16) = try .initCapacity(allocator, capacity);
    errdefer tab_stops.deinit(allocator);
    var col: usize = 0;
    while (col < @as(usize, width)) : (col += 8)
        tab_stops.appendAssumeCapacity(@intCast(col));
    return tab_stops;
}

fn nextDrawColumn(col: u16, cell_width: u8) u16 {
    return col +| @as(u16, @max(cell_width, 1));
}

fn queueSyncReleaseRedraw(
    queue: *Queue,
    dirty: *bool,
    was_synchronized: bool,
    is_synchronized: bool,
) !void {
    if (!was_synchronized or is_synchronized) return;
    try queue.push(.redraw);
    dirty.* = true;
}

fn pollQueuedEvent(
    queue: *Queue,
    exit_reported: *bool,
    child_exited: bool,
    pty_output_drained: bool,
) !?QueuedEvent {
    if (try queue.tryPop()) |event| return event;
    if (!exit_reported.* and child_exited and pty_output_drained) {
        exit_reported.* = true;
        return .exited;
    }
    return null;
}

const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.terminal);

const ChildState = struct {
    pid: posix.pid_t,
    process_group_id: posix.pid_t,
    lock: std.atomic.Mutex = .unlocked,
    reaped: bool = false,
    exited: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u8) = .init(2),

    fn acquire(self: *ChildState) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn releaseLock(self: *ChildState) void {
        self.lock.unlock();
    }

    fn release(self: *ChildState) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1)
            std.heap.page_allocator.destroy(self);
    }

    fn signalLocked(self: *ChildState, signal: posix.SIG) bool {
        if (self.reaped) return false;
        while (true) switch (linux.errno(linux.kill(-self.process_group_id, signal))) {
            .SUCCESS => return true,
            .INTR => continue,
            .SRCH => return false,
            else => return true,
        };
    }
};

pub const Options = struct {
    scrollback_size: u16 = 500,
    winsize: Winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
    initial_working_directory: ?[]const u8 = null,
};

pub const Mode = struct {
    origin: bool = false,
    autowrap: bool = true,
    cursor: bool = true,
    sync: bool = false,
};

const IndexRange = struct { start: usize, end: usize };
const CursorPosition = struct { row: u16, col: u16 };
const Viewport = struct { top: u16, bottom: u16 };

fn viewportBounds(source_height: u16, viewport_height: u16, live_start: usize) Viewport {
    std.debug.assert(source_height > 0 and viewport_height > 0);
    std.debug.assert(viewport_height <= source_height);
    const max_start = @as(usize, source_height - viewport_height);
    const top = @min(live_start, max_start);
    return .{
        .top = @intCast(top),
        .bottom = @intCast(top + @as(usize, viewport_height) - 1),
    };
}

fn liveViewportStart(source: *const Screen, viewport_height: u16, previous_start: usize) usize {
    if (viewport_height == 0 or source.height <= viewport_height) return 0;
    const max_start = @as(usize, source.height - viewport_height);
    const cursor_bottom = @min(@as(usize, source.cursor.row) + 1, @as(usize, source.height));
    const follow_start = @min(cursor_bottom -| @as(usize, viewport_height), max_start);
    return @min(@max(previous_start, follow_start), max_start);
}

fn displayedViewportStart(live_start: usize, scroll_offset: usize) usize {
    return live_start -| @min(scroll_offset, live_start);
}

fn absoluteCursorRow(
    viewport: Viewport,
    scrolling_region: Screen.ScrollingRegion,
    origin: bool,
    row: u16,
) u16 {
    const row_offset = row -| 1;
    const top = if (origin)
        @max(viewport.top, @min(scrolling_region.top, viewport.bottom))
    else
        viewport.top;
    const bottom = if (origin)
        @max(top, @min(scrolling_region.bottom, viewport.bottom))
    else
        viewport.bottom;
    return @min(top +| row_offset, bottom);
}

fn absoluteCursorColumn(
    width: u16,
    scrolling_region: Screen.ScrollingRegion,
    origin: bool,
    col: u16,
) u16 {
    std.debug.assert(width > 0);
    const col_offset = col -| 1;
    const left = if (origin) @min(scrolling_region.left, width - 1) else 0;
    const right = if (origin)
        @max(left, @min(scrolling_region.right, width - 1))
    else
        width - 1;
    return @min(left +| col_offset, right);
}

fn absoluteCursorPosition(
    width: u16,
    viewport: Viewport,
    scrolling_region: Screen.ScrollingRegion,
    origin: bool,
    row: u16,
    col: u16,
) CursorPosition {
    return .{
        .row = absoluteCursorRow(viewport, scrolling_region, origin, row),
        .col = absoluteCursorColumn(width, scrolling_region, origin, col),
    };
}

fn scrollingRegionForViewport(
    viewport: Viewport,
    current: Screen.ScrollingRegion,
    top_param: u16,
    bottom_param: u16,
) ?Screen.ScrollingRegion {
    const viewport_height = @as(usize, viewport.bottom) - @as(usize, viewport.top) + 1;
    const top_offset = @as(usize, @max(top_param, 1) - 1);
    const bottom_offset = if (bottom_param == 0)
        viewport_height - 1
    else
        @as(usize, bottom_param - 1);
    if (top_offset >= bottom_offset or bottom_offset >= viewport_height) return null;
    return .{
        .top = @intCast(@as(usize, viewport.top) + top_offset),
        .bottom = @intCast(@as(usize, viewport.top) + bottom_offset),
        .left = current.left,
        .right = current.right,
    };
}

fn scrollingRegionInViewport(
    viewport: Viewport,
    current: Screen.ScrollingRegion,
) ?Screen.ScrollingRegion {
    const top = @max(viewport.top, current.top);
    const bottom = @min(viewport.bottom, current.bottom);
    if (top > bottom) return null;
    return .{
        .top = top,
        .bottom = bottom,
        .left = current.left,
        .right = current.right,
    };
}

fn backingScrollingRegion(
    viewport: Viewport,
    source_height: u16,
    visible_region: Screen.ScrollingRegion,
) Screen.ScrollingRegion {
    std.debug.assert(source_height > 0);
    if (visible_region.top != viewport.top or visible_region.bottom != viewport.bottom)
        return visible_region;
    return .{
        .top = 0,
        .bottom = source_height - 1,
        .left = visible_region.left,
        .right = visible_region.right,
    };
}

fn verticalRelativeCursorRow(
    current_row: u16,
    viewport: Viewport,
    scrolling_region: Screen.ScrollingRegion,
    count: u16,
    down: bool,
) u16 {
    var top = viewport.top;
    var bottom = viewport.bottom;
    if (scrollingRegionInViewport(viewport, scrolling_region)) |region| {
        if (current_row >= region.top and current_row <= region.bottom) {
            top = region.top;
            bottom = region.bottom;
        }
    }
    const delta = @max(count, 1);
    if (down) return @min(current_row +| delta, bottom);
    return @max(current_row -| delta, top);
}

fn cursorVerticalRelative(screen: *Screen, viewport: Viewport, count: u16) void {
    screen.cursor.pending_wrap = false;
    screen.cursor.row = verticalRelativeCursorRow(
        screen.cursor.row,
        viewport,
        screen.scrolling_region,
        count,
        true,
    );
}

fn horizontalPositionRelative(current: u16, maximum: u16, count: u16) u16 {
    return @min(maximum, current +| @max(count, 1));
}

fn horizontalBackTabPosition(
    tab_stops: []const u16,
    current: u16,
    count: usize,
    minimum: u16,
) u16 {
    const insertion_index = for (tab_stops, 0..) |stop, i| {
        if (stop >= current) break i;
    } else tab_stops.len;
    if (insertion_index == 0) return @min(current, minimum);
    const target_index = insertion_index -| @max(count, 1);
    return @min(current, @max(tab_stops[target_index], minimum));
}

fn rememberLastPrinted(
    last_printed: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    grapheme: []const u8,
) !void {
    try last_printed.ensureTotalCapacity(allocator, grapheme.len);
    last_printed.clearRetainingCapacity();
    last_printed.appendSliceAssumeCapacity(grapheme);
}

fn eraseCharacterRange(width: u16, height: u16, row: u16, col: u16, count: u16) IndexRange {
    std.debug.assert(width > 0 and height > 0);
    const bounded_row = @min(row, height - 1);
    const bounded_col = @min(col, width - 1);
    const line_start = @as(usize, bounded_row) * @as(usize, width);
    const start = line_start + @as(usize, bounded_col);
    const line_end = line_start + @as(usize, width);
    const requested = @as(usize, @max(count, 1));
    return .{
        .start = start,
        .end = start + @min(requested, line_end - start),
    };
}

fn eraseDisplayRange(
    width: u16,
    viewport: Viewport,
    row: u16,
    col: u16,
    kind: u16,
) ?IndexRange {
    std.debug.assert(width > 0);
    const bounded_row = @max(viewport.top, @min(row, viewport.bottom));
    const bounded_col = @min(col, width - 1);
    const viewport_start = @as(usize, viewport.top) * @as(usize, width);
    const viewport_end = (@as(usize, viewport.bottom) + 1) * @as(usize, width);
    const cursor = @as(usize, bounded_row) * @as(usize, width) + bounded_col;
    return switch (kind) {
        0 => .{ .start = cursor, .end = viewport_end },
        1 => .{ .start = viewport_start, .end = cursor + 1 },
        2 => .{ .start = viewport_start, .end = viewport_end },
        3 => .{ .start = 0, .end = viewport_start },
        else => null,
    };
}

fn cursorReportPosition(
    width: u16,
    viewport: Viewport,
    scrolling_region: Screen.ScrollingRegion,
    origin: bool,
    row: u16,
    col: u16,
) CursorPosition {
    std.debug.assert(width > 0);
    const base_row = if (origin)
        @max(viewport.top, @min(scrolling_region.top, viewport.bottom))
    else
        viewport.top;
    const base_col = if (origin) @min(scrolling_region.left, width - 1) else 0;
    const bounded_row = @max(viewport.top, @min(row, viewport.bottom));
    const bounded_col = @min(col, width - 1);
    return .{
        .row = (bounded_row -| base_row) +| 1,
        .col = (bounded_col -| base_col) +| 1,
    };
}

pub const InputEvent = union(enum) {
    key_press: vaxis.Key,
};

io: std.Io,
allocator: std.mem.Allocator,
scrollback_size: u16,

pty: Pty,
pty_slave_open: bool = true,
pty_writer: std.Io.File.Writer,
cmd: Command,
thread: ?std.Io.Future(void) = null,
child_state: ?*ChildState = null,
exit_reported: bool = false,
pty_output_drained: std.atomic.Value(bool) = .init(false),

/// the screen we draw from
front_screen: Screen,
front_mutex: std.Io.Mutex = .init,

/// the back screens
back_screen: *Screen = undefined,
back_screen_pri: Screen,
back_screen_alt: Screen,
// only applies to primary screen
scroll_offset: usize = 0,
primary_viewport_start: usize = 0,
back_mutex: std.Io.Mutex = .init,
// dirty is protected by back_mutex. Only access this field when you hold that mutex
dirty: bool = false,

should_quit: std.atomic.Value(bool) = .init(false),

mode: Mode = .{},

tab_stops: std.ArrayList(u16),
title: std.ArrayList(u8) = .empty,
working_directory: std.ArrayList(u8) = .empty,

last_printed: std.ArrayList(u8) = .empty,

event_queue: Queue,
event_text: ?[]u8 = null,

/// initialize a Terminal. This sets the size of the underlying pty and allocates the sizes of the
/// screen
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
    opts: Options,
    write_buf: []u8,
) !Terminal {
    if (argv.len == 0 or argv[0].len == 0) return error.InvalidCommand;
    const back_screen_height = try backScreenHeight(opts.winsize, opts.scrollback_size);
    // Verify we have an absolute path
    if (opts.initial_working_directory) |pwd| {
        if (!std.fs.path.isAbsolute(pwd)) return error.InvalidWorkingDirectory;
    }
    const pty = try Pty.init(io);
    errdefer pty.deinit(io);
    try pty.setSize(opts.winsize);
    const cmd: Command = .{
        .argv = argv,
        .env_map = env,
        .pty = pty,
        .working_directory = opts.initial_working_directory,
    };
    var tabs = try createDefaultTabStops(allocator, opts.winsize.cols);
    errdefer tabs.deinit(allocator);
    var front_screen = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows);
    errdefer front_screen.deinit(allocator);
    var back_screen_pri = try Screen.init(allocator, opts.winsize.cols, back_screen_height);
    errdefer back_screen_pri.deinit(allocator);
    var back_screen_alt = try Screen.init(allocator, opts.winsize.cols, opts.winsize.rows);
    errdefer back_screen_alt.deinit(allocator);
    return .{
        .io = io,
        .allocator = allocator,
        .pty = pty,
        .pty_writer = pty.pty.writerStreaming(io, write_buf),
        .cmd = cmd,
        .scrollback_size = opts.scrollback_size,
        .front_screen = front_screen,
        .back_screen_pri = back_screen_pri,
        .back_screen_alt = back_screen_alt,
        .tab_stops = tabs,
        .event_queue = .init(io),
    };
}

/// release all resources of the Terminal
pub fn deinit(self: *Terminal) void {
    self.should_quit.store(true, .release);
    self.event_queue.close(error.TerminalClosed);

    if (self.thread) |*thread| {
        thread.cancel(self.io);
        self.thread = null;
    }
    if (self.signalChild(posix.SIG.TERM)) {
        self.io.sleep(.fromMilliseconds(100), .awake) catch {};
        self.killLiveChildAfterGrace();
    }
    self.releaseChildState();
    if (self.event_text) |text| self.allocator.free(text);
    while (self.event_queue.tryPop() catch null) |event| {
        self.freeQueuedEvent(event);
    }
    self.pty.pty.close(self.io);
    if (self.pty_slave_open) self.pty.tty.close(self.io);
    self.front_screen.deinit(self.allocator);
    self.back_screen_pri.deinit(self.allocator);
    self.back_screen_alt.deinit(self.allocator);
    self.tab_stops.deinit(self.allocator);
    self.title.deinit(self.allocator);
    self.working_directory.deinit(self.allocator);
    self.last_printed.deinit(self.allocator);
}

/// Start the command and its sole child reaper. The embedding process must not
/// concurrently reap this child (including via waitpid(-1)); doing so violates
/// the process-wide child-wait ownership required by all wait-based APIs.
pub fn spawn(self: *Terminal) !void {
    if (self.thread != null or self.child_state != null) return;
    if (!self.pty_slave_open) return error.TerminalAlreadySpawned;
    if (comptime builtin.single_threaded) return error.ConcurrencyUnavailable;
    try requireCompatibleSigchldPolicy();
    self.back_screen = &self.back_screen_pri;

    var next_working_directory: std.ArrayList(u8) = .empty;
    defer next_working_directory.deinit(self.allocator);
    if (self.cmd.working_directory) |pwd| {
        try next_working_directory.appendSlice(self.allocator, pwd);
    } else {
        const pwd: std.Io.Dir = .cwd();
        const out_path = try pwd.realPathFileAlloc(self.io, ".", self.allocator);
        defer self.allocator.free(out_path);
        try next_working_directory.appendSlice(self.allocator, out_path);
    }

    const process = try self.cmd.spawn(self.io, self.allocator);
    // The child inherited its slave descriptor. The parent must close its copy
    // so the master observes EOF when the whole child group is gone.
    self.pty.tty.close(self.io);
    self.pty_slave_open = false;

    const state = std.heap.page_allocator.create(ChildState) catch |err| {
        terminateUnwatched(process);
        return err;
    };
    state.* = .{
        .pid = process.pid,
        .process_group_id = process.process_group_id,
    };
    const reaper = std.Thread.spawn(.{}, reapChild, .{state}) catch |err| {
        std.heap.page_allocator.destroy(state);
        terminateUnwatched(process);
        return err;
    };
    self.child_state = state;
    self.exit_reported = false;
    self.pty_output_drained.store(false, .release);
    reaper.detach();
    errdefer self.abortSpawn();

    std.mem.swap(std.ArrayList(u8), &self.working_directory, &next_working_directory);
    errdefer std.mem.swap(std.ArrayList(u8), &self.working_directory, &next_working_directory);
    self.thread = try self.io.concurrent(Terminal.run, .{self});
}

fn abortSpawn(self: *Terminal) void {
    self.should_quit.store(true, .release);
    _ = self.signalChild(posix.SIG.KILL);
    if (self.thread) |*thread| {
        thread.cancel(self.io);
        self.thread = null;
    }
    self.releaseChildState();
    while (self.event_queue.tryPop() catch null) |event| self.freeQueuedEvent(event);
    self.exit_reported = false;
    self.should_quit.store(false, .release);
}

fn signalChild(self: *Terminal, signal: posix.SIG) bool {
    const state = self.child_state orelse return false;
    state.acquire();
    defer state.releaseLock();
    return state.signalLocked(signal);
}

fn killLiveChildAfterGrace(self: *Terminal) void {
    const state = self.child_state orelse return;
    state.acquire();
    defer state.releaseLock();
    if (state.reaped) return;

    // If the leader is still running, its live PID pins the process-group ID
    // and KILL is safe. If it is already a zombie, leave cleanup to reapChild,
    // which immediately kills the group and reaps under this same lock.
    var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
    while (true) switch (linux.errno(linux.waitid(
        .PID,
        state.pid,
        &info,
        linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT,
        null,
    ))) {
        .SUCCESS => {
            if (info.fields.common.first.piduid.pid == 0)
                _ = state.signalLocked(posix.SIG.KILL);
            return;
        },
        .INTR => continue,
        .CHILD => {
            // An external reaper or incompatible SIGCHLD policy broke the
            // ownership contract. Retire the numeric identity without using it.
            state.reaped = true;
            state.exited.store(true, .release);
            log.err("terminal child was reaped outside its owner", .{});
            return;
        },
        else => |err| {
            log.err("waitid failed while checking terminal child: {}", .{err});
            return;
        },
    };
}

fn releaseChildState(self: *Terminal) void {
    const state = self.child_state orelse return;
    self.child_state = null;
    state.release();
}

fn reapChild(state: *ChildState) void {
    defer state.release();

    var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
    while (true) switch (linux.errno(linux.waitid(
        .PID,
        state.pid,
        &info,
        linux.W.EXITED | linux.W.NOWAIT,
        null,
    ))) {
        .SUCCESS => break,
        .INTR => continue,
        .CHILD => {
            state.acquire();
            state.reaped = true;
            state.releaseLock();
            state.exited.store(true, .release);
            log.err("terminal child was reaped outside its owner", .{});
            return;
        },
        else => |err| {
            log.err("waitid failed while reaping terminal child: {}", .{err});
            sleepReaperRetry();
        },
    };

    // WNOWAIT leaves the leader as a zombie, pinning its numeric PID/PGID.
    // Kill descendants and reap immediately under one lock; a deliberate
    // post-exit grace window would let a contract-violating external waiter
    // reap the anchor and expose the numeric group ID to reuse.
    state.acquire();
    _ = state.signalLocked(posix.SIG.KILL);
    var status: i32 = undefined;
    while (true) {
        switch (linux.errno(linux.waitpid(state.pid, &status, 0))) {
            .SUCCESS, .CHILD => {
                state.reaped = true;
                break;
            },
            .INTR => continue,
            else => |err| {
                log.err("waitpid failed while reaping terminal child: {}", .{err});
                // WNOWAIT already proved this exact child waitable. If the
                // kernel nevertheless rejects waitpid, retire the numeric
                // identity rather than risk signaling a later reused PGID.
                state.reaped = true;
                break;
            },
        }
    }
    state.releaseLock();
    state.exited.store(true, .release);
}

fn sleepReaperRetry() void {
    var duration: posix.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    while (linux.errno(linux.nanosleep(&duration, &duration)) == .INTR) {}
}

fn requireCompatibleSigchldPolicy() !void {
    var action: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.CHLD, null, &action);
    if (action.handler.handler == posix.SIG.IGN or
        action.flags & linux.SA.NOCLDWAIT != 0)
        return error.IncompatibleSigchldPolicy;
}

fn terminateUnwatched(process: Command.Process) void {
    _ = linux.kill(-process.process_group_id, .KILL);
    _ = linux.kill(process.pid, .KILL);
    var status: i32 = undefined;
    while (true) switch (linux.errno(linux.waitpid(process.pid, &status, 0))) {
        .SUCCESS, .CHILD => return,
        .INTR => continue,
        else => |err| {
            log.err("waitpid failed after terminal spawn error: {}", .{err});
            return;
        },
    };
}

/// resize the screen. Locks access to the back screen. Should only be called from the main thread.
/// This is safe to call every render cycle: there is a guard to only perform a resize if the size
/// of the window has changed.
pub fn resize(self: *Terminal, ws: Winsize) !void {
    const back_screen_height = try backScreenHeight(ws, self.scrollback_size);
    // don't deinit with no size change
    if (ws.cols == self.front_screen.width and
        ws.rows == self.front_screen.height)
        return;

    try self.back_mutex.lock(self.io);
    defer self.back_mutex.unlock(self.io);

    var front_screen = try Screen.init(self.allocator, ws.cols, ws.rows);
    errdefer front_screen.deinit(self.allocator);
    var back_screen_pri = try Screen.init(self.allocator, ws.cols, back_screen_height);
    errdefer back_screen_pri.deinit(self.allocator);
    var back_screen_alt = try Screen.init(self.allocator, ws.cols, ws.rows);
    errdefer back_screen_alt.deinit(self.allocator);
    const old_width = self.front_screen.width;
    const first_new_tab = ((@as(usize, old_width) + 7) / 8) * 8;
    if (ws.cols > old_width) {
        const additional_tabs = (@as(usize, ws.cols) + 7) / 8 - first_new_tab / 8;
        try self.tab_stops.ensureUnusedCapacity(self.allocator, additional_tabs);
    }

    try self.pty.setSize(ws);

    // Preserve application tab choices in retained columns. Reserve before
    // changing the PTY size so all remaining state updates are infallible.
    if (ws.cols > old_width) {
        var col = first_new_tab;
        while (col < ws.cols) : (col += 8)
            self.tab_stops.appendAssumeCapacity(@intCast(col));
    } else if (ws.cols < old_width) {
        while (self.tab_stops.items.len > 0 and
            self.tab_stops.items[self.tab_stops.items.len - 1] >= ws.cols)
            self.tab_stops.items.len -= 1;
    }

    self.front_screen.deinit(self.allocator);
    self.back_screen_pri.deinit(self.allocator);
    self.back_screen_alt.deinit(self.allocator);
    self.front_screen = front_screen;
    self.back_screen_pri = back_screen_pri;
    self.back_screen_alt = back_screen_alt;
    self.primary_viewport_start = 0;
    self.scroll_offset = 0;
}

fn backScreenHeight(ws: Winsize, scrollback_size: u16) !u16 {
    if (ws.rows == 0 or ws.cols == 0 or
        scrollback_size > std.math.maxInt(u16) - ws.rows)
        return error.InvalidWinsize;
    return ws.rows + scrollback_size;
}

fn updatePrimaryViewportStart(self: *Terminal) void {
    if (self.back_screen != &self.back_screen_pri) return;
    self.primary_viewport_start = liveViewportStart(
        self.back_screen,
        self.front_screen.height,
        self.primary_viewport_start,
    );
}

fn currentViewport(self: *Terminal) Viewport {
    self.updatePrimaryViewportStart();
    const live_start = if (self.back_screen == &self.back_screen_pri)
        self.primary_viewport_start
    else
        0;
    return viewportBounds(self.back_screen.height, self.front_screen.height, live_start);
}

fn indexWithinViewport(self: *Terminal) !void {
    const viewport = self.currentViewport();
    if (self.back_screen.cursor.row < self.back_screen.scrolling_region.top or
        self.back_screen.cursor.row > self.back_screen.scrolling_region.bottom)
    {
        self.back_screen.cursor.pending_wrap = false;
        self.back_screen.cursor.row = @min(
            viewport.bottom,
            self.back_screen.cursor.row +| 1,
        );
        return;
    }
    try self.back_screen.index();
}

fn reverseIndexWithinViewport(self: *Terminal) !void {
    const viewport = self.currentViewport();
    const saved_region = self.back_screen.scrolling_region;
    const effective_region = scrollingRegionInViewport(viewport, saved_region) orelse return;
    if (self.back_screen.cursor.row == effective_region.top) {
        self.back_screen.scrolling_region = effective_region;
        defer self.back_screen.scrolling_region = saved_region;
        try self.back_screen.scrollDown(1);
        return;
    }
    self.back_screen.cursor.pending_wrap = false;
    self.back_screen.cursor.row = verticalRelativeCursorRow(
        self.back_screen.cursor.row,
        viewport,
        saved_region,
        1,
        false,
    );
}

fn printGrapheme(self: *Terminal, grapheme: []const u8, width: u8) !void {
    if (self.back_screen.cursor.pending_wrap) {
        try self.indexWithinViewport();
        self.back_screen.cursor.col = self.back_screen.scrolling_region.left;
    }
    try self.back_screen.print(grapheme, width, self.mode.autowrap);
}

pub fn draw(self: *Terminal, allocator: std.mem.Allocator, win: vaxis.Window) !void {
    if (self.back_mutex.tryLock()) {
        defer self.back_mutex.unlock(self.io);
        // We keep this as a separate condition so we don't deadlock by obtaining the lock but not
        // having sync
        if (!self.mode.sync) {
            self.updatePrimaryViewportStart();
            const source_row = if (self.back_screen == &self.back_screen_pri)
                displayedViewportStart(self.primary_viewport_start, self.scroll_offset)
            else
                0;
            try self.back_screen.copyTo(allocator, &self.front_screen, source_row);
            self.dirty = false;
        }
    }

    var row: u16 = 0;
    while (row < self.front_screen.height) : (row += 1) {
        var col: u16 = 0;
        while (col < self.front_screen.width) {
            const cell = self.front_screen.readCell(col, row) orelse {
                col = nextDrawColumn(col, 1);
                continue;
            };
            win.writeCell(col, row, cell);
            col = nextDrawColumn(col, cell.char.width);
        }
    }

    if (self.mode.cursor and self.front_screen.cursor.visible) {
        win.setCursorShape(self.front_screen.cursor.shape);
        win.showCursor(self.front_screen.cursor.col, self.front_screen.cursor.row);
    }
}

pub fn tryEvent(self: *Terminal) !?Event {
    if (self.event_text) |text| {
        self.allocator.free(text);
        self.event_text = null;
    }
    const child_exited = if (self.child_state) |state|
        state.exited.load(.acquire)
    else
        false;
    const event = try pollQueuedEvent(
        &self.event_queue,
        &self.exit_reported,
        child_exited,
        self.pty_output_drained.load(.acquire),
    ) orelse return null;
    return switch (event) {
        .exited => .exited,
        .redraw => .redraw,
        .bell => .bell,
        .title_change => |text| blk: {
            self.event_text = text;
            break :blk .{ .title_change = text };
        },
        .pwd_change => |text| blk: {
            self.event_text = text;
            break :blk .{ .pwd_change = text };
        },
    };
}

fn freeQueuedEvent(self: *Terminal, event: QueuedEvent) void {
    switch (event) {
        .title_change, .pwd_change => |text| self.allocator.free(text),
        else => {},
    }
}

pub fn update(self: *Terminal, event: InputEvent) !void {
    switch (event) {
        .key_press => |k| {
            const pty_writer = self.get_pty_writer();
            defer pty_writer.flush() catch {};
            try key.encode(pty_writer, k, true, self.back_screen.csi_u_flags);
        },
    }
}

pub fn get_pty_writer(self: *Terminal) *std.Io.Writer {
    return &self.pty_writer.interface;
}

fn reader(self: *const Terminal, buf: []u8) std.Io.File.Reader {
    return self.pty.pty.readerStreaming(self.io, buf);
}

/// process the output from the command on the pty
fn run(self: *Terminal) void {
    defer self.pty_output_drained.store(true, .release);
    self._run() catch {};
}

fn _run(self: *Terminal) !void {
    var parser: Parser = .{
        .buf = try .initCapacity(self.allocator, 128),
    };
    defer parser.buf.deinit();

    var reader_buf: [4096]u8 = undefined;
    var reader_ = self.reader(&reader_buf);

    while (!self.should_quit.load(.acquire)) {
        const event = try parser.parseReader(&reader_.interface);
        try self.back_mutex.lock(self.io);
        defer self.back_mutex.unlock(self.io);

        if (!self.dirty and try self.event_queue.tryPush(.redraw))
            self.dirty = true;

        switch (event) {
            .print => |str| {
                var iter = vaxis.unicode.graphemeIterator(str);
                while (iter.next()) |grapheme| {
                    const gr = grapheme.bytes(str);
                    // TODO: use actual instead of .unicode
                    const w = vaxis.gwidth.gwidth(gr, .unicode);
                    try rememberLastPrinted(&self.last_printed, self.allocator, gr);
                    try self.printGrapheme(self.last_printed.items, @truncate(w));
                }
            },
            .c0 => |b| try self.handleC0(b),
            .escape => |esc| {
                const final = esc[esc.len - 1];
                switch (final) {
                    'B' => {}, // TODO: handle charsets
                    // Index
                    'D' => try self.indexWithinViewport(),
                    // Next Line
                    'E' => {
                        try self.indexWithinViewport();
                        self.carriageReturn();
                    },
                    // Horizontal Tab Set
                    'H' => {
                        const already_set: bool = for (self.tab_stops.items) |ts| {
                            if (ts == self.back_screen.cursor.col) break true;
                        } else false;
                        if (already_set) continue;
                        try self.tab_stops.append(self.allocator, @truncate(self.back_screen.cursor.col));
                        std.mem.sort(u16, self.tab_stops.items, {}, std.sort.asc(u16));
                    },
                    // Reverse Index
                    'M' => try self.reverseIndexWithinViewport(),
                    else => log.info("unhandled escape: {s}", .{esc}),
                }
            },
            .ss2 => |ss2| log.info("unhandled ss2: {c}", .{ss2}),
            .ss3 => |ss3| log.info("unhandled ss3: {c}", .{ss3}),
            .csi => |seq| {
                // A failed conversion must not be confused with an omitted
                // parameter, whose command-specific default often mutates state.
                if (!seq.parametersValid(u16)) continue;
                switch (seq.final) {
                    // Cursor up
                    'A', 'k' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        const viewport = self.currentViewport();
                        self.back_screen.cursor.pending_wrap = false;
                        self.back_screen.cursor.row = verticalRelativeCursorRow(
                            self.back_screen.cursor.row,
                            viewport,
                            self.back_screen.scrolling_region,
                            delta,
                            false,
                        );
                    },
                    // Cursor Down
                    'B' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        const viewport = self.currentViewport();
                        cursorVerticalRelative(self.back_screen, viewport, delta);
                    },
                    // Cursor Right
                    'C' => {
                        var iter = seq.iterator(u16);
                        const delta = @max(iter.next() orelse 1, 1);
                        self.back_screen.cursorRight(delta);
                    },
                    // Cursor Left
                    'D', 'j' => {
                        var iter = seq.iterator(u16);
                        const delta = @max(iter.next() orelse 1, 1);
                        self.back_screen.cursorLeft(delta);
                    },
                    // Cursor Next Line
                    'E' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        const viewport = self.currentViewport();
                        cursorVerticalRelative(self.back_screen, viewport, delta);
                        self.carriageReturn();
                    },
                    // Cursor Previous Line
                    'F' => {
                        var iter = seq.iterator(u16);
                        const delta = iter.next() orelse 1;
                        const viewport = self.currentViewport();
                        self.back_screen.cursor.pending_wrap = false;
                        self.back_screen.cursor.row = verticalRelativeCursorRow(
                            self.back_screen.cursor.row,
                            viewport,
                            self.back_screen.scrolling_region,
                            delta,
                            false,
                        );
                        self.carriageReturn();
                    },
                    // Horizontal Position Absolute
                    'G', '`' => {
                        var iter = seq.iterator(u16);
                        const col = iter.next() orelse 1;
                        self.back_screen.cursor.col = absoluteCursorColumn(
                            self.back_screen.width,
                            self.back_screen.scrolling_region,
                            self.mode.origin,
                            col,
                        );
                        self.back_screen.cursor.pending_wrap = false;
                    },
                    // Cursor Absolute Position
                    'H', 'f' => {
                        var iter = seq.iterator(u16);
                        const row = iter.next() orelse 1;
                        const col = iter.next() orelse 1;
                        const viewport = self.currentViewport();
                        const position = absoluteCursorPosition(
                            self.back_screen.width,
                            viewport,
                            self.back_screen.scrolling_region,
                            self.mode.origin,
                            row,
                            col,
                        );
                        self.back_screen.cursor.row = position.row;
                        self.back_screen.cursor.col = position.col;
                        self.back_screen.cursor.pending_wrap = false;
                    },
                    // Cursor Horizontal Tab
                    'I' => {
                        var iter = seq.iterator(u16);
                        const n = @max(iter.next() orelse 1, 1);
                        self.horizontalTab(n);
                    },
                    // Erase In Display
                    'J' => {
                        // TODO: selective erase (private_marker == '?')
                        var iter = seq.iterator(u16);
                        const kind = iter.next() orelse 0;
                        const viewport = self.currentViewport();
                        if (eraseDisplayRange(
                            self.back_screen.width,
                            viewport,
                            self.back_screen.cursor.row,
                            self.back_screen.cursor.col,
                            kind,
                        )) |range| {
                            self.back_screen.cursor.pending_wrap = false;
                            for (range.start..range.end) |i| {
                                self.back_screen.buf[i].erase(
                                    self.allocator,
                                    self.back_screen.cursor.style.bg,
                                );
                            }
                        }
                    },
                    // Erase in Line
                    'K' => {
                        // TODO: selective erase (private_marker == '?')
                        var iter = seq.iterator(u16);
                        const ps = iter.next() orelse 0;
                        switch (ps) {
                            0 => self.back_screen.eraseRight(),
                            1 => self.back_screen.eraseLeft(),
                            2 => self.back_screen.eraseLine(),
                            else => continue,
                        }
                    },
                    // Insert Lines
                    'L' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const saved_region = self.back_screen.scrolling_region;
                        const viewport = self.currentViewport();
                        self.back_screen.scrolling_region = scrollingRegionInViewport(
                            viewport,
                            saved_region,
                        ) orelse continue;
                        defer self.back_screen.scrolling_region = saved_region;
                        try self.back_screen.insertLine(n);
                    },
                    // Delete Lines
                    'M' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const saved_region = self.back_screen.scrolling_region;
                        const viewport = self.currentViewport();
                        self.back_screen.scrolling_region = scrollingRegionInViewport(
                            viewport,
                            saved_region,
                        ) orelse continue;
                        defer self.back_screen.scrolling_region = saved_region;
                        try self.back_screen.deleteLine(n);
                    },
                    // Delete Character
                    'P' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        try self.back_screen.deleteCharacters(n);
                    },
                    // Scroll Up
                    'S' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const saved_region = self.back_screen.scrolling_region;
                        const viewport = self.currentViewport();
                        self.back_screen.scrolling_region = scrollingRegionInViewport(
                            viewport,
                            saved_region,
                        ) orelse continue;
                        defer self.back_screen.scrolling_region = saved_region;
                        const cur_row = self.back_screen.cursor.row;
                        const cur_col = self.back_screen.cursor.col;
                        const wrap = self.back_screen.cursor.pending_wrap;
                        defer {
                            self.back_screen.cursor.row = cur_row;
                            self.back_screen.cursor.col = cur_col;
                            self.back_screen.cursor.pending_wrap = wrap;
                        }
                        self.back_screen.cursor.col = self.back_screen.scrolling_region.left;
                        self.back_screen.cursor.row = self.back_screen.scrolling_region.top;
                        try self.back_screen.deleteLine(n);
                    },
                    // Scroll Down
                    'T' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const saved_region = self.back_screen.scrolling_region;
                        const viewport = self.currentViewport();
                        self.back_screen.scrolling_region = scrollingRegionInViewport(
                            viewport,
                            saved_region,
                        ) orelse continue;
                        defer self.back_screen.scrolling_region = saved_region;
                        try self.back_screen.scrollDown(n);
                    },
                    // Tab Control
                    'W' => {
                        if (seq.private_marker) |pm| {
                            if (pm != '?') continue;
                            var iter = seq.iterator(u16);
                            const n = iter.next() orelse continue;
                            if (n != 5) continue;
                            var tab_stops = try createDefaultTabStops(
                                self.allocator,
                                self.back_screen.width,
                            );
                            std.mem.swap(std.ArrayList(u16), &self.tab_stops, &tab_stops);
                            tab_stops.deinit(self.allocator);
                        }
                    },
                    'X' => {
                        self.back_screen.cursor.pending_wrap = false;
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const range = eraseCharacterRange(
                            self.back_screen.width,
                            self.back_screen.height,
                            self.back_screen.cursor.row,
                            self.back_screen.cursor.col,
                            n,
                        );
                        for (range.start..range.end) |i| {
                            self.back_screen.buf[i].erase(self.allocator, self.back_screen.cursor.style.bg);
                        }
                    },
                    'Z' => {
                        var iter = seq.iterator(u16);
                        const n = @max(iter.next() orelse 1, 1);
                        self.horizontalBackTab(n);
                    },
                    // Cursor Horizontal Position Relative
                    'a' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        self.back_screen.cursor.pending_wrap = false;
                        const max_end = if (self.mode.origin)
                            self.back_screen.scrolling_region.right
                        else
                            self.back_screen.width - 1;
                        self.back_screen.cursor.col = horizontalPositionRelative(
                            self.back_screen.cursor.col,
                            max_end,
                            n,
                        );
                    },
                    // Repeat Previous Character
                    'b' => {
                        var iter = seq.iterator(u16);
                        const n = @max(iter.next() orelse 1, 1);
                        if (self.last_printed.items.len != 0) {
                            // TODO: maybe not .unicode
                            const w = vaxis.gwidth.gwidth(self.last_printed.items, .unicode);
                            var i: usize = 0;
                            while (i < n) : (i += 1) {
                                try self.printGrapheme(self.last_printed.items, @truncate(w));
                            }
                        }
                    },
                    // Device Attributes
                    'c' => {
                        const pty_writer = self.get_pty_writer();
                        defer pty_writer.flush() catch {};
                        if (seq.private_marker) |pm| {
                            switch (pm) {
                                // Secondary
                                '>' => try pty_writer.writeAll("\x1B[>1;69;0c"),
                                '=' => try pty_writer.writeAll("\x1B[=0000c"),
                                else => log.info("unhandled CSI: {f}", .{seq}),
                            }
                        } else {
                            // Primary
                            try pty_writer.writeAll("\x1B[?62;22c");
                        }
                    },
                    // Cursor Vertical Position Absolute
                    'd' => {
                        self.back_screen.cursor.pending_wrap = false;
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const viewport = self.currentViewport();
                        self.back_screen.cursor.row = absoluteCursorRow(
                            viewport,
                            self.back_screen.scrolling_region,
                            self.mode.origin,
                            n,
                        );
                    },
                    // Cursor Vertical Position Relative
                    'e' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 1;
                        const viewport = self.currentViewport();
                        cursorVerticalRelative(self.back_screen, viewport, n);
                    },
                    // Tab Clear
                    'g' => {
                        var iter = seq.iterator(u16);
                        const n = iter.next() orelse 0;
                        switch (n) {
                            0 => {
                                const current = try self.tab_stops.toOwnedSlice(self.allocator);
                                defer self.allocator.free(current);
                                self.tab_stops.clearRetainingCapacity();
                                for (current) |stop| {
                                    if (stop == self.back_screen.cursor.col) continue;
                                    try self.tab_stops.append(self.allocator, stop);
                                }
                            },
                            3 => self.tab_stops.clearAndFree(self.allocator),
                            else => log.info("unhandled CSI: {f}", .{seq}),
                        }
                    },
                    'h', 'l' => {
                        var iter = seq.iterator(u16);
                        const mode = iter.next() orelse continue;
                        // There is only one collision (mode = 4), and we don't support the private
                        // version of it
                        if (seq.private_marker != null and mode == 4) continue;
                        if (mode == 6 and (seq.private_marker orelse 0) != '?') continue;
                        const was_synchronized = self.mode.sync;
                        self.setMode(mode, seq.final == 'h');
                        try queueSyncReleaseRedraw(
                            &self.event_queue,
                            &self.dirty,
                            was_synchronized,
                            self.mode.sync,
                        );
                    },
                    'm' => {
                        if (seq.intermediate == null and seq.private_marker == null) {
                            self.back_screen.sgr(seq);
                        }
                        // TODO: private marker and intermediates
                    },
                    'n' => {
                        var iter = seq.iterator(u16);
                        const ps = iter.next() orelse 0;
                        if (seq.intermediate == null and seq.private_marker == null) {
                            const pty_writer = self.get_pty_writer();
                            defer pty_writer.flush() catch {};
                            switch (ps) {
                                5 => try pty_writer.writeAll("\x1b[0n"),
                                6 => {
                                    const viewport = self.currentViewport();
                                    const position = cursorReportPosition(
                                        self.back_screen.width,
                                        viewport,
                                        self.back_screen.scrolling_region,
                                        self.mode.origin,
                                        self.back_screen.cursor.row,
                                        self.back_screen.cursor.col,
                                    );
                                    try pty_writer.print("\x1b[{d};{d}R", .{
                                        position.row,
                                        position.col,
                                    });
                                },
                                else => log.info("unhandled CSI: {f}", .{seq}),
                            }
                        }
                    },
                    'p' => {
                        var iter = seq.iterator(u16);
                        const ps = iter.next() orelse 0;
                        if (seq.intermediate) |int| {
                            switch (int) {
                                // report mode
                                '$' => {
                                    const pty_writer = self.get_pty_writer();
                                    defer pty_writer.flush() catch {};
                                    switch (ps) {
                                        2026 => try pty_writer.writeAll("\x1b[?2026;2$p"),
                                        else => {
                                            std.log.warn("unhandled mode: {}", .{ps});
                                            try pty_writer.print("\x1b[?{d};0$p", .{ps});
                                        },
                                    }
                                },
                                else => log.info("unhandled CSI: {f}", .{seq}),
                            }
                        }
                    },
                    'q' => {
                        if (seq.intermediate) |int| {
                            switch (int) {
                                ' ' => {
                                    if (cursorShapeForSequence(seq)) |shape|
                                        self.back_screen.cursor.shape = shape;
                                },
                                else => {},
                            }
                        }
                        if (seq.private_marker) |pm| {
                            const pty_writer = self.get_pty_writer();
                            defer pty_writer.flush() catch {};
                            switch (pm) {
                                // XTVERSION
                                '>' => try pty_writer.print(
                                    "\x1bP>|libvaxis {s}\x1B\\",
                                    .{"dev"},
                                ),
                                else => log.info("unhandled CSI: {f}", .{seq}),
                            }
                        }
                    },
                    'r' => {
                        if (seq.intermediate) |_| {
                            // TODO: XTRESTORE
                            continue;
                        }
                        if (seq.private_marker) |_| {
                            // TODO: DECCARA
                            continue;
                        }
                        // DECSTBM
                        var iter = seq.iterator(u16);
                        const top_param = iter.next() orelse 1;
                        const bottom_param = iter.next() orelse self.front_screen.height;
                        const viewport = self.currentViewport();
                        const region = scrollingRegionForViewport(
                            viewport,
                            self.back_screen.scrolling_region,
                            top_param,
                            bottom_param,
                        ) orelse continue;
                        self.back_screen.scrolling_region = backingScrollingRegion(
                            viewport,
                            self.back_screen.height,
                            region,
                        );
                        self.back_screen.cursor.pending_wrap = false;
                        if (self.mode.origin) {
                            self.back_screen.cursor.col = region.left;
                            self.back_screen.cursor.row = region.top;
                        } else {
                            self.back_screen.cursor.col = 0;
                            self.back_screen.cursor.row = viewport.top;
                        }
                    },
                    else => log.info("unhandled CSI: {f}", .{seq}),
                }
            },
            .osc => |osc| {
                const semicolon = std.mem.indexOfScalar(u8, osc, ';') orelse {
                    log.info("unhandled osc: {s}", .{osc});
                    continue;
                };
                const ps = std.fmt.parseUnsigned(u8, osc[0..semicolon], 10) catch {
                    log.info("unhandled osc: {s}", .{osc});
                    continue;
                };
                switch (ps) {
                    0 => {
                        self.title.clearRetainingCapacity();
                        try self.title.appendSlice(self.allocator, osc[semicolon + 1 ..]);
                        const text = try self.allocator.dupe(u8, self.title.items);
                        errdefer self.allocator.free(text);
                        try self.event_queue.push(.{ .title_change = text });
                    },
                    7 => {
                        var decoded = (try decodeWorkingDirectoryUri(self.allocator, osc[semicolon + 1 ..])) orelse {
                            log.info("unknown OSC 7 format", .{});
                            continue;
                        };
                        errdefer decoded.deinit(self.allocator);
                        const text = try self.allocator.dupe(u8, decoded.items);
                        errdefer self.allocator.free(text);
                        try self.event_queue.push(.{ .pwd_change = text });
                        self.working_directory.deinit(self.allocator);
                        self.working_directory = decoded;
                    },
                    else => log.info("unhandled osc: {s}", .{osc}),
                }
            },
            .apc => |apc| log.info("unhandled apc: {s}", .{apc}),
        }
        self.updatePrimaryViewportStart();
    }
}

fn decodeWorkingDirectoryUri(
    allocator: std.mem.Allocator,
    uri: []const u8,
) std.mem.Allocator.Error!?std.ArrayList(u8) {
    const scheme = "file://";
    if (!std.mem.startsWith(u8, uri, scheme)) return null;

    const authority_and_path = uri[scheme.len..];
    const path_start = std.mem.indexOfScalar(u8, authority_and_path, '/') orelse return null;
    const encoded = authority_and_path[path_start..];

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] != '%') {
            i += 1;
            continue;
        }
        if (i + 2 >= encoded.len) return null;
        if (!std.ascii.isHex(encoded[i + 1]) or !std.ascii.isHex(encoded[i + 2])) return null;
        if (std.fmt.parseUnsigned(u8, encoded[i + 1 .. i + 3], 16) catch unreachable == 0) return null;
        i += 3;
    }

    var decoded: std.ArrayList(u8) = try .initCapacity(allocator, encoded.len);
    errdefer decoded.deinit(allocator);
    i = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%') {
            const byte = std.fmt.parseUnsigned(u8, encoded[i + 1 .. i + 3], 16) catch unreachable;
            try decoded.append(allocator, byte);
            i += 3;
        } else {
            try decoded.append(allocator, encoded[i]);
            i += 1;
        }
    }
    return decoded;
}

fn cursorShapeForSequence(seq: ansi.CSI) ?vaxis.Cell.CursorShape {
    if (!seq.parametersValid(u8)) return null;
    var iter = seq.iterator(u8);
    const shape = iter.next() orelse if (seq.params.len == 0) @as(u8, 0) else return null;
    return std.enums.fromInt(vaxis.Cell.CursorShape, shape);
}

test "cursor style ignores invalid and overflowing CSI parameters" {
    var parser: Parser = .{ .buf = .init(std.testing.allocator) };
    defer parser.buf.deinit();
    const cases = .{
        .{ "\x1b[ q", .default },
        .{ "\x1b[0 q", .default },
        .{ "\x1b[1 q", .block_blink },
        .{ "\x1b[6 q", .beam },
        .{ "\x1b[7 q", null },
        .{ "\x1b[8 q", null },
        .{ "\x1b[255 q", null },
        .{ "\x1b[256 q", null },
        .{ "\x1b[1;256 q", null },
        .{ "\x1b[999999999999999999999999 q", null },
    };
    inline for (cases) |case| {
        var input: std.Io.Reader = .fixed(case[0]);
        const event = try parser.parseReader(&input);
        try std.testing.expect(event == .csi);
        try std.testing.expectEqual(@as(?vaxis.Cell.CursorShape, case[1]), cursorShapeForSequence(event.csi));
    }
}

inline fn handleC0(self: *Terminal, b: ansi.C0) !void {
    switch (b) {
        .NUL, .SOH, .STX => {},
        .EOT => {},
        .ENQ => {},
        .BEL => try self.event_queue.push(.bell),
        .BS => self.back_screen.cursorLeft(1),
        .HT => self.horizontalTab(1),
        .LF, .VT, .FF => try self.indexWithinViewport(),
        .CR => self.carriageReturn(),
        .SO => {}, // TODO: Charset shift out
        .SI => {}, // TODO: Charset shift in
        else => log.warn("unhandled C0: 0x{x}", .{@backingInt(b)}),
    }
}

fn testInitAllocationFailures(allocator: std.mem.Allocator) !void {
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    var write_buf: [4096]u8 = undefined;
    var terminal = try Terminal.init(
        std.testing.io,
        allocator,
        &.{"/bin/true"},
        &env,
        .{ .winsize = .{ .rows = 2, .cols = 8, .x_pixel = 0, .y_pixel = 0 } },
        &write_buf,
    );
    defer terminal.deinit();
}

test "init cleans up allocation failures" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testInitAllocationFailures,
        .{},
    );
}

test "terminal dimensions reject empty and overflowing screens" {
    try std.testing.expectError(
        error.InvalidWinsize,
        backScreenHeight(.{ .rows = 0, .cols = 80, .x_pixel = 0, .y_pixel = 0 }, 500),
    );
    try std.testing.expectError(
        error.InvalidWinsize,
        backScreenHeight(.{ .rows = 24, .cols = 0, .x_pixel = 0, .y_pixel = 0 }, 500),
    );
    try std.testing.expectError(
        error.InvalidWinsize,
        backScreenHeight(.{ .rows = std.math.maxInt(u16), .cols = 80, .x_pixel = 0, .y_pixel = 0 }, 1),
    );
    try std.testing.expectEqual(
        @as(u16, 524),
        try backScreenHeight(.{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 }, 500),
    );
}

test "default tab stops cover the maximum terminal width safely" {
    var tab_stops = try createDefaultTabStops(std.testing.allocator, std.math.maxInt(u16));
    defer tab_stops.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 8192), tab_stops.items.len);
    try std.testing.expectEqual(@as(u16, 0), tab_stops.items[0]);
    try std.testing.expectEqual(@as(u16, 65528), tab_stops.items[tab_stops.items.len - 1]);
}

test "resize preserves programmed tabs and initializes only new columns" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    var write_buf: [4096]u8 = undefined;
    var terminal = try Terminal.init(
        std.testing.io,
        allocator,
        &.{"/bin/true"},
        &env,
        .{ .winsize = .{ .rows = 2, .cols = 7, .x_pixel = 0, .y_pixel = 0 } },
        &write_buf,
    );
    defer terminal.deinit();
    terminal.tab_stops.clearRetainingCapacity();
    try terminal.tab_stops.append(allocator, 6);

    try terminal.resize(.{ .rows = 3, .cols = 7, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqualSlices(u16, &.{6}, terminal.tab_stops.items);

    try terminal.resize(.{ .rows = 3, .cols = 17, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqualSlices(u16, &.{ 6, 8, 16 }, terminal.tab_stops.items);

    try terminal.resize(.{ .rows = 3, .cols = 7, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqualSlices(u16, &.{6}, terminal.tab_stops.items);

    terminal.tab_stops.clearAndFree(allocator);
    try terminal.resize(.{ .rows = 4, .cols = 7, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqual(@as(usize, 0), terminal.tab_stops.items.len);

    try terminal.resize(.{ .rows = 4, .cols = 6, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqual(@as(usize, 0), terminal.tab_stops.items.len);
    try terminal.resize(.{ .rows = 4, .cols = 8, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqual(@as(usize, 0), terminal.tab_stops.items.len);
    try terminal.resize(.{ .rows = 4, .cols = 9, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqualSlices(u16, &.{8}, terminal.tab_stops.items);

    try std.testing.expectError(error.InvalidWinsize, terminal.resize(.{
        .rows = 0,
        .cols = 17,
        .x_pixel = 0,
        .y_pixel = 0,
    }));
    try std.testing.expectEqualSlices(u16, &.{8}, terminal.tab_stops.items);
}

test "draw traversal saturates after a double-width final cell" {
    try std.testing.expectEqual(@as(u16, 1), nextDrawColumn(0, 0));
    try std.testing.expectEqual(@as(u16, 12), nextDrawColumn(10, 2));
    try std.testing.expectEqual(
        std.math.maxInt(u16),
        nextDrawColumn(std.math.maxInt(u16) - 1, 2),
    );
}

test "leaving synchronized output queues a redraw even when already dirty" {
    var queue: Queue = .init(std.testing.io);
    var dirty = true;

    try queueSyncReleaseRedraw(&queue, &dirty, true, false);
    const event = (try queue.tryPop()).?;
    try std.testing.expect(event == .redraw);
    try std.testing.expect(dirty);

    try queueSyncReleaseRedraw(&queue, &dirty, false, false);
    try std.testing.expect((try queue.tryPop()) == null);
}

test "child exit follows queued events and drained PTY output" {
    var queue: Queue = .init(std.testing.io);
    var exit_reported = false;
    try queue.push(.bell);

    const queued = (try pollQueuedEvent(&queue, &exit_reported, true, true)).?;
    try std.testing.expect(queued == .bell);
    try std.testing.expect(!exit_reported);

    const exited = (try pollQueuedEvent(&queue, &exit_reported, true, true)).?;
    try std.testing.expect(exited == .exited);
    try std.testing.expect(exit_reported);

    exit_reported = false;
    try std.testing.expect(
        (try pollQueuedEvent(&queue, &exit_reported, true, false)) == null,
    );
    try std.testing.expect(!exit_reported);
}

test "back tab is bounded for sparse and empty tab-stop lists" {
    const stops = [_]u16{ 0, 8, 16 };
    try std.testing.expectEqual(@as(u16, 0), horizontalBackTabPosition(&stops, 5, 1, 0));
    try std.testing.expectEqual(@as(u16, 0), horizontalBackTabPosition(&stops, 8, 1, 0));
    try std.testing.expectEqual(@as(u16, 16), horizontalBackTabPosition(&stops, 17, 1, 0));
    try std.testing.expectEqual(@as(u16, 8), horizontalBackTabPosition(&stops, 17, 2, 0));
    try std.testing.expectEqual(@as(u16, 0), horizontalBackTabPosition(&stops, 17, 99, 0));
    try std.testing.expectEqual(@as(u16, 0), horizontalBackTabPosition(&.{}, 5, 1, 0));
    try std.testing.expectEqual(@as(u16, 3), horizontalBackTabPosition(&.{}, 5, 1, 3));
}

test "last printed grapheme owns parser text" {
    const allocator = std.testing.allocator;
    var remembered: std.ArrayList(u8) = .empty;
    defer remembered.deinit(allocator);
    var parser_text = [_]u8{ 'a', 'b', 'c' };
    try rememberLastPrinted(&remembered, allocator, &parser_text);
    parser_text[0] = 'x';
    try std.testing.expectEqualStrings("abc", remembered.items);
    try rememberLastPrinted(&remembered, allocator, "z");
    try std.testing.expectEqualStrings("z", remembered.items);
}

test "full visible scrolling region retains primary scrollback sentinel" {
    const viewport: Viewport = .{ .top = 3, .bottom = 4 };
    const full: Screen.ScrollingRegion = .{ .top = 3, .bottom = 4, .left = 0, .right = 4 };
    try std.testing.expectEqualDeep(
        Screen.ScrollingRegion{ .top = 0, .bottom = 4, .left = 0, .right = 4 },
        backingScrollingRegion(viewport, 5, full),
    );
    const partial: Screen.ScrollingRegion = .{ .top = 3, .bottom = 3, .left = 0, .right = 4 };
    try std.testing.expectEqualDeep(partial, backingScrollingRegion(viewport, 5, partial));
}

test "erase character range is count-limited and screen-bounded" {
    try std.testing.expectEqualDeep(
        IndexRange{ .start = 7, .end = 9 },
        eraseCharacterRange(5, 3, 1, 2, 2),
    );
    try std.testing.expectEqualDeep(
        IndexRange{ .start = 7, .end = 8 },
        eraseCharacterRange(5, 3, 1, 2, 0),
    );
    try std.testing.expectEqualDeep(
        IndexRange{ .start = 7, .end = 10 },
        eraseCharacterRange(5, 3, 1, 2, std.math.maxInt(u16)),
    );
    try std.testing.expectEqualDeep(
        IndexRange{ .start = 14, .end = 15 },
        eraseCharacterRange(5, 3, std.math.maxInt(u16), std.math.maxInt(u16), 4),
    );
}

test "absolute and relative cursor positioning stays screen-bounded" {
    const region: Screen.ScrollingRegion = .{ .top = 1, .bottom = 2, .left = 1, .right = 3 };
    const viewport: Viewport = .{ .top = 0, .bottom = 2 };
    try std.testing.expectEqualDeep(
        CursorPosition{ .row = 0, .col = 0 },
        absoluteCursorPosition(5, viewport, region, false, 0, 0),
    );
    try std.testing.expectEqualDeep(
        CursorPosition{ .row = 2, .col = 4 },
        absoluteCursorPosition(5, viewport, region, false, std.math.maxInt(u16), std.math.maxInt(u16)),
    );
    try std.testing.expectEqualDeep(
        CursorPosition{ .row = 1, .col = 1 },
        absoluteCursorPosition(5, viewport, region, true, 1, 1),
    );
    try std.testing.expectEqualDeep(
        CursorPosition{ .row = 2, .col = 3 },
        absoluteCursorPosition(5, viewport, region, true, std.math.maxInt(u16), std.math.maxInt(u16)),
    );
    try std.testing.expectEqual(@as(u16, 0), absoluteCursorColumn(5, region, false, 1));
    try std.testing.expectEqual(@as(u16, 1), absoluteCursorColumn(5, region, true, 1));

    var cells: [0]Screen.Cell = .{};
    var screen: Screen = .{
        .allocator = undefined,
        .width = 5,
        .height = 3,
        .scrolling_region = .{ .top = 0, .bottom = 2, .left = 0, .right = 4 },
        .buf = &cells,
    };
    cursorVerticalRelative(&screen, viewport, 0);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor.row);
    cursorVerticalRelative(&screen, viewport, std.math.maxInt(u16));
    try std.testing.expectEqual(@as(u16, 2), screen.cursor.row);

    try std.testing.expectEqual(@as(u16, 3), horizontalPositionRelative(2, 4, 0));
    try std.testing.expectEqual(@as(u16, 4), horizontalPositionRelative(2, 4, std.math.maxInt(u16)));
}

test "primary scrollback and alternate screen use distinct viewport coordinates" {
    const allocator = std.testing.allocator;
    var primary = try Screen.init(allocator, 5, 5);
    defer primary.deinit(allocator);
    var alternate = try Screen.init(allocator, 5, 2);
    defer alternate.deinit(allocator);

    primary.cursor.row = 4;
    var live_start = liveViewportStart(&primary, 2, 0);
    try std.testing.expectEqual(@as(usize, 3), live_start);
    const primary_viewport = viewportBounds(primary.height, 2, live_start);
    try std.testing.expectEqualDeep(Viewport{ .top = 3, .bottom = 4 }, primary_viewport);
    try std.testing.expectEqualDeep(
        CursorPosition{ .row = 3, .col = 0 },
        absoluteCursorPosition(
            primary.width,
            primary_viewport,
            primary.scrolling_region,
            false,
            1,
            1,
        ),
    );

    const primary_region = scrollingRegionForViewport(
        primary_viewport,
        primary.scrolling_region,
        1,
        2,
    ).?;
    try std.testing.expectEqual(@as(u16, 3), primary_region.top);
    try std.testing.expectEqual(@as(u16, 4), primary_region.bottom);
    try std.testing.expectEqual(
        @as(u16, 3),
        absoluteCursorRow(primary_viewport, primary_region, true, 1),
    );
    try std.testing.expectEqualDeep(
        CursorPosition{ .row = 1, .col = 1 },
        cursorReportPosition(primary.width, primary_viewport, primary_region, true, 3, 0),
    );
    try std.testing.expectEqualDeep(
        IndexRange{ .start = 17, .end = 25 },
        eraseDisplayRange(primary.width, primary_viewport, 3, 2, 0).?,
    );
    try std.testing.expectEqualDeep(
        IndexRange{ .start = 15, .end = 18 },
        eraseDisplayRange(primary.width, primary_viewport, 3, 2, 1).?,
    );
    try std.testing.expectEqualDeep(
        IndexRange{ .start = 15, .end = 25 },
        eraseDisplayRange(primary.width, primary_viewport, 3, 2, 2).?,
    );
    try std.testing.expectEqualDeep(
        IndexRange{ .start = 0, .end = 15 },
        eraseDisplayRange(primary.width, primary_viewport, 3, 2, 3).?,
    );

    primary.cursor.row = 3;
    live_start = liveViewportStart(&primary, 2, live_start);
    try std.testing.expectEqual(@as(usize, 3), live_start);
    try std.testing.expectEqual(@as(usize, 2), displayedViewportStart(live_start, 1));
    try std.testing.expectEqual(
        @as(usize, 0),
        displayedViewportStart(live_start, std.math.maxInt(usize)),
    );

    alternate.cursor.row = 1;
    const alternate_start = liveViewportStart(&alternate, 2, 0);
    try std.testing.expectEqual(@as(usize, 0), alternate_start);
    const alternate_viewport = viewportBounds(alternate.height, 2, alternate_start);
    try std.testing.expectEqualDeep(Viewport{ .top = 0, .bottom = 1 }, alternate_viewport);
    try std.testing.expectEqualDeep(
        IndexRange{ .start = 0, .end = 0 },
        eraseDisplayRange(alternate.width, alternate_viewport, 1, 1, 3).?,
    );
    try std.testing.expectEqualDeep(
        CursorPosition{ .row = 1, .col = 4 },
        absoluteCursorPosition(
            alternate.width,
            alternate_viewport,
            alternate.scrolling_region,
            false,
            std.math.maxInt(u16),
            std.math.maxInt(u16),
        ),
    );
}

test "spawn publishes a ready process group and teardown stays bounded" {
    if (comptime builtin.os.tag != .linux or builtin.single_threaded) return error.SkipZigTest;

    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    for (0..4) |_| {
        var write_buf: [4096]u8 = undefined;
        var terminal = try Terminal.init(
            std.testing.io,
            std.testing.allocator,
            &.{ "/bin/sh", "-c", "trap '' TERM; sleep 30" },
            &env,
            .{ .winsize = .{ .rows = 2, .cols = 8, .x_pixel = 0, .y_pixel = 0 } },
            &write_buf,
        );
        terminal.spawn() catch |err| {
            terminal.deinit();
            return err;
        };
        const started: std.Io.Timestamp = .now(std.testing.io, .awake);
        terminal.deinit();
        const elapsed = started.durationTo(.now(std.testing.io, .awake));
        try std.testing.expect(elapsed.nanoseconds < 5 * std.time.ns_per_s);
    }
}

test "natural leader exit reaps after terminating background descendants" {
    if (comptime builtin.os.tag != .linux or builtin.single_threaded) return error.SkipZigTest;

    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const descendant_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/descendant.pid",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(descendant_path);
    var write_buf: [4096]u8 = undefined;
    var terminal = try Terminal.init(
        std.testing.io,
        std.testing.allocator,
        &.{
            "/bin/sh",
            "-c",
            "(trap '' TERM; sleep 30) & echo $! > \"$1\"; exit 0",
            "sh",
            descendant_path,
        },
        &env,
        .{ .winsize = .{ .rows = 2, .cols = 8, .x_pixel = 0, .y_pixel = 0 } },
        &write_buf,
    );
    defer terminal.deinit();
    try terminal.spawn();

    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).addDuration(.fromSeconds(5));
    while (!terminal.child_state.?.exited.load(.acquire)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).durationTo(deadline).nanoseconds <= 0)
            return error.TestUnexpectedResult;
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    terminal.child_state.?.acquire();
    const reaped = terminal.child_state.?.reaped;
    terminal.child_state.?.releaseLock();
    try std.testing.expect(reaped);

    const pid_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        descendant_path,
        std.testing.allocator,
        .limited(32),
    );
    defer std.testing.allocator.free(pid_text);
    const descendant_pid = try std.fmt.parseInt(
        posix.pid_t,
        std.mem.trim(u8, pid_text, " \t\r\n"),
        10,
    );
    const gone_deadline = std.Io.Timestamp.now(std.testing.io, .awake).addDuration(.fromSeconds(5));
    while (true) switch (linux.errno(linux.kill(descendant_pid, @fromBackingInt(@intCast(0))))) {
        .SRCH => break,
        .INTR => continue,
        .SUCCESS, .PERM => {
            if (std.Io.Timestamp.now(std.testing.io, .awake).durationTo(gone_deadline).nanoseconds <= 0)
                return error.TestUnexpectedResult;
            try std.testing.io.sleep(.fromMilliseconds(10), .awake);
        },
        else => return error.TestUnexpectedResult,
    };
}

test "OSC 7 working directory URI decoding" {
    {
        var decoded = (try decodeWorkingDirectoryUri(std.testing.allocator, "file:///tmp/a%20b")).?;
        defer decoded.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("/tmp/a b", decoded.items);
    }
    {
        var decoded = (try decodeWorkingDirectoryUri(std.testing.allocator, "file://host/a%2Fb")).?;
        defer decoded.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("/a/b", decoded.items);
    }

    try std.testing.expect((try decodeWorkingDirectoryUri(std.testing.allocator, "https://host/path")) == null);
    try std.testing.expect((try decodeWorkingDirectoryUri(std.testing.allocator, "file://host")) == null);
    try std.testing.expect((try decodeWorkingDirectoryUri(std.testing.allocator, "file://host/path%")) == null);
    try std.testing.expect((try decodeWorkingDirectoryUri(std.testing.allocator, "file://host/path%2")) == null);
    try std.testing.expect((try decodeWorkingDirectoryUri(std.testing.allocator, "file://host/path%zz")) == null);
    try std.testing.expect((try decodeWorkingDirectoryUri(std.testing.allocator, "file://host/path%_F")) == null);
    try std.testing.expect((try decodeWorkingDirectoryUri(std.testing.allocator, "file://host/path%F_")) == null);
    try std.testing.expect((try decodeWorkingDirectoryUri(std.testing.allocator, "file://host/path%00tail")) == null);
}

pub fn setMode(self: *Terminal, mode: u16, val: bool) void {
    switch (mode) {
        6 => {
            self.mode.origin = val;
            const viewport = self.currentViewport();
            self.back_screen.cursor.pending_wrap = false;
            self.back_screen.cursor.col = if (val)
                self.back_screen.scrolling_region.left
            else
                0;
            self.back_screen.cursor.row = if (val)
                @max(viewport.top, @min(self.back_screen.scrolling_region.top, viewport.bottom))
            else
                viewport.top;
        },
        7 => self.mode.autowrap = val,
        25 => self.mode.cursor = val,
        1049 => {
            if (val)
                self.back_screen = &self.back_screen_alt
            else
                self.back_screen = &self.back_screen_pri;
            var i: usize = 0;
            while (i < self.back_screen.buf.len) : (i += 1) {
                self.back_screen.buf[i].dirty = true;
            }
        },
        2026 => self.mode.sync = val,
        else => return,
    }
}

pub fn carriageReturn(self: *Terminal) void {
    self.back_screen.cursor.pending_wrap = false;
    self.back_screen.cursor.col = if (self.mode.origin)
        self.back_screen.scrolling_region.left
    else if (self.back_screen.cursor.col >= self.back_screen.scrolling_region.left)
        self.back_screen.scrolling_region.left
    else
        0;
}

pub fn horizontalTab(self: *Terminal, n: usize) void {
    // Get the current cursor position
    const col = self.back_screen.cursor.col;

    // Find desired final position
    var i: usize = 0;
    const final = for (self.tab_stops.items) |ts| {
        if (ts <= col) continue;
        i += 1;
        if (i == n) break ts;
    } else self.back_screen.width - 1;

    // Move right the delta
    self.back_screen.cursorRight(final -| col);
}

pub fn horizontalBackTab(self: *Terminal, n: usize) void {
    const col = self.back_screen.cursor.col;
    const minimum = if (self.mode.origin) self.back_screen.scrolling_region.left else 0;
    self.back_screen.cursor.pending_wrap = false;
    self.back_screen.cursor.col = horizontalBackTabPosition(
        self.tab_stops.items,
        col,
        n,
        minimum,
    );
}
