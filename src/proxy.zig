//! The proxy event loop.
//!
//! Multiplexes:
//!   - stdin    (bytes from the user's keyboard)
//!   - master   (bytes from the child shell)
//!   - sig_pipe (self-pipe trick for SIGWINCH / SIGCHLD)
//!
//! On poll() timeout we fire `dispatchTick` so modules can do periodic
//! work (e.g. expire stale ghost-text). The tick interval is set in
//! config.zig and stays single-digit-millisecond cheap because the
//! comptime dispatcher unrolls the iteration.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const config = @import("config");
const dispatch = @import("dispatch.zig");
const module = @import("module.zig");

extern "c" fn clock_gettime(clk_id: c_int, tp: *posix.timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;

fn nowMs() i64 {
    var ts: posix.timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

const Pty = @import("pty.zig").Pty;
const RawMode = @import("terminal.zig").RawMode;
const LineState = @import("line_state.zig").LineState;
const Ghost = @import("ghost.zig").Ghost;
const ansi = @import("ansi.zig");

/// The single dispatcher specialisation used by the binary. Comptime
/// expansion of `config.modules` happens here.
const D = dispatch.Dispatcher(config.modules);

const buf_size = 4096;

pub const Args = struct {
    /// argv for the child process. Sentinel-terminated.
    argv: [*:null]const ?[*:0]const u8,
    /// True if stdout AND stdin are real TTYs.
    is_tty: bool,
};

pub const ExitInfo = struct {
    exit_code: u8,
};

// ---------------------------------------------------------------------------
// Self-pipe for async signal delivery into the poll loop.
// ---------------------------------------------------------------------------

const SignalPipe = struct {
    read: posix.fd_t,
    write: posix.fd_t,

    fn init() !SignalPipe {
        var fds: [2]posix.fd_t = undefined;
        const rc = std.c.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (rc != 0) return error.PipeFailed;
        return .{ .read = fds[0], .write = fds[1] };
    }

    fn deinit(self: *SignalPipe) void {
        _ = std.c.close(self.read);
        _ = std.c.close(self.write);
    }
};

var g_sig_pipe_write: posix.fd_t = -1;

fn sigHandler(sig: posix.SIG) callconv(.c) void {
    if (g_sig_pipe_write < 0) return;
    const tag: [1]u8 = .{@intCast(@intFromEnum(sig) & 0xFF)};
    _ = std.c.write(g_sig_pipe_write, &tag, 1);
}

fn installSignalHandlers() void {
    const sa = posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
    posix.sigaction(posix.SIG.CHLD, &sa, null);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: Args) !ExitInfo {
    // --- PTY + child --------------------------------------------------------
    var pty = try Pty.open(allocator);
    defer pty.deinit();

    if (args.is_tty) {
        if (Pty.querySize(posix.STDOUT_FILENO)) |s| {
            _ = pty.setSize(s) catch {};
        } else |_| {}
    }

    var sig_pipe = try SignalPipe.init();
    defer sig_pipe.deinit();
    g_sig_pipe_write = sig_pipe.write;
    defer g_sig_pipe_write = -1;

    installSignalHandlers();

    const empty_envp: [*:null]const ?[*:0]const u8 = @ptrCast(&[_:null]?[*:0]const u8{});
    const child_pid = try pty.spawn(args.argv, empty_envp);

    // --- Raw mode on our own stdin -----------------------------------------
    var raw_guard: ?RawMode = null;
    if (args.is_tty) {
        raw_guard = RawMode.enter(posix.STDIN_FILENO) catch null;
    }
    defer if (raw_guard) |*g| g.deinit();

    // --- Module runtimes ---------------------------------------------------
    var runtimes = try D.attachAll(allocator, io);
    defer D.detachAll(allocator, io, &runtimes);

    // --- Loop state --------------------------------------------------------
    var line_state = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(allocator);
    try scratch.ensureTotalCapacity(allocator, buf_size);

    var ghost = Ghost.init(allocator);
    defer ghost.deinit();

    var ctx = module.Context{
        .allocator = allocator,
        .io = io,
        .line = &line_state,
        .scratch = &scratch,
        .is_tty = args.is_tty,
    };

    var pfds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = POLLIN, .revents = 0 },
        .{ .fd = pty.master, .events = POLLIN, .revents = 0 },
        .{ .fd = sig_pipe.read, .events = POLLIN, .revents = 0 },
    };

    var read_buf: [buf_size]u8 = undefined;

    // Stdout assembly buffer + fixed Writer.
    //   • ANSI sequences (ghost overlay show/clear) are written into
    //     `out_buf` via the Writer, then flushed in one std.c.write.
    //   • Shell output bypasses the writer and goes straight to STDOUT.
    var out_buf: [buf_size]u8 = undefined;

    var exit_code: u8 = 0;
    var child_alive = true;

    var last_tick_ms = nowMs();

    while (child_alive) {
        const n = try posix.poll(&pfds, config.tick_interval_ms);

        // ---- timeout → tick ----------------------------------------------
        if (n == 0) {
            const now = nowMs();
            const elapsed: u64 = @intCast(@max(0, now - last_tick_ms));
            last_tick_ms = now;
            D.dispatchTick(&runtimes, &ctx, elapsed) catch {};
            renderGhost(&runtimes, &ctx, &ghost, &out_buf) catch {};
            continue;
        }

        // ---- stdin → dispatch → master -----------------------------------
        if (pfds[0].revents & POLLIN != 0) {
            const read_n = posix.read(posix.STDIN_FILENO, &read_buf) catch 0;
            if (read_n > 0) {
                var input: []const u8 = read_buf[0..read_n];

                // Accept-ghost keystroke: if the user's accept key
                // arrives while a ghost is visible and the line is
                // still certain, swap the keystroke for the suggestion
                // bytes — the rest of the loop then treats them as if
                // they were typed. Must happen BEFORE applyInput,
                // because a CSI like `ESC [ C` would otherwise mark
                // the line uncertain and we'd lose the chance to act.
                var accept_buf: [4096]u8 = undefined;
                for (config.bindings) |bind| {
                    if (bind.bytes.len == 0) continue;
                    if (!std.mem.eql(u8, input, bind.bytes)) continue;
                    switch (bind.action) {
                        .ghost_accept => {
                            if (ghost.visible and
                                !line_state.uncertain and
                                ghost.rendered.items.len > 0 and
                                ghost.rendered.items.len <= accept_buf.len)
                            {
                                const accept_n = ghost.rendered.items.len;
                                @memcpy(accept_buf[0..accept_n], ghost.rendered.items);
                                input = accept_buf[0..accept_n];
                            }
                        },
                    }
                    break;
                }

                if (ghost.visible) try clearGhost(&ghost, &out_buf);
                _ = line_state.applyInput(input);

                const action = D.dispatchInput(&runtimes, &ctx, input) catch .forward;
                switch (action) {
                    .forward => try writeAll(pty.master, input),
                    .swallow => {},
                    .replace => |bytes| try writeAll(pty.master, bytes),
                }

                // Fire onLineCommit if Enter was pressed during this read
                // and the pre-Enter line was non-empty and certain.
                if (line_state.lastCommitted()) |committed| {
                    if (!line_state.committed_was_uncertain)
                        D.dispatchLineCommit(&runtimes, &ctx, committed) catch {};
                    line_state.clearLastCommitted();
                }

                renderGhost(&runtimes, &ctx, &ghost, &out_buf) catch {};
            }
        }

        // ---- master → dispatch → stdout ----------------------------------
        if (pfds[1].revents & POLLIN != 0) {
            const read_n = posix.read(pty.master, &read_buf) catch 0;
            if (read_n > 0) {
                const output = read_buf[0..read_n];

                if (ghost.visible) try clearGhost(&ghost, &out_buf);
                D.dispatchOutput(&runtimes, &ctx, output) catch {};
                try writeAll(posix.STDOUT_FILENO, output);

                renderGhost(&runtimes, &ctx, &ghost, &out_buf) catch {};
            } else if (read_n == 0) {
                child_alive = false;
            }
        }
        if (pfds[1].revents & (POLLHUP | POLLERR) != 0) {
            child_alive = false;
        }

        // ---- signal pipe --------------------------------------------------
        if (pfds[2].revents & POLLIN != 0) {
            var sig_buf: [16]u8 = undefined;
            const sn = posix.read(sig_pipe.read, &sig_buf) catch 0;
            var i: usize = 0;
            while (i < sn) : (i += 1) {
                const sig: posix.SIG = @enumFromInt(sig_buf[i]);
                if (sig == posix.SIG.WINCH) {
                    if (Pty.querySize(posix.STDOUT_FILENO)) |s| {
                        _ = pty.setSize(s) catch {};
                    } else |_| {}
                } else if (sig == posix.SIG.CHLD) {
                    var status: u32 = 0;
                    const wp = std.os.linux.waitpid(child_pid, &status, std.os.linux.W.NOHANG);
                    if (wp == child_pid) {
                        child_alive = false;
                        exit_code = @intCast((status >> 8) & 0xFF);
                    }
                }
            }
        }
    }

    _ = posix.kill(child_pid, posix.SIG.HUP) catch {};
    var status: u32 = 0;
    _ = std.os.linux.waitpid(child_pid, &status, 0);

    return .{ .exit_code = exit_code };
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const POLLIN: i16 = 0x001;
const POLLHUP: i16 = 0x010;
const POLLERR: i16 = 0x008;

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = std.c.write(fd, bytes[i..].ptr, bytes.len - i);
        if (rc < 0) {
            // EINTR / EAGAIN are vanishingly rare on PTY master; retry.
            continue;
        }
        if (rc == 0) return error.EndOfFile;
        i += @intCast(rc);
    }
}

/// Render the current best suggestion (or clear the overlay if no
/// module wants one). Idempotent.
///
/// `out_buf` is a caller-owned scratch buffer; we wrap it in a fixed
/// `std.Io.Writer`, let the Ghost state machine emit ANSI bytes into
/// it, then flush in a single `std.c.write` syscall.
fn renderGhost(rts: *D.Runtimes, ctx: *module.Context, ghost: *Ghost, out_buf: []u8) !void {
    if (!ctx.is_tty) return;

    if (ctx.line.uncertain) {
        if (ghost.visible) try clearGhost(ghost, out_buf);
        return;
    }

    const sug_opt = D.gatherGhostText(rts, ctx) catch null;
    if (sug_opt) |sug| {
        if (sug.len > 0) {
            var w: std.Io.Writer = .fixed(out_buf);
            ghost.show(&w, sug) catch return;
            try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
            return;
        }
    }
    if (ghost.visible) try clearGhost(ghost, out_buf);
}

fn clearGhost(ghost: *Ghost, out_buf: []u8) !void {
    var w: std.Io.Writer = .fixed(out_buf);
    ghost.clear(&w) catch return;
    try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
}
