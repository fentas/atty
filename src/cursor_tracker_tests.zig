//! Tests for `cursor_tracker.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("cursor_tracker.zig");

// Re-binds of pub decls so test bodies stay short.
const CursorTracker = mod.CursorTracker;

// =============================================================================
// Tests
// =============================================================================

test "CursorTracker: starts at row 1" {
    var c = CursorTracker.init(24);
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: LF advances row, capped at max_rows" {
    var c = CursorTracker.init(5);
    c.feed("\n\n\n");
    try testing.expectEqual(@as(u16, 4), c.currentRow());
    c.feed("\n\n\n\n\n");
    try testing.expectEqual(@as(u16, 5), c.currentRow()); // capped
}

test "CursorTracker: CR does not change row" {
    var c = CursorTracker.init(24);
    c.feed("\n\n");
    try testing.expectEqual(@as(u16, 3), c.currentRow());
    c.feed("\r");
    try testing.expectEqual(@as(u16, 3), c.currentRow());
}

test "CursorTracker: CUP sets row from param1" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[10;5H");
    try testing.expectEqual(@as(u16, 10), c.currentRow());
    c.feed("\x1B[3;1H");
    try testing.expectEqual(@as(u16, 3), c.currentRow());
}

test "CursorTracker: CUP with no params goes to row 1" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[5;5H");
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[H");
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: CUP with only row param" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[7H");
    try testing.expectEqual(@as(u16, 7), c.currentRow());
}

test "CursorTracker: HVP (`f`) is equivalent to CUP" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[12;3f");
    try testing.expectEqual(@as(u16, 12), c.currentRow());
}

test "CursorTracker: CUU subtracts, floored at 1" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[10H");
    c.feed("\x1B[3A");
    try testing.expectEqual(@as(u16, 7), c.currentRow());
    c.feed("\x1B[100A");
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: CUD adds, capped at max_rows" {
    var c = CursorTracker.init(20);
    c.feed("\x1B[5B");
    try testing.expectEqual(@as(u16, 6), c.currentRow());
    c.feed("\x1B[100B");
    try testing.expectEqual(@as(u16, 20), c.currentRow());
}

test "CursorTracker: VPA sets row absolutely" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[15d");
    try testing.expectEqual(@as(u16, 15), c.currentRow());
}

test "CursorTracker: CNL / CPL behave like CUD / CUU for row tracking" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[10;1H");
    c.feed("\x1B[3E"); // CNL — row + 3
    try testing.expectEqual(@as(u16, 13), c.currentRow());
    c.feed("\x1B[5F"); // CPL — row - 5
    try testing.expectEqual(@as(u16, 8), c.currentRow());
}

test "CursorTracker: SGR / ED / EL / unknown CSI do not move the row" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[5;1H");
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[2J"); // ED
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[K"); // EL
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[31;1m"); // SGR
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[?25h"); // DECSET
    try testing.expectEqual(@as(u16, 5), c.currentRow());
}

test "CursorTracker: mixed prompt-like stream tracks correctly" {
    var c = CursorTracker.init(24);
    // Simulate: home + clear, then 5 lines of output, then prompt.
    c.feed("\x1B[H\x1B[2J");
    try testing.expectEqual(@as(u16, 1), c.currentRow());
    c.feed("line1\nline2\nline3\nline4\nline5\n");
    try testing.expectEqual(@as(u16, 6), c.currentRow());
    c.feed("$ "); // shell prompt — no movement
    try testing.expectEqual(@as(u16, 6), c.currentRow());
}

test "CursorTracker: setMaxRows on shrink clamps row" {
    var c = CursorTracker.init(40);
    c.feed("\x1B[30H");
    try testing.expectEqual(@as(u16, 30), c.currentRow());
    c.setMaxRows(20);
    try testing.expectEqual(@as(u16, 20), c.currentRow());
}

test "CursorTracker: param overflow drops extra digits, doesn't crash" {
    var c = CursorTracker.init(24);
    // 20-digit param — buffer is 16 bytes, extras dropped.
    c.feed("\x1B[12345678901234567890H");
    // Parsing the truncated digits — implementation-defined exact
    // value, but must not crash and must end in `ground`.
    _ = c.currentRow();
}

test "CursorTracker: param > u16 max clamps instead of falling back to default 1" {
    var c = CursorTracker.init(80);
    c.feed("\x1B[10;1H"); // baseline: row 10
    try testing.expectEqual(@as(u16, 10), c.currentRow());
    // 999_999 is parseable as u32, overflows u16. With the previous
    // direct-into-u16 parse, this errored to 0 → default 1 → CUD by
    // 1 → row 11. With the clamp, we expect CUD by u16-max →
    // clamped to max_rows.
    c.feed("\x1B[999999B"); // CUD by huge amount
    try testing.expectEqual(@as(u16, 80), c.currentRow());
}

test "CursorTracker: arbitrarily-long digit run saturates instead of falling back to default" {
    var c = CursorTracker.init(80);
    c.feed("\x1B[10;1H"); // baseline: row 10
    try testing.expectEqual(@as(u16, 10), c.currentRow());
    // 16-digit param exceeds u64 mantissa when accumulated — the
    // old `parseUnsigned(u32, …)` would error to 0 → default 1.
    // The saturating accumulator clamps to u16 max → CUD all the
    // way to `max_rows`. (Param buffer caps at 16 bytes so all
    // 16 digits get accumulated.)
    c.feed("\x1B[9999999999999999B");
    try testing.expectEqual(@as(u16, 80), c.currentRow());
}

test "CursorTracker: lone ESC followed by non-`[` returns to ground" {
    var c = CursorTracker.init(24);
    c.feed("\x1B"); // pending ESC
    c.feed("M"); // RI — we don't model it; just consume + back to ground
    c.feed("\x1B[5;1H");
    try testing.expectEqual(@as(u16, 5), c.currentRow());
}

test "CursorTracker: CSI split across feeds reassembles correctly" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[");
    c.feed("10");
    c.feed(";5H");
    try testing.expectEqual(@as(u16, 10), c.currentRow());
}
