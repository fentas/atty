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
        const fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        return .{ .read = fds[0], .write = fds[1] };
    }

    fn deinit(self: *SignalPipe) void {
        posix.close(self.read);
        posix.close(self.write);
    }
};

var g_sig_pipe_write: posix.fd_t = -1;

fn sigHandler(sig: c_int) callconv(.C) void {
    if (g_sig_pipe_write < 0) return;
    const tag: [1]u8 = .{@intCast(sig & 0xFF)};
    _ = std.c.write(g_sig_pipe_write, &tag, 1);
}

fn installSignalHandlers() !void {
    var sa = posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = posix.empty_sigset,
        .flags = posix.SA.RESTART,
    };
    try posix.sigaction(posix.SIG.WINCH, &sa, null);
    try posix.sigaction(posix.SIG.CHLD, &sa, null);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(allocator: std.mem.Allocator, args: Args) !ExitInfo {
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

    try installSignalHandlers();

    const empty_envp: [*:null]const ?[*:0]const u8 = @ptrCast(&[_:null]?[*:0]const u8{});
    const child_pid = try pty.spawn(args.argv, empty_envp);

    // --- Raw mode on our own stdin -----------------------------------------
    var raw_guard: ?RawMode = null;
    if (args.is_tty) {
        raw_guard = RawMode.enter(posix.STDIN_FILENO) catch null;
    }
    defer if (raw_guard) |*g| g.deinit();

    // --- Module runtimes ---------------------------------------------------
    var runtimes = try D.attachAll(allocator);
    defer D.detachAll(allocator, &runtimes);

    // --- Loop state --------------------------------------------------------
    var line_state = LineState{};
    var scratch = std.ArrayList(u8).init(allocator);
    defer scratch.deinit();
    try scratch.ensureTotalCapacity(buf_size);

    var ghost = Ghost.init(allocator);
    defer ghost.deinit();

    var ctx = module.Context{
        .allocator = allocator,
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
    const stdout = std.io.getStdOut();
    const stdout_writer = stdout.writer();

    var exit_code: u8 = 0;
    var child_alive = true;

    var last_tick_ms = std.time.milliTimestamp();

    while (child_alive) {
        const n = try posix.poll(&pfds, config.tick_interval_ms);

        // ---- timeout → tick ----------------------------------------------
        if (n == 0) {
            const now = std.time.milliTimestamp();
            const elapsed: u64 = @intCast(@max(0, now - last_tick_ms));
            last_tick_ms = now;
            D.dispatchTick(&runtimes, &ctx, elapsed) catch {};
            renderGhost(&runtimes, &ctx, &ghost, stdout_writer) catch {};
            continue;
        }

        // ---- stdin → dispatch → master -----------------------------------
        if (pfds[0].revents & POLLIN != 0) {
            const read_n = posix.read(posix.STDIN_FILENO, &read_buf) catch 0;
            if (read_n > 0) {
                const input = read_buf[0..read_n];

                if (ghost.visible) try ghost.clear(stdout_writer);
                _ = line_state.applyInput(input);

                const action = D.dispatchInput(&runtimes, &ctx, input) catch .forward;
                switch (action) {
                    .forward => try writeAll(pty.master, input),
                    .swallow => {},
                    .replace => |bytes| try writeAll(pty.master, bytes),
                }

                renderGhost(&runtimes, &ctx, &ghost, stdout_writer) catch {};
            }
        }

        // ---- master → dispatch → stdout ----------------------------------
        if (pfds[1].revents & POLLIN != 0) {
            const read_n = posix.read(pty.master, &read_buf) catch 0;
            if (read_n > 0) {
                const output = read_buf[0..read_n];

                if (ghost.visible) try ghost.clear(stdout_writer);
                D.dispatchOutput(&runtimes, &ctx, output) catch {};
                try writeAll(posix.STDOUT_FILENO, output);

                renderGhost(&runtimes, &ctx, &ghost, stdout_writer) catch {};
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
                const sig = sig_buf[i];
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
        const n = posix.write(fd, bytes[i..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.EndOfFile;
        i += n;
    }
}

/// Idempotent: renders the current best suggestion, or clears any
/// overlay if no module wants to show one (e.g. line is empty,
/// uncertain, or TTL expired).
fn renderGhost(rts: *D.Runtimes, ctx: *module.Context, ghost: *Ghost, writer: anytype) !void {
    if (!ctx.is_tty) return;

    if (ctx.line.uncertain) {
        if (ghost.visible) try ghost.clear(writer);
        return;
    }

    const sug_opt = D.gatherGhostText(rts, ctx) catch null;
    if (sug_opt) |sug| {
        if (sug.len > 0) {
            try ghost.show(writer, sug);
            return;
        }
    }
    if (ghost.visible) try ghost.clear(writer);
}
