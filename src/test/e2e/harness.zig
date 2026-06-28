//! PTY harness for e2e scenarios.
//!
//! Conceptually identical to what a user's terminal emulator does:
//!   - open a master/slave PTY pair
//!   - fork; child dup2's the slave to stdio and execvp's atty
//!   - parent reads master output, writes input, pumps until done
//!
//! All output is fed to a `vt.Grid` so we can compare a *rendered* screen
//! state against goldens, not a raw byte stream.
//!
//! Environment is locked down: by default the child sees only PATH, TERM,
//! LANG, LC_ALL, HOME, SHELL, USER set to known values, plus whatever
//! the scenario added via `env KEY=VALUE`. Inherited env is discarded so
//! goldens are reproducible across machines.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const vt = @import("vt.zig");
const snapshot = @import("snapshot.zig");

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

pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

pub const SpawnOpts = struct {
    atty_bin: []const u8,
    argv: []const []const u8,
    cols: u16,
    rows: u16,
    forced_env: []const KV,
    extra_env: []const KV,
};

pub const Session = struct {
    allocator: Allocator,
    master: posix.fd_t,
    pid: posix.pid_t,
    cols: u16,
    rows: u16,
    grid: vt.Grid,
    cast: snapshot.Cast,
    text_buf: []u8,
    exited: bool = false,
    exit_status: u32 = 0,

    pub fn deinit(self: *Session) void {
        if (!self.exited) self.terminate();
        _ = std.c.close(self.master);
        self.grid.deinit();
        self.cast.deinit();
        self.allocator.free(self.text_buf);
        self.* = undefined;
    }

    pub fn terminate(self: *Session) void {
        if (self.exited) return;
        _ = posix.kill(self.pid, posix.SIG.TERM) catch {};
        // Give it 200ms to exit cleanly.
        const deadline = snapshot.monoMillis() + 200;
        while (snapshot.monoMillis() < deadline) {
            var status: u32 = 0;
            const r = linux.waitpid(self.pid, &status, linux.W.NOHANG);
            if (r == self.pid) {
                self.exited = true;
                self.exit_status = status;
                return;
            }
            _ = self.pumpMs(20) catch {};
        }
        _ = posix.kill(self.pid, posix.SIG.KILL) catch {};
        var status: u32 = 0;
        _ = linux.waitpid(self.pid, &status, 0);
        self.exited = true;
        self.exit_status = status;
    }

    /// Write bytes to the PTY master (i.e. send to the child's stdin).
    pub fn writeInput(self: *Session, bytes: []const u8) !void {
        try self.cast.record('i', bytes);
        var written: usize = 0;
        while (written < bytes.len) {
            const rem = bytes[written..];
            const rc = std.c.write(self.master, rem.ptr, rem.len);
            if (rc < 0) {
                const err = std.posix.errno(rc);
                if (err == .AGAIN or err == .INTR) {
                    _ = try self.pumpMs(10);
                    continue;
                }
                return error.WriteFailed;
            }
            if (rc == 0) break;
            written += @intCast(rc);
        }
    }

    /// Pump output for up to `ms` milliseconds. Returns true if we read
    /// any bytes, false on timeout with nothing.
    pub fn pumpMs(self: *Session, ms: i32) !bool {
        var pfd = [_]posix.pollfd{.{ .fd = self.master, .events = 0x001, .revents = 0 }};
        const n = posix.poll(&pfd, ms) catch 0;
        if (n == 0) {
            self.reapIfDone();
            return false;
        }
        if (pfd[0].revents & 0x001 != 0) {
            var buf: [4096]u8 = undefined;
            const r = posix.read(self.master, &buf) catch |e| switch (e) {
                error.WouldBlock => return false,
                error.InputOutput => {
                    // Slave closed — child has likely exited.
                    self.reapIfDone();
                    return false;
                },
                else => return e,
            };
            if (r == 0) {
                self.reapIfDone();
                return false;
            }
            self.grid.feed(buf[0..r]);
            try self.cast.record('o', buf[0..r]);
            return true;
        }
        if (pfd[0].revents & 0x018 != 0) {
            // HUP/ERR — child likely gone.
            self.reapIfDone();
        }
        return false;
    }

    fn reapIfDone(self: *Session) void {
        if (self.exited) return;
        var status: u32 = 0;
        const r = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        if (r == self.pid) {
            self.exited = true;
            self.exit_status = status;
        }
    }

    /// Pump until `needle` appears in the rendered grid, or until timeout.
    pub fn waitFor(self: *Session, needle: []const u8, timeout_ms: u32) !bool {
        const deadline = snapshot.monoMillis() + @as(i64, @intCast(timeout_ms));
        while (true) {
            if (self.gridContains(needle)) return true;
            if (snapshot.monoMillis() >= deadline) return false;
            _ = try self.pumpMs(50);
        }
    }

    /// Sleep, while pumping output so the grid stays current.
    pub fn sleepMs(self: *Session, ms: u32) !void {
        const deadline = snapshot.monoMillis() + @as(i64, @intCast(ms));
        while (snapshot.monoMillis() < deadline) {
            const remaining: i64 = deadline - snapshot.monoMillis();
            const slice: i32 = @intCast(@min(remaining, 50));
            _ = try self.pumpMs(slice);
        }
    }

    /// Pump until the child's output goes quiet for `quiet_ms` (a poll of
    /// that length reads nothing), capped at `timeout_ms`. A deterministic
    /// replacement for a fixed `sleep` before a snapshot: it waits exactly
    /// until the screen settles, regardless of how slow/loaded the host is,
    /// and the quiet window resets on every byte — so a late async repaint
    /// (e.g. ghost text computed off the keystroke) is still awaited.
    pub fn waitStable(self: *Session, quiet_ms: u32, timeout_ms: u32) !void {
        const deadline = snapshot.monoMillis() + @as(i64, @intCast(timeout_ms));
        const quiet: i32 = @intCast(@max(quiet_ms, 1));
        while (snapshot.monoMillis() < deadline) {
            // pumpMs returns false when the poll elapsed with no bytes — i.e.
            // a full quiet window passed → settled.
            if (!try self.pumpMs(quiet)) return;
        }
    }

    /// Render the current grid text and check for substring.
    pub fn gridContains(self: *Session, needle: []const u8) bool {
        const text = self.renderTextInto(self.text_buf) catch return false;
        return std.mem.indexOf(u8, text, needle) != null;
    }

    fn renderTextInto(self: *Session, buf: []u8) ![]u8 {
        var w = std.Io.Writer.fixed(buf);
        try self.grid.renderText(&w);
        return w.buffered();
    }

    /// Capture a snapshot frame from the current grid.
    pub fn captureFrame(self: *Session) !snapshot.Frame {
        return snapshot.captureFrame(self.allocator, &self.grid);
    }

    /// Wait for the child to exit, pumping output until then.
    pub fn waitExit(self: *Session, timeout_ms: u32) !u32 {
        const deadline = snapshot.monoMillis() + @as(i64, @intCast(timeout_ms));
        while (!self.exited and snapshot.monoMillis() < deadline) {
            _ = try self.pumpMs(50);
        }
        if (!self.exited) {
            self.terminate();
        }
        return self.exit_status;
    }
};

