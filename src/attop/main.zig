//! attop — the atty dashboard.
//!
//! A standalone TUI (the "Grafana" of atty) that reads the atty-guard
//! metrics API and answers, at a glance: am I protected, what is atty
//! doing for me, is everything healthy. It is NOT part of the hot-path
//! proxy — it reuses the `atty` module's style/ansi primitives but runs as
//! its own binary, talking to the daemon over the UDS. See
//! docs/dashboard.md for the design.
//!
//! `main` drives the live loop: poll get_metrics on a cadence, render the
//! Home screen, handle keys, and restore the terminal on every exit path.

const std = @import("std");
const atty = @import("atty");
const term = @import("term.zig");
const uds = @import("uds.zig");
const home = @import("home.zig");
const posix = std.posix;

// Force-analyze the atty-module reuse so the cross-binary import wiring
// compiles (home.zig consumes atty.style).
comptime {
    _ = atty.Style;
    _ = atty.ansi;
}

/// Refresh cadence: poll stdin this long; on timeout, re-fetch + repaint.
const refresh_ms: i32 = 1500;
/// Per-request budget for the get_metrics round-trip (off the UI tempo).
const fetch_timeout_ms: u32 = 200;

pub fn main() void {
    // attop is a full-screen TUI — it needs a real terminal. Without one
    // (piped / redirected) print the banner + bail rather than emit raw
    // escapes into a pipe.
    if (!term.isatty(posix.STDOUT_FILENO)) {
        var buf: [160]u8 = undefined;
        const line = banner(&buf, std.c.getenv("ATTY") != null);
        _ = std.c.write(posix.STDOUT_FILENO, line.ptr, line.len);
        return;
    }
    runLoop();
}

fn runLoop() void {
    const out = posix.STDOUT_FILENO;
    // Raw mode on stdin (fails cleanly if stdin isn't a tty — e.g. input
    // redirected). The guard restores the original termios on deinit.
    var raw = term.RawMode.enter(posix.STDIN_FILENO) catch return;
    defer raw.deinit();
    // Alt-screen + hide cursor; the defer restores on EVERY exit path
    // (quit key, EOF, error), so the user's shell is never left wedged.
    _ = std.c.write(out, term.enter_screen.ptr, term.enter_screen.len);
    defer _ = std.c.write(out, term.exit_screen.ptr, term.exit_screen.len);
    term.installWinch();

    // Self-pipe: SIGTERM/SIGHUP/SIGINT wake the loop so it returns on its
    // normal path and the teardown defers run (no wedged terminal on kill /
    // terminal-close). Best-effort — if the pipe can't be made, we just run
    // without the trap.
    var sigpipe: [2]c_int = undefined;
    const have_sigpipe = std.c.pipe(&sigpipe) == 0;
    defer if (have_sigpipe) {
        _ = std.c.close(sigpipe[0]);
        _ = std.c.close(sigpipe[1]);
    };
    const quit_r: i32 = if (have_sigpipe) sigpipe[0] else -1;
    if (have_sigpipe) term.installQuitSignals(sigpipe[1]);

    const sock = uds.socketPath();
    var framebuf: [16384]u8 = undefined;
    var sz = term.size(out);

    while (true) {
        if (term.resized.swap(false, .seq_cst)) sz = term.size(out);

        // Fetch (best-effort) + render. A per-iteration arena owns the JSON
        // parse; renderHome copies what it needs into framebuf before the
        // arena is freed, so the frame write below is safe.
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const parsed = uds.fetch(arena.allocator(), sock, fetch_timeout_ms);
            const metrics: ?uds.Metrics = if (parsed) |p| p.value else null;
            const frame = home.renderHome(&framebuf, metrics, sz.cols, sz.rows);
            _ = std.c.write(out, frame.ptr, frame.len);
        }

        // Wait for a key, a terminating signal, or the refresh tick. A
        // fd of -1 (no sigpipe) is ignored by poll.
        var pfds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = quit_r, .events = posix.POLL.IN, .revents = 0 },
        };
        if (std.c.poll(&pfds, 2, refresh_ms) > 0) {
            if (quit_r >= 0 and (pfds[1].revents & posix.POLL.IN) != 0) return; // signal → teardown
            if ((pfds[0].revents & posix.POLL.IN) != 0) {
                var b: [8]u8 = undefined;
                const n = std.c.read(posix.STDIN_FILENO, &b, b.len);
                if (n <= 0) return; // EOF / error → restore + exit
                if (isQuit(b[0..@intCast(n)])) return;
                // Other keys (h/j/k/l, arrows, ?) are nav/help stubs — the
                // panels land in the next P2 step; ignore for now.
            }
        }
    }
}

/// Quit on a lone `q`, Ctrl-C (0x03), or a BARE Esc — but not a multi-byte
/// Esc sequence (arrow keys etc. start with Esc and are nav, not quit).
pub fn isQuit(input: []const u8) bool {
    if (input.len == 1) return input[0] == 'q' or input[0] == 0x03 or input[0] == 0x1b;
    return false;
}

/// The startup line. Pure (no I/O) so it's unit-testable without a TTY.
/// attop is session-aware — it notes when launched beneath atty; the
/// embedded doctor health-check + the Fleet current-session highlight
/// build on this detection.
pub fn banner(buf: []u8, under_atty: bool) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "attop — atty dashboard{s}\n" ++
            "Needs an interactive terminal; stdout is not a TTY.\n",
        .{if (under_atty) " \u{B7} in atty session" else ""},
    ) catch "attop — atty dashboard\nNeeds an interactive terminal.\n";
}

test {
    _ = @import("main_tests.zig");
    _ = @import("term.zig");
    _ = @import("uds.zig");
    _ = @import("home.zig");
}
