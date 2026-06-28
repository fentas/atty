//! attop Guard panel — the security profile as one comprehensible control
//! (docs/dashboard.md Guard slider). Shows the rung ladder with the active
//! profile highlighted + a plain-language TL;DR per rung, plus the kernel
//! posture. Read-only for now: switching is daemon-global + gated, so it's
//! driven by atty's Alt+P / `sudo atty-guard profile set` (a future step
//! may wire interactive switching here). PURE render — unit-testable.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");
const theme = @import("theme.zig");
const i18n = @import("i18n.zig");
const panel = @import("panel.zig");
const list_mod = @import("list.zig");

const reset = atty.style.reset;

const Rung = struct { name: []const u8, tldr: []const u8 };

/// The ladder, weakest→strongest (matches the daemon's SecurityProfile +
/// the docs/dashboard.md Guard-slider copy).
pub const rungs = [_]Rung{
    .{ .name = "prompt", .tldr = "only warns on the risky commands you type" },
    .{ .name = "audit", .tldr = "watches the session + logs threats" },
    .{ .name = "session", .tldr = "watches + kills a threat right after it starts" },
    .{ .name = "strict", .tldr = "refuses known-bad before it runs" },
    .{ .name = "lockdown", .tldr = "freezes anything ambiguous; max safety, can wedge" },
    .{ .name = "smart", .tldr = "picks the lightest sufficient guard automatically" },
};

/// Below this width the title drops its suffix (matches home.zig's break).
pub const compact_cols: u16 = 80;

pub fn renderGuard(buf: []u8, m: ?uds.Metrics, cols: u16, rows: u16) []const u8 {
    _ = rows;
    var w = std.Io.Writer.fixed(buf);
    draw(&w, m, cols, null) catch {};
    return buf[0..w.end];
}

/// Guard panel — the security-profile ladder, now browsable: j/k move a
/// selection cursor over the rungs (the ACTIVE profile stays marked with ▸).
/// Read-only — switching a daemon-global, gated profile stays on atty's
/// Alt+P / `sudo atty-guard profile set` per the agreed scope.
pub const Panel = struct {
    pub const Runtime = struct {
        list: list_mod.List = .{},
    };
    pub fn attach(_: std.mem.Allocator) !Runtime {
        return .{};
    }
    pub fn title() []const u8 {
        return "Guard";
    }
    pub fn navKey() u8 {
        return 'g';
    }
    pub fn render(rt: *Runtime, ctx: *panel.Ctx, w: *std.Io.Writer) !void {
        rt.list.setViewport(rungs.len); // all rungs fit; no scroll needed
        rt.list.setLen(rungs.len);
        try draw(w, ctx.metrics, ctx.cols, rt.list.selected);
    }
    pub fn onKey(rt: *Runtime, _: *panel.Ctx, k: panel.Key) !panel.Action {
        if (rt.list.handleKey(k)) return .handled;
        return .pass;
    }
    pub fn footerHint(_: *Runtime, _: *panel.Ctx) ?[]const u8 {
        return "j/k browse rungs \u{b7} switch via Alt+P / sudo atty-guard profile set";
    }
};

/// `selected` highlights a rung with the browse cursor (reverse video);
/// null = no cursor (the read-only render path used by tests).
fn draw(w: *std.Io.Writer, m: ?uds.Metrics, cols: u16, selected: ?usize) !void {
    const t = theme.active;
    const s = i18n.active;
    if (cols < compact_cols) {
        try w.print("{f}Guard{s}\r\n\r\n", .{ t.title, reset });
    } else {
        try w.print("{f}Guard{s}{s}\r\n\r\n", .{ t.title, reset, s.suffix_security });
    }

    if (m == null) {
        try w.print("  {f}{s}{s}\r\n", .{ t.danger, s.not_running, reset });
        try w.print("  {s}\r\n", .{s.fix_start_daemon});
        return;
    }
    const g = m.?.guard;

    var matched = false;
    for (rungs, 0..) |r, i| {
        const is_active = std.mem.eql(u8, r.name, g.profile);
        if (is_active) matched = true;
        const is_sel = if (selected) |sel| i == sel else false;
        if (is_sel) {
            // Reverse-video the whole row; no inner `reset` (it would cancel
            // the reverse mid-row). The active rung keeps its ▸ marker.
            const marker = if (is_active) t.glyph.active else " ";
            try w.print("\x1b[7m  {s} {s:<9}  {s}\x1b[27m\r\n", .{ marker, r.name, r.tldr });
        } else if (is_active) {
            try w.print("  {f}{s} {s:<9}{s}  {s}\r\n", .{ t.ok, t.glyph.active, r.name, reset, r.tldr });
        } else {
            try w.print("    {s:<9}  {f}{s}{s}\r\n", .{ r.name, t.muted, r.tldr, reset });
        }
    }
    // A profile the daemon reports but we don't know (older/newer daemon)
    // would otherwise leave NO rung marked — say so rather than look idle.
    if (!matched) {
        const p = if (g.profile.len > 0) g.profile else "unknown";
        try w.print("  {f}active: {s} ({s}){s}\r\n", .{ t.warn, p, s.not_listed_rung, reset });
    }

    try w.writeAll("\r\n");
    const ebpf = if (g.ebpf.len > 0) g.ebpf else "\u{2014}";
    try w.print(
        "  {f}{s}{s} {s}    deny-rules: {d} path + {d} basename\r\n",
        .{ t.muted, s.word_kernel, reset, ebpf, g.deny_path, g.deny_basename },
    );
    try w.print(
        "  {f}{s}{s} Alt+P in atty, or: sudo atty-guard profile set <rung>\r\n",
        .{ t.muted, s.word_switch, reset },
    );
}

test {
    _ = @import("guard_tests.zig");
}