/// Open a master/slave PTY pair, set the slave size, fork, and exec the
/// scenario's argv with the controlled environment.
pub fn spawn(allocator: Allocator, opts: SpawnOpts) !Session {
    // ── Open master ────────────────────────────────────────────────────
    const master = posix_openpt(O_RDWR_NOCTTY);
    if (master < 0) return error.OpenPtFailed;
    errdefer _ = std.c.close(master);

    if (grantpt(master) != 0) return error.GrantPtFailed;
    if (unlockpt(master) != 0) return error.UnlockPtFailed;

    const name_ptr = ptsname(master) orelse return error.PtsnameFailed;
    const slave_path_slice = std.mem.sliceTo(name_ptr, 0);
    const slave_path = try allocator.dupeZ(u8, slave_path_slice);
    defer allocator.free(slave_path);

    // ── Set master non-blocking so poll-driven I/O works cleanly ───────
    const fl = std.c.fcntl(master, F_GETFL, @as(c_int, 0));
    _ = std.c.fcntl(master, F_SETFL, fl | O_NONBLOCK);

    // ── Set window size on the master (slave inherits) ─────────────────
    const ws = posix.winsize{ .row = opts.rows, .col = opts.cols, .xpixel = 0, .ypixel = 0 };
    const ws_rc = linux.ioctl(master, TIOCSWINSZ, @intFromPtr(&ws));
    if (@as(isize, @bitCast(ws_rc)) < 0) return error.IoctlFailed;

    // ── Build argv (NUL-terminated) ────────────────────────────────────
    var argv_owned: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv_owned.items) |maybe| if (maybe) |p| allocator.free(std.mem.sliceTo(p, 0));
        argv_owned.deinit(allocator);
    }
    for (opts.argv) |a| {
        const resolved: []const u8 = if (std.mem.eql(u8, a, "$ATTY")) opts.atty_bin else a;
        const z = try allocator.dupeZ(u8, resolved);
        try argv_owned.append(allocator, z.ptr);
    }
    try argv_owned.append(allocator, null);

    // ── Build envp (NUL-terminated) ────────────────────────────────────
    var envp_owned: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (envp_owned.items) |maybe| if (maybe) |p| allocator.free(std.mem.sliceTo(p, 0));
        envp_owned.deinit(allocator);
    }
    for (opts.forced_env) |kv| try envp_owned.append(allocator, try fmtKvZ(allocator, kv));
    for (opts.extra_env) |kv| try envp_owned.append(allocator, try fmtKvZ(allocator, kv));
    try envp_owned.append(allocator, null);

    // ── Fork ───────────────────────────────────────────────────────────
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child.
        childSetup(master, slave_path) catch std.c._exit(127);
        const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_owned.items.ptr);
        const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(envp_owned.items.ptr);
        _ = execvpe(argv_ptr[0].?, argv_ptr, envp_ptr);
        std.c._exit(127);
    }

    // Parent.
    var grid = try vt.Grid.init(allocator, opts.rows, opts.cols);
    errdefer grid.deinit();
    var cast = snapshot.Cast.init(allocator, opts.cols, opts.rows);
    errdefer cast.deinit();
    const text_buf = try allocator.alloc(u8, @as(usize, opts.cols + 1) * (opts.rows + 1));
    errdefer allocator.free(text_buf);

    return .{
        .allocator = allocator,
        .master = master,
        .pid = pid,
        .cols = opts.cols,
        .rows = opts.rows,
        .grid = grid,
        .cast = cast,
        .text_buf = text_buf,
    };
}

