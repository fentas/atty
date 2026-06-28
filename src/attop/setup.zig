//! attop Setup/Doctor screen (docs/dashboard.md Setup) — the embedded
//! health check. Answers "is my atty stack wired up?" with a checklist + a
//! one-line fix per failing/optional item, so onboarding + troubleshooting
//! live in the dashboard. PURE render (no I/O): the daemon metrics + the
//! under-atty flag are passed in.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");
const theme = @import("theme.zig");
const home = @import("home.zig");
const i18n = @import("i18n.zig");

const reset = atty.style.reset;

pub const compact_cols: u16 = 80;

const Status = enum { ok, bad, neutral };

pub fn renderSetup(buf: []u8, m: ?uds.Metrics, atty_on_path: bool, under_atty: bool, cols: u16, rows: u16) []const u8 {
    _ = rows;
    var w = std.Io.Writer.fixed(buf);
    render(&w, m, atty_on_path, under_atty, cols) catch {};
    return buf[0..w.end];
}

fn render(w: *std.Io.Writer, m: ?uds.Metrics, atty_on_path: bool, under_atty: bool, cols: u16) !void {
    const t = theme.active;
    const s = i18n.active;
    try w.writeAll("\x1b[2J\x1b[H");
    if (cols < compact_cols) {
        try w.print("{f}Setup{s}\r\n\r\n", .{ t.title, reset });
    } else {
        try w.print("{f}Setup{s}{s}\r\n\r\n", .{ t.title, reset, s.suffix_health });
    }

    // atty itself first — the rest is moot if the proxy isn't installed.
    if (atty_on_path) {
        try row(w, t, .ok, "atty", s.st_installed, "");
    } else {
        try row(w, t, .bad, "atty", s.st_not_installed, s.fix_install_atty);
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
    if (under_atty) {
        try row(w, t, .ok, "session", s.st_in_session, "");
    } else {
        try row(w, t, .neutral, "session", s.st_not_under_atty, s.fix_run_atty);
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
