const Command = @This();

const std = @import("std");
const Pty = @import("Pty.zig");

const linux = std.os.linux;
const posix = std.posix;

const child_group_ready: u8 = 1;
const child_setup_failed: u8 = 2;

argv: []const []const u8,

working_directory: ?[]const u8,

env_map: *const std.process.Environ.Map,

pty: Pty,

pub const Process = struct {
    pid: posix.pid_t,
    process_group_id: posix.pid_t,
};

pub fn spawn(self: *Command, io: std.Io, allocator: std.mem.Allocator) !Process {
    _ = io;
    if (self.argv.len == 0 or self.argv[0].len == 0)
        return error.InvalidCommand;

    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    // Keep fork->exec child path allocation-free, following std/Io/Threaded.zig:posixExecv
    const argv_block = try arena.allocSentinel(?[*:0]const u8, self.argv.len, null);
    for (self.argv, 0..) |arg, i| argv_block[i] = (try arena.dupeSentinel(u8, arg, 0)).ptr;
    const env_block = try self.env_map.createPosixBlock(arena, .{});
    const path = self.env_map.get("PATH") orelse std.Io.Threaded.default_PATH;

    // The parent must not publish a process-group ID until setsid has completed.
    // A CLOEXEC pipe gives us an allocation-free child-to-parent handshake and
    // also closes automatically if a later exec path forgets to close it.
    var ready_pipe: [2]posix.fd_t = undefined;
    switch (linux.errno(linux.pipe2(&ready_pipe, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.PipeError,
    }

    const pid = pid: {
        const rc = linux.fork();
        break :pid switch (linux.errno(rc)) {
            .SUCCESS => rc,
            else => {
                _ = linux.close(ready_pipe[0]);
                _ = linux.close(ready_pipe[1]);
                return error.ForkError;
            },
        };
    };
    if (pid == 0) {
        // we are the child
        // linux.exit is the raw _exit syscall. Never return from this branch:
        // doing so would unwind into the caller in the forked child.
        _ = linux.close(ready_pipe[0]);
        if (linux.errno(linux.setsid()) != .SUCCESS) failChildSetup(ready_pipe[1]);
        if (!writeChildStatus(ready_pipe[1], child_group_ready)) linux.exit(127);

        // set the controlling terminal
        if (posix.system.ioctl(self.pty.tty.handle, posix.T.IOCSCTTY, 0) != 0)
            failChildSetup(ready_pipe[1]);

        // set up io
        {
            const rc = linux.dup2(self.pty.tty.handle, std.posix.STDIN_FILENO);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                else => failChildSetup(ready_pipe[1]),
            }
        }
        {
            const rc = linux.dup2(self.pty.tty.handle, std.posix.STDOUT_FILENO);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                else => failChildSetup(ready_pipe[1]),
            }
        }
        {
            const rc = linux.dup2(self.pty.tty.handle, std.posix.STDERR_FILENO);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                else => failChildSetup(ready_pipe[1]),
            }
        }
        // dup2 clears FD_CLOEXEC only when oldfd != newfd. Explicitly clear it
        // on all three standard descriptors so closed parent stdio cannot make
        // a slave opened directly as fd 0/1/2 disappear during exec.
        for ([_]posix.fd_t{ posix.STDIN_FILENO, posix.STDOUT_FILENO, posix.STDERR_FILENO }) |fd| {
            if (linux.errno(linux.fcntl(fd, posix.F.SETFD, 0)) != .SUCCESS)
                failChildSetup(ready_pipe[1]);
        }
        if (self.pty.tty.handle > 2) _ = linux.close(self.pty.tty.handle);
        if (self.pty.pty.handle > 2) _ = linux.close(self.pty.pty.handle);

        if (self.working_directory) |wd| {
            const wd_z = posix.toPosixPath(wd) catch failChildSetup(ready_pipe[1]);
            if (linux.errno(linux.chdir(&wd_z)) != .SUCCESS) failChildSetup(ready_pipe[1]);
        }

        // exec
        execvpeLinux(argv_block.ptr, env_block, self.argv[0], path) catch
            failChildSetup(ready_pipe[1]);
    }

    // we are the parent. Do not allow signaling until the child has created its
    // session/process group; otherwise an early abort can miss descendants.
    _ = linux.close(ready_pipe[1]);
    var byte: u8 = 0;
    var group_ready = false;
    const exec_succeeded = while (true) {
        const rc = linux.read(ready_pipe[0], @ptrCast(&byte), 1);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break group_ready;
                if (rc != 1) break false;
                if (!group_ready and byte == child_group_ready) {
                    group_ready = true;
                    continue;
                }
                break false;
            },
            .INTR => continue,
            else => break false,
        }
    };
    _ = linux.close(ready_pipe[0]);

    const child_pid: posix.pid_t = @intCast(pid);
    if (!exec_succeeded) {
        // Before the token, setsid is unconfirmed and a negative numeric ID
        // could still name an unrelated process group. The child cannot fork
        // before the token, so killing the exact child PID is sufficient.
        _ = linux.kill(child_pid, .KILL);
        reapFailedChild(child_pid);
        return error.ChildSetupFailed;
    }
    return .{ .pid = child_pid, .process_group_id = child_pid };
}

fn writeChildStatus(fd: posix.fd_t, status: u8) bool {
    const message = [1]u8{status};
    while (true) {
        const rc = linux.write(fd, &message, message.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc == message.len,
            .INTR => continue,
            else => return false,
        }
    }
}

fn failChildSetup(status_fd: posix.fd_t) noreturn {
    _ = writeChildStatus(status_fd, child_setup_failed);
    _ = linux.close(status_fd);
    linux.exit(127);
}

fn reapFailedChild(pid: posix.pid_t) void {
    var status: i32 = undefined;
    while (true) switch (linux.errno(linux.waitpid(pid, &status, 0))) {
        .SUCCESS, .CHILD => return,
        .INTR => continue,
        else => return,
    };
}

// Keep fork->exec child path allocation-free, following std/Io/Threaded.zig:posixExecv
fn execvpeLinux(
    argv: [*:null]const ?[*:0]const u8,
    env_block: std.process.Environ.PosixBlock,
    arg0: []const u8,
    path: []const u8,
) !noreturn {
    // This implementation is largely copied from std/Io/Threaded.zig
    // (`spawnPosix` + `posixExecv`/`posixExecveat`) and adapted for this PTY fork path.
    if (std.mem.indexOfScalar(u8, arg0, '/') != null) {
        const path_z = try posix.toPosixPath(arg0);
        return std.Io.Threaded.posixExecveat(posix.AT.FDCWD, &path_z, argv, env_block);
    }

    var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    var err: std.process.ReplaceError = error.FileNotFound;
    var seen_eacces = false;

    while (it.next()) |dir| {
        const separator_len: usize = if (dir.len == 0) 0 else 1;
        const path_len = dir.len + separator_len + arg0.len;
        if (path_buf.len < path_len + 1) return error.NameTooLong;
        @memcpy(path_buf[0..dir.len], dir);
        if (separator_len != 0) path_buf[dir.len] = '/';
        @memcpy(path_buf[dir.len + separator_len ..][0..arg0.len], arg0);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0].ptr;
        err = std.Io.Threaded.posixExecveat(posix.AT.FDCWD, full_path, argv, env_block);
        switch (err) {
            error.AccessDenied => seen_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        }
    }

    if (seen_eacces) return error.AccessDenied;
    return err;
}
