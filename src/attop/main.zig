//! attop — the atty dashboard.
//!
//! A standalone interactive TUI (the "Grafana" of atty) that reads the
//! atty-guard metrics API and answers, at a glance: am I protected, what
//! is atty doing for me, is everything healthy. It is NOT part of the
//! hot-path proxy — it reuses the `atty` module's style/ansi primitives but
//! runs as its own binary, talking to the daemon over the UDS. See
//! docs/dashboard.md.
//!
//! The UI is composed Suckless-style from a comptime tuple of PANELS
//! (config.zig → `panels`), walked by `PanelHost` (panel_host.zig) — the
//! dashboard analog of the proxy's modules + `Dispatcher`. `main` drives
//! the live loop: fetch daemon data on a cadence + cache it, render the
//! focused panel on every keystroke (instant), route keys (focus nav +
//! the focused panel's `onKey`), and restore the terminal on every exit.

const std = @import("std");
const atty = @import("atty");
const term = @import("term.zig");
const uds = @import("uds.zig");
const caps = @import("caps.zig");
const theme = @import("theme.zig");
const i18n = @import("i18n.zig");
const panel = @import("panel.zig");
const key = @import("key.zig");
const config = @import("config.zig");
const frame_mod = @import("frame.zig");
const PanelHost = @import("panel_host.zig").PanelHost;
const posix = std.posix;

// Force-analyze the atty-module reuse so the cross-binary import wiring
// compiles (the panels consume atty.style).
comptime {
    _ = atty.Style;
    _ = atty.ansi;
}

/// The dashboard, specialised on the configured panel tuple.
const Host = PanelHost(config.panels);

/// Re-fetch daemon data this often (poll timeout). Rendering happens on
/// every keystroke regardless, off the cached data — so interactivity is
/// instant and only the live metrics lag by at most one tick.
const refresh_ms: i32 = 1500;
/// Per-request budget for a UDS round-trip (kept off the UI tempo).
const fetch_timeout_ms: u32 = 200;

/// Synchronized-output (DECSET 2026): brackets a frame so a supporting
/// terminal (Ghostty, kitty, foot, WezTerm) swaps it atomically — no
/// clear-then-repaint flicker even though we render on every keystroke.
/// Terminals that don't grok it ignore the markers harmlessly.
const begin_sync = "\x1b[?2026h";
const end_sync = "\x1b[?2026l";

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

/// Mutable dashboard state for one run. Holds the panel runtimes, the
/// cached daemon snapshot, focus, and the frame buffer.
const App = struct {
    rts: Host.Runtimes,
    focus: usize = 0,
    host: panel.Host,
    sock: []const u8,
    sz: term.Size,
    out: i32,
    /// Owns the current daemon snapshot; reset + refilled by `refetch`.
    fetch_arena: std.heap.ArenaAllocator,
    cur_metrics: ?uds.Metrics = null,
    cur_instances: ?[]const uds.Instance = null,
    framebuf: [65536]u8 = undefined,
    /// Diff state + the buffer the row-diff ops are emitted into.
    frame: frame_mod.Frame = .{},
    diffbuf: [131072]u8 = undefined,

    fn ctx(self: *App, frame_arena: std.mem.Allocator, focused: bool) panel.Ctx {
        return .{
            .metrics = self.cur_metrics,
            .instances = self.cur_instances,
            .host = self.host,
            .cols = self.sz.cols,
            .rows = self.sz.rows,
            .focused = focused,
            .arena = frame_arena,
        };
    }

    /// Re-poll the daemon. Resets the snapshot arena first; the parsed
    /// values live in it until the next refetch (callers render between
    /// fetches, so the cache stays valid).
    fn refetch(self: *App) void {
        _ = self.fetch_arena.reset(.retain_capacity);
        const a = self.fetch_arena.allocator();
        self.cur_metrics = metricsOf(uds.fetch(a, self.sock, fetch_timeout_ms));
        self.cur_instances = instancesOf(uds.listInstances(a, self.sock, fetch_timeout_ms));
    }

    /// Paint the new frame, then emit only the rows that changed (diff
    /// render) bracketed by synchronized-output markers. The markers are
    /// SEPARATE writes so `end_sync` always lands even if the diff buffer
    /// overflowed — otherwise the terminal could stay stuck in
    /// synchronized-update mode (a frozen display). Diffing means a keystroke
    /// or a metric tick rewrites a row or two, not the whole screen — no
    /// flicker.
    fn render(self: *App) void {
        var frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer frame_arena.deinit();
        var pw = std.Io.Writer.fixed(&self.framebuf);
        self.paint(&pw, frame_arena.allocator()) catch {};

        var dw = std.Io.Writer.fixed(&self.diffbuf);
        self.frame.diff(self.framebuf[0..pw.end], self.sz.rows, &dw) catch {};

        _ = std.c.write(self.out, begin_sync.ptr, begin_sync.len);
        const bytes = self.diffbuf[0..dw.end];
        _ = std.c.write(self.out, bytes.ptr, bytes.len);
        _ = std.c.write(self.out, end_sync.ptr, end_sync.len);
    }

    fn paint(self: *App, w: *std.Io.Writer, frame_arena: std.mem.Allocator) !void {
        try paintTabBar(w, self.focus);

        // Focused panel content.
        var pctx = self.ctx(frame_arena, true);
        try Host.renderAt(&self.rts, &pctx, self.focus, w);

        // Footer: the focused panel's own hint (if any) + the global legend.
        const t = theme.active;
        try w.writeAll("\r\n");
        if (Host.footerHintAt(&self.rts, &pctx, self.focus)) |hint| {
            try w.print("  {f}{s}{s}\r\n", .{ t.muted, hint, atty.style.reset });
        }
        try w.print("  {f}Tab/\u{2190}\u{2192} switch \u{b7} q quit{s}\r\n", .{ t.muted, atty.style.reset });
    }
};

