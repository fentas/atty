//! PTY harness for e2e scenarios — the `Session` driver.
//!
//! The controlled-env spawn (open a PTY, fork, dup2 the slave, execvpe) lives in
//! the `pty` module; this file wraps the resulting child in a `vt.Grid` + cast so
//! a scenario writes input, pumps master output, and compares a *rendered*
//! screen against goldens rather than a raw byte stream.
//!
//! Environment is locked down to the scenario's forced + extra env
//! (PATH/TERM/LANG/…), nothing inherited, so goldens reproduce across machines.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const vt = @import("vt.zig");
const snapshot = @import("snapshot.zig");
const pty = @import("pty");
const wait = @import("wait");
const typing = @import("typing");

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

    /// Alias for the generic `typing`/driver interface (mirrors Harness.send).
    pub fn send(self: *Session, bytes: []const u8) !void {
        return self.writeInput(bytes);
    }

    /// Type `text` at a chosen cadence via the shared `typing` helper.
    pub fn typeWith(self: *Session, text: []const u8, pattern: typing.Pattern) !void {
        return typing.typeText(self, text, pattern);
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
    // Screen queries + poll-until-condition waits — shared with ttysnap's
    // Harness via the generic `wait` module (this Session supplies gridText +
    // pumpMs + the `exited` flag). The DSL calls these; the loops live once.
    pub fn waitFor(self: *Session, needle: []const u8, timeout_ms: u32) !bool {
        return wait.waitFor(self, needle, timeout_ms);
    }
    pub fn waitForAbsent(self: *Session, needle: []const u8, timeout_ms: u32) !bool {
        return wait.waitForAbsent(self, needle, timeout_ms);
    }
    pub fn waitStable(self: *Session, quiet_ms: u32, timeout_ms: u32) !bool {
        return wait.waitStable(self, quiet_ms, timeout_ms);
    }
    pub fn waitForCount(self: *Session, needle: []const u8, count: usize, timeout_ms: u32) !bool {
        return wait.waitForCount(self, needle, count, timeout_ms);
    }
    pub fn gridContains(self: *Session, needle: []const u8) bool {
        return wait.gridContains(self, needle);
    }
    pub fn gridCount(self: *Session, needle: []const u8) usize {
        return wait.gridCount(self, needle);
    }
    pub fn sleepMs(self: *Session, ms: u32) !void {
        return wait.sleepMs(self, ms);
    }

    /// Render the current grid into the reusable text buffer.
    pub fn gridText(self: *Session) []const u8 {
        var w = std.Io.Writer.fixed(self.text_buf);
        self.grid.renderText(&w) catch {};
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

/// Spawn the scenario under its controlled environment via the shared
/// `pty.spawn`, wrapping the child in a `vt.Grid` + cast so a scenario asserts
/// the *rendered* screen.
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
    // Reap the child if a later init fails — closing the master alone only
    // SIGHUPs it (racily), so kill + wait to avoid an orphan on the OOM window.
    errdefer {
        _ = posix.kill(pid, posix.SIG.KILL) catch {};
        var st: u32 = 0;
        _ = linux.waitpid(pid, &st, 0);
    }

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
