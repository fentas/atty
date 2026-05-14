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
// Tests
// ===========================================================================

const testing = std.testing;

test "parseHistoryLine strips zsh extended prefix" {
    try testing.expectEqualStrings("ls -la", parseHistoryLine(": 1700000000:0;ls -la"));
    try testing.expectEqualStrings("echo hi", parseHistoryLine("echo hi"));
    try testing.expectEqualStrings("", parseHistoryLine(""));
    // Lines without the colon prefix are returned as-is.
    try testing.expectEqualStrings(":not-extended", parseHistoryLine(":not-extended"));
}

test "formatHistoryLine emits zsh extended prefix" {
    var buf: [128]u8 = undefined;
    const out = formatHistoryLine(&buf, "ls -la", .zsh_extended, 1_700_000_000).?;
    try testing.expectEqualStrings(": 1700000000:0;ls -la\n", out);
}

test "formatHistoryLine bash + plain emit bare lines" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("git status\n", formatHistoryLine(&buf, "git status", .bash, 0).?);
    try testing.expectEqualStrings("ls\n", formatHistoryLine(&buf, "ls", .plain, 0).?);
}

test "formatHistoryLine round-trips through parseHistoryLine" {
    var buf: [128]u8 = undefined;
    const formatted = formatHistoryLine(&buf, "echo hi", .zsh_extended, 42).?;
    const without_nl = std.mem.trimEnd(u8, formatted, "\n");
    try testing.expectEqualStrings("echo hi", parseHistoryLine(without_nl));
}
