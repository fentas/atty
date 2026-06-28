//! attop Setup/Doctor screen — the embedded health check (docs/dashboard.md
//! Setup). Answers "is my atty stack wired up?" with a checklist + a one-
//! line fix per failing/optional item, so onboarding + troubleshooting live
//! in the dashboard. PURE render (no I/O): the daemon metrics + the
//! under-atty flag are passed in.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");
const theme = @import("theme.zig");

const reset = atty.style.reset;

pub const compact_cols: u16 = 80;

const Status = enum { ok, bad, neutral };

pub fn renderSetup(buf: []u8, m: ?uds.Metrics, under_atty: bool, cols: u16, rows: u16) []const u8 {
    _ = rows;
    var w = std.Io.Writer.fixed(buf);
    render(&w, m, under_atty, cols) catch {};
    return buf[0..w.end];
}

fn render(w: *std.Io.Writer, m: ?uds.Metrics, under_atty: bool, cols: u16) !void {
    const t = theme.active;
    try w.writeAll("\x1b[2J\x1b[H");
    if (cols < compact_cols) {
        try w.print("{f}Setup{s}\r\n\r\n", .{ t.title, reset });
    } else {
        try w.print("{f}Setup{s} \u{2014} health check\r\n\r\n", .{ t.title, reset });
    }

    if (m) |metrics| {
        try row(w, t, .ok, "atty-guard", "running", "");

        const protected = metrics.guard.profile.len > 0 and !std.mem.eql(u8, metrics.guard.profile, "prompt");
        if (protected) {
            try row(w, t, .ok, "security", metrics.guard.profile, "");
        } else {
            try row(w, t, .neutral, "security", "prompt (warn-only)", "raise it in the Guard panel ([g])");
        }

        if (std.mem.eql(u8, metrics.guard.ebpf, "attached")) {
            try row(w, t, .ok, "eBPF", "attached", "");
        } else {
            try row(w, t, .neutral, "eBPF", "off", "install: sudo make install-guard GUARD_FEATURES=...,ebpf");
        }

        if (metrics.instances > 0) {
            var nbuf: [40]u8 = undefined;
            const plural: []const u8 = if (metrics.instances == 1) "" else "s";
            const sess = std.fmt.bufPrint(&nbuf, "{d} session{s} reporting", .{ metrics.instances, plural }) catch "reporting";
            try row(w, t, .ok, "metrics", sess, "");
        } else {
            try row(w, t, .neutral, "metrics", "no sessions", "enable the metrics_exporter module");
        }
    } else {
        try row(w, t, .bad, "atty-guard", "not reachable", "sudo systemctl start atty-guard");
        try row(w, t, .neutral, "security", "unknown (daemon down)", "");
        try row(w, t, .neutral, "eBPF", "unknown (daemon down)", "");
        try row(w, t, .neutral, "metrics", "unknown (daemon down)", "");
    }

    // Always checkable — attop knows its own environment.
    if (under_atty) {
        try row(w, t, .ok, "session", "in an atty session", "");
    } else {
        try row(w, t, .neutral, "session", "not under atty", "run: atty");
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
