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

// The low-level controlled-env PTY spawn (openpt/grantpt/fork/execvpe +
// childSetup) lives in ttysnap's shared `pty` module — one spawner for both the
// ttysnap framework and this harness. This file is just the vt-backed Session
// that wraps a pty.Child for golden-screen scenarios.
const pty = @import("pty");

pub const KV = pty.KV;

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

    /// Pump until `needle` is NO LONGER on the grid, capped at `timeout_ms`.
    /// The inverse of waitFor — for "wait until the old screen is gone" before
    /// a snapshot (e.g. a `clear` that must wipe a prior line before the new
    /// output is captured). Returns false on timeout (still present).
    pub fn waitForAbsent(self: *Session, needle: []const u8, timeout_ms: u32) !bool {
        const deadline = snapshot.monoMillis() + @as(i64, @intCast(timeout_ms));
        while (true) {
            if (!self.gridContains(needle)) return true;
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
    /// Returns true if it observed a full quiet window (settled), false if it
    /// hit `timeout_ms` first (the screen never went quiet — likely a
    /// too-long quiet_ms or continuous output; the caller proceeds but should
    /// surface it).
    pub fn waitStable(self: *Session, quiet_ms: u32, timeout_ms: u32) !bool {
        const deadline = snapshot.monoMillis() + @as(i64, @intCast(timeout_ms));
        const quiet: i64 = @max(@as(i64, @intCast(quiet_ms)), 1);
        while (true) {
            const remaining = deadline - snapshot.monoMillis();
            if (remaining <= 0) return false; // hit timeout_ms before settling
            // Clamp the poll to the remaining budget so the total never
            // exceeds timeout_ms. Only a FULL quiet window with no bytes
            // counts as settled — a clamped final slice elapsing just loops
            // back to the timeout check above.
            const full = remaining >= quiet;
            const slice: i32 = @intCast(if (full) quiet else remaining);
            if (!try self.pumpMs(slice) and full) return true;
        }
    }

    /// Render the current grid text and check for substring.
    pub fn gridContains(self: *Session, needle: []const u8) bool {
        const text = self.renderTextInto(self.text_buf) catch return false;
        return std.mem.indexOf(u8, text, needle) != null;
    }

    /// How many (non-overlapping) times `needle` appears in the grid text.
    pub fn gridCount(self: *Session, needle: []const u8) usize {
        if (needle.len == 0) return 0;
        const text = self.renderTextInto(self.text_buf) catch return 0;
        var n: usize = 0;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, needle)) |pos| {
            n += 1;
            i = pos + needle.len;
        }
        return n;
    }

    /// Pump until `needle` appears at least `count` times, capped at
    /// `timeout_ms`. For an async paint whose text ALSO appears elsewhere on
    /// screen (a ghost completing a command that's still in scrollback): the
    /// count rises when the new occurrence lands, so this waits for the paint
    /// deterministically — where waitFor (any occurrence) returns immediately
    /// on the pre-existing copy and wait_stable can settle before the worker
    /// paints. Returns false on timeout.
    pub fn waitForCount(self: *Session, needle: []const u8, count: usize, timeout_ms: u32) !bool {
        const deadline = snapshot.monoMillis() + @as(i64, @intCast(timeout_ms));
        while (true) {
            if (self.gridCount(needle) >= count) return true;
            if (snapshot.monoMillis() >= deadline) return false;
            _ = try self.pumpMs(50);
        }
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

/// Open a PTY, fork, and exec the scenario's argv (with `$ATTY` resolved to the
/// per-scenario binary) under the controlled environment — via ttysnap's shared
/// `pty.spawn`. The returned Session wraps the child in a `vt.Grid` + cast so a
/// scenario asserts the *rendered* screen.
pub fn spawn(allocator: Allocator, opts: SpawnOpts) !Session {
    // Resolve `$ATTY` → the per-scenario binary.
    const argv = try allocator.alloc([]const u8, opts.argv.len);
    defer allocator.free(argv);
    for (opts.argv, 0..) |a, i| {
        argv[i] = if (std.mem.eql(u8, a, "$ATTY")) opts.atty_bin else a;
    }
    // The child sees forced_env + the scenario's extra_env, nothing inherited.
    const env = try allocator.alloc(pty.KV, opts.forced_env.len + opts.extra_env.len);
    defer allocator.free(env);
    @memcpy(env[0..opts.forced_env.len], opts.forced_env);
    @memcpy(env[opts.forced_env.len..], opts.extra_env);

    const child = try pty.spawn(allocator, .{ .argv = argv, .cols = opts.cols, .rows = opts.rows, .env = env });
    // The Session owns the master fd directly (it closes it in `deinit`); take
    // the fd + pid and release the Child's owned slave_path now.
    const master = child.master;
    const pid = child.pid;
    allocator.free(child.slave_path);
    errdefer _ = std.c.close(master);

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
