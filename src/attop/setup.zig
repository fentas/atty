//! attop Setup/Doctor screen (docs/dashboard.md Setup) — the embedded
//! health check. Answers "is my atty stack wired up?" with a checklist + a
//! one-line fix per failing/optional item, so onboarding + troubleshooting
//! live in the dashboard. PURE render (no I/O): the daemon metrics + the
//! host-detected `Host` caps (atty-on-PATH, under-atty, shell wiring) are
//! passed in.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");
const theme = @import("theme.zig");
const home = @import("home.zig");
const i18n = @import("i18n.zig");
const panel = @import("panel.zig");
const caps = @import("caps.zig");
const rc_writer = @import("rc_writer.zig");
const rc_apply = @import("rc_apply.zig");

const reset = atty.style.reset;

pub const compact_cols: u16 = 80;

const Status = enum { ok, bad, neutral };

/// Host-side capabilities attop detects locally (not from the daemon).
/// Canonical definition lives in the panel contract; re-exported here so
/// existing call sites (`renderSetup`, setup_tests) keep `setup.Host`.
pub const Host = panel.Host;

pub fn renderSetup(buf: []u8, m: ?uds.Metrics, host: Host, cols: u16, rows: u16) []const u8 {
    _ = rows;
    var w = std.Io.Writer.fixed(buf);
    draw(&w, m, host, cols) catch {};
    return buf[0..w.end];
}

fn draw(w: *std.Io.Writer, m: ?uds.Metrics, host: Host, cols: u16) !void {
    const t = theme.active;
    const s = i18n.active;
    if (cols < compact_cols) {
        try w.print("{f}Setup{s}\r\n\r\n", .{ t.title, reset });
    } else {
        try w.print("{f}Setup{s}{s}\r\n\r\n", .{ t.title, reset, s.suffix_health });
    }

    // atty itself first — the rest is moot if the proxy isn't installed.
    if (host.atty_on_path) {
        try row(w, t, .ok, "atty", s.st_installed, "");
    } else {
        try row(w, t, .bad, "atty", s.st_not_installed, s.fix_install_atty);
    }

    // When atty is installed, offer the consented [w] write; otherwise show
    // the manual command (the [w] write would point at an atty that isn't on
    // PATH yet — install it first via the atty row).
    if (host.shell_integrated) {
        try row(w, t, .ok, "shell", s.st_wired, "");
    } else if (host.atty_on_path) {
        try row(w, t, .neutral, "shell", s.st_not_wired, s.wire_hint);
    } else {
        var fixbuf: [128]u8 = undefined;
        // fish has no `eval "$(...)"`; it pipes to source.
        const fix = if (std.mem.eql(u8, host.shell_name, "fish"))
            std.fmt.bufPrint(&fixbuf, "{s}atty init fish | source", .{s.fix_wire_shell}) catch s.fix_wire_shell
        else
            std.fmt.bufPrint(&fixbuf, "{s}eval \"$(atty init {s})\"", .{ s.fix_wire_shell, host.shell_name }) catch s.fix_wire_shell;
        try row(w, t, .neutral, "shell", s.st_not_wired, fix);
    }

    if (m) |metrics| {
        try row(w, t, .ok, "atty-guard", s.st_running, "");

        if (home.isProtected(metrics)) {
            try row(w, t, .ok, "security", metrics.guard.profile, "");
        } else if (std.mem.eql(u8, metrics.guard.profile, "prompt")) {
            try row(w, t, .neutral, "security", s.st_warn_only, s.fix_raise_profile);
        } else {
            // Daemon up but the profile field is empty/absent (any non-empty
            // value is either "prompt" or → isProtected) — don't claim "prompt".
            try row(w, t, .neutral, "security", s.st_unknown, "");
        }

        // The daemon reports ebpf as exactly "attached" or "off"
        // (main.rs GuardPosture); handle both, keep the install fix on the
        // explicit "off", and stay forward/older-daemon tolerant.
        if (std.mem.eql(u8, metrics.guard.ebpf, "attached")) {
            try row(w, t, .ok, "eBPF", s.st_attached, "");
        } else if (std.mem.eql(u8, metrics.guard.ebpf, "off")) {
            try row(w, t, .neutral, "eBPF", s.st_off, s.fix_ebpf_install);
        } else if (metrics.guard.ebpf.len > 0) {
            try row(w, t, .neutral, "eBPF", metrics.guard.ebpf, ""); // future status, verbatim
        } else {
            try row(w, t, .neutral, "eBPF", s.st_unknown, ""); // field absent (older daemon)
        }

        // The enforcement depth only matters while eBPF is attached.
        if (std.mem.eql(u8, metrics.guard.ebpf, "attached") and metrics.guard.enforcement.len > 0) {
            try row(w, t, .neutral, "enforce", metrics.guard.enforcement, "");
        }

        // What the daemon was BUILT with, distinct from what's configured.
        // null = an older daemon that doesn't report it (unknown, not minimal).
        if (metrics.guard.features) |feats| {
            if (feats.len > 0) {
                var fbuf: [160]u8 = undefined;
                var fw = std.Io.Writer.fixed(&fbuf);
                for (feats, 0..) |feat, i| {
                    if (i > 0) fw.writeAll(", ") catch {};
                    fw.writeAll(feat) catch {};
                }
                try row(w, t, .ok, "features", fbuf[0..fw.end], "");
            } else {
                // Empty = a default build; the eBPF "off" row above already
                // carries the GUARD_FEATURES install line, so don't repeat it.
                try row(w, t, .neutral, "features", s.st_minimal, "");
            }
        } else {
            try row(w, t, .neutral, "features", s.st_unknown, "");
        }

        if (metrics.instances > 0) {
            var nbuf: [48]u8 = undefined;
            const word = if (metrics.instances == 1) s.session_reporting_one else s.session_reporting_many;
            const sess = std.fmt.bufPrint(&nbuf, "{d} {s}", .{ metrics.instances, word }) catch word;
            try row(w, t, .ok, "metrics", sess, "");
        } else {
            try row(w, t, .neutral, "metrics", s.st_no_sessions, s.fix_enable_metrics);
        }
    } else {
        try row(w, t, .bad, "atty-guard", s.st_not_reachable, "sudo systemctl start atty-guard");
        try row(w, t, .neutral, "security", s.daemon_down, "");
        try row(w, t, .neutral, "eBPF", s.daemon_down, "");
        try row(w, t, .neutral, "metrics", s.daemon_down, "");
    }

    // Always checkable — attop knows its own environment.
    if (host.under_atty) {
        try row(w, t, .ok, "session", s.st_in_session, "");
    } else {
        try row(w, t, .neutral, "session", s.st_not_under_atty, s.fix_run_atty);
    }
}

