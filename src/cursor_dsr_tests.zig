//! Tests for `cursor_dsr.zig` — the DSR-6n reply interceptor.

const std = @import("std");
const testing = std.testing;
const mod = @import("cursor_dsr.zig");

const DsrParser = mod.DsrParser;

test "DsrParser: full reply in one chunk is consumed; position returned" {
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[24;80R", &out);
    try testing.expectEqual(@as(usize, 0), r.filtered_len);
    try testing.expect(r.pos != null);
    try testing.expectEqual(@as(u16, 24), r.pos.?.row);
    try testing.expectEqual(@as(u16, 80), r.pos.?.col);
}

test "DsrParser: reply embedded between printable bytes — only reply consumed" {
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r = p.feed("a\x1B[10;5Rb", &out);
    try testing.expect(r.pos != null);
    try testing.expectEqual(@as(u16, 10), r.pos.?.row);
    try testing.expectEqual(@as(u16, 5), r.pos.?.col);
    try testing.expectEqualStrings("ab", out[0..r.filtered_len]);
}

test "DsrParser: unrelated CSI (`\\x1b[A` — Up arrow) passes through" {
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[A", &out);
    try testing.expect(r.pos == null);
    try testing.expectEqualStrings("\x1B[A", out[0..r.filtered_len]);
}

test "DsrParser: CSI with single param ending in `R` (no `;`) doesn't match" {
    // A real DSR reply always has row + col separated by `;`. A
    // sequence like `\x1B[24R` is malformed — pass through.
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[24R", &out);
    try testing.expect(r.pos == null);
    try testing.expectEqualStrings("\x1B[24R", out[0..r.filtered_len]);
}

test "DsrParser: reply split across two feeds — NEITHER chunk leaks bytes" {
    // Critical invariant: pending bytes stay in the parser's
    // internal buffer until completion (drop) or abort (flush).
    // A naive implementation would write `\x1B[12;` into the first
    // chunk's filtered output and forward to bash before learning
    // it was a reply.
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r1 = p.feed("\x1B[12;", &out);
    try testing.expect(r1.pos == null);
    try testing.expectEqual(@as(usize, 0), r1.filtered_len);

    var out2: [64]u8 = undefined;
    const r2 = p.feed("45R", &out2);
    try testing.expect(r2.pos != null);
    try testing.expectEqual(@as(u16, 12), r2.pos.?.row);
    try testing.expectEqual(@as(u16, 45), r2.pos.?.col);
    try testing.expectEqual(@as(usize, 0), r2.filtered_len);
}

test "DsrParser: split reply with user bytes BEFORE the tail — user bytes preserved" {
    // Pathological case: chunk 1 starts a reply, chunk 2 contains
    // user keystrokes BEFORE the reply completes (the user typed
    // while the terminal queued the DSR response). The user bytes
    // would abort the reply parse and must reach bash; the
    // pending-buffer flush emits the partial-reply bytes
    // VERBATIM so keymap matchers still see them.
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r1 = p.feed("\x1B[12;", &out);
    try testing.expectEqual(@as(usize, 0), r1.filtered_len);

    // Chunk 2 has user input that aborts the pending reply.
    var out2: [64]u8 = undefined;
    const r2 = p.feed("xls\r", &out2);
    try testing.expect(r2.pos == null);
    // Aborted: the pending `\x1B[12;` flushes verbatim followed by
    // `xls\r`.
    try testing.expectEqualStrings("\x1B[12;xls\r", out2[0..r2.filtered_len]);
}

test "DsrParser: in-flight pending across an idle feed call — bytes still withheld" {
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r1 = p.feed("\x1B[", &out);
    try testing.expectEqual(@as(usize, 0), r1.filtered_len);

    // Empty feed (nothing arrives this tick).
    const r2 = p.feed("", &out);
    try testing.expectEqual(@as(usize, 0), r2.filtered_len);
    try testing.expect(r2.pos == null);

    // Reply finishes later.
    const r3 = p.feed("1;2R", &out);
    try testing.expect(r3.pos != null);
    try testing.expectEqual(@as(u16, 1), r3.pos.?.row);
    try testing.expectEqual(@as(u16, 2), r3.pos.?.col);
    try testing.expectEqual(@as(usize, 0), r3.filtered_len);
}

test "DsrParser: zero-param fields parse as 0 (caller's job to clamp)" {
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[;R", &out);
    try testing.expect(r.pos != null);
    try testing.expectEqual(@as(u16, 0), r.pos.?.row);
    try testing.expectEqual(@as(u16, 0), r.pos.?.col);
}

test "DsrParser: massive digit values saturate at u16 max" {
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[99999;88888R", &out);
    try testing.expect(r.pos != null);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), r.pos.?.row);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), r.pos.?.col);
}

test "DsrParser: writeQuery emits the standard sequence + sets expecting_reply" {
    var p = DsrParser{};
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expect(!p.expecting_reply);
    try p.writeQuery(&w);
    try testing.expectEqualStrings("\x1B[6n", buf[0..w.end]);
    try testing.expect(p.expecting_reply);
}

test "DsrParser: lone Esc with no query outstanding passes through immediately" {
    // Regression for the silent-ESC bug: user pressed Esc, parser
    // ate it into pending_buf waiting for a follow-up byte that
    // never came, the proxy's filter saw 0 bytes and skipped the
    // keymap match. With expecting_reply gated to actual queries,
    // a stray Esc forwards through unchanged.
    var p = DsrParser{};
    var out: [16]u8 = undefined;
    const r = p.feed("\x1B", &out);
    try testing.expectEqual(@as(usize, 1), r.filtered_len);
    try testing.expectEqualSlices(u8, "\x1B", out[0..r.filtered_len]);
    try testing.expect(r.pos == null);
}

test "DsrParser: arrow-key CSI without outstanding query passes through" {
    // `\x1B[A` (Up arrow) used to enter the parser's `.esc` then
    // `.csi` state and abort-flush on the `A`. Now it just streams
    // through verbatim since no query is outstanding — saves the
    // pending-buf round-trip and is observationally identical.
    var p = DsrParser{};
    var out: [16]u8 = undefined;
    const r = p.feed("\x1B[A", &out);
    try testing.expectEqual(@as(usize, 3), r.filtered_len);
    try testing.expectEqualSlices(u8, "\x1B[A", out[0..r.filtered_len]);
}

test "DsrParser: reply parses correctly when query was marked" {
    // The legitimate DSR-reply path still works when atty has
    // explicitly emitted a query. Mirrors the existing "full reply
    // in one chunk" test but exercises the gated path.
    var p = DsrParser{};
    p.markQuerySent();
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[12;34R", &out);
    try testing.expectEqual(@as(usize, 0), r.filtered_len);
    try testing.expect(r.pos != null);
    try testing.expectEqual(@as(u16, 12), r.pos.?.row);
    try testing.expectEqual(@as(u16, 34), r.pos.?.col);
    // Successful parse clears the gate so the NEXT Esc (no new
    // query yet) passes through.
    try testing.expect(!p.expecting_reply);

    const r2 = p.feed("\x1B", &out);
    try testing.expectEqual(@as(usize, 1), r2.filtered_len);
    try testing.expectEqualSlices(u8, "\x1B", out[0..r2.filtered_len]);
}

test "DsrParser: back-to-back queries each parse their own reply" {
    // Two distinct DSR queries from atty, each followed by a reply.
    // Caller re-marks expecting_reply before each round; without
    // the re-mark the second reply would stream through verbatim
    // (correct — atty isn't waiting on a reply it didn't request).
    var p = DsrParser{};
    var out: [64]u8 = undefined;

    p.markQuerySent();
    const r1 = p.feed("\x1B[1;2R", &out);
    try testing.expect(r1.pos != null);
    try testing.expectEqual(@as(u16, 1), r1.pos.?.row);
    try testing.expectEqual(@as(u16, 2), r1.pos.?.col);

    p.markQuerySent();
    var out2: [64]u8 = undefined;
    const r2 = p.feed("\x1B[3;4R", &out2);
    try testing.expect(r2.pos != null);
    try testing.expectEqual(@as(u16, 3), r2.pos.?.row);
    try testing.expectEqual(@as(u16, 4), r2.pos.?.col);
}

test "DsrParser: abort mid-CSI (`\\x1b[12;abc`) restores byte stream verbatim" {
    // If the user types something that LOOKS like the start of a
    // DSR reply but isn't, the parser must release the bytes so
    // keymap matching downstream still works.
    var p = DsrParser{};
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[12;a", &out);
    try testing.expect(r.pos == null);
    // The chunk contained `\x1B[12;` (5 bytes accumulated as
    // pending) + `a` (abort). After abort the parser should have
    // released all 6 bytes through the output buffer.
    try testing.expectEqualStrings("\x1B[12;a", out[0..r.filtered_len]);
}
