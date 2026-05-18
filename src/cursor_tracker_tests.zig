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
    var c = CursorTracker.init(24, 80);
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: LF advances row, capped at max_rows" {
    var c = CursorTracker.init(5, 80);
    c.feed("\n\n\n");
    try testing.expectEqual(@as(u16, 4), c.currentRow());
    c.feed("\n\n\n\n\n");
    try testing.expectEqual(@as(u16, 5), c.currentRow()); // capped
}

test "CursorTracker: CR does not change row" {
    var c = CursorTracker.init(24, 80);
    c.feed("\n\n");
    try testing.expectEqual(@as(u16, 3), c.currentRow());
    c.feed("\r");
    try testing.expectEqual(@as(u16, 3), c.currentRow());
}

test "CursorTracker: CUP sets row from param1" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[10;5H");
    try testing.expectEqual(@as(u16, 10), c.currentRow());
    c.feed("\x1B[3;1H");
    try testing.expectEqual(@as(u16, 3), c.currentRow());
}

test "CursorTracker: CUP with no params goes to row 1" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[5;5H");
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[H");
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: CUP with only row param" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[7H");
    try testing.expectEqual(@as(u16, 7), c.currentRow());
}

test "CursorTracker: HVP (`f`) is equivalent to CUP" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[12;3f");
    try testing.expectEqual(@as(u16, 12), c.currentRow());
}

test "CursorTracker: CUU subtracts, floored at 1" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[10H");
    c.feed("\x1B[3A");
    try testing.expectEqual(@as(u16, 7), c.currentRow());
    c.feed("\x1B[100A");
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: CUD adds, capped at max_rows" {
    var c = CursorTracker.init(20, 80);
    c.feed("\x1B[5B");
    try testing.expectEqual(@as(u16, 6), c.currentRow());
    c.feed("\x1B[100B");
    try testing.expectEqual(@as(u16, 20), c.currentRow());
}

test "CursorTracker: VPA sets row absolutely" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[15d");
    try testing.expectEqual(@as(u16, 15), c.currentRow());
}

test "CursorTracker: CNL / CPL behave like CUD / CUU for row tracking" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[10;1H");
    c.feed("\x1B[3E"); // CNL — row + 3
    try testing.expectEqual(@as(u16, 13), c.currentRow());
    c.feed("\x1B[5F"); // CPL — row - 5
    try testing.expectEqual(@as(u16, 8), c.currentRow());
}

test "CursorTracker: SGR / ED / EL / unknown CSI do not move the row" {
    var c = CursorTracker.init(24, 80);
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
    var c = CursorTracker.init(24, 80);
    // Simulate: home + clear, then 5 lines of output, then prompt.
    c.feed("\x1B[H\x1B[2J");
    try testing.expectEqual(@as(u16, 1), c.currentRow());
    c.feed("line1\nline2\nline3\nline4\nline5\n");
    try testing.expectEqual(@as(u16, 6), c.currentRow());
    c.feed("$ "); // shell prompt — no movement
    try testing.expectEqual(@as(u16, 6), c.currentRow());
}

test "CursorTracker: setMaxRows on shrink clamps row" {
    var c = CursorTracker.init(40, 80);
    c.feed("\x1B[30H");
    try testing.expectEqual(@as(u16, 30), c.currentRow());
    c.setMaxRows(20);
    try testing.expectEqual(@as(u16, 20), c.currentRow());
}

test "CursorTracker: param overflow drops extra digits, doesn't crash" {
    var c = CursorTracker.init(24, 80);
    // 20-digit param — buffer is 16 bytes, extras dropped.
    c.feed("\x1B[12345678901234567890H");
    // Parsing the truncated digits — implementation-defined exact
    // value, but must not crash and must end in `ground`.
    _ = c.currentRow();
}

test "CursorTracker: param > u16 max clamps instead of falling back to default 1" {
    var c = CursorTracker.init(80, 80);
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
    var c = CursorTracker.init(80, 80);
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
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B"); // pending ESC
    c.feed("M"); // RI — we don't model it; just consume + back to ground
    c.feed("\x1B[5;1H");
    try testing.expectEqual(@as(u16, 5), c.currentRow());
}

test "CursorTracker: CSI split across feeds reassembles correctly" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[");
    c.feed("10");
    c.feed(";5H");
    try testing.expectEqual(@as(u16, 10), c.currentRow());
}

// =============================================================================
// Column tracking
// =============================================================================

test "CursorTracker: col starts at 1, printables advance" {
    var c = CursorTracker.init(24, 80);
    try testing.expectEqual(@as(u16, 1), c.currentCol());
    c.feed("hello");
    try testing.expectEqual(@as(u16, 6), c.currentCol());
}

test "CursorTracker: CR resets col, doesn't change row" {
    var c = CursorTracker.init(24, 80);
    c.feed("hello\r");
    try testing.expectEqual(@as(u16, 1), c.currentCol());
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: CRLF resets col + advances row" {
    var c = CursorTracker.init(24, 80);
    c.feed("hi\r\n");
    try testing.expectEqual(@as(u16, 1), c.currentCol());
    try testing.expectEqual(@as(u16, 2), c.currentRow());
}