pub const WireState = enum { confirm, done, failed };

/// The confirm/result view for the consented shell-integration write. The
/// confirm state shows the EXACT block + target paths so the user consents to
/// precisely what lands on disk — no write happens elsewhere without a 'y'.
/// `block` is built by the caller (which owns an allocator); rendering it
/// verbatim avoids re-deriving the block format here (single source = rc_writer).
pub fn renderWire(buf: []u8, state: WireState, init_path: []const u8, rc_path: []const u8, block: []const u8, cols: u16, rows: u16) []const u8 {
    _ = rows;
    _ = cols;
    var w = std.Io.Writer.fixed(buf);
    renderWireInner(&w, state, init_path, rc_path, block) catch {};
    return buf[0..w.end];
}

fn renderWireInner(w: *std.Io.Writer, state: WireState, init_path: []const u8, rc_path: []const u8, block: []const u8) !void {
    const t = theme.active;
    const s = i18n.active;
    try w.print("{f}Setup{s}{s}\r\n\r\n", .{ t.title, reset, s.suffix_health });
    switch (state) {
        .confirm => {
            try w.print("  {s}\r\n\r\n", .{s.wire_intro});
            try w.print("  {f}{s}{s}\r\n", .{ t.muted, init_path, reset });
            var it = std.mem.splitScalar(u8, block, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                try w.print("    {f}{s}{s}\r\n", .{ t.muted, line, reset });
            }
            try w.print("\r\n  \u{2192} {f}{s}{s}\r\n\r\n", .{ t.muted, rc_path, reset });
            try w.print("  {f}{s}{s}\r\n", .{ t.warn, s.wire_confirm, reset });
        },
        .done => try w.print("  {f}{s} {s}{s}\r\n", .{ t.ok, t.glyph.ok_mark, s.wire_done, reset }),
        .failed => try w.print("  {f}{s} {s}{s}\r\n", .{ t.danger, t.glyph.bad_mark, s.wire_failed, reset }),
    }
}

