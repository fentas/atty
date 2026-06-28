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

const reset = atty.style.reset;

pub const compact_cols: u16 = 80;

const Status = enum { ok, bad, neutral };

/// Host-side capabilities attop detects locally (not from the daemon) — see
/// caps.zig. Bundled so the render signature stays small as the wizard grows.
pub const Host = struct {
    atty_on_path: bool = false,
    under_atty: bool = false,
    shell_integrated: bool = false,
    shell_name: []const u8 = "bash",
};

pub fn renderSetup(buf: []u8, m: ?uds.Metrics, host: Host, cols: u16, rows: u16) []const u8 {
    _ = rows;
    var w = std.Io.Writer.fixed(buf);
    render(&w, m, host, cols) catch {};
    return buf[0..w.end];
}

fn render(w: *std.Io.Writer, m: ?uds.Metrics, host: Host, cols: u16) !void {
    const t = theme.active;
    const s = i18n.active;
    try w.writeAll("\x1b[2J\x1b[H");
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
    try w.writeAll("\x1b[2J\x1b[H");
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
