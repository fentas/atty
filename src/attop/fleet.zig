//! attop Fleet panel — every live atty session as a row (docs/dashboard.md
//! Fleet). Driven by the daemon's list_instances. PURE render so the layout
//! is unit-testable; cwd is tail-truncated to fit the width.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");

const style = atty.style;
const reset = style.reset;

pub const compact_cols: u16 = 80;

pub fn renderFleet(buf: []u8, instances: ?[]const uds.Instance, cols: u16, rows: u16) []const u8 {
    _ = rows;
    var w = std.Io.Writer.fixed(buf);
    render(&w, instances, cols) catch {};
    return buf[0..w.end];
}

fn render(w: *std.Io.Writer, instances: ?[]const uds.Instance, cols: u16) !void {
    const compact = cols < compact_cols;
    try w.writeAll("\x1b[2J\x1b[H");
    if (compact) {
        try w.print("{f}Fleet{s}\r\n\r\n", .{ style.presets.emphasis, reset });
    } else {
        try w.print("{f}Fleet{s} \u{2014} atty sessions\r\n\r\n", .{ style.presets.emphasis, reset });
    }

    if (instances == null) {
        try w.print("  {f}atty-guard not running{s}\r\n", .{ style.presets.danger, reset });
        try w.writeAll("  start it:  sudo systemctl start atty-guard\r\n");
        return;
    }
    const list = instances.?;
    if (list.len == 0) {
        try w.print("  {f}no atty sessions reporting{s}\r\n", .{ style.presets.muted, reset });
        try w.writeAll("  (enable the metrics_exporter module — see docs/dashboard.md)\r\n");
        return;
    }

    if (compact) {
        try w.print("  {f}{s:<7} {s:<8} {s:>5}{s}\r\n", .{ style.presets.muted, "pid", "shell", "cmds", reset });
    } else {
        try w.print("  {f}{s:<7} {s:<8} {s:>5}  {s}{s}\r\n", .{ style.presets.muted, "pid", "shell", "cmds", "cwd", reset });
    }

    for (list) |inst| {
        const shell = if (inst.shell.len > 0) inst.shell else "\u{2014}";
        const incog: []const u8 = if (inst.incognito) " \u{1F512}" else "";
        if (compact) {
            try w.print("  {d:<7} {s:<8} {d:>5}{s}\r\n", .{ inst.pid, shell, inst.counters.commands, incog });
        } else {
            const cwd = cwdShow(inst.cwd, cwdBudget(cols));
            try w.print("  {d:<7} {s:<8} {d:>5}  ", .{ inst.pid, shell, inst.counters.commands });
            if (cwd.ellipsis) try w.writeAll("\u{2026}");
            try w.print("{s}{s}\r\n", .{ cwd.text, incog });
        }
    }

    const plural: []const u8 = if (list.len == 1) "" else "s";
    try w.print("\r\n  {d} terminal{s}\r\n", .{ list.len, plural });
}

/// Columns available for the cwd after the pid/shell/cmds prefix.
fn cwdBudget(cols: u16) usize {
    const prefix: usize = 26; // 2 + 7 + 1 + 8 + 1 + 5 + 2
    return if (cols > prefix + 8) cols - prefix else 8;
}

const Cwd = struct { ellipsis: bool, text: []const u8 };

/// Show the TAIL of a path (the deepest dirs are the useful part), with a
/// leading ellipsis when truncated.
fn cwdShow(cwd: []const u8, max: usize) Cwd {
    if (cwd.len <= max) return .{ .ellipsis = false, .text = cwd };
    return .{ .ellipsis = true, .text = cwd[cwd.len - (max - 1) ..] };
}

test {
    _ = @import("fleet_tests.zig");
}