fn fmtKvZ(allocator: Allocator, kv: KV) ![*:0]const u8 {
    const buf = try allocator.allocSentinel(u8, kv.key.len + 1 + kv.value.len, 0);
    @memcpy(buf[0..kv.key.len], kv.key);
    buf[kv.key.len] = '=';
    @memcpy(buf[kv.key.len + 1 ..][0..kv.value.len], kv.value);
    return buf.ptr;
}

fn childSetup(master_fd: posix.fd_t, slave_path: [:0]const u8) !void {
    if (setsid() == -1) return error.SetCtrlTtyFailed;

    const slave_fd = std.c.open(slave_path.ptr, open_flags, @as(std.c.mode_t, 0));
    if (slave_fd < 0) return error.OpenSlaveFailed;

    const rc = linux.ioctl(slave_fd, TIOCSCTTY, 0);
    if (@as(isize, @bitCast(rc)) < 0) return error.SetCtrlTtyFailed;

    if (std.c.dup2(slave_fd, 0) < 0) return error.OpenSlaveFailed;
    if (std.c.dup2(slave_fd, 1) < 0) return error.OpenSlaveFailed;
    if (std.c.dup2(slave_fd, 2) < 0) return error.OpenSlaveFailed;

    if (slave_fd > 2) _ = std.c.close(slave_fd);
    _ = std.c.close(master_fd);
}
