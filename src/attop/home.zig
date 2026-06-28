//! attop Home screen — the 3-second answer (docs/dashboard.md): am I
//! protected, what is atty doing for me, is everything healthy. PURE
//! render (no I/O) so the layout is unit-testable: it builds the full
//! frame into a caller buffer and returns the written slice.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");

const style = atty.style;
const reset = style.reset;
const Style = atty.Style;

// Local palette (themeable later). presets lacks a green, so define it.
const ok: Style = .{ .bold = true, .fg = 2 }; // green — protected
const warn: Style = .{ .bold = true, .fg = 3 }; // yellow — unguarded

/// `cols` below this stacks into a tighter layout (the responsive break).
pub const compact_cols: u16 = 80;

/// True when the active profile means the guard is doing something beyond
/// the bare prompt tripwire.
pub fn isProtected(m: uds.Metrics) bool {
    return m.guard.profile.len > 0 and !std.mem.eql(u8, m.guard.profile, "prompt");
}

/// Render the Home frame into `buf`; returns the written slice. `m == null`
/// is the daemon-unavailable state.
pub fn renderHome(buf: []u8, m: ?uds.Metrics, cols: u16, rows: u16) []const u8 {
    _ = rows;
    var w = std.Io.Writer.fixed(buf);
    render(&w, m, cols) catch {};
    return buf[0..w.end];
}

fn render(w: *std.Io.Writer, m: ?uds.Metrics, cols: u16) !void {
    const compact = cols < compact_cols;
    try w.writeAll("\x1b[2J\x1b[H"); // clear + home

    if (compact) {
        try w.print("{f}atty{s}\r\n\r\n", .{ style.presets.emphasis, reset });
    } else {
        try w.print("{f}atty{s} — dashboard\r\n\r\n", .{ style.presets.emphasis, reset });
    }

    if (m == null) {
        try w.print("  {f}atty-guard not running{s}\r\n", .{ style.presets.danger, reset });
        try w.writeAll("  start it:  sudo systemctl start atty-guard\r\n");
        return;
    }
    const metrics = m.?;

    if (isProtected(metrics)) {
        try w.print("  {f}\u{25CF} Protected{s}\r\n\r\n", .{ ok, reset });
    } else {
        try w.print("  {f}\u{25CB} Unguarded{s}\r\n\r\n", .{ warn, reset });
    }

    // AI/Suggest aren't wired into the metrics yet — show an honest
    // em-dash rather than faking activity.
    const prof = if (metrics.guard.profile.len > 0) metrics.guard.profile else "\u{2014}";
    const ebpf = if (metrics.guard.ebpf.len > 0) metrics.guard.ebpf else "\u{2014}";
    try w.print("  \u{1F6E1}  Guard     {s}     kernel: {s}\r\n", .{ prof, ebpf });
    try w.writeAll("  \u{1F916}  AI        \u{2014}\r\n");
    try w.writeAll("  \u{2728}  Suggest   \u{2014}\r\n\r\n");

    try w.print(
        "  {f}Today{s}    {d} commands \u{B7} {d} threats blocked\r\n",
        .{ style.presets.muted, reset, metrics.aggregate.commands, metrics.aggregate.guard_block },
    );

    const plural: []const u8 = if (metrics.instances == 1) "" else "s";
    try w.print("  {d} terminal{s} active\r\n", .{ metrics.instances, plural });
}

test {
    _ = @import("home_tests.zig");
}