test "CursorTracker: BS decrements col, floored at 1" {
    var c = CursorTracker.init(24, 80);
    c.feed("abc");
    try testing.expectEqual(@as(u16, 4), c.currentCol());
    c.feed("\x08\x08");
    try testing.expectEqual(@as(u16, 2), c.currentCol());
    c.feed("\x08\x08\x08\x08\x08");
    try testing.expectEqual(@as(u16, 1), c.currentCol());
}

test "CursorTracker: HT jumps to next 8-col tab stop" {
    var c = CursorTracker.init(24, 80);
    c.feed("\t"); // col 1 → 9
    try testing.expectEqual(@as(u16, 9), c.currentCol());
    c.feed("x\t"); // col 9 → 10 → 17
    try testing.expectEqual(@as(u16, 17), c.currentCol());
}

test "CursorTracker: printable past max_cols soft-wraps to next row" {
    var c = CursorTracker.init(24, 5);
    c.feed("12345"); // col 1..5 → after = col 6 wraps? Actually 5 + 1 = 6 > 5 → wrap. After 5 chars, col=1, row=2.
    try testing.expectEqual(@as(u16, 1), c.currentCol());
    try testing.expectEqual(@as(u16, 2), c.currentRow());
}

test "CursorTracker: CUF / CUB move col" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[10C"); // CUF 10 — col 11
    try testing.expectEqual(@as(u16, 11), c.currentCol());
    c.feed("\x1B[3D"); // CUB 3 — col 8
    try testing.expectEqual(@as(u16, 8), c.currentCol());
    c.feed("\x1B[100D"); // floor at 1
    try testing.expectEqual(@as(u16, 1), c.currentCol());
}

test "CursorTracker: CUP sets both row + col" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[10;25H");
    try testing.expectEqual(@as(u16, 10), c.currentRow());
    try testing.expectEqual(@as(u16, 25), c.currentCol());
}

test "CursorTracker: CHA / HPA set col absolutely" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B[15G"); // CHA
    try testing.expectEqual(@as(u16, 15), c.currentCol());
    c.feed("\x1B[42`"); // HPA
    try testing.expectEqual(@as(u16, 42), c.currentCol());
}

test "CursorTracker: CNL / CPL reset col to 1" {
    var c = CursorTracker.init(24, 80);
    c.feed("hello world"); // col 12
    c.feed("\x1B[2E"); // CNL — col → 1, row += 2
    try testing.expectEqual(@as(u16, 1), c.currentCol());
    try testing.expectEqual(@as(u16, 3), c.currentRow());
}

test "CursorTracker: UTF-8 multi-byte counts as ONE col, not per byte" {
    var c = CursorTracker.init(24, 80);
    // "é" = 0xC3 0xA9 (2 bytes, 1 codepoint)
    c.feed("a\xC3\xA9b");
    try testing.expectEqual(@as(u16, 4), c.currentCol());
}

test "CursorTracker: OSC 133 ;A resets col to 1" {
    var c = CursorTracker.init(24, 80);
    c.feed("garbage from previous command"); // col not 1
    c.feed("\x1B]133;A\x07");
    try testing.expectEqual(@as(u16, 1), c.currentCol());
}

test "CursorTracker: OSC 133 ;B snapshots prompt_end_col" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B]133;A\x07"); // prompt start, col = 1
    c.feed("~ )"); // PS1 text, col → 4
    c.feed("\x1B]133;B\x07"); // input region start
    try testing.expectEqual(@as(u16, 4), c.currentCol());
    try testing.expectEqual(@as(u16, 4), c.prompt_end_col);
    // Subsequent typing doesn't change the snapshot.
    c.feed("ls -la");
    try testing.expectEqual(@as(u16, 4), c.prompt_end_col);
    try testing.expectEqual(@as(u16, 10), c.currentCol());
}

test "CursorTracker: ST-terminated OSC (`\\x1B\\\\`) also consumed correctly" {
    var c = CursorTracker.init(24, 80);
    c.feed("a\x1B]0;title\x1B\\b"); // OSC 0 title set with ST terminator
    // The 'a' advanced col to 2; OSC consumed; 'b' should land at col 3.
    try testing.expectEqual(@as(u16, 3), c.currentCol());
}

test "CursorTracker: OSC body bytes do NOT count as printables" {
    var c = CursorTracker.init(24, 80);
    c.feed("\x1B]0;hello world\x07");
    try testing.expectEqual(@as(u16, 1), c.currentCol());
}

test "CursorTracker: setPosition trusts the caller (used by DSR-6n reply)" {
    var c = CursorTracker.init(24, 80);
    c.feed("hello");
    c.setPosition(10, 25);
    try testing.expectEqual(@as(u16, 10), c.currentRow());
    try testing.expectEqual(@as(u16, 25), c.currentCol());
}
