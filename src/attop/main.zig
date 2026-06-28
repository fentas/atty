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
const guard = @import("guard.zig");
const fleet = @import("fleet.zig");
const setup = @import("setup.zig");
const help = @import("help.zig");
const caps = @import("caps.zig");
const theme = @import("theme.zig");
const i18n = @import("i18n.zig");
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
        const line = banner(&buf, caps.underAtty());
        _ = std.c.write(posix.STDOUT_FILENO, line.ptr, line.len);
        return;
    }
    runLoop();
}

fn runLoop() void {
    // Resolve the palette/glyph set + locale once. The renders read
    // theme.active / i18n.active.
    theme.active = theme.resolve();
    i18n.active = i18n.resolve();
    const out = posix.STDOUT_FILENO;
    // Raw mode on stdin. If stdin isn't a tty (e.g. `echo x | attop`),
    // say so instead of exiting silently — the stdout-tty guard alone
    // wouldn't have caught this.
    var raw = term.RawMode.enter(posix.STDIN_FILENO) catch {
        const msg = "attop needs an interactive terminal (stdin is not a TTY)\n";
        _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        return;
    };
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
    // NONBLOCK so the signal handler's write can never block (a full pipe
    // just drops the byte — one wake suffices); CLOEXEC for hygiene.
    // Mirrors the proxy's own signal self-pipe (proxy.zig).
    const have_sigpipe = std.c.pipe2(&sigpipe, .{ .CLOEXEC = true, .NONBLOCK = true }) == 0;
    defer if (have_sigpipe) {
        _ = std.c.close(sigpipe[0]);
        _ = std.c.close(sigpipe[1]);
    };
    const quit_r: i32 = if (have_sigpipe) sigpipe[0] else -1;
    if (have_sigpipe) term.installQuitSignals(sigpipe[1]);

    const sock = uds.socketPath();
    // Fixed for the session — attop is launched once, in or out of atty.
    const under_atty = caps.underAtty();
    const atty_on_path = caps.attyOnPath();
    // Sized to hold a full Fleet render of a large reply (matches uds's
    // 64KiB read buffer). Per-row capping to the visible height is a future
    // polish; for now a big fleet renders complete (the terminal scrolls).
    var framebuf: [65536]u8 = undefined;
    var sz = term.size(out);
    // Land on the Setup/wizard when the stack isn't ready (atty not
    // installed, or the daemon unreachable on a one-shot probe) — else Home.
    var screen: Screen = blk: {
        if (!atty_on_path) break :blk .setup;
        var probe = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer probe.deinit();
        break :blk if (uds.fetch(probe.allocator(), sock, fetch_timeout_ms) != null) .home else .setup;
    };
    const footer = "\r\n  \x1b[2m[h]ome  [g]uard  [f]leet  [s]etup  [?]help  q quit\x1b[0m\r\n";

    while (true) {
        if (term.resized.swap(false, .seq_cst)) sz = term.size(out);

        // Fetch (best-effort) + render the active screen. A per-iteration
        // arena owns the JSON parse; the render copies what it needs into
        // framebuf before the arena is freed, so the writes below are safe.
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            // Each screen fetches only what it needs (Home/Guard →
            // get_metrics, Fleet → list_instances). The Parsed lives in the
            // arena; the render copies into framebuf before it's freed.
            const frame = switch (screen) {
                .home => home.renderHome(&framebuf, metricsOf(uds.fetch(a, sock, fetch_timeout_ms)), sz.cols, sz.rows),
                .guard => guard.renderGuard(&framebuf, metricsOf(uds.fetch(a, sock, fetch_timeout_ms)), sz.cols, sz.rows),
                .fleet => fleet.renderFleet(&framebuf, instancesOf(uds.listInstances(a, sock, fetch_timeout_ms)), sz.cols, sz.rows),
                .setup => setup.renderSetup(&framebuf, metricsOf(uds.fetch(a, sock, fetch_timeout_ms)), atty_on_path, under_atty, sz.cols, sz.rows),
                .help => help.renderHelp(&framebuf, sz.cols, sz.rows),
            };
            _ = std.c.write(out, frame.ptr, frame.len);
            _ = std.c.write(out, footer.ptr, footer.len);
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
                switch (classifyInput(b[0..@intCast(n)])) {
                    .quit => return, // restore + exit
                    .home => screen = .home,
                    .guard => screen = .guard,
                    .fleet => screen = .fleet,
                    .setup => screen = .setup,
                    .help => screen = .help,
                    .none => {}, // nav (j/k, arrows) — stubs for now
                }
            }
        }
    }
}

pub const Screen = enum { home, guard, fleet, setup, help };

pub const Input = enum { none, quit, home, guard, fleet, setup, help };

/// Extract the Metrics from a Parsed (no deinit — the caller's arena owns
/// the allocation). null passes through.
fn metricsOf(p: ?std.json.Parsed(uds.Metrics)) ?uds.Metrics {
    return if (p) |x| x.value else null;
}

/// Extract the instance slice from a list_instances Parsed.
fn instancesOf(p: ?std.json.Parsed(uds.InstancesReply)) ?[]const uds.Instance {
    return if (p) |x| x.value.instances else null;
}

/// Classify a raw-mode read into one action. Quit is `q` or Ctrl-C only —
/// NOT Esc: a terminal can deliver an arrow key's `\x1b[A` split across
/// reads (the bare `\x1b` first, over a slow ssh link), so quitting on a
/// lone Esc would false-fire. A multi-byte read starting with Esc is a
/// CSI/SS3 sequence → none (nav stub). The first recognized command byte
/// wins, so a fast multi-key burst (read() can return >1 byte) still acts.
pub fn classifyInput(keys: []const u8) Input {
    if (keys.len == 0) return .none;
    if (keys.len > 1 and keys[0] == 0x1b) return .none; // Esc-sequence → nav
    for (keys) |k| switch (k) {
        'q', 0x03 => return .quit,
        'g' => return .guard,
        'h' => return .home,
        'f' => return .fleet,
        's' => return .setup,
        '?' => return .help,
        else => {},
    };
    return .none;
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
    _ = @import("guard.zig");
    _ = @import("fleet.zig");
    _ = @import("setup.zig");
    _ = @import("help.zig");
    _ = @import("caps.zig");
    _ = @import("screenshot_tests.zig");
    _ = @import("theme.zig");
    _ = @import("i18n.zig");
}
