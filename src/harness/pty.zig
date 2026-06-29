//! Spawn a child under a pseudo-terminal with a fully controlled environment.
//!
//! This is the "open a real terminal for the program under test" primitive: a
//! master/slave PTY pair, a fork, the child becomes a session leader and
//! adopts the slave as its controlling terminal + stdio, then execs the target
//! with EXACTLY the environment the caller passed (no inheritance) so a
//! rendered screen is reproducible across machines. The parent keeps the
//! non-blocking master fd to drive input + read output.
//!
//! Self-contained POSIX (its own externs) so the harness depends only on the
//! `vt` grid — not on atty's proxy PTY, whose `spawn` is purpose-built for the
//! proxy (injects ATTY env markers, inherits the parent env). A future cleanup
//! can fold the proxy e2e harness's near-identical spawn onto this.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn execvpe(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;

const TIOCSCTTY: u32 = 0x540E;
const TIOCSWINSZ: u32 = 0x5414;
const open_flags: std.c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
const O_RDWR_NOCTTY: c_int = 0o2 | 0o400;
const O_NONBLOCK: c_int = 0o4000;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;

pub const Error = error{
    OpenPtFailed,
    GrantPtFailed,
    UnlockPtFailed,
    PtsnameFailed,
    IoctlFailed,
    ForkFailed,
} || Allocator.Error;

/// One `name=value` environment entry.
pub const KV = struct { key: []const u8, value: []const u8 };

pub const Opts = struct {
    /// argv[0] is the program (PATH-resolved via execvpe).
    argv: []const []const u8,
    cols: u16,
    rows: u16,
    /// The COMPLETE environment handed to the child — nothing is inherited,
    /// so the run is reproducible. Empty = an empty environment.
    env: []const KV = &.{},
};

/// A spawned child plus its PTY master. The caller pumps `master`, reaps the
/// child, then calls `deinit` (which closes the master + frees the slave path).
pub const Child = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
    slave_path: [:0]u8,
    allocator: Allocator,

    pub fn deinit(self: *Child) void {
        _ = std.c.close(self.master);
        self.allocator.free(self.slave_path);
        self.* = undefined;
    }
};

pub fn spawn(allocator: Allocator, opts: Opts) Error!Child {
    const master = posix_openpt(O_RDWR_NOCTTY);
    if (master < 0) return Error.OpenPtFailed;
    errdefer _ = std.c.close(master);
    if (grantpt(master) != 0) return Error.GrantPtFailed;
    if (unlockpt(master) != 0) return Error.UnlockPtFailed;

    const name_ptr = ptsname(master) orelse return Error.PtsnameFailed;
    const slave_path = try allocator.dupeZ(u8, std.mem.sliceTo(name_ptr, 0));
    errdefer allocator.free(slave_path);

    // Non-blocking master: the poll-driven pump must never wedge on a read.
    const fl = std.c.fcntl(master, F_GETFL, @as(c_int, 0));
    _ = std.c.fcntl(master, F_SETFL, fl | O_NONBLOCK);

    const ws = posix.winsize{ .row = opts.rows, .col = opts.cols, .xpixel = 0, .ypixel = 0 };
    if (@as(isize, @bitCast(linux.ioctl(master, TIOCSWINSZ, @intFromPtr(&ws)))) < 0) return Error.IoctlFailed;

    // argv → NUL-terminated array of NUL-terminated strings.
    var argv_owned: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv_owned.items) |m| if (m) |p| allocator.free(std.mem.sliceTo(p, 0));
        argv_owned.deinit(allocator);
    }
    for (opts.argv) |a| try argv_owned.append(allocator, (try allocator.dupeZ(u8, a)).ptr);
    try argv_owned.append(allocator, null);

    // env → NUL-terminated array of "key=value" strings.
    var envp_owned: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (envp_owned.items) |m| if (m) |p| allocator.free(std.mem.sliceTo(p, 0));
        envp_owned.deinit(allocator);
    }
    for (opts.env) |kv| try envp_owned.append(allocator, try fmtKvZ(allocator, kv));
    try envp_owned.append(allocator, null);

    const pid = fork();
    if (pid < 0) return Error.ForkFailed;
    if (pid == 0) {
        childSetup(master, slave_path) catch std.c._exit(127);
        const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_owned.items.ptr);
        const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(envp_owned.items.ptr);
        _ = execvpe(argv_ptr[0].?, argv_ptr, envp_ptr);
        std.c._exit(127); // exec failed
    }

    return .{ .master = master, .pid = pid, .slave_path = slave_path, .allocator = allocator };
}

fn fmtKvZ(allocator: Allocator, kv: KV) ![*:0]const u8 {
    const buf = try allocator.allocSentinel(u8, kv.key.len + 1 + kv.value.len, 0);
    @memcpy(buf[0..kv.key.len], kv.key);
    buf[kv.key.len] = '=';
    @memcpy(buf[kv.key.len + 1 ..][0..kv.value.len], kv.value);
    return buf.ptr;
}

fn childSetup(master_fd: posix.fd_t, slave_path: [:0]const u8) !void {
    if (setsid() == -1) return error.SetsidFailed;
    const slave_fd = std.c.open(slave_path.ptr, open_flags, @as(std.c.mode_t, 0));
    if (slave_fd < 0) return error.OpenSlaveFailed;
    // Adopt the slave as the controlling terminal (we are the session leader).
    if (@as(isize, @bitCast(linux.ioctl(slave_fd, TIOCSCTTY, 0))) < 0) return error.SetCtrlTtyFailed;
    if (std.c.dup2(slave_fd, 0) < 0) return error.DupFailed;
    if (std.c.dup2(slave_fd, 1) < 0) return error.DupFailed;
    if (std.c.dup2(slave_fd, 2) < 0) return error.DupFailed;
    if (slave_fd > 2) _ = std.c.close(slave_fd);
    _ = std.c.close(master_fd); // the child only needs the slave
}
