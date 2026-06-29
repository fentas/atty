//! `Harness(modules)` — the composed TTY-test driver.
//!
//! The test-lifecycle sibling of atty's `Dispatcher(modules)` / attop's
//! `PanelHost(panels)`: given a comptime tuple of module TYPES it produces a
//! driver that spawns a child under a PTY, renders its output into a `vt.Grid`,
//! drives input, and fans the lifecycle (see `module.zig`) into each module —
//! every hook resolved by `@hasDecl` at comptime, so unused hooks cost nothing.
//!
//! `Harness(.{})` (empty tuple) is the bare engine: spawn + drive + a rendered
//! screen, with no observers or injectors. Add modules to record, assert, or
//! perturb. The composition is what `config.zig` picks and `zig build` bakes
//! into one binary — "menuconfig, not runtime config."
//!
//! Usage:
//!   const H = ttysnap.Harness(config.modules);
//!   var h = try H.spawn(alloc, .{ .argv = &.{"bash","--norc","-i"}, .env = ... });
//!   defer h.deinit();
//!   _ = try h.waitFor("$", 2000);
//!   try h.send("echo hi\r");
//!   _ = try h.waitFor("hi", 2000);
//!   try h.snapshot("after_echo");   // fans onSnapshot → golden compare/capture
//!   const code = try h.waitExit(2000);

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const vt = @import("vt");
const pty = @import("pty.zig");
const module = @import("module.zig");

/// Max bytes per master read. `beforeRead` modules may shrink it per-read
/// (fault injection); they can never grow it past this.
pub const read_buf_size: usize = 4096;

/// Convenience re-exports so callers import only `ttysnap`.
pub const KV = pty.KV;
pub const SessionInfo = module.SessionInfo;
pub const Grid = module.Grid;