/// Render the tab bar: every panel as `[<key>]<title>`, the focused one in
/// reverse video so it reads as "you are here" regardless of theme. Pure
/// (Host comptime metadata + the active theme) — unit-testable.
pub fn paintTabBar(w: *std.Io.Writer, focus: usize) !void {
    const t = theme.active;
    var i: usize = 0;
    while (i < Host.count) : (i += 1) {
        const title = Host.titleAt(i);
        const nk = Host.navKeyAt(i);
        if (i == focus) {
            try w.print(" \x1b[7m [{c}]{s} \x1b[27m", .{ nk, title });
        } else {
            try w.print(" {f}[{c}]{s}{s}", .{ t.muted, nk, title, atty.style.reset });
        }
    }
    try w.writeAll("\r\n\r\n");
}

fn runLoop() void {
    // Resolve the palette/glyph set + locale once; panels read the globals.
    theme.active = theme.resolve();
    i18n.active = i18n.resolve();
    const out = posix.STDOUT_FILENO;

    var raw = term.RawMode.enter(posix.STDIN_FILENO) catch {
        const msg = "attop needs an interactive terminal (stdin is not a TTY)\n";
        _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        return;
    };
    defer raw.deinit();
    _ = std.c.write(out, term.enter_screen.ptr, term.enter_screen.len);
    defer _ = std.c.write(out, term.exit_screen.ptr, term.exit_screen.len);
    term.installWinch();

    // Self-pipe so terminating signals wake the loop → it returns on its
    // normal path and the teardown defers run (no wedged terminal).
    var sigpipe: [2]c_int = undefined;
    const have_sigpipe = std.c.pipe2(&sigpipe, .{ .CLOEXEC = true, .NONBLOCK = true }) == 0;
    defer if (have_sigpipe) {
        _ = std.c.close(sigpipe[0]);
        _ = std.c.close(sigpipe[1]);
    };
    const quit_r: i32 = if (have_sigpipe) sigpipe[0] else -1;
    if (have_sigpipe) term.installQuitSignals(sigpipe[1]);

    // Attach the panel runtimes (tiny; heap-pinned for stable addresses).
    const palloc = std.heap.page_allocator;
    var rts = Host.attachAll(palloc) catch return;
    defer Host.detachAll(palloc, &rts);

    var app = App{
        .rts = rts,
        .host = .{
            .atty_on_path = caps.attyOnPath(),
            .under_atty = caps.underAtty(),
            .shell_integrated = caps.shellIntegrated(),
            .shell_name = caps.shellName(),
        },
        .sock = uds.socketPath(),
        .sz = term.size(out),
        .out = out,
        .fetch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer app.fetch_arena.deinit();

    app.refetch();
    // Landing focus: the first panel that votes for it (Setup, when the
    // stack isn't ready), else panel 0. A dedicated scratch arena — never
    // the cache arena, which `refetch` resets out from under any panel
    // allocation (see panel.Ctx.arena's per-frame contract).
    {
        var la = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer la.deinit();
        var lctx = app.ctx(la.allocator(), true);
        app.focus = Host.landingIndex(&lctx);
    }
    app.render();

    while (true) {
        if (term.resized.swap(false, .seq_cst)) {
            app.sz = term.size(out);
            app.frame.invalidate(); // row positions shift → full repaint
            app.render();
        }

        var pfds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = quit_r, .events = posix.POLL.IN, .revents = 0 },
        };
        const pr = std.c.poll(&pfds, 2, refresh_ms);
        if (pr > 0) {
            if (quit_r >= 0 and (pfds[1].revents & posix.POLL.IN) != 0) return; // signal
            if ((pfds[0].revents & posix.POLL.IN) != 0) {
                var b: [64]u8 = undefined;
                const n = std.c.read(posix.STDIN_FILENO, &b, b.len);
                if (n <= 0) return; // EOF / error → restore + exit
                if (handleRead(&app, b[0..@intCast(n)])) return; // quit requested
                app.render();
            }
        } else if (pr == 0) {
            app.refetch();
            // Dedicated scratch arena (not the cache arena — see landing).
            var ta = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer ta.deinit();
            var tctx = app.ctx(ta.allocator(), true);
            Host.tickAll(&app.rts, &tctx, app.focus, @intCast(refresh_ms)) catch {};
            app.render();
        }
    }
}

