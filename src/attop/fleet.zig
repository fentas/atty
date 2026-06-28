//! attop Fleet panel — every live atty session as a row (docs/dashboard.md
//! Fleet). Driven by the daemon's list_instances. PURE render so the layout
//! is unit-testable; cwd is tail-truncated to fit the width.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");
const theme = @import("theme.zig");
const i18n = @import("i18n.zig");

const reset = atty.style.reset;

pub const compact_cols: u16 = 80;

pub fn renderFleet(buf: []u8, instances: ?[]const uds.Instance, cols: u16, rows: u16) []const u8 {
    _ = rows;
    var w = std.Io.Writer.fixed(buf);
    render(&w, instances, cols) catch {};
    return buf[0..w.end];
}

fn render(w: *std.Io.Writer, instances: ?[]const uds.Instance, cols: u16) !void {
    const t = theme.active;
    const s = i18n.active;
    const compact = cols < compact_cols;
    try w.writeAll("\x1b[2J\x1b[H");
    if (compact) {
        try w.print("{f}Fleet{s}\r\n\r\n", .{ t.title, reset });
    } else {
        try w.print("{f}Fleet{s}{s}\r\n\r\n", .{ t.title, reset, s.suffix_sessions });
    }

    if (instances == null) {
        // null = the round-trip failed for ANY reason (down, unreachable,
        // timeout, malformed) — say "not reachable", not "not running".
        try w.print("  {f}{s}{s}\r\n", .{ t.danger, s.not_reachable, reset });
        try w.writeAll("  is it running?  sudo systemctl start atty-guard\r\n");
        return;
    }
    const list = instances.?;
    if (list.len == 0) {
        try w.print("  {f}{s}{s}\r\n", .{ t.muted, s.no_sessions, reset });
        try w.writeAll("  (enable the metrics_exporter module — see docs/dashboard.md)\r\n");
        return;
    }

    if (compact) {
        try w.print("  {f}{s:<7} {s:<8} {s:>5}{s}\r\n", .{ t.muted, "pid", "shell", "cmds", reset });
    } else {
        try w.print("  {f}{s:<7} {s:<8} {s:>5}  {s}{s}\r\n", .{ t.muted, "pid", "shell", "cmds", "cwd", reset });
    }

    for (list) |inst| {
        const shell = if (inst.shell.len > 0) inst.shell else "\u{2014}";
        if (compact) {
            try w.print("  {d:<7} {s:<8} {d:>5}", .{ inst.pid, shell, inst.counters.commands });
        } else {
            const cwd = cwdShow(inst.cwd, cwdBudget(cols), t.glyph.ellipsis);
            try w.print("  {d:<7} {s:<8} {d:>5}  ", .{ inst.pid, shell, inst.counters.commands });
            if (cwd.ellipsis) try w.writeAll(t.glyph.ellipsis);
            try w.print("{s}", .{cwd.text});
        }
        if (inst.incognito) try w.print(" {s}", .{t.glyph.incognito});
        try w.writeAll("\r\n");
    }

    const plural: []const u8 = if (list.len == 1) "" else "s";
    try w.print("\r\n  {d} terminal{s}\r\n", .{ list.len, plural });
}

/// Columns available for the cwd after the pid/shell/cmds prefix, leaving
/// room for the trailing incognito marker so an incognito row's cwd can't
/// push the line past the width. Reserves the worst case (unicode " 🔒" ≈ 3
/// cols); the ascii " P" (2) just over-reserves harmlessly.
fn cwdBudget(cols: u16) usize {
    const reserved: usize = 26 + 3; // prefix (2+7+1+8+1+5+2) + marker
    return if (cols > reserved + 8) cols - reserved else 8;
}

const Cwd = struct { ellipsis: bool, text: []const u8 };

/// Show the TAIL of a path (the deepest dirs are the useful part), with a
/// leading ellipsis when truncated. Reserves the ellipsis's DISPLAY width
/// (1 for "…", 3 for the ascii "...") so the marked line still fits `max`.
fn cwdShow(cwd: []const u8, max: usize, ellipsis: []const u8) Cwd {
    if (cwd.len <= max) return .{ .ellipsis = false, .text = cwd };
    const ew = cellWidth(ellipsis);
    const keep = if (max > ew) max - ew else 1;
    var start = cwd.len - keep;
    // Don't start mid-codepoint: skip UTF-8 continuation bytes (10xxxxxx)
    // so a tail-truncated path can't emit a garbled glyph.
    while (start < cwd.len and (cwd[start] & 0xC0) == 0x80) start += 1;
    return .{ .ellipsis = true, .text = cwd[start..] };
}

/// Display columns of a (no-wide-char) glyph string = its codepoint count
/// (one column each); a UTF-8 continuation byte adds no column.
fn cellWidth(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) n += 1;
    }
    return n;
}

test {
    _ = @import("fleet_tests.zig");
}