pub fn Harness(comptime modules: anytype) type {
    const N = modules.len;

    return struct {
        const Self = @This();

        /// One `*Runtime` per module — heap-pinned for stable addresses, same
        /// rationale as Dispatcher/PanelHost.
        pub const Runtimes = blk: {
            var types: [N]type = undefined;
            for (modules, 0..) |M, i| types[i] = *M.Runtime;
            break :blk std.meta.Tuple(&types);
        };

        pub const Opts = struct {
            argv: []const []const u8,
            cols: u16 = 80,
            rows: u16 = 24,
            env: []const pty.KV = &.{},
        };

        allocator: Allocator,
        child: pty.Child,
        grid: vt.Grid,
        cols: u16,
        rows: u16,
        rts: Runtimes,
        /// Scratch for rendering the grid to text (for `waitFor`/`gridContains`).
        text_buf: []u8,
        exited: bool = false,
        exit_status: u32 = 0,

        // ---- construction / teardown --------------------------------------

        pub fn spawn(allocator: Allocator, opts: Opts) !Self {
            var child = try pty.spawn(allocator, .{
                .argv = opts.argv,
                .cols = opts.cols,
                .rows = opts.rows,
                .env = opts.env,
            });
            errdefer child.deinit();

            var grid = try vt.Grid.init(allocator, opts.rows, opts.cols);
            errdefer grid.deinit();

            // 4 bytes/cell is the max for one UTF-8 codepoint (vt renders one
            // codepoint per cell) + a newline per row — so renderText never
            // truncates, even on a screen full of multi-byte glyphs.
            const text_buf = try allocator.alloc(u8, (@as(usize, opts.cols) * 4 + 1) * (@as(usize, opts.rows) + 1));
            errdefer allocator.free(text_buf);

            const info = module.SessionInfo{ .argv = opts.argv, .cols = opts.cols, .rows = opts.rows };
            var rts: Runtimes = undefined;
            var attached: usize = 0;
            errdefer detachUpTo(allocator, &rts, attached);
            inline for (modules, 0..) |M, i| {
                const slot = try allocator.create(M.Runtime);
                slot.* = M.attach(allocator, info) catch |e| {
                    allocator.destroy(slot);
                    return e;
                };
                rts[i] = slot;
                attached = i + 1;
            }

            return .{
                .allocator = allocator,
                .child = child,
                .grid = grid,
                .cols = opts.cols,
                .rows = opts.rows,
                .rts = rts,
                .text_buf = text_buf,
            };
        }

        pub fn deinit(self: *Self) void {
            if (!self.exited) self.terminate();
            detachUpTo(self.allocator, &self.rts, N);
            self.allocator.free(self.text_buf);
            self.grid.deinit();
            self.child.deinit();
            self.* = undefined;
        }

        fn detachUpTo(allocator: Allocator, rts: *Runtimes, n: usize) void {
            inline for (modules, 0..) |M, i| {
                if (i < n) {
                    if (comptime @hasDecl(M, "detach")) M.detach(rts[i]);
                    allocator.destroy(rts[i]);
                }
            }
        }

        // ---- driving ------------------------------------------------------

        /// Send bytes to the child's stdin. Fans `onInput`, then writes to the
        /// (non-blocking) master, pumping output if the write would block.
        pub fn send(self: *Self, bytes: []const u8) !void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onInput")) M.onInput(self.rts[i], bytes);
            }
            const deadline = monoMillis() + 2000;
            var written: usize = 0;
            while (written < bytes.len) {
                const rem = bytes[written..];
                const rc = std.c.write(self.child.master, rem.ptr, rem.len);
                if (rc < 0) {
                    const err = posix.errno(rc);
                    if (err == .AGAIN or err == .INTR) {
                        if (monoMillis() >= deadline) return error.WriteTimeout;
                        _ = try self.pumpMs(10);
                        continue;
                    }
                    return error.WriteFailed;
                }
                if (rc == 0) break;
                written += @intCast(rc);
            }
        }

        /// Pump output for up to `ms`. Returns true if any bytes were read.
        /// The read is capped by the smallest `beforeRead` any module requests;
        /// the chunk is fed to the grid, then fanned to `onOutput` + `onFrame`.
        pub fn pumpMs(self: *Self, ms: i32) !bool {
            var pfd = [_]posix.pollfd{.{ .fd = self.child.master, .events = posix.POLL.IN, .revents = 0 }};
            const n = posix.poll(&pfd, ms) catch 0;
            if (n == 0) {
                self.reapIfDone();
                return false;
            }
            if (pfd[0].revents & posix.POLL.IN != 0) {
                var buf: [read_buf_size]u8 = undefined;
                const cap = self.readCap();
                const r = posix.read(self.child.master, buf[0..cap]) catch |e| switch (e) {
                    error.WouldBlock => return false,
                    error.InputOutput => { // slave closed — child likely gone
                        self.reapIfDone();
                        return false;
                    },
                    else => return e,
                };
                if (r == 0) {
                    self.reapIfDone();
                    return false;
                }
                const chunk = buf[0..r];
                self.grid.feed(chunk);
                inline for (modules, 0..) |M, i| {
                    if (comptime @hasDecl(M, "onOutput")) M.onOutput(self.rts[i], chunk);
                }
                inline for (modules, 0..) |M, i| {
                    if (comptime @hasDecl(M, "onFrame")) M.onFrame(self.rts[i], &self.grid);
                }
                return true;
            }
            if (pfd[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) self.reapIfDone();
            return false;
        }

        /// Smallest read cap any `beforeRead` module asks for (default: the
        /// full buffer). Never returns 0 — a zero-length read is meaningless.
        fn readCap(self: *Self) usize {
            var cap: usize = read_buf_size;
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "beforeRead")) {
                    const c = M.beforeRead(self.rts[i], read_buf_size);
                    if (c < cap) cap = c;
                }
            }
            return if (cap == 0) 1 else cap;
        }

        // ---- waiting / querying -------------------------------------------

        /// Render the current screen to `text_buf` and return it.
        pub fn gridText(self: *Self) []const u8 {
            var w = std.Io.Writer.fixed(self.text_buf);
            self.grid.renderText(&w) catch {};
            return self.text_buf[0..w.end];
        }

        /// True if `needle` is anywhere on the current rendered screen.
        pub fn gridContains(self: *Self, needle: []const u8) bool {
            return std.mem.indexOf(u8, self.gridText(), needle) != null;
        }

        /// Pump until `needle` appears on screen or `timeout_ms` elapses.
        pub fn waitFor(self: *Self, needle: []const u8, timeout_ms: u32) !bool {
            const deadline = monoMillis() + @as(i64, timeout_ms);
            while (true) {
                if (self.gridContains(needle)) return true;
                const remaining = deadline - monoMillis();
                if (remaining <= 0) return self.gridContains(needle);
                _ = try self.pumpMs(@intCast(@min(remaining, 50)));
                if (self.exited and !self.gridContains(needle)) {
                    // One last drain so output racing the exit is still seen.
                    while (try self.pumpMs(0)) {}
                    return self.gridContains(needle);
                }
            }
        }

        /// Pump until `needle` is ABSENT or `timeout_ms` elapses.
        pub fn waitForAbsent(self: *Self, needle: []const u8, timeout_ms: u32) !bool {
            const deadline = monoMillis() + @as(i64, timeout_ms);
            while (self.gridContains(needle)) {
                if (monoMillis() >= deadline) return !self.gridContains(needle);
                if (self.exited) { // child gone: drain, then the screen can't change
                    while (try self.pumpMs(0)) {}
                    return !self.gridContains(needle);
                }
                _ = try self.pumpMs(@intCast(@min(deadline - monoMillis(), 50)));
            }
            return true;
        }

        /// Pump until the output has been quiet for `quiet_ms`, or `timeout_ms`
        /// elapses. Returns true if it settled (false = timed out still noisy).
        pub fn waitStable(self: *Self, quiet_ms: u32, timeout_ms: u32) !bool {
            const deadline = monoMillis() + @as(i64, timeout_ms);
            var quiet_since = monoMillis();
            while (true) {
                if (monoMillis() - quiet_since >= quiet_ms) return true;
                if (monoMillis() >= deadline) return false;
                const got = try self.pumpMs(@intCast(@min(quiet_ms, 25)));
                if (got) quiet_since = monoMillis();
                if (self.exited) {
                    while (try self.pumpMs(0)) {} // drain final output
                    return true; // child gone → the screen is permanently stable
                }
            }
        }

        /// A named checkpoint: fan `onSnapshot` to every module (recorders
        /// capture, the snapshotter compares against a golden). The first
        /// module error (e.g. a golden mismatch) fails the run.
        pub fn snapshot(self: *Self, name: []const u8) !void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onSnapshot")) try M.onSnapshot(self.rts[i], name, &self.grid);
            }
        }

        // ---- exit ---------------------------------------------------------

        /// Pump until the child exits or `timeout_ms` elapses. Returns the raw
        /// wait status, or null on timeout — so a hung child is distinguishable
        /// from a clean exit 0. Fans `onExit` once when the child is reaped.
        pub fn waitExit(self: *Self, timeout_ms: u32) !?u32 {
            const deadline = monoMillis() + @as(i64, timeout_ms);
            while (!self.exited and monoMillis() < deadline) {
                _ = try self.pumpMs(@intCast(@min(deadline - monoMillis(), 50)));
            }
            return if (self.exited) self.exit_status else null;
        }

        fn reapIfDone(self: *Self) void {
            if (self.exited) return;
            var status: u32 = 0;
            if (linux.waitpid(self.child.pid, &status, linux.W.NOHANG) == self.child.pid) {
                self.markExited(status);
            }
        }

        fn markExited(self: *Self, status: u32) void {
            if (self.exited) return; // idempotent — onExit fires once, status set once
            self.exited = true;
            self.exit_status = status;
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onExit")) M.onExit(self.rts[i], status);
            }
        }

        fn terminate(self: *Self) void {
            if (self.exited) return;
            _ = posix.kill(self.child.pid, posix.SIG.TERM) catch {};
            const deadline = monoMillis() + 200;
            while (monoMillis() < deadline) {
                var status: u32 = 0;
                if (linux.waitpid(self.child.pid, &status, linux.W.NOHANG) == self.child.pid) {
                    self.markExited(status);
                    return;
                }
                _ = self.pumpMs(20) catch {};
                if (self.exited) return; // pumpMs's reapIfDone may have caught it —
                // don't fall through to KILL + a second reap of a dead PID
            }
            _ = posix.kill(self.child.pid, posix.SIG.KILL) catch {};
            var status: u32 = 0;
            _ = linux.waitpid(self.child.pid, &status, 0);
            self.markExited(status);
        }
    };
}

/// Monotonic milliseconds for deadlines — aliases the contract's clock.
pub const monoMillis = module.nowMs;

test {
    _ = @import("ttysnap_tests.zig");
}