/// Decode + handle every key in one read. Returns true when the user asked
/// to quit. The focused panel sees each key FIRST (so a panel can claim
/// keys, e.g. Setup's wire gate); unclaimed keys fall through to global
/// focus navigation. Ctrl-C always quits.
fn handleRead(app: *App, bytes: []const u8) bool {
    var i: usize = 0;
    while (key.decode(bytes[i..])) |d| {
        i += d.len;
        if (handleKey(app, d.key)) return true;
    }
    return false;
}

fn handleKey(app: *App, k: panel.Key) bool {
    // Universal escape hatch — never trapped by a panel.
    switch (k) {
        .ctrl => |c| if (c == 'c') return true,
        else => {},
    }

    var frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer frame_arena.deinit();
    var pctx = app.ctx(frame_arena.allocator(), true);

    const action = Host.keyAt(&app.rts, &pctx, app.focus, k) catch panel.Action.pass;
    switch (action) {
        .quit => return true,
        .handled => return false,
        .refresh => {
            app.refetch();
            return false;
        },
        .pass => {}, // fall through to global handling
    }

    // Global handling for keys the focused panel didn't claim.
    switch (k) {
        .tab, .right => app.focus = (app.focus + 1) % Host.count,
        .back_tab, .left => app.focus = (app.focus + Host.count - 1) % Host.count,
        .char => |c| {
            if (c == 'q') return true;
            if (Host.indexForKey(c)) |idx| app.focus = idx;
        },
        else => {},
    }
    return false;
}

/// Extract the Metrics from a Parsed (no deinit — the caller's arena owns
/// the allocation). null passes through.
fn metricsOf(p: ?std.json.Parsed(uds.Metrics)) ?uds.Metrics {
    return if (p) |x| x.value else null;
}

/// Extract the instance slice from a list_instances Parsed.
fn instancesOf(p: ?std.json.Parsed(uds.InstancesReply)) ?[]const uds.Instance {
    return if (p) |x| x.value.instances else null;
}

/// The startup line. Pure (no I/O) so it's unit-testable without a TTY.
/// attop is session-aware — it notes when launched beneath atty.
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
    _ = @import("key.zig");
    _ = @import("panel.zig");
    _ = @import("panel_host.zig");
    _ = @import("list.zig");
    _ = @import("box.zig");
    _ = @import("frame.zig");
    _ = @import("home.zig");
    _ = @import("guard.zig");
    _ = @import("fleet.zig");
    _ = @import("setup.zig");
    _ = @import("help.zig");
    _ = @import("caps.zig");
    _ = @import("rc_writer.zig");
    _ = @import("rc_apply.zig");
    _ = @import("screenshot_tests.zig");
    _ = @import("theme.zig");
    _ = @import("i18n.zig");
}
