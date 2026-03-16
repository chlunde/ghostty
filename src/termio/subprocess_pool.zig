//! Pre-fork process pool for fast tab creation.
//!
//! Maintains a small pool of pre-forked child processes that are waiting
//! for commands on a pipe. When a new tab is requested, we can skip the
//! fork() overhead (~3ms page table copy) by reusing a warm child.
//!
//! The child does minimal setup at pre-fork time (just blocks on pipe).
//! All PTY setup, signal reset, and exec happen after the command is
//! received over the pipe.
const SubprocessPool = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const ptypkg = @import("../pty.zig");
const Pty = ptypkg.Pty;
const global_state = &@import("../global.zig").state;

const log = std.log.scoped(.subprocess_pool);

/// Maximum number of pre-forked children to keep warm.
const POOL_SIZE = 2;

/// Maximum size of the command message buffer (256KB).
const MAX_MSG_SIZE = 256 * 1024;

/// A pre-forked child ready to accept a command.
pub const PoolEntry = struct {
    /// PID of the pre-forked child.
    pid: posix.pid_t,

    /// PTY master fd (parent side). Caller will use this for I/O.
    pty: Pty,

    /// Write end of the command pipe (parent side).
    pipe_w: posix.fd_t,
};

/// Pool entries. Entries with pid != 0 are active.
entries: [POOL_SIZE]?PoolEntry = .{null} ** POOL_SIZE,

/// Global pool instance.
var global: SubprocessPool = .{};

/// Get the global pool, warming it if needed.
pub fn getGlobal() *SubprocessPool {
    return &global;
}

/// Try to acquire a pre-forked child from the pool.
/// Returns null if the pool is empty.
pub fn acquire(self: *SubprocessPool) ?PoolEntry {
    for (&self.entries) |*slot| {
        if (slot.*) |entry| {
            slot.* = null;
            log.info("pool: acquired entry pid={}", .{entry.pid});
            return entry;
        }
    }
    return null;
}

/// Warm the pool by pre-forking children to fill empty slots.
/// This is safe to call from the main thread.
pub fn warm(self: *SubprocessPool) void {
    for (&self.entries) |*slot| {
        if (slot.* == null) {
            slot.* = warmOne() catch |err| {
                log.warn("pool: failed to warm entry: {}", .{err});
                continue;
            };
        }
    }
}

/// Pre-fork a single child. Returns a PoolEntry on success.
fn warmOne() !PoolEntry {
    const warm_start = std.time.Instant.now() catch null;

    // Create a PTY with a default size (will be resized before use).
    var pty = try Pty.open(.{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 640,
        .ws_ypixel = 480,
    });
    errdefer pty.deinit();

    // Create a pipe for sending the command to the child.
    const pipe_fds = try posix.pipe2(.{ .CLOEXEC = true });
    // pipe_fds[0] = read end (child), pipe_fds[1] = write end (parent)
    errdefer {
        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);
    }

    // We need to clear CLOEXEC on the read end so the child inherits it
    // across fork. Actually, after fork both parent and child have copies,
    // but CLOEXEC would close it on exec in the child. We need to clear it
    // before fork so the child's copy doesn't have CLOEXEC. Wait - actually
    // after fork() both processes have independent fd tables. The child will
    // clear CLOEXEC on its copy before exec. But the child reads the pipe
    // BEFORE exec, so CLOEXEC is fine - it'll be closed when exec happens,
    // which is what we want. So keep CLOEXEC on both ends.

    const pid = try posix.fork();

    if (pid == 0) {
        // === CHILD PROCESS ===
        // Close parent-side fds.
        posix.close(pipe_fds[1]); // close write end
        posix.close(pty.master); // close master

        // Block on pipe, waiting for command.
        childWorker(pipe_fds[0], pty.slave);
        // childWorker never returns (it execs or exits).
        unreachable;
    }

    // === PARENT PROCESS ===
    // Close child-side fds.
    posix.close(pipe_fds[0]); // close read end
    posix.close(pty.slave); // close slave (child has its own copy)

    if (warm_start) |ws| {
        if (std.time.Instant.now()) |now| {
            log.info("pool: warmed entry pid={} elapsed={}us", .{ pid, now.since(ws) / 1000 });
        } else |_| {}
    }

    return .{
        .pid = pid,
        .pty = pty,
        .pipe_w = pipe_fds[1],
    };
}

