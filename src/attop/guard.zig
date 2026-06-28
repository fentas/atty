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
    render(&w, m, cols) catch {};
    return buf[0..w.end];
}

fn render(w: *std.Io.Writer, m: ?uds.Metrics, cols: u16) !void {
    const t = theme.active;
    try w.writeAll("\x1b[2J\x1b[H");
    if (cols < compact_cols) {
        try w.print("{f}Guard{s}\r\n\r\n", .{ t.title, reset });
    } else {
        try w.print("{f}Guard{s} \u{2014} security profile\r\n\r\n", .{ t.title, reset });
    }

    if (m == null) {
        try w.print("  {f}atty-guard not running{s}\r\n", .{ t.danger, reset });
        try w.writeAll("  start it:  sudo systemctl start atty-guard\r\n");
        return;
    }
    const g = m.?.guard;

    var matched = false;
    for (rungs) |r| {
        if (std.mem.eql(u8, r.name, g.profile)) {
            matched = true;
            try w.print("  {f}{s} {s:<9}{s}  {s}\r\n", .{ t.ok, t.glyph.active, r.name, reset, r.tldr });
        } else {
            try w.print("    {s:<9}  {f}{s}{s}\r\n", .{ r.name, t.muted, r.tldr, reset });
        }
    }
    // A profile the daemon reports but we don't know (older/newer daemon)
    // would otherwise leave NO rung marked — say so rather than look idle.
    if (!matched) {
        const p = if (g.profile.len > 0) g.profile else "unknown";
        try w.print("  {f}active: {s} (not a listed rung){s}\r\n", .{ t.warn, p, reset });
    }

    try w.writeAll("\r\n");
    const ebpf = if (g.ebpf.len > 0) g.ebpf else "\u{2014}";
    try w.print(
        "  {f}kernel{s} {s}    deny-rules: {d} path + {d} basename\r\n",
        .{ t.muted, reset, ebpf, g.deny_path, g.deny_basename },
    );
    try w.print(
        "  {f}switch{s} Alt+P in atty, or: sudo atty-guard profile set <rung>\r\n",
        .{ t.muted, reset },
    );
}

test {
    _ = @import("guard_tests.zig");
}
