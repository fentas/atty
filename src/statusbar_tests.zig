//! Tests for `statusbar.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("statusbar.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const ansi = @import("ansi.zig");
const Style = @import("style.zig").Style;

// Re-binds of pub decls so test bodies stay short.
const StatusBar = mod.StatusBar;

test "effectiveRows subtracts reserve, clamps at 1" {
    var b = StatusBar.init(24, 80, 2, .{});
    try testing.expectEqual(@as(u16, 22), b.effectiveRows());

    b.rows = 2;
    try testing.expectEqual(@as(u16, 1), b.effectiveRows());

    b.rows = 0;
    try testing.expectEqual(@as(u16, 1), b.effectiveRows());
}

test "render emits SGR + CUP + text" {
    var b = StatusBar.init(24, 80, 2, .{ .dim = true });
    b.setText("hello");

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = w.buffered();

    try testing.expect(std.mem.indexOf(u8, out, ansi.save_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[24;1H") != null); // CUP last row
    try testing.expect(std.mem.indexOf(u8, out, ansi.sgr_dim) != null);
    try testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, out, ansi.restore_cursor) != null);
}

test "render is idempotent when text unchanged" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("x");

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const first = w.end;
    try b.render(&w);
    try testing.expectEqual(first, w.end); // no additional bytes
}

test "activate forces next render to repaint" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("x");

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const before = w.end;
    try b.activate(&w);
    try b.render(&w);
    try testing.expect(w.end > before);
}

test "setTransient overrides text_buf for the TTL window" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setTransient("deleted: foo", 5_000);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "deleted: foo") != null);
    try testing.expect(std.mem.indexOf(u8, out, "atty") == null);
}

test "applyReserveRows: no-op when n == current reserve_rows" {
    var b = StatusBar.init(24, 80, 3, .{});
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.applyReserveRows(&w, 3);
    try testing.expectEqual(@as(usize, 0), w.end);
    try testing.expectEqual(@as(u16, 3), b.reserve_rows);
}

