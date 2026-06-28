//! attop Guard panel — the security profile as one comprehensible control
//! (docs/dashboard.md Guard slider). Shows the rung ladder with the active
//! profile highlighted + a plain-language TL;DR per rung, plus the kernel
//! posture. Read-only for now: switching is daemon-global + gated, so it's
//! driven by atty's Alt+P / `sudo atty-guard profile set` (a future step
//! may wire interactive switching here). PURE render — unit-testable.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");

const style = atty.style;
const reset = style.reset;
const Style = atty.Style;

const active_style: Style = .{ .bold = true, .fg = 2 }; // green — active rung

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

pub fn renderGuard(buf: []u8, m: ?uds.Metrics, cols: u16, rows: u16) []const u8 {
    _ = rows;
    _ = cols;
    var w = std.Io.Writer.fixed(buf);
    render(&w, m) catch {};
    return buf[0..w.end];
}

fn render(w: *std.Io.Writer, m: ?uds.Metrics) !void {
    try w.writeAll("\x1b[2J\x1b[H");
    try w.print("{f}Guard{s} \u{2014} security profile\r\n\r\n", .{ style.presets.emphasis, reset });

    if (m == null) {
        try w.print("  {f}atty-guard not running{s}\r\n", .{ style.presets.danger, reset });
        try w.writeAll("  start it:  sudo systemctl start atty-guard\r\n");
        return;
    }
    const g = m.?.guard;

    for (rungs) |r| {
        if (std.mem.eql(u8, r.name, g.profile)) {
            try w.print("  {f}\u{25B8} {s:<9}{s}  {s}\r\n", .{ active_style, r.name, reset, r.tldr });
        } else {
            try w.print("    {s:<9}  {f}{s}{s}\r\n", .{ r.name, style.presets.muted, r.tldr, reset });
        }
    }

    try w.writeAll("\r\n");
    const ebpf = if (g.ebpf.len > 0) g.ebpf else "\u{2014}";
    try w.print(
        "  {f}kernel{s} {s}    deny-rules: {d} path + {d} basename\r\n",
        .{ style.presets.muted, reset, ebpf, g.deny_path, g.deny_basename },
    );
    try w.print(
        "  {f}switch{s} Alt+P in atty, or: sudo atty-guard profile set <rung>\r\n",
        .{ style.presets.muted, reset },
    );
}

test {
    _ = @import("guard_tests.zig");
}
