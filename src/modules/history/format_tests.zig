//! Tests for `modules/history/format.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("format.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const history = @import("../history.zig");

// Re-binds of pub decls so test bodies stay short.
const formatHistoryLine = mod.formatHistoryLine;
const parseHistoryLine = mod.parseHistoryLine;

// ===========================================================================
// Tests
// ===========================================================================

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

test "parseHistoryLine drops bash HISTTIMEFORMAT timestamp markers" {
    // `#<digits>` lines are bash's HISTTIMEFORMAT metadata, not
    // typed commands — drop them so they don't surface as ghost
    // suggestions. Empty return makes the caller's empty-filter
    // skip the line.
    try testing.expectEqualStrings("", parseHistoryLine("#1700000000"));
    try testing.expectEqualStrings("", parseHistoryLine("#0"));
    // `#` followed by a non-digit is a genuine typed comment; keep
    // it (operator wanted to bookmark `# TODO` in their history).
    try testing.expectEqualStrings("# TODO", parseHistoryLine("# TODO"));
    try testing.expectEqualStrings("#!/bin/bash", parseHistoryLine("#!/bin/bash"));
}
