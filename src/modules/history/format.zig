//! History — pure line format helpers (parse + emit).
//!
//! Two cfg-agnostic functions live here so they can be exercised by
//! unit tests without dragging in the runtime / file I/O surface.
//! Re-exported from `../history.zig` as `H.parseHistoryLine` /
//! `H.formatHistoryLine` so existing test sites keep working with no
//! rewrites.

const std = @import("std");
const history = @import("../history.zig");

/// Strip the zsh extended-history prefix from a recorded line, if
/// present. `: <timestamp>:<duration>;<command>` → `<command>`.
/// Plain bash / plain-format lines pass through unchanged.
pub fn parseHistoryLine(line: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (trimmed.len < 4 or trimmed[0] != ':' or trimmed[1] != ' ') return trimmed;
    const semi = std.mem.indexOfScalar(u8, trimmed, ';') orelse return trimmed;
    return trimmed[semi + 1 ..];
}

/// Pure formatting helper — separable from the file I/O so it can be
/// unit-tested without touching disk. Returns null on buffer overrun
/// (caller's `buf` was too small to fit the formatted record + the
/// trailing newline).
pub fn formatHistoryLine(buf: []u8, line: []const u8, fmt: history.Format, ts: i64) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    switch (fmt) {
        .zsh_extended => w.print(": {d}:0;", .{ts}) catch return null,
        else => {},
    }
    w.writeAll(line) catch return null;
    w.writeByte('\n') catch return null;
    return w.buffered();
}

// ===========================================================================
// Tests — extracted to `format_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("format_tests.zig");
}