/// Setup panel — the health checklist + the consented shell-integration
/// write. The one panel that takes a mutating action ([w] → rc write);
/// it owns the wire state machine that used to live in main.zig.
pub const Panel = struct {
    pub const Runtime = struct {
        /// Non-null while the consented write is being confirmed / shown.
        wire: ?WireState = null,
        /// Post-write shell-integration result. null → use the host
        /// snapshot; set after a successful [w] so the checklist + the [w]
        /// gate reflect the new state without a host-level re-detect.
        wired: ?bool = null,
    };

    pub fn attach(_: std.mem.Allocator) !Runtime {
        return .{};
    }
    pub fn title() []const u8 {
        return "Setup";
    }
    pub fn navKey() u8 {
        return 's';
    }

    /// Grab focus at launch when the stack isn't ready — atty not on PATH
    /// or the daemon unreachable. Mirrors main.zig's old landing logic, now
    /// owned by the panel that fixes those problems.
    pub fn wantsFocusAtStart(ctx: *panel.Ctx) bool {
        return !ctx.host.atty_on_path or ctx.metrics == null;
    }

    pub fn render(rt: *Runtime, ctx: *panel.Ctx, w: *std.Io.Writer) !void {
        if (rt.wire) |ws| {
            // Build the exact block + paths in the per-frame arena so the
            // confirm view shows precisely what lands on disk.
            if (wirePaths(ctx.arena)) |wp| {
                const block = rc_writer.buildBlock(ctx.arena, wp.init_path, wp.shell) catch "";
                try renderWireInner(w, ws, wp.init_path, wp.rc_path, block);
            } else {
                try renderWireInner(w, ws, "", "", "");
            }
            return;
        }
        var host = ctx.host;
        host.shell_integrated = rt.wired orelse ctx.host.shell_integrated;
        try draw(w, ctx.metrics, host, ctx.cols);
    }

    pub fn onKey(rt: *Runtime, ctx: *panel.Ctx, k: panel.Key) !panel.Action {
        if (rt.wire) |ws| {
            switch (ws) {
                // The consent gate: ONLY 'y' writes; anything else cancels.
                .confirm => {
                    const yes = switch (k) {
                        .char => |c| c == 'y' or c == 'Y',
                        else => false,
                    };
                    if (yes) {
                        rt.wire = if (doWire()) .done else .failed;
                        rt.wired = caps.shellIntegrated(); // re-detect post-write
                    } else rt.wire = null;
                },
                // Any key dismisses the result view.
                .done, .failed => rt.wire = null,
            }
            return .handled;
        }
        // [w] opens the consent view — only when atty is installed + the
        // shell isn't already wired (else the write would point at an atty
        // that isn't on PATH, or redo existing work).
        const integrated = rt.wired orelse ctx.host.shell_integrated;
        const is_w = switch (k) {
            .char => |c| c == 'w',
            else => false,
        };
        if (is_w and ctx.host.atty_on_path and !integrated) {
            rt.wire = .confirm;
            return .handled;
        }
        return .pass;
    }

    pub fn footerHint(rt: *Runtime, ctx: *panel.Ctx) ?[]const u8 {
        if (rt.wire) |ws| return switch (ws) {
            .confirm => "[y] write   any other key cancels",
            .done, .failed => "any key dismisses",
        };
        const integrated = rt.wired orelse ctx.host.shell_integrated;
        if (ctx.host.atty_on_path and !integrated) return "[w] wire atty into your shell rc";
        return null;
    }
};

const WirePaths = struct {
    config_dir: []const u8,
    init_path: []const u8,
    rc_path: []const u8,
    shell: []const u8,
};

/// Shell-integration paths from $HOME + the detected shell; strings
/// allocated in `a`. null when $HOME is unset (nothing to write into).
fn wirePaths(a: std.mem.Allocator) ?WirePaths {
    const home_dir = std.mem.span(std.c.getenv("HOME") orelse return null);
    const shell = caps.shellName();
    const config_dir = std.fmt.allocPrint(a, "{s}/.config/atty", .{home_dir}) catch return null;
    const init_path = std.fmt.allocPrint(a, "{s}/init.{s}", .{ config_dir, shell }) catch return null;
    var rcbuf: [4096]u8 = undefined;
    const rc = caps.rcPath(&rcbuf) orelse return null;
    const rc_path = a.dupe(u8, rc) catch return null;
    return .{ .config_dir = config_dir, .init_path = init_path, .rc_path = rc_path, .shell = shell };
}

/// Perform the consented write in its own arena. true on success.
fn doWire() bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wp = wirePaths(a) orelse return false;
    rc_apply.wireShell(a, wp.config_dir, wp.shell, wp.rc_path) catch return false;
    return true;
}

fn row(w: *std.Io.Writer, t: theme.Theme, st: Status, label: []const u8, status_text: []const u8, fix: []const u8) !void {
    const mark = switch (st) {
        .ok => t.glyph.ok_mark,
        .bad => t.glyph.bad_mark,
        .neutral => t.glyph.neutral_mark,
    };
    const mstyle = switch (st) {
        .ok => t.ok,
        .bad => t.danger,
        .neutral => t.muted,
    };
    try w.print("  {f}{s}{s}  {s:<10}  {s}\r\n", .{ mstyle, mark, reset, label, status_text });
    if (fix.len > 0) {
        try w.print("       {f}\u{2192} {s}{s}\r\n", .{ t.muted, fix, reset });
    }
}

test {
    _ = @import("setup_tests.zig");
}