/// Send a command to a pre-forked child via the pipe.
/// The message format is:
///   u32: total payload length (after this field)
///   u16: num_args
///   u16: num_env_pairs
///   [cwd as null-terminated string, or single \x00 if none]
///   [each arg as null-terminated string]
///   [each env pair as null-terminated "KEY=VALUE" string]
pub fn sendCommand(
    entry: *const PoolEntry,
    args: []const [:0]const u8,
    env: ?*const std.process.EnvMap,
    cwd: ?[]const u8,
) !void {
    // Calculate total message size.
    var payload_size: usize = 4; // num_args(u16) + num_env(u16)

    // CWD
    if (cwd) |c| {
        payload_size += c.len + 1; // including null terminator
    } else {
        payload_size += 1; // single null byte
    }

    // Args
    for (args) |arg| {
        payload_size += arg.len + 1; // including null terminator
    }

    // Env
    var num_env: u16 = 0;
    if (env) |env_map| {
        var it = env_map.iterator();
        while (it.next()) |pair| {
            payload_size += pair.key_ptr.len + 1 + pair.value_ptr.len + 1; // KEY=VALUE\0
            num_env += 1;
        }
    }

    if (payload_size > MAX_MSG_SIZE) return error.MessageTooLarge;

    // Build the message in a buffer.
    var buf: [MAX_MSG_SIZE + 4]u8 = undefined;
    var pos: usize = 0;

    // Total payload length (u32, little-endian)
    const len_bytes = std.mem.toBytes(@as(u32, @intCast(payload_size)));
    @memcpy(buf[pos..][0..4], &len_bytes);
    pos += 4;

    // num_args (u16)
    const nargs_bytes = std.mem.toBytes(@as(u16, @intCast(args.len)));
    @memcpy(buf[pos..][0..2], &nargs_bytes);
    pos += 2;

    // num_env (u16)
    const nenv_bytes = std.mem.toBytes(num_env);
    @memcpy(buf[pos..][0..2], &nenv_bytes);
    pos += 2;

    // CWD
    if (cwd) |c| {
        @memcpy(buf[pos..][0..c.len], c);
        pos += c.len;
        buf[pos] = 0;
        pos += 1;
    } else {
        buf[pos] = 0;
        pos += 1;
    }

    // Args
    for (args) |arg| {
        @memcpy(buf[pos..][0..arg.len], arg);
        pos += arg.len;
        buf[pos] = 0;
        pos += 1;
    }

    // Env
    if (env) |env_map| {
        var it = env_map.iterator();
        while (it.next()) |pair| {
            @memcpy(buf[pos..][0..pair.key_ptr.len], pair.key_ptr.*);
            pos += pair.key_ptr.len;
            buf[pos] = '=';
            pos += 1;
            @memcpy(buf[pos..][0..pair.value_ptr.len], pair.value_ptr.*);
            pos += pair.value_ptr.len;
            buf[pos] = 0;
            pos += 1;
        }
    }

    // Write the entire message to the pipe.
    var written: usize = 0;
    const total = pos;
    while (written < total) {
        const n = posix.write(entry.pipe_w, buf[written..total]) catch |err| {
            return err;
        };
        if (n == 0) return error.BrokenPipe;
        written += n;
    }

    log.info("pool: sent command to pid={} args[0]={s} payload={}bytes", .{
        entry.pid,
        if (args.len > 0) args[0] else "(empty)",
        total,
    });
}

/// Discard a pool entry, killing the child.
pub fn discard(entry: *PoolEntry) void {
    posix.close(entry.pipe_w);
    // Closing the pipe will cause the child's read to return 0,
    // and it will exit on its own. But also send SIGKILL to be sure.
    posix.kill(entry.pid, posix.SIG.KILL) catch {};
    // Reap the child to avoid zombie.
    _ = posix.waitpid(entry.pid, std.c.W.NOHANG);
    entry.pty.deinit();
}

/// Destroy all pool entries.
pub fn deinit(self: *SubprocessPool) void {
    for (&self.entries) |*slot| {
        if (slot.*) |*entry| {
            discard(entry);
            slot.* = null;
        }
    }
}

// ============================================================
// Child-side code (runs in forked child, before exec)
// ============================================================

/// The child worker function. This blocks on the pipe waiting for a
/// command message, then sets up the PTY and execs.
/// This function never returns.
fn childWorker(pipe_read_fd: posix.fd_t, slave_fd: posix.fd_t) noreturn {
    childWorkerInner(pipe_read_fd, slave_fd) catch {
        posix.exit(1);
    };
    unreachable; // childWorkerInner execs or errors
}

