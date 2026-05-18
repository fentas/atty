//! Tests for `cursor_dsr.zig` — the DSR-6n reply interceptor.

const std = @import("std");
const testing = std.testing;
const mod = @import("cursor_dsr.zig");

const DsrParser = mod.DsrParser;

test "DsrParser: full reply in one chunk is consumed; position returned" {
    var p = DsrParser{};
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[24;80R", &out);
    try testing.expectEqual(@as(usize, 0), r.filtered_len);
    try testing.expect(r.pos != null);
    try testing.expectEqual(@as(u16, 24), r.pos.?.row);
    try testing.expectEqual(@as(u16, 80), r.pos.?.col);
}

test "DsrParser: reply embedded between printable bytes — only reply consumed" {
    var p = DsrParser{};
    var out: [64]u8 = undefined;
    const r = p.feed("a\x1B[10;5Rb", &out);
    try testing.expect(r.pos != null);
    try testing.expectEqual(@as(u16, 10), r.pos.?.row);
    try testing.expectEqual(@as(u16, 5), r.pos.?.col);
    try testing.expectEqualStrings("ab", out[0..r.filtered_len]);
}

test "DsrParser: unrelated CSI (`\\x1b[A` — Up arrow) passes through" {
    var p = DsrParser{};
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[A", &out);
    try testing.expect(r.pos == null);
    try testing.expectEqualStrings("\x1B[A", out[0..r.filtered_len]);
}

test "DsrParser: CSI with single param ending in `R` (no `;`) doesn't match" {
    // A real DSR reply always has row + col separated by `;`. A
    // sequence like `\x1B[24R` is malformed — pass through.
    var p = DsrParser{};
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[24R", &out);
    try testing.expect(r.pos == null);
    try testing.expectEqualStrings("\x1B[24R", out[0..r.filtered_len]);
}

test "DsrParser: reply split across two feeds reassembles correctly" {
    var p = DsrParser{};
    var out: [64]u8 = undefined;
    const r1 = p.feed("\x1B[12;", &out);
    // No completion yet — bytes go to output buffer (caller hasn't
    // decided yet whether to forward them; in the proxy they get
    // filtered out via the rewind on completion).
    try testing.expect(r1.pos == null);

    var out2: [64]u8 = undefined;
    const r2 = p.feed("45R", &out2);
    try testing.expect(r2.pos != null);
    try testing.expectEqual(@as(u16, 12), r2.pos.?.row);
    try testing.expectEqual(@as(u16, 45), r2.pos.?.col);
    // Second chunk's filtered output should be empty (everything
    // was part of the reply).
    try testing.expectEqual(@as(usize, 0), r2.filtered_len);
}

test "DsrParser: zero-param fields parse as 0 (caller's job to clamp)" {
    var p = DsrParser{};
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[;R", &out);
    try testing.expect(r.pos != null);
    try testing.expectEqual(@as(u16, 0), r.pos.?.row);
    try testing.expectEqual(@as(u16, 0), r.pos.?.col);
}

test "DsrParser: massive digit values saturate at u16 max" {
    var p = DsrParser{};
    var out: [64]u8 = undefined;
    const r = p.feed("\x1B[99999;88888R", &out);
    try testing.expect(r.pos != null);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), r.pos.?.row);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), r.pos.?.col);
}

test "DsrParser: writeQuery emits the standard sequence" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try DsrParser.writeQuery(&w);
    try testing.expectEqualStrings("\x1B[6n", buf[0..w.end]);
}

test "DsrParser: two replies in a single chunk both parse" {
    var p = DsrParser{};
    var out: [64]u8 = undefined;
    const r1 = p.feed("\x1B[1;2R", &out);
    try testing.expect(r1.pos != null);
    try testing.expectEqual(@as(u16, 1), r1.pos.?.row);
    try testing.expectEqual(@as(u16, 2), r1.pos.?.col);

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