test "applyReserveRows grows reservation without screen-clear (no ED 2)" {
    // Growing the reservation must NOT emit `\x1B[2J` (whole-screen
    // clear). That would wipe the user's visible shell history when
    // they press Alt+C — the very thing inline chat is meant to
    // preserve. Tightens the contract added in PR #64 review.
    var b = StatusBar.init(24, 80, 3, .{});
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.applyReserveRows(&w, 13); // base=3 → live=13 (inline +10)
    const out = buf[0..w.end];

    try testing.expect(std.mem.indexOf(u8, out, "\x1B[2J") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[1;11r") != null); // DECSTBM new top
    try testing.expectEqual(@as(u16, 13), b.reserve_rows);
    // base_reserve_rows must NOT change (hint stays anchored).
    try testing.expectEqual(@as(u16, 3), b.baseReserveRows());
}

test "applyReserveRows shrinks: clears just-released rows" {
    // Closing the inline panel: rows that used to belong to the
    // (larger) reservation must be wiped so the panel chrome doesn't
    // linger in the now-shell area until the next prompt redraw.
    var b = StatusBar.init(24, 80, 13, .{}); // grown state
    b.base_reserve_rows = 3; // mimic post-init "base recorded" state
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.applyReserveRows(&w, 3);
    const out = buf[0..w.end];

    // The just-released rows (12..21, i.e. rows-12 through rows-3 with
    // rows=24) should each be CUP+EL erased. Spot-check row 12 (old
    // top of reservation) and row 21 (one above new top).
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[12;1H\x1B[K") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[21;1H\x1B[K") != null);
    try testing.expectEqual(@as(u16, 3), b.reserve_rows);
}

test "hint row anchors to base_reserve_rows after setReserveRows growth" {
    // With base=3 and an inline panel adding 10, the live reservation
    // is 13 — but the hint must STAY at `rows - base + 1` = 22, not
    // slide up to `rows - 13 + 1` = 12. That's how the inline panel
    // claims the top rows of the expansion without overlapping the
    // hint surface.
    var b = StatusBar.initFull(
        24,
        80,
        3,
        .{ .dim = true },
        .{ .dim = true, .fg = 1 },
        .{ .italic = true },
    );
    b.setText("atty");
    b.setHint("explanation", 5_000);
    b.setReserveRows(13); // simulate inline panel grown

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    try testing.expect(std.mem.indexOf(u8, out, "\x1B[22;1H") != null); // hint still at row 22
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[12;1H") == null); // not row 12
    try testing.expect(std.mem.indexOf(u8, out, "explanation") != null);
}

test "setHint paints into the hint row with hint_style (dim by default)" {
    var b = StatusBar.init(24, 80, 2, .{ .dim = true });
    b.setText("atty");
    b.setHint("lists files in long format", 5_000);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    try testing.expect(std.mem.indexOf(u8, out, "\x1B[24;1H") != null); // status row
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[23;1H") != null); // hint row
    try testing.expect(std.mem.indexOf(u8, out, "lists files in long format") != null);
    try testing.expect(std.mem.indexOf(u8, out, "atty") != null);
}

test "hint paints at TOP of the reserved region (gap above status when reserve_rows >= 3)" {
    // Default reserve_rows=3 layout:
    //   rows-2 = hint, rows-1 = blank padding, rows = status.
    var b = StatusBar.initFull(
        24,
        80,
        3,
        .{ .dim = true }, // bar style
        .{ .dim = true, .fg = 1 }, // error style
        .{ .italic = true }, // hint style (distinct from bar)
    );
    b.setText("atty");
    b.setHint("explanation", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    // Status at row 24.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[24;1H") != null);
    // Hint at row 22 (rows - reserve_rows + 1 = 24 - 3 + 1).
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[22;1H") != null);
    // Hint must NOT paint into row 23 (the blank padding row).
    // We only verify the explicit CUP escape isn't present —
    // it's fine for the cursor to traverse rows in between
    // implicitly.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[23;1H") == null);
    // Hint uses hint_style (italic), not bar style (dim).
    try testing.expect(std.mem.indexOf(u8, out, ansi.sgr_italic) != null);
    try testing.expect(std.mem.indexOf(u8, out, "explanation") != null);
}

test "render is idempotent even when reserve_rows < 2 (hint silently dropped)" {
    // When there's no room for the hint row, painting must still
    // be skipped — but the "last hint" tracking state has to
    // advance so subsequent `render` calls become true no-ops.
    // Otherwise every tick re-emits the save/restore-cursor pair
    // for nothing visible.
    var b = StatusBar.init(24, 80, 1, .{}); // reserve_rows=1
    b.setText("atty");
    b.setHint("explanation", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const first_end = w.end;

    // Second call with same state → zero new bytes written.
    // (idempotence even though the hint row is silently dropped.)
    try b.render(&w);
    try testing.expectEqual(first_end, w.end);
}

test "render guards against u16 underflow when rows < reserve_rows" {
    // Pathological config: rows smaller than reserve_rows. The
    // computation has to use `effectiveRows()` (which clamps) so
    // the row math never underflows in u16 — without that guard,
    // `rows - reserve_rows + 1` wraps to ~65000 and the emitted
    // CUP escape lands on a nonsense row.
    var b = StatusBar.init(2, 80, 5, .{}); // rows=2 < reserve_rows=5
    b.setText("status");
    b.setHint("explanation", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    // None of the wraparound row values should appear.
    try testing.expect(std.mem.indexOf(u8, out, "65532") == null);
    try testing.expect(std.mem.indexOf(u8, out, "65533") == null);
    try testing.expect(std.mem.indexOf(u8, out, "65534") == null);
    try testing.expect(std.mem.indexOf(u8, out, "65535") == null);
}

test "render still paints hint when reserve_rows > rows (effectiveRows clamps)" {
    // rows=3, reserve_rows=5 → effectiveRows=1, hint_row=2,
    // status at rows=3. There IS room for the hint above the
    // status row even though `rows < reserve_rows`; the previous
    // `self.rows >= self.reserve_rows` guard would have dropped
    // it. Pin that the new effectiveRows-based math actually
    // paints something.
    var b = StatusBar.init(3, 80, 5, .{});
    b.setText("status");
    b.setHint("hint here", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    // Status painted on row 3, hint painted on row 2.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[3;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[2;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out, "hint here") != null);
}

test "hint row is skipped when reserve_rows < 2 (no row above status)" {
    var b = StatusBar.init(24, 80, 1, .{});
    b.setText("atty");
    b.setHint("explanation", 5_000);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    try testing.expect(std.mem.indexOf(u8, out, "atty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "explanation") == null);
}

test "clearHint forces a repaint that erases the hint row" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setHint("explanation", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const first_end = w.end;
    b.clearHint();
    try b.render(&w);
    const second = buf[first_end..w.end];

    try testing.expect(std.mem.indexOf(u8, second, "\x1B[23;1H") != null); // erase hint row
    try testing.expect(std.mem.indexOf(u8, second, "explanation") == null);
}

test "expired hint is dropped on the next render" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setHint("flash", 5_000);
    b.hint_until_ms = 0;

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);

    try testing.expectEqual(@as(usize, 0), b.hint_len);
}

test "setError paints with error_style + warning glyph, hint suppressed" {
    var b = StatusBar.initWithError(24, 80, 2, .{ .dim = true }, .{ .dim = true, .fg = 1 });
    b.setText("atty");
    b.setHint("an explanation", 5_000);
    b.setError("HTTP 500", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    // Warning glyph (U+26A0) UTF-8 = 0xE2 0x9A 0xA0.
    try testing.expect(std.mem.indexOf(u8, out, "\xE2\x9A\xA0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "HTTP 500") != null);
    // Error wins precedence; hint text must NOT be on screen while
    // the error is active.
    try testing.expect(std.mem.indexOf(u8, out, "an explanation") == null);
    // Style emits `\x1B[38;5;<n>m` for fg=1 (256-color form).
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[38;5;1m") != null);
}

test "error expiry falls back to hint if hint is still active" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setHint("the explanation", 60_000);
    b.setError("HTTP 500", 5_000);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const first_end = w.end;

    // Force the error to expire without touching the hint.
    b.error_until_ms = 0;
    try b.render(&w);
    const second = buf[first_end..w.end];

    // After error expiry, render must paint the hint that was being
    // suppressed.
    try testing.expect(std.mem.indexOf(u8, second, "the explanation") != null);
    try testing.expect(std.mem.indexOf(u8, second, "HTTP 500") == null);
    try testing.expectEqual(@as(usize, 0), b.error_len);
}

test "expired transient is dropped on the next render" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setTransient("flash", 5_000);
    // Force expiry by rewinding the deadline. Avoids real-time sleep
    // in the test.
    b.transient_until_ms = 0;

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "flash") == null);
    try testing.expect(std.mem.indexOf(u8, out, "atty") != null);
    try testing.expectEqual(@as(usize, 0), b.transient_len); // cleared by render
}