fn childWorkerInner(pipe_read_fd: posix.fd_t, slave_fd: posix.fd_t) !noreturn {
    // Read the message length (u32).
    var len_buf: [4]u8 = undefined;
    try readExact(pipe_read_fd, &len_buf);
    const payload_len = std.mem.readInt(u32, &len_buf, .little);

    if (payload_len > MAX_MSG_SIZE) {
        posix.exit(1);
    }

    // Read the payload.
    var msg_buf: [MAX_MSG_SIZE]u8 = undefined;
    try readExact(pipe_read_fd, msg_buf[0..payload_len]);

    // Close the pipe fd (no longer needed).
    posix.close(pipe_read_fd);

    // Parse the message.
    var pos: usize = 0;
    const num_args = std.mem.readInt(u16, msg_buf[pos..][0..2], .little);
    pos += 2;
    const num_env = std.mem.readInt(u16, msg_buf[pos..][0..2], .little);
    pos += 2;

    // CWD
    const cwd_start = pos;
    while (pos < payload_len and msg_buf[pos] != 0) : (pos += 1) {}
    const cwd_slice = msg_buf[cwd_start..pos];
    pos += 1; // skip null

    // Args - build argv array on stack
    var argv_buf: [128]?[*:0]const u8 = undefined;
    if (num_args > 127) posix.exit(1);
    var arg_idx: usize = 0;
    while (arg_idx < num_args) : (arg_idx += 1) {
        const arg_start = pos;
        while (pos < payload_len and msg_buf[pos] != 0) : (pos += 1) {}
        // The string is already null-terminated in the buffer.
        argv_buf[arg_idx] = @ptrCast(msg_buf[arg_start..pos :0]);
        pos += 1; // skip null
    }
    argv_buf[num_args] = null;
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);

    // Env - build envp array on stack
    var envp_buf: [512]?[*:0]const u8 = undefined;
    if (num_env > 511) posix.exit(1);
    var env_idx: usize = 0;
    while (env_idx < num_env) : (env_idx += 1) {
        const env_start = pos;
        while (pos < payload_len and msg_buf[pos] != 0) : (pos += 1) {}
        envp_buf[env_idx] = @ptrCast(msg_buf[env_start..pos :0]);
        pos += 1; // skip null
    }
    envp_buf[num_env] = null;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(&envp_buf);

    // --- PTY setup (same as PosixPty.childPreExec + setupFd) ---

    // dup2 slave to stdin/stdout/stderr
    try dupFd(slave_fd, posix.STDIN_FILENO);
    try dupFd(slave_fd, posix.STDOUT_FILENO);
    try dupFd(slave_fd, posix.STDERR_FILENO);

    // Reset signals to defaults
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]u6{
        posix.SIG.ABRT, posix.SIG.ALRM, posix.SIG.BUS,  posix.SIG.CHLD,
        posix.SIG.FPE,  posix.SIG.HUP,  posix.SIG.ILL,  posix.SIG.INT,
        posix.SIG.PIPE, posix.SIG.SEGV,  posix.SIG.TRAP, posix.SIG.TERM,
        posix.SIG.QUIT,
    }) |sig| {
        posix.sigaction(sig, &sa, null);
    }

    // Create new session
    const c = @cImport({
        @cInclude("unistd.h");
        @cInclude("sys/ioctl.h");
    });
    if (c.setsid() < 0) posix.exit(1);

    // Set controlling terminal
    if (c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_ulong, 0)) < 0) posix.exit(1);

    // Close original slave and master (dup'd copies remain on 0,1,2)
    posix.close(slave_fd);

    // Restore rlimits
    global_state.rlimits.restore();

    // chdir if CWD was provided
    if (cwd_slice.len > 0) {
        posix.chdir(cwd_slice) catch {};
    }

    // Exec!
    const path = argv_buf[0] orelse posix.exit(1);
    return posix.execvpeZ(path, argv, envp);
}

fn dupFd(src: posix.fd_t, target: posix.fd_t) !void {
    while (true) {
        const rc = std.os.linux.dup3(src, target, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.DupFailed,
        }
    }
}

/// Read exactly `buf.len` bytes from fd, looping on partial reads.
fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch |err| {
            return err;
        };
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}
