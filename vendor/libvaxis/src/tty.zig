const std = @import("std");
const builtin = @import("builtin");

const vaxis = @import("main.zig");

const ctlseqs = vaxis.ctlseqs;
const posix = std.posix;
const windows = std.os.windows;

const Event = vaxis.Event;
const Key = vaxis.Key;
const Mouse = vaxis.Mouse;
const Parser = vaxis.Parser;
const Winsize = vaxis.Winsize;

/// The target TTY implementation
pub const Tty = if (builtin.is_test)
    TestTty
else switch (builtin.os.tag) {
    .windows => WindowsTty,
    else => PosixTty,
};

/// global tty instance, used in case of a panic. Not guaranteed to work if
/// for some reason there are multiple TTYs open under a single vaxis
/// compilation unit - but this is better than nothing
pub var global_tty: ?Tty = null;

pub const PosixTty = struct {
    io: std.Io,

    /// the original state of the terminal, prior to calling makeRaw
    termios: posix.termios,

    /// The file descriptor of the tty
    fd: std.Io.File,

    /// File.Writer for efficient buffered writing
    tty_writer: std.Io.File.Writer,
    active: bool = true,

    pub const SignalHandler = struct {
        context: *anyopaque,
        callback: *const fn (context: *anyopaque) void,
        /// Set this when the callback calls APIs tied to an Io implementation.
        /// The dispatcher verifies that it runs in that same Io context, and
        /// callback removal must also be initiated from that context. Leave it
        /// null for callbacks owned and removed by unmanaged OS threads.
        /// Callbacks must be unregistered by their owner before their context or
        /// associated Tty is destroyed. Do not unregister from within the
        /// callback itself, because removal waits for an in-flight callback.
        io: ?std.Io = null,
    };

    const HandlerSlot = struct {
        handler: SignalHandler = undefined,
        generation: u64 = 0,
        born_sequence: usize = 0,
        live: bool = false,
        executing: bool = false,
    };

    const HandlerToken = struct {
        index: usize,
        generation: u64,
    };

    const SignalThreadState = enum(u8) {
        stopped,
        running,
        retiring,
    };

    const SignalWakeAction = enum {
        delivered,
        already_pending,
        retry,
        failed,
    };

    // Both callers need a bounded async-signal-safe operation. Teardown falls
    // back to Future.cancel when this budget is exhausted, while SIGWINCH may
    // safely coalesce with the next resize notification.
    const signal_wake_interrupt_retries = 8;

    var handlers: [8]HandlerSlot = @splat(.{});
    var next_generation: u64 = 1;
    var state_lock: std.atomic.Value(u8) = .init(0);
    var tty_refcount: usize = 0;
    var original_termios: posix.termios = undefined;

    var signal_pipe: [2]posix.fd_t = .{ -1, -1 };
    var signal_thread_state: std.atomic.Value(SignalThreadState) = .init(.stopped);
    var signal_thread_quit: std.atomic.Value(bool) = .init(false);
    var signal_thread_joining: bool = false;
    var signal_write_fd: std.atomic.Value(posix.fd_t) = .init(-1);
    var signal_handler_frames: std.atomic.Value(usize) = .init(0);
    var signal_sequence: std.atomic.Value(usize) = .init(0);
    var signal_io: std.Io = undefined;
    var signal_thread: std.Io.Future(void) = undefined;

    var handler_installed: bool = false;
    var previous_sigwinch: posix.Sigaction = undefined;

    /// initializes a Tty instance by opening /dev/tty and "making it raw". A
    /// signal handler is installed for SIGWINCH. No callbacks are installed, be
    /// sure to register a callback when initializing the event loop
    pub fn init(io: std.Io, buffer: []u8) !PosixTty {
        // Open our tty
        var f = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });

        errdefer f.close(io);

        lockState();
        // The final owner joins the managed dispatcher before a new lifecycle
        // may start. Returning keeps a second task from racing that join.
        if (tty_refcount == 0 and signal_thread_joining) {
            unlockState();
            return error.SignalDispatcherStopping;
        }
        // The dispatcher and all callbacks share one scheduler context. Using
        // a different Io backend for another handle would make joining or
        // callback-side synchronization operate on the wrong scheduler.
        if (tty_refcount != 0 and !sameIo(io, signal_io)) {
            unlockState();
            return error.IncompatibleTtyIo;
        }

        // A dispatcher read failure retires the dispatcher and its callbacks.
        // Do not attach another Tty to that failed lifecycle; the last active
        // Tty must unwind it before a fresh lifecycle can be started.
        if (tty_refcount != 0 and !signalDispatcherAcceptsRegistrations()) {
            unlockState();
            return error.SignalDispatcherUnavailable;
        }

        if (tty_refcount == 0) {
            original_termios = makeRaw(f.handle) catch |err| {
                unlockState();
                return err;
            };
            startSignalThread(io) catch |err| {
                posix.tcsetattr(f.handle, .FLUSH, original_termios) catch {};
                unlockState();
                return err;
            };
        }
        tty_refcount += 1;
        const termios = original_termios;
        unlockState();

        const self: PosixTty = .{
            .io = io,
            .fd = f,
            .termios = termios,
            .tty_writer = f.writerStreaming(io, buffer),
        };

        global_tty = self;

        return self;
    }

    /// release resources associated with the Tty return it to its original state
    pub fn deinit(self: *PosixTty) void {
        if (!self.active) return;
        self.active = false;
        if (global_tty) |current| {
            if (current.fd.handle == self.fd.handle) global_tty = null;
        }

        var retired_handlers: [handlers.len]HandlerToken = undefined;
        var retired_count: usize = 0;
        var dispatcher_woken = true;
        lockState();
        std.debug.assert(tty_refcount > 0);
        tty_refcount -= 1;
        const last = tty_refcount == 0;
        if (last) {
            signal_thread_joining = true;
            for (&handlers, 0..) |*slot, index| {
                if (!slot.live) continue;
                slot.live = false;
                retired_handlers[retired_count] = .{ .index = index, .generation = slot.generation };
                retired_count += 1;
            }
            disarmSignalHandlerLocked();
            posix.tcsetattr(self.fd.handle, .FLUSH, original_termios) catch |err| {
                std.log.err("couldn't restore terminal: {}", .{err});
            };
            signal_thread_quit.store(true, .release);
            dispatcher_woken = wakeSignalThread(signal_pipe[1]);
        }
        unlockState();

        for (retired_handlers[0..retired_count]) |token| waitForHandler(token);
        if (last) {
            if (dispatcher_woken)
                signal_thread.await(signal_io)
            else
                // A broken wake descriptor must not leave teardown awaiting a
                // dispatcher that is still blocked in readStreaming.
                signal_thread.cancel(signal_io);
            lockState();
            signal_thread_joining = false;
            unlockState();
        }
        // Darwin may block in close while another thread is still reading this
        // descriptor. As on the other platforms, callers must stop and join
        // input readers before destroying their Tty; within that ownership
        // contract the descriptor must be closed rather than leaked.
        self.fd.close(self.io);
    }

    /// Remove all registered resize callbacks and restore the previous SIGWINCH action.
    pub fn resetSignalHandler() void {
        var tokens: [handlers.len]HandlerToken = undefined;
        var token_count: usize = 0;
        lockState();
        for (&handlers, 0..) |*slot, index| {
            if (!slot.live) continue;
            slot.live = false;
            tokens[token_count] = .{ .index = index, .generation = slot.generation };
            token_count += 1;
        }
        disarmSignalHandlerLocked();
        unlockState();

        for (tokens[0..token_count]) |token| waitForHandler(token);
    }

    fn installSignalHandlerLocked() void {
        if (handler_installed) return;
        var act = posix.Sigaction{
            .handler = .{ .handler = PosixTty.handleWinch },
            .mask = switch (builtin.os.tag) {
                .macos => 0,
                else => posix.sigemptyset(),
            },
            .flags = 0,
        };
        signal_write_fd.store(signal_pipe[1], .seq_cst);
        posix.sigaction(posix.SIG.WINCH, &act, &previous_sigwinch);
        handler_installed = true;
    }

    fn disarmSignalHandlerLocked() void {
        if (!handler_installed) return;
        signal_write_fd.store(-1, .seq_cst);
        posix.sigaction(posix.SIG.WINCH, &previous_sigwinch, null);
        handler_installed = false;
        while (signal_handler_frames.load(.seq_cst) != 0)
            std.atomic.spinLoopHint();
    }

    pub fn writer(self: *PosixTty) *std.Io.Writer {
        return &self.tty_writer.interface;
    }

    pub fn read(self: *const PosixTty, buf: []u8) !usize {
        return try self.fd.readStreaming(self.io, &.{buf});
    }

    /// Install a signal handler for winsize. A maximum of 8 handlers may be
    /// installed
    pub fn notifyWinsize(handler: SignalHandler) !void {
        lockState();
        defer unlockState();
        if (tty_refcount == 0 or !signalDispatcherAcceptsRegistrations())
            return error.SignalDispatcherUnavailable;
        if (handler.io) |io| {
            if (!sameIo(io, signal_io))
                return error.IncompatibleSignalHandlerIo;
        }
        for (&handlers) |*slot| {
            if (slot.live or slot.executing) continue;
            installSignalHandlerLocked();
            slot.* = .{
                .handler = handler,
                .generation = next_generation,
                .born_sequence = signal_sequence.load(.seq_cst),
                .live = true,
            };
            // A read failure announces retirement without waiting for
            // state_lock. Recheck after publishing the slot so registration
            // cannot report success after that announcement won the race.
            if (!signalDispatcherAcceptsRegistrations()) {
                slot.live = false;
                if (!hasLiveHandlersLocked()) disarmSignalHandlerLocked();
                return error.SignalDispatcherUnavailable;
            }
            next_generation +%= 1;
            if (next_generation == 0) next_generation = 1;
            return;
        }
        return error.OutOfMemory;
    }

    /// Remove a previously installed winsize signal handler
    pub fn removeWinsize(handler: SignalHandler) void {
        lockState();
        var token: ?HandlerToken = null;
        for (&handlers, 0..) |*slot, index| {
            if (!slot.live or slot.handler.context != handler.context or slot.handler.callback != handler.callback)
                continue;
            slot.live = false;
            token = .{ .index = index, .generation = slot.generation };
            break;
        }
        if (!hasLiveHandlersLocked()) disarmSignalHandlerLocked();
        unlockState();
        if (token) |value| waitForHandler(value);
    }

    fn handleWinch(_: std.posix.SIG) callconv(.c) void {
        // libc-backed write(2) reports failures through thread-local errno.
        // A signal handler must restore the interrupted code's errno value.
        const saved_errno = if (comptime @hasDecl(posix.system, "_errno"))
            posix.system._errno().*
        else {};
        defer {
            if (comptime @hasDecl(posix.system, "_errno"))
                posix.system._errno().* = saved_errno;
        }

        _ = signal_handler_frames.fetchAdd(1, .seq_cst);
        defer _ = signal_handler_frames.fetchSub(1, .seq_cst);
        _ = signal_sequence.fetchAdd(1, .seq_cst);
        const fd = signal_write_fd.load(.seq_cst);
        if (fd < 0) return;
        _ = wakeSignalThread(fd);
    }

    fn wakeSignalThread(fd: posix.fd_t) bool {
        const byte = [1]u8{0};
        var interrupted_retries: usize = 0;
        while (true) {
            const action = signalWakeAction(posix.errno(posix.system.write(fd, &byte, byte.len)));
            switch (action) {
                .delivered, .already_pending => return true,
                .failed => return false,
                .retry => {
                    if (interrupted_retries == signal_wake_interrupt_retries)
                        return false;
                    interrupted_retries += 1;
                },
            }
        }
    }

    fn signalWakeAction(err: posix.E) SignalWakeAction {
        return switch (err) {
            .SUCCESS => .delivered,
            .AGAIN => .already_pending,
            .INTR => .retry,
            else => .failed,
        };
    }

    fn startSignalThread(io: std.Io) !void {
        if (signal_thread_state.load(.seq_cst) != .stopped)
            return error.SignalDispatcherStopping;
        if (comptime builtin.single_threaded) return error.ConcurrencyUnavailable;

        var fds: [2]posix.fd_t = undefined;
        switch (posix.errno(posix.system.pipe(&fds))) {
            .SUCCESS => {},
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return posix.unexpectedErrno(err),
        }
        errdefer {
            _ = posix.system.close(fds[0]);
            _ = posix.system.close(fds[1]);
        }

        for (fds) |fd| {
            switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(u32, posix.FD_CLOEXEC)))) {
                .SUCCESS => {},
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        const nonblocking: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        switch (posix.errno(posix.system.fcntl(fds[1], posix.F.SETFL, nonblocking))) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }

        signal_pipe = fds;
        signal_thread_quit.store(false, .release);
        signal_io = io;
        signal_thread_state.store(.running, .seq_cst);
        signal_thread = io.concurrent(runSignalThread, .{io}) catch |err| {
            signal_thread_state.store(.stopped, .seq_cst);
            return err;
        };
    }

    fn runSignalThread(io: std.Io) void {
        const read_file: std.Io.File = .{
            .handle = signal_pipe[0],
            .flags = .{ .nonblocking = false },
        };
        var buf: [64]u8 = undefined;
        while (true) {
            const len = read_file.readStreaming(io, &.{&buf}) catch |err| {
                beginSignalThreadRetirement();
                if (err != error.Canceled)
                    std.log.scoped(.vaxis).err("SIGWINCH dispatcher read failed: {}", .{err});
                break;
            };
            if (len == 0) {
                beginSignalThreadRetirement();
                std.log.scoped(.vaxis).err("SIGWINCH dispatcher pipe reached EOF", .{});
                break;
            }
            if (signal_thread_quit.load(.acquire)) {
                beginSignalThreadRetirement();
                break;
            }
            dispatchHandlers(signal_sequence.load(.seq_cst));
        }

        lockState();
        // This is redundant on the normal last-Tty path, but essential after
        // an unexpected read failure: no signal handler may retain a closed or
        // subsequently reused descriptor, and no callback may remain live
        // without a dispatcher capable of invoking/removing it.
        signal_write_fd.store(-1, .seq_cst);
        disarmSignalHandlerLocked();
        retireHandlerSlots(&handlers);
        const retired_pipe = signal_pipe;
        signal_pipe = .{ -1, -1 };
        signal_thread_quit.store(true, .release);
        beginSignalThreadRetirement();
        unlockState();

        for (retired_pipe) |fd| {
            if (fd >= 0) _ = posix.system.close(fd);
        }
        signal_thread_state.store(.stopped, .seq_cst);
    }

    fn retireHandlerSlots(slots: []HandlerSlot) void {
        for (slots) |*slot| {
            slot.live = false;
            slot.executing = false;
        }
    }

    fn dispatchHandlers(wake_sequence: usize) void {
        var tokens: [handlers.len]HandlerToken = undefined;
        var token_count: usize = 0;
        lockState();
        for (handlers, 0..) |slot, index| {
            if (!slot.live or slot.born_sequence >= wake_sequence) continue;
            tokens[token_count] = .{ .index = index, .generation = slot.generation };
            token_count += 1;
        }
        unlockState();

        for (tokens[0..token_count]) |token| {
            lockState();
            const slot = &handlers[token.index];
            if (!slot.live or slot.generation != token.generation or slot.executing) {
                unlockState();
                continue;
            }
            slot.executing = true;
            const handler = slot.handler;
            unlockState();

            handler.callback(handler.context);

            lockState();
            const current = &handlers[token.index];
            if (current.generation == token.generation) current.executing = false;
            unlockState();
        }
    }

    fn waitForHandler(token: HandlerToken) void {
        while (true) {
            lockState();
            const slot = &handlers[token.index];
            const done = slot.generation != token.generation or !slot.executing;
            const handler_io = if (done) null else slot.handler.io;
            unlockState();
            if (done) return;
            if (handler_io) |io| {
                io.sleep(.fromMilliseconds(1), .awake) catch {
                    std.Thread.yield() catch {};
                };
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    fn hasLiveHandlersLocked() bool {
        for (handlers) |slot| {
            if (slot.live) return true;
        }
        return false;
    }

    fn dispatcherAcceptsRegistration(state: SignalThreadState) bool {
        return state == .running;
    }

    fn signalDispatcherAcceptsRegistrations() bool {
        return dispatcherAcceptsRegistration(signal_thread_state.load(.seq_cst));
    }

    fn beginSignalThreadRetirement() void {
        signal_thread_state.store(.retiring, .seq_cst);
    }

    fn sameIo(a: std.Io, b: std.Io) bool {
        return a.userdata == b.userdata and a.vtable == b.vtable;
    }

    fn lockState() void {
        while (state_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockState() void {
        state_lock.store(0, .release);
    }

    /// makeRaw enters the raw state for the terminal.
    pub fn makeRaw(fd: posix.fd_t) !posix.termios {
        const state = try posix.tcgetattr(fd);
        var raw = state;
        // see termios(3)
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .FLUSH, raw);
        return state;
    }

    /// Get the window size from the kernel
    pub fn getWinsize(self: *PosixTty) !Winsize {
        var winsize = posix.winsize{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };

        const err = posix.system.ioctl(self.fd.handle, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
        if (posix.errno(err) == .SUCCESS)
            return Winsize{
                .rows = winsize.row,
                .cols = winsize.col,
                .x_pixel = winsize.xpixel,
                .y_pixel = winsize.ypixel,
            };
        return error.IoctlError;
    }
};

pub const WindowsTty = struct {
    stdin: windows.HANDLE,
    stdout: windows.HANDLE,
    input_stop: windows.HANDLE,

    initial_codepage: c_uint,
    initial_input_mode: CONSOLE_MODE_INPUT,
    initial_output_mode: CONSOLE_MODE_OUTPUT,

    // a buffer to write key text into
    buf: [4]u8 = undefined,

    event_state: EventState = .{},

    /// File.Writer for efficient buffered writing
    tty_writer: std.Io.File.Writer,
    active: bool = true,

    /// The last mouse button that was pressed. We store the previous state of button presses on each
    /// mouse event so we can detect which button was released
    last_mouse_button_press: u16 = 0,

    const utf8_codepage: c_uint = 65001;
    var lifecycle_lock: std.atomic.Mutex = .unlocked;
    var active_instance: bool = false;

    fn lockLifecycle() void {
        while (!lifecycle_lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub const SignalHandler = struct {
        context: *anyopaque,
        callback: *const fn (context: *anyopaque) void,
        io: ?std.Io = null,
    };

    /// The input mode set by init
    pub const input_raw_mode: CONSOLE_MODE_INPUT = .{
        .WINDOW_INPUT = 1, // resize events
        .MOUSE_INPUT = 1,
        .EXTENDED_FLAGS = 1, // allow mouse events
        .VIRTUAL_TERMINAL_INPUT = 1, // preserve bracketed paste delimiters
    };

    /// The output mode set by init
    pub const output_raw_mode: CONSOLE_MODE_OUTPUT = .{
        .PROCESSED_OUTPUT = 1, // handle control sequences
        .VIRTUAL_TERMINAL_PROCESSING = 1, // handle ANSI sequences
        .DISABLE_NEWLINE_AUTO_RETURN = 1, // disable inserting a new line when we write at the last column
        .ENABLE_LVB_GRID_WORLDWIDE = 1, // enables reverse video and underline
    };

    pub fn init(io: std.Io, buffer: []u8) !WindowsTty {
        lockLifecycle();
        defer lifecycle_lock.unlock();
        if (active_instance) return error.TtyAlreadyInitialized;

        const stdin: std.Io.File = .stdin();
        const stdout: std.Io.File = .stdout();
        const input_stop = CreateEventW(null, .TRUE, .FALSE, null) orelse
            return windows.unexpectedError(windows.GetLastError());
        errdefer windows.CloseHandle(input_stop);

        // get initial modes
        const initial_output_codepage = try getConsoleOutputCodepage();
        const initial_input_mode = try getConsoleMode(CONSOLE_MODE_INPUT, stdin.handle);
        const initial_output_mode = try getConsoleMode(CONSOLE_MODE_OUTPUT, stdout.handle);

        // set new modes
        try setConsoleMode(stdin.handle, input_raw_mode);
        errdefer setConsoleMode(stdin.handle, initial_input_mode) catch {};
        try setConsoleMode(stdout.handle, output_raw_mode);
        errdefer setConsoleMode(stdout.handle, initial_output_mode) catch {};
        if (SetConsoleOutputCP(utf8_codepage) == .FALSE)
            return windows.unexpectedError(windows.GetLastError());
        errdefer _ = SetConsoleOutputCP(initial_output_codepage);

        var self: WindowsTty = .{
            .stdin = stdin.handle,
            .stdout = stdout.handle,
            .input_stop = input_stop,
            .initial_codepage = initial_output_codepage,
            .initial_input_mode = initial_input_mode,
            .initial_output_mode = initial_output_mode,
            .tty_writer = .initStreaming(stdout, io, buffer),
        };

        // VT input alone loses key releases and modifier keys. Win32-input-mode
        // carries the original KEY_EVENT_RECORD fields in CSI ... _ sequences.
        errdefer {
            // A failed flush may already have emitted all or part of the enable
            // sequence. Roll it back before the console modes/codepage are
            // restored by the earlier error defers.
            var rollback_output: std.Io.File.Writer = .initStreaming(stdout, io, &.{});
            rollback_output.interface.writeAll("\x1b[?9001l") catch {};
        }
        try self.writer().writeAll("\x1b[?9001h");
        try self.writer().flush();

        // save a copy of this tty as the global_tty for panic handling
        global_tty = self;
        active_instance = true;

        return self;
    }

    pub fn deinit(self: *WindowsTty) void {
        lockLifecycle();
        defer lifecycle_lock.unlock();
        if (!self.active or !active_instance) return;
        self.active = false;
        active_instance = false;
        if (global_tty) |current| {
            if (current.stdout == self.stdout) global_tty = null;
        }
        var output: std.Io.File.Writer = .initStreaming(self.tty_writer.file, self.tty_writer.io, &.{});
        output.interface.writeAll("\x1b[?9001l") catch {};
        _ = SetConsoleOutputCP(self.initial_codepage);
        setConsoleMode(self.stdin, self.initial_input_mode) catch {};
        setConsoleMode(self.stdout, self.initial_output_mode) catch {};
        windows.CloseHandle(self.input_stop);
        // std.Io.File.stdin()/stdout() wrap process-global borrowed handles.
        // Closing either here invalidates them for the entire process (and the
        // handles may alias), so only the event created by init is owned.
    }

    pub const CONSOLE_MODE_INPUT = packed struct(u32) {
        PROCESSED_INPUT: u1 = 0,
        LINE_INPUT: u1 = 0,
        ECHO_INPUT: u1 = 0,
        WINDOW_INPUT: u1 = 0,
        MOUSE_INPUT: u1 = 0,
        INSERT_MODE: u1 = 0,
        QUICK_EDIT_MODE: u1 = 0,
        EXTENDED_FLAGS: u1 = 0,
        AUTO_POSITION: u1 = 0,
        VIRTUAL_TERMINAL_INPUT: u1 = 0,
        _: u22 = 0,
    };

    pub const CONSOLE_MODE_OUTPUT = packed struct(u32) {
        PROCESSED_OUTPUT: u1 = 0,
        WRAP_AT_EOL_OUTPUT: u1 = 0,
        VIRTUAL_TERMINAL_PROCESSING: u1 = 0,
        DISABLE_NEWLINE_AUTO_RETURN: u1 = 0,
        ENABLE_LVB_GRID_WORLDWIDE: u1 = 0,
        _: u27 = 0,
    };

    pub fn getConsoleMode(comptime T: type, handle: windows.HANDLE) !T {
        var mode: u32 = undefined;
        if (GetConsoleMode(handle, &mode) == .FALSE) return switch (windows.GetLastError()) {
            .INVALID_HANDLE => error.InvalidHandle,
            else => |e| windows.unexpectedError(e),
        };
        return @bitCast(mode);
    }

    fn getConsoleOutputCodepage() !c_uint {
        const codepage = GetConsoleOutputCP();
        if (codepage == 0)
            return validateConsoleOutputCodepage(codepage, windows.GetLastError());
        return codepage;
    }

    fn validateConsoleOutputCodepage(codepage: c_uint, last_error: windows.Win32Error) !c_uint {
        if (codepage == 0) return windows.unexpectedError(last_error);
        return codepage;
    }

    pub fn setConsoleMode(handle: windows.HANDLE, mode: anytype) !void {
        if (SetConsoleMode(handle, @bitCast(mode)) == .FALSE) return switch (windows.GetLastError()) {
            .INVALID_HANDLE => error.InvalidHandle,
            else => |e| windows.unexpectedError(e),
        };
    }

    pub fn writer(self: *WindowsTty) *std.Io.Writer {
        return &self.tty_writer.interface;
    }

    pub fn read(self: *const WindowsTty, buf: []u8) !usize {
        const input: std.Io.File = .{ .handle = self.stdin };
        return try input.readStreaming(self.tty_writer.io, &.{buf});
    }

    pub fn resetInput(self: *WindowsTty) !void {
        if (ResetEvent(self.input_stop) == .FALSE)
            return windows.unexpectedError(windows.GetLastError());
        self.event_state = .{};
        self.last_mouse_button_press = 0;
    }

    pub fn interruptInput(self: *WindowsTty) void {
        // The handle is owned by this Tty and remains open until deinit.
        if (SetEvent(self.input_stop) == .FALSE) @panic("invalid console stop event");
    }

    fn inputError(code: windows.Win32Error) anyerror {
        return switch (code) {
            .INVALID_HANDLE => error.InvalidHandle,
            .ACCESS_DENIED => error.AccessDenied,
            .OPERATION_ABORTED => error.InputInterrupted,
            .NOT_READY, .BUSY, .RETRY => error.WouldBlock,
            .NOT_ENOUGH_MEMORY, .NO_SYSTEM_RESOURCES => error.SystemResources,
            else => {
                std.log.scoped(.vaxis).warn("console input failed: Win32 error {d}", .{@backingInt(code)});
                return error.Unexpected;
            },
        };
    }

    pub fn nextEvent(self: *WindowsTty, parser: *Parser, paste_allocator: ?std.mem.Allocator) !Event {
        // Keep partial ANSI and UTF-16 input across transient console read errors.
        while (true) {
            // A console handle is signaled while input is available. Put the stop
            // event first so shutdown wins even during a continuous input stream.
            // This Tty must be the sole reader of the console input buffer.
            const handles = [_]windows.HANDLE{ self.input_stop, self.stdin };
            switch (WaitForMultipleObjects(handles.len, &handles, .FALSE, 0xffffffff)) {
                0 => return error.Canceled,
                1 => {},
                else => return inputError(windows.GetLastError()),
            }
            var event_count: u32 = 0;
            var input_record: INPUT_RECORD = undefined;
            if (ReadConsoleInputW(self.stdin, &input_record, 1, &event_count) == .FALSE)
                return inputError(windows.GetLastError());

            const event = self.eventFromRecord(&input_record, &self.event_state, parser, paste_allocator) catch |err| {
                self.event_state = .{};
                return err;
            };
            if (event) |ev| {
                return ev;
            }
        }
    }

    pub const EventState = struct {
        // Outer VT transport, including win32-input-mode keyboard records.
        vt_buf: [128]u8 = undefined,
        vt_idx: usize = 0,
        // Some console versions also wrap pasted VT bytes in win32 records.
        ansi_buf: [128]u8 = undefined,
        ansi_idx: usize = 0,
        ansi_key_up: ?u16 = null,
        utf16_buf: [2]u16 = undefined,
        utf16_half: bool = false,
    };

    // https://github.com/microsoft/terminal/blob/main/doc/specs/%234999%20-%20Improved%20keyboard%20handling%20in%20Conpty.md
    fn parseWin32Input(sequence: []const u8) ?KEY_EVENT_RECORD {
        var params: [6]u32 = .{ 0, 0, 0, 0, 0, 1 };
        var fields = std.mem.splitScalar(u8, sequence[2 .. sequence.len - 1], ';');
        var i: usize = 0;
        while (fields.next()) |field| : (i += 1) {
            if (i == params.len) return null;
            if (field.len > 0)
                params[i] = std.fmt.parseInt(u32, field, 10) catch return null;
        }
        return .{
            .wVirtualKeyCode = std.math.cast(u16, params[0]) orelse return null,
            .wVirtualScanCode = std.math.cast(u16, params[1]) orelse return null,
            .uChar = .{ .UnicodeChar = std.math.cast(u16, params[2]) orelse return null },
            .bKeyDown = switch (params[3]) {
                0 => .FALSE,
                1 => .TRUE,
                else => return null,
            },
            .dwControlKeyState = params[4],
            .wRepeatCount = std.math.cast(u16, params[5]) orelse return null,
        };
    }

    pub const SMALL_RECT = extern struct {
        Left: windows.SHORT,
        Top: windows.SHORT,
        Right: windows.SHORT,
        Bottom: windows.SHORT,
    };

    pub const COORD = extern struct {
        X: windows.SHORT,
        Y: windows.SHORT,
    };

    pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: windows.WORD,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };

    pub fn eventFromRecord(self: *WindowsTty, record: *const INPUT_RECORD, state: *EventState, parser: *Parser, paste_allocator: ?std.mem.Allocator) !?Event {
        switch (record.EventType) {
            0x0001 => { // Key event
                var event = record.Event.KeyEvent;

                if (event.wVirtualKeyCode == 0) {
                    if (event.bKeyDown == .FALSE) return null;
                    if (state.vt_idx > 0 or event.uChar.UnicodeChar == 27) {
                        if (state.vt_idx == state.vt_buf.len or event.uChar.UnicodeChar > 127) {
                            state.vt_idx = 0;
                            return null;
                        }
                        state.vt_buf[state.vt_idx] = @intCast(event.uChar.UnicodeChar);
                        state.vt_idx += 1;
                        if (state.vt_idx <= 2) return null;
                        const sequence = state.vt_buf[0..state.vt_idx];
                        if (std.mem.startsWith(u8, sequence, "\x1b[") and sequence[sequence.len - 1] == '_') {
                            state.vt_idx = 0;
                            event = parseWin32Input(sequence) orelse return null;
                        } else {
                            const result = try parser.parse(sequence, paste_allocator);
                            if (result.n > 0) state.vt_idx = 0;
                            return result.event;
                        }
                    }
                }

                // Encoded paste records may contain key-up duplicates. Only
                // key-down text belongs to the inner escape-sequence stream.
                if (event.wVirtualKeyCode == 0 and event.bKeyDown == .FALSE and
                    state.ansi_key_up == event.uChar.UnicodeChar)
                {
                    state.ansi_key_up = null;
                    return null;
                }
                state.ansi_key_up = null;

                if (state.utf16_half) half: {
                    state.utf16_half = false;
                    state.utf16_buf[1] = event.uChar.UnicodeChar;
                    const codepoint: u21 = std.unicode.utf16DecodeSurrogatePair(&state.utf16_buf) catch break :half;
                    const n = std.unicode.utf8Encode(codepoint, &self.buf) catch return null;

                    const key: Key = .{
                        .codepoint = codepoint,
                        .base_layout_codepoint = codepoint,
                        .mods = translateMods(event.dwControlKeyState),
                        .text = self.buf[0..n],
                    };

                    switch (event.bKeyDown) {
                        .FALSE => return .{ .key_release = key },
                        else => return .{ .key_press = key },
                    }
                }

                const base_layout: u16 = switch (event.wVirtualKeyCode) {
                    0x00 => blk: { // delivered when we get an escape sequence or a unicode codepoint
                        if (state.ansi_idx == 0 and event.uChar.UnicodeChar != 27)
                            break :blk event.uChar.UnicodeChar;
                        if (state.ansi_idx == state.ansi_buf.len or event.uChar.UnicodeChar > 127) {
                            state.ansi_idx = 0;
                            return null;
                        }
                        state.ansi_key_up = event.uChar.UnicodeChar;
                        state.ansi_buf[state.ansi_idx] = @intCast(event.uChar.UnicodeChar);
                        state.ansi_idx += 1;
                        if (state.ansi_idx <= 2) return null;
                        const result = try parser.parse(state.ansi_buf[0..state.ansi_idx], paste_allocator);
                        return if (result.n == 0) null else evt: {
                            state.ansi_idx = 0;
                            break :evt result.event;
                        };
                    },
                    0x08 => Key.backspace,
                    0x09 => Key.tab,
                    0x0D => Key.enter,
                    0x13 => Key.pause,
                    0x14 => Key.caps_lock,
                    0x1B => Key.escape,
                    0x20 => Key.space,
                    0x21 => Key.page_up,
                    0x22 => Key.page_down,
                    0x23 => Key.end,
                    0x24 => Key.home,
                    0x25 => Key.left,
                    0x26 => Key.up,
                    0x27 => Key.right,
                    0x28 => Key.down,
                    0x2c => Key.print_screen,
                    0x2d => Key.insert,
                    0x2e => Key.delete,
                    0x30...0x39 => |k| k,
                    0x41...0x5a => |k| k + 0x20, // translate to lowercase
                    0x5b => Key.left_meta,
                    0x5c => Key.right_meta,
                    0x60 => Key.kp_0,
                    0x61 => Key.kp_1,
                    0x62 => Key.kp_2,
                    0x63 => Key.kp_3,
                    0x64 => Key.kp_4,
                    0x65 => Key.kp_5,
                    0x66 => Key.kp_6,
                    0x67 => Key.kp_7,
                    0x68 => Key.kp_8,
                    0x69 => Key.kp_9,
                    0x6a => Key.kp_multiply,
                    0x6b => Key.kp_add,
                    0x6c => Key.kp_separator,
                    0x6d => Key.kp_subtract,
                    0x6e => Key.kp_decimal,
                    0x6f => Key.kp_divide,
                    0x70 => Key.f1,
                    0x71 => Key.f2,
                    0x72 => Key.f3,
                    0x73 => Key.f4,
                    0x74 => Key.f5,
                    0x75 => Key.f6,
                    0x76 => Key.f7,
                    0x77 => Key.f8,
                    0x78 => Key.f9,
                    0x79 => Key.f10,
                    0x7a => Key.f11,
                    0x7b => Key.f12,
                    0x7c => Key.f13,
                    0x7d => Key.f14,
                    0x7e => Key.f15,
                    0x7f => Key.f16,
                    0x80 => Key.f17,
                    0x81 => Key.f18,
                    0x82 => Key.f19,
                    0x83 => Key.f20,
                    0x84 => Key.f21,
                    0x85 => Key.f22,
                    0x86 => Key.f23,
                    0x87 => Key.f24,
                    0x90 => Key.num_lock,
                    0x91 => Key.scroll_lock,
                    0xa0 => Key.left_shift,
                    0x10 => Key.left_shift,
                    0xa1 => Key.right_shift,
                    0xa2 => Key.left_control,
                    0x11 => Key.left_control,
                    0xa3 => Key.right_control,
                    0xa4 => Key.left_alt,
                    0x12 => Key.left_alt,
                    0xa5 => Key.right_alt,
                    0xad => Key.mute_volume,
                    0xae => Key.lower_volume,
                    0xaf => Key.raise_volume,
                    0xb0 => Key.media_track_next,
                    0xb1 => Key.media_track_previous,
                    0xb2 => Key.media_stop,
                    0xb3 => Key.media_play_pause,
                    0xba => ';',
                    0xbb => '+',
                    0xbc => ',',
                    0xbd => '-',
                    0xbe => '.',
                    0xbf => '/',
                    0xc0 => '`',
                    0xdb => '[',
                    0xdc => '\\',
                    0xdf => '\\',
                    0xe2 => '\\',
                    0xdd => ']',
                    0xde => '\'',
                    else => {
                        const log = std.log.scoped(.vaxis);
                        log.warn("unknown wVirtualKeyCode: 0x{x}", .{event.wVirtualKeyCode});
                        return null;
                    },
                };

                if (std.unicode.utf16IsHighSurrogate(base_layout)) {
                    state.utf16_buf[0] = base_layout;
                    state.utf16_half = true;
                    return null;
                }
                if (std.unicode.utf16IsLowSurrogate(base_layout)) {
                    return null;
                }

                var codepoint: u21 = base_layout;
                var text: ?[]const u8 = null;
                switch (event.uChar.UnicodeChar) {
                    0x00...0x1F => {},
                    else => |cp| {
                        codepoint = cp;
                        const n = try std.unicode.utf8Encode(codepoint, &self.buf);
                        text = self.buf[0..n];
                    },
                }

                const key: Key = .{
                    .codepoint = codepoint,
                    .base_layout_codepoint = base_layout,
                    .mods = translateMods(event.dwControlKeyState),
                    .text = text,
                };

                switch (event.bKeyDown) {
                    .FALSE => return .{ .key_release = key },
                    else => return .{ .key_press = key },
                }
            },
            0x0002 => { // Mouse event
                // see https://learn.microsoft.com/en-us/windows/console/mouse-event-record-str

                const event = record.Event.MouseEvent;

                // High word of dwButtonState represents mouse wheel. Positive is wheel_up, negative
                // is wheel_down
                // Low word represents button state
                const mouse_wheel_direction: i16 = blk: {
                    const wheelu32: u32 = event.dwButtonState >> 16;
                    const wheelu16: u16 = @truncate(wheelu32);
                    break :blk @bitCast(wheelu16);
                };

                const buttons: u16 = @truncate(event.dwButtonState);
                // save the current state when we are done
                defer self.last_mouse_button_press = buttons;
                const button_xor = self.last_mouse_button_press ^ buttons;

                var event_type: Mouse.Type = .press;
                const btn: Mouse.Button = switch (button_xor) {
                    0x0000 => blk: {
                        // Check wheel event
                        if (event.dwEventFlags & 0x0004 > 0) {
                            if (mouse_wheel_direction > 0)
                                break :blk .wheel_up
                            else
                                break :blk .wheel_down;
                        }

                        // If we have no change but one of the buttons is still pressed we have a
                        // drag event. Find out which button is held down
                        if (buttons > 0 and event.dwEventFlags & 0x0001 > 0) {
                            event_type = .drag;
                            if (buttons & 0x0001 > 0) break :blk .left;
                            if (buttons & 0x0002 > 0) break :blk .right;
                            if (buttons & 0x0004 > 0) break :blk .middle;
                            if (buttons & 0x0008 > 0) break :blk .button_8;
                            if (buttons & 0x0010 > 0) break :blk .button_9;
                        }

                        if (event.dwEventFlags & 0x0001 > 0) event_type = .motion;
                        break :blk .none;
                    },
                    0x0001 => blk: {
                        if (buttons & 0x0001 == 0) event_type = .release;
                        break :blk .left;
                    },
                    0x0002 => blk: {
                        if (buttons & 0x0002 == 0) event_type = .release;
                        break :blk .right;
                    },
                    0x0004 => blk: {
                        if (buttons & 0x0004 == 0) event_type = .release;
                        break :blk .middle;
                    },
                    0x0008 => blk: {
                        if (buttons & 0x0008 == 0) event_type = .release;
                        break :blk .button_8;
                    },
                    0x0010 => blk: {
                        if (buttons & 0x0010 == 0) event_type = .release;
                        break :blk .button_9;
                    },
                    else => {
                        std.log.warn("unknown mouse event: {}", .{event});
                        return null;
                    },
                };

                const shift: u32 = 0x0010;
                const alt: u32 = 0x0001 | 0x0002;
                const ctrl: u32 = 0x0004 | 0x0008;
                const mods: Mouse.Modifiers = .{
                    .shift = event.dwControlKeyState & shift > 0,
                    .alt = event.dwControlKeyState & alt > 0,
                    .ctrl = event.dwControlKeyState & ctrl > 0,
                };

                const mouse: Mouse = .{
                    .col = @as(i16, @bitCast(event.dwMousePosition.X)), // Windows reports with 0 index
                    .row = @as(i16, @bitCast(event.dwMousePosition.Y)), // Windows reports with 0 index
                    .mods = mods,
                    .type = event_type,
                    .button = btn,
                };
                return .{ .mouse = mouse };
            },
            0x0004 => { // Screen resize events
                // NOTE: Even though the event comes with a size, it may not be accurate. We ask for
                // the size directly when we get this event
                var console_info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
                if (GetConsoleScreenBufferInfo(self.stdout, &console_info) == .FALSE) {
                    return inputError(windows.GetLastError());
                }
                const window_rect = console_info.srWindow;
                const width = window_rect.Right - window_rect.Left + 1;
                const height = window_rect.Bottom - window_rect.Top + 1;
                return .{
                    .winsize = .{
                        .cols = @intCast(width),
                        .rows = @intCast(height),
                        .x_pixel = 0,
                        .y_pixel = 0,
                    },
                };
            },
            0x0010 => { // Focus events
                switch (record.Event.FocusEvent.bSetFocus) {
                    .FALSE => {
                        self.last_mouse_button_press = 0;
                        return .focus_out;
                    },
                    else => return .focus_in,
                }
            },
            else => {},
        }
        return null;
    }

    fn translateMods(mods: u32) Key.Modifiers {
        const left_alt: u32 = 0x0002;
        const right_alt: u32 = 0x0001;
        const left_ctrl: u32 = 0x0008;
        const right_ctrl: u32 = 0x0004;

        const caps: u32 = 0x0080;
        const num_lock: u32 = 0x0020;
        const shift: u32 = 0x0010;
        const alt: u32 = left_alt | right_alt;
        const ctrl: u32 = left_ctrl | right_ctrl;

        const altGr = (mods & right_alt > 0) and (mods & left_ctrl > 0);

        return .{
            .shift = mods & shift > 0,
            .alt = if (altGr) mods & left_alt > 0 else mods & alt > 0,
            .ctrl = if (altGr) mods & right_ctrl > 0 else mods & ctrl > 0,
            .caps_lock = mods & caps > 0,
            .num_lock = mods & num_lock > 0,
        };
    }

    pub fn getWinsize(self: *WindowsTty) !Winsize {
        var console_info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(self.stdout, &console_info) == .FALSE) {
            return windows.unexpectedError(windows.GetLastError());
        }
        const window_rect = console_info.srWindow;
        const width = window_rect.Right - window_rect.Left + 1;
        const height = window_rect.Bottom - window_rect.Top + 1;
        return .{
            .cols = @intCast(width),
            .rows = @intCast(height),
            .x_pixel = 0,
            .y_pixel = 0,
        };
    }

    // From gitub.com/ziglibs/zig-windows-console. Thanks :)
    //
    // Events
    const union_unnamed_248 = extern union {
        UnicodeChar: windows.WCHAR,
        AsciiChar: windows.CHAR,
    };

    pub const KEY_EVENT_RECORD = extern struct {
        bKeyDown: windows.BOOL,
        wRepeatCount: windows.WORD,
        wVirtualKeyCode: windows.WORD,
        wVirtualScanCode: windows.WORD,
        uChar: union_unnamed_248,
        dwControlKeyState: windows.DWORD,
    };

    pub const PKEY_EVENT_RECORD = *KEY_EVENT_RECORD;

    pub const MOUSE_EVENT_RECORD = extern struct {
        dwMousePosition: windows.COORD,
        dwButtonState: windows.DWORD,
        dwControlKeyState: windows.DWORD,
        dwEventFlags: windows.DWORD,
    };

    pub const PMOUSE_EVENT_RECORD = *MOUSE_EVENT_RECORD;

    pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
        dwSize: windows.COORD,
    };

    pub const PWINDOW_BUFFER_SIZE_RECORD = *WINDOW_BUFFER_SIZE_RECORD;

    pub const MENU_EVENT_RECORD = extern struct {
        dwCommandId: windows.UINT,
    };

    pub const PMENU_EVENT_RECORD = *MENU_EVENT_RECORD;

    pub const FOCUS_EVENT_RECORD = extern struct {
        bSetFocus: windows.BOOL,
    };

    pub const PFOCUS_EVENT_RECORD = *FOCUS_EVENT_RECORD;

    const union_unnamed_249 = extern union {
        KeyEvent: KEY_EVENT_RECORD,
        MouseEvent: MOUSE_EVENT_RECORD,
        WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
        MenuEvent: MENU_EVENT_RECORD,
        FocusEvent: FOCUS_EVENT_RECORD,
    };

    pub const INPUT_RECORD = extern struct {
        EventType: windows.WORD,
        Event: union_unnamed_249,
    };

    pub const PINPUT_RECORD = *INPUT_RECORD;

    extern "kernel32" fn CreateEventW(?*windows.SECURITY_ATTRIBUTES, windows.BOOL, windows.BOOL, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetEvent(windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ResetEvent(windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForMultipleObjects(windows.DWORD, [*]const windows.HANDLE, windows.BOOL, windows.DWORD) callconv(.winapi) windows.DWORD;
    pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: windows.HANDLE, lpBuffer: PINPUT_RECORD, nLength: windows.DWORD, lpNumberOfEventsRead: *windows.DWORD) callconv(.winapi) windows.BOOL;
    pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;
    pub extern "kernel32" fn GetConsoleMode(kConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
    pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
    pub extern "kernel32" fn SetConsoleOutputCP(wCodePageId: windows.UINT) callconv(.winapi) windows.BOOL;
    pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutpur: windows.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) windows.BOOL;
};

pub const TestTty = switch (builtin.os.tag) {
    .linux => struct {
        const linux = std.os.linux;
        /// Used for API compat
        fd: posix.fd_t,
        pipe_read: posix.fd_t,
        pipe_write: posix.fd_t,
        tty_writer: *std.Io.Writer.Allocating,

        pub const SignalHandler = struct {
            context: *anyopaque,
            callback: *const fn (context: *anyopaque) void,
            io: ?std.Io = null,
        };

        /// Initializes a TestTty.
        pub fn init(_: std.Io, buffer: []u8) !@This() {
            _ = buffer;

            const list = try std.testing.allocator.create(std.Io.Writer.Allocating);
            list.* = .init(std.testing.allocator);
            var fds: [2]i32 = undefined;
            const rc = linux.pipe(&fds);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                else => return error.PipeCreateFailed,
            }
            return .{
                .fd = fds[0],
                .pipe_read = fds[0],
                .pipe_write = fds[1],
                .tty_writer = list,
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = linux.close(self.pipe_read);
            _ = linux.close(self.pipe_write);
            self.tty_writer.deinit();
            std.testing.allocator.destroy(self.tty_writer);
        }

        pub fn writer(self: *@This()) *std.Io.Writer {
            return &self.tty_writer.writer;
        }

        pub fn read(self: *const @This(), buf: []u8) !usize {
            return posix.read(self.fd, buf);
        }

        /// Get the window size from the kernel
        pub fn getWinsize(_: *@This()) !Winsize {
            return .{
                .rows = 40,
                .cols = 80,
                .x_pixel = 40 * 8,
                .y_pixel = 40 * 8 * 2,
            };
        }

        /// Implemented for the Windows API
        pub fn nextEvent(_: *@This(), _: *Parser, _: ?std.mem.Allocator) !Event {
            return error.SkipZigTest;
        }

        pub fn resetSignalHandler() void {
            return;
        }
    },
    else => struct {
        d: std.Io.Writer.Discarding,

        pub const SignalHandler = struct {
            context: *anyopaque,
            callback: *const fn (context: *anyopaque) void,
            io: ?std.Io = null,
        };

        pub fn init(_: std.Io, buf: []u8) !@This() {
            return .{
                .d = .init(buf),
            };
        }

        pub fn deinit(_: *const @This()) void {}

        pub fn writer(self: *@This()) *std.Io.Writer {
            return &self.d.writer;
        }

        pub fn getWinsize(_: *@This()) !Winsize {
            return .{
                .rows = 40,
                .cols = 80,
                .x_pixel = 40 * 8,
                .y_pixel = 40 * 8 * 2,
            };
        }

        /// Implemented for the Windows API
        pub fn nextEvent(_: *@This(), _: *Parser, _: ?std.mem.Allocator) !Event {
            return error.SkipZigTest;
        }

        pub fn resetSignalHandler() void {
            return;
        }
    },
};

test "signal wake errno decisions distinguish retry and readable pipe" {
    try std.testing.expectEqual(
        PosixTty.SignalWakeAction.delivered,
        PosixTty.signalWakeAction(.SUCCESS),
    );
    try std.testing.expectEqual(
        PosixTty.SignalWakeAction.already_pending,
        PosixTty.signalWakeAction(.AGAIN),
    );
    try std.testing.expectEqual(
        PosixTty.SignalWakeAction.retry,
        PosixTty.signalWakeAction(.INTR),
    );
    try std.testing.expectEqual(
        PosixTty.SignalWakeAction.failed,
        PosixTty.signalWakeAction(.BADF),
    );
}

test "signal dispatcher retirement clears callback state" {
    var slots: [3]PosixTty.HandlerSlot = @splat(.{});
    slots[0].generation = 7;
    slots[0].live = true;
    slots[1].generation = 9;
    slots[1].live = true;
    slots[1].executing = true;

    PosixTty.retireHandlerSlots(&slots);

    for (slots) |slot| {
        try std.testing.expect(!slot.live);
        try std.testing.expect(!slot.executing);
    }
    try std.testing.expectEqual(@as(u64, 7), slots[0].generation);
    try std.testing.expectEqual(@as(u64, 9), slots[1].generation);
}

test "signal dispatcher retirement rejects new registrations" {
    try std.testing.expect(PosixTty.dispatcherAcceptsRegistration(.running));
    try std.testing.expect(!PosixTty.dispatcherAcceptsRegistration(.retiring));
    try std.testing.expect(!PosixTty.dispatcherAcceptsRegistration(.stopped));
}

test "Windows output codepage validation rejects the failure sentinel" {
    try std.testing.expectEqual(
        @as(c_uint, WindowsTty.utf8_codepage),
        try WindowsTty.validateConsoleOutputCodepage(WindowsTty.utf8_codepage, .SUCCESS),
    );
    try std.testing.expectError(
        error.Unexpected,
        WindowsTty.validateConsoleOutputCodepage(0, .INVALID_FUNCTION),
    );
}

test "Windows win32-input-mode fields and defaults" {
    const record = WindowsTty.parseWin32Input("\x1b[65;30;65;1;16;3_").?;
    try std.testing.expectEqual(@as(u16, 65), record.wVirtualKeyCode);
    try std.testing.expectEqual(@as(u16, 30), record.wVirtualScanCode);
    try std.testing.expectEqual(@as(u16, 65), record.uChar.UnicodeChar);
    try std.testing.expectEqual(windows.BOOL.TRUE, record.bKeyDown);
    try std.testing.expectEqual(@as(u32, 16), record.dwControlKeyState);
    try std.testing.expectEqual(@as(u16, 3), record.wRepeatCount);
    const defaults = WindowsTty.parseWin32Input("\x1b[65;;97;1_").?;
    try std.testing.expectEqual(@as(u16, 0), defaults.wVirtualScanCode);
    try std.testing.expectEqual(@as(u32, 0), defaults.dwControlKeyState);
    try std.testing.expectEqual(@as(u16, 1), defaults.wRepeatCount);
    for ([_][]const u8{
        "\x1b[65536;0;0;1;0;1_",
        "\x1b[0;0;65536;1;0;1_",
        "\x1b[0;0;0;2;0;1_",
        "\x1b[0;0;0;1;4294967296;1_",
        "\x1b[0;0;0;1;0;65536_",
        "\x1b[0;0;0;1;0;1;0_",
    }) |sequence| try std.testing.expect(WindowsTty.parseWin32Input(sequence) == null);
}

const WindowsInputTest = struct {
    tty: WindowsTty = .{
        .stdin = undefined,
        .stdout = undefined,
        .input_stop = undefined,
        .initial_codepage = 0,
        .initial_input_mode = .{},
        .initial_output_mode = .{},
        .tty_writer = undefined,
    },
    parser: Parser = .{},

    fn expectSequence(self: *@This(), input: []const u16, expected: ?Event) !void {
        for (input, 0..) |unit, i| {
            const record: WindowsTty.INPUT_RECORD = .{
                .EventType = 0x0001,
                .Event = .{ .KeyEvent = .{
                    .bKeyDown = .TRUE,
                    .wRepeatCount = 1,
                    .wVirtualKeyCode = 0,
                    .wVirtualScanCode = 0,
                    .uChar = .{ .UnicodeChar = unit },
                    .dwControlKeyState = 0,
                } },
            };
            const event = try self.tty.eventFromRecord(&record, &self.tty.event_state, &self.parser, null);
            try std.testing.expectEqualDeep(if (i == input.len - 1) expected else null, event);
        }
    }
};

test "Windows paste boundaries, Unicode, and ordinary keyboard events" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
    var input: WindowsInputTest = .{};
    try std.testing.expectEqual(@as(u1, 1), WindowsTty.input_raw_mode.VIRTUAL_TERMINAL_INPUT);
    try input.expectSequence(utf16("\x1b[200~"), .paste_start);
    try input.expectSequence(utf16("a"), .{ .key_press = .{ .codepoint = 'a', .base_layout_codepoint = 'a', .text = "a" } });
    try input.expectSequence(utf16("\r"), .{ .key_press = .{ .codepoint = Key.enter, .base_layout_codepoint = Key.enter } });
    // U+011B has ESC as its low byte; it must not start a control sequence.
    try input.expectSequence(utf16("ě"), .{ .key_press = .{ .codepoint = 'ě', .base_layout_codepoint = 'ě', .text = "ě" } });
    try input.expectSequence(utf16("😀"), .{ .key_press = .{ .codepoint = '😀', .base_layout_codepoint = '😀', .text = "😀" } });
    try input.expectSequence(utf16("\r"), .{ .key_press = .{ .codepoint = Key.enter, .base_layout_codepoint = Key.enter } });
    try input.expectSequence(utf16("z"), .{ .key_press = .{ .codepoint = 'z', .base_layout_codepoint = 'z', .text = "z" } });
    try input.expectSequence(utf16("\x1b[201~"), .paste_end);

    // Physical keys arrive as win32-input-mode, including releases and Escape.
    try input.expectSequence(utf16("\x1b[13;28;13;1;0;1_"), .{ .key_press = .{ .codepoint = Key.enter, .base_layout_codepoint = Key.enter } });
    try input.expectSequence(utf16("\x1b[13;28;13;0;0;1_"), .{ .key_release = .{ .codepoint = Key.enter, .base_layout_codepoint = Key.enter } });
    try input.expectSequence(utf16("\x1b[27;1;27;1;0;1_"), .{ .key_press = .{ .codepoint = Key.escape, .base_layout_codepoint = Key.escape } });
    try input.expectSequence(utf16("\x1b[65;30;65;1;16;1_"), .{ .key_press = .{ .codepoint = 'A', .base_layout_codepoint = 'a', .mods = .{ .shift = true }, .text = "A" } });
    try input.expectSequence(utf16("\x1b[65;30;65;0;16;1_"), .{ .key_release = .{ .codepoint = 'A', .base_layout_codepoint = 'a', .mods = .{ .shift = true }, .text = "A" } });
    try input.expectSequence(utf16("\x1b[67;46;3;1;8;1_"), .{ .key_press = .{ .codepoint = 'c', .base_layout_codepoint = 'c', .mods = .{ .ctrl = true } } });
    try input.expectSequence(utf16("\x1b[81;16;64;1;9;1_"), .{ .key_press = .{ .codepoint = '@', .base_layout_codepoint = 'q', .text = "@" } });
    try input.expectSequence(utf16("\x1b[16;42;0;0;0;1_"), .{ .key_release = .{ .codepoint = Key.left_shift, .base_layout_codepoint = Key.left_shift } });
    try input.expectSequence(utf16("\x1b[0;0;283;1;0;1_"), .{ .key_press = .{ .codepoint = 'ě', .base_layout_codepoint = 'ě', .text = "ě" } });
    try input.expectSequence(utf16("\x1b[0;0;283;0;0;1_"), .{ .key_release = .{ .codepoint = 'ě', .base_layout_codepoint = 'ě', .text = "ě" } });
}

test "Windows paste delimiters wrapped in win32-input-mode" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var input: WindowsInputTest = .{};
    for ([_][]const u8{ "\x1b[200~", "\x1b[201~" }, 0..) |marker, m| {
        for (marker, 0..) |byte, i| {
            for ([_]u1{ 1, 0 }) |down| {
                var buffer: [64]u8 = undefined;
                const sequence = try std.fmt.bufPrint(&buffer, "\x1b[0;0;{d};{d};0;1_", .{ byte, down });
                var units: [64]u16 = undefined;
                for (sequence, 0..) |b, j| units[j] = b;
                const expected: ?Event = if (down == 1 and i == marker.len - 1)
                    (if (m == 0) .paste_start else .paste_end)
                else
                    null;
                try input.expectSequence(units[0..sequence.len], expected);
            }
        }
    }
}

test "Windows mouse state resets across input reset and focus loss" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var input: WindowsInputTest = .{};
    const stop = WindowsTty.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.Unexpected;
    defer windows.CloseHandle(stop);
    input.tty.input_stop = stop;

    const press: WindowsTty.INPUT_RECORD = .{
        .EventType = 0x0002,
        .Event = .{ .MouseEvent = .{
            .dwMousePosition = .{ .X = 3, .Y = 4 },
            .dwButtonState = 0x0001,
            .dwControlKeyState = 0,
            .dwEventFlags = 0,
        } },
    };

    const first = (try input.tty.eventFromRecord(&press, &input.tty.event_state, &input.parser, null)).?;
    try std.testing.expect(first == .mouse);
    try std.testing.expectEqual(Mouse.Type.press, first.mouse.type);
    try std.testing.expectEqual(Mouse.Button.left, first.mouse.button);
    try std.testing.expectEqual(@as(u16, 1), input.tty.last_mouse_button_press);

    try input.tty.resetInput();
    try std.testing.expectEqual(@as(u16, 0), input.tty.last_mouse_button_press);
    const after_reset = (try input.tty.eventFromRecord(&press, &input.tty.event_state, &input.parser, null)).?;
    try std.testing.expect(after_reset == .mouse);
    try std.testing.expectEqual(Mouse.Type.press, after_reset.mouse.type);
    try std.testing.expectEqual(Mouse.Button.left, after_reset.mouse.button);

    const focus_out: WindowsTty.INPUT_RECORD = .{
        .EventType = 0x0010,
        .Event = .{ .FocusEvent = .{ .bSetFocus = .FALSE } },
    };
    const focus_event = (try input.tty.eventFromRecord(&focus_out, &input.tty.event_state, &input.parser, null)).?;
    try std.testing.expect(focus_event == .focus_out);
    try std.testing.expectEqual(@as(u16, 0), input.tty.last_mouse_button_press);

    const after_focus = (try input.tty.eventFromRecord(&press, &input.tty.event_state, &input.parser, null)).?;
    try std.testing.expect(after_focus == .mouse);
    try std.testing.expectEqual(Mouse.Type.press, after_focus.mouse.type);
    try std.testing.expectEqual(Mouse.Button.left, after_focus.mouse.button);
}

test "console errors distinguish interruption from permanent failures" {
    try std.testing.expectEqual(error.InputInterrupted, WindowsTty.inputError(.OPERATION_ABORTED));
    try std.testing.expectEqual(error.InvalidHandle, WindowsTty.inputError(.INVALID_HANDLE));
    try std.testing.expectEqual(error.AccessDenied, WindowsTty.inputError(.ACCESS_DENIED));
    try std.testing.expectEqual(error.SystemResources, WindowsTty.inputError(.NO_SYSTEM_RESOURCES));
}

test "Windows input wait is interruptible without a console response" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    // An unsignaled event stands in for an idle console handle. Cancellation
    // must return without ever reaching ReadConsoleInputW.
    const input = WindowsTty.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.Unexpected;
    defer windows.CloseHandle(input);
    const stop = WindowsTty.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.Unexpected;
    defer windows.CloseHandle(stop);
    var tty: WindowsTty = undefined;
    tty.stdin = input;
    tty.input_stop = stop;
    const Reader = struct {
        fn run(t: *WindowsTty, ready: *std.Io.Event) !void {
            var parser: Parser = .{};
            ready.set(std.testing.io);
            try std.testing.expectError(error.Canceled, t.nextEvent(&parser, null));
        }
    };
    var ready: std.Io.Event = .unset;
    var task = try io.concurrent(Reader.run, .{ &tty, &ready });
    defer {
        tty.interruptInput();
        task.cancel(io) catch {};
    }
    try ready.wait(io);
    try io.sleep(.fromMilliseconds(10), .awake);
    tty.interruptInput();
    try task.await(io);

    try tty.resetInput();
    try std.testing.expectEqual(@as(u32, 258), WindowsTty.WaitForMultipleObjects(1, &.{stop}, .FALSE, 0));
    // Shutdown also wins if input and stop are both already signaled.
    try std.testing.expect(WindowsTty.SetEvent(input) != .FALSE);
    tty.interruptInput();
    var parser: Parser = .{};
    try std.testing.expectError(error.Canceled, tty.nextEvent(&parser, null));
}

test {
    std.testing.refAllDecls(@This());
}
