//! attop Home screen — the 3-second answer (docs/dashboard.md): am I
//! protected, what is atty doing for me, is everything healthy. PURE
//! render (no I/O) so the layout is unit-testable: it builds the full
//! frame into a caller buffer and returns the written slice.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");
const theme = @import("theme.zig");
const i18n = @import("i18n.zig");

const reset = atty.style.reset;

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
    const t = theme.active;
    const g = t.glyph;
    const s = i18n.active;
    const compact = cols < compact_cols;
    try w.writeAll("\x1b[2J\x1b[H"); // clear + home

    if (compact) {
        try w.print("{f}atty{s}\r\n\r\n", .{ t.title, reset });
    } else {
        try w.print("{f}atty{s}{s}\r\n\r\n", .{ t.title, reset, s.suffix_dashboard });
    }

    if (m == null) {
        try w.print("  {f}{s}{s}\r\n", .{ t.danger, s.not_running, reset });
        try w.print("  {s}\r\n", .{s.fix_start_daemon});
        return;
    }
    const metrics = m.?;

    if (isProtected(metrics)) {
        try w.print("  {f}{s} {s}{s}\r\n\r\n", .{ t.ok, g.protected, s.protected, reset });
    } else {
        try w.print("  {f}{s} {s}{s}\r\n\r\n", .{ t.warn, g.unguarded, s.unguarded, reset });
    }

    // AI/Suggest aren't wired into the metrics yet — show an honest
    // em-dash rather than faking activity.
    const prof = if (metrics.guard.profile.len > 0) metrics.guard.profile else "\u{2014}";
    const ebpf = if (metrics.guard.ebpf.len > 0) metrics.guard.ebpf else "\u{2014}";
    try w.print("  {s}  Guard     {s}     {s}: {s}\r\n", .{ g.shield, prof, s.word_kernel, ebpf });
    try w.print("  {s}  AI        \u{2014}\r\n", .{g.ai});
    try w.print("  {s}  Suggest   \u{2014}\r\n\r\n", .{g.suggest});

    try w.print(
        "  {f}{s}{s}    {d} {s} {s} {d} {s}\r\n",
        .{ t.muted, s.today, reset, metrics.aggregate.commands, s.word_commands, g.bullet, metrics.aggregate.guard_block, s.word_threats_blocked },
    );

    const term = if (metrics.instances == 1) s.terminals_active_one else s.terminals_active_many;
    try w.print("  {d} {s}\r\n", .{ metrics.instances, term });
}

test {
    _ = @import("home_tests.zig");
}
