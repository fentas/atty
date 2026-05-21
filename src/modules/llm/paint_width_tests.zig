const std = @import("std");
const testing = std.testing;
const mod = @import("paint_width.zig");

const displayWidth = mod.displayWidth;
const measureCols = mod.measureCols;
const truncateToCols = mod.truncateToCols;
const utf8Iter = mod.utf8Iter;

test "displayWidth: ASCII printable = 1, control = 0" {
    try testing.expectEqual(@as(u8, 1), displayWidth('a'));
    try testing.expectEqual(@as(u8, 1), displayWidth(' '));
    try testing.expectEqual(@as(u8, 1), displayWidth('~'));
    try testing.expectEqual(@as(u8, 0), displayWidth(0x00));
    try testing.expectEqual(@as(u8, 0), displayWidth(0x1B));
    try testing.expectEqual(@as(u8, 0), displayWidth(0x7F));
}

test "displayWidth: bullet U+2022 = 1 col (narrow)" {
    try testing.expectEqual(@as(u8, 1), displayWidth(0x2022));
}

test "displayWidth: ellipsis U+2026 = 1 col" {
    try testing.expectEqual(@as(u8, 1), displayWidth(0x2026));
}

test "displayWidth: CJK + Hangul + fullwidth = 2 cols" {
    try testing.expectEqual(@as(u8, 2), displayWidth(0x4E2D));
    try testing.expectEqual(@as(u8, 2), displayWidth(0xAC00));
    try testing.expectEqual(@as(u8, 2), displayWidth(0xFF21));
}

test "displayWidth: emoji ranges = 2 cols" {
    try testing.expectEqual(@as(u8, 2), displayWidth(0x1F600));
    try testing.expectEqual(@as(u8, 2), displayWidth(0x1F680));
    try testing.expectEqual(@as(u8, 2), displayWidth(0x1F1E6));
    try testing.expectEqual(@as(u8, 2), displayWidth(0x2728));
}

test "displayWidth: combining marks + ZWJ + variation selectors = 0 cols" {
    try testing.expectEqual(@as(u8, 0), displayWidth(0x0301));
    try testing.expectEqual(@as(u8, 0), displayWidth(0x200D));
    try testing.expectEqual(@as(u8, 0), displayWidth(0xFE0F));
    try testing.expectEqual(@as(u8, 0), displayWidth(0x200B));
}

test "measureCols: ascii string sums byte count" {
    try testing.expectEqual(@as(usize, 5), measureCols("hello"));
    try testing.expectEqual(@as(usize, 0), measureCols(""));
}

test "measureCols: bullet billed as 1 col despite 3 bytes" {
    try testing.expectEqual(@as(usize, 3), measureCols("\u{2022} a"));
}

test "measureCols: mixed CJK + ASCII" {
    try testing.expectEqual(@as(usize, 6), measureCols("\u{4E2D}\u{6587}ok"));
}

test "measureCols: emoji bills 2 cols" {
    try testing.expectEqual(@as(usize, 2), measureCols("\u{1F600}"));
    try testing.expectEqual(@as(usize, 3), measureCols("\u{1F600} "));
}

test "truncateToCols: cuts on codepoint boundary, not mid-sequence" {
    const input = "a\u{2022}b";
    try testing.expectEqualSlices(u8, "a", truncateToCols(input, 1));
    try testing.expectEqualSlices(u8, "a\u{2022}", truncateToCols(input, 2));
    try testing.expectEqualSlices(u8, "a\u{2022}b", truncateToCols(input, 3));
    try testing.expectEqualSlices(u8, "a\u{2022}b", truncateToCols(input, 99));
}

test "truncateToCols: wide char doesn't fit in 1 col budget, dropped whole" {
    const input = "\u{4E2D}x";
    try testing.expectEqualSlices(u8, "", truncateToCols(input, 1));
    try testing.expectEqualSlices(u8, "\u{4E2D}", truncateToCols(input, 2));
    try testing.expectEqualSlices(u8, "\u{4E2D}x", truncateToCols(input, 3));
}

test "truncateToCols: zero budget returns empty" {
    try testing.expectEqualSlices(u8, "", truncateToCols("abc", 0));
}

test "Utf8Iterator: invalid sequence yields U+FFFD + advances 1 byte" {
    const garbage = [_]u8{ 0xC0, 0x41 };
    var it = utf8Iter(&garbage);
    const first = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(u21, 0xFFFD), first.cp);
    try testing.expectEqual(@as(usize, 1), first.byte_len);
    const second = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(u21, 'A'), second.cp);
    try testing.expectEqual(@as(?mod.Codepoint, null), it.next());
}

test "Utf8Iterator: truncated multibyte yields U+FFFD then stops" {
    const truncated = [_]u8{0xE2};
    var it = utf8Iter(&truncated);
    const first = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(u21, 0xFFFD), first.cp);
    try testing.expectEqual(@as(?mod.Codepoint, null), it.next());
}

test "truncateToCols on invalid sequence doesn't loop forever" {
    const garbage = [_]u8{ 0xFF, 0xFE, 0xFD };
    const out = truncateToCols(&garbage, 10);
    try testing.expect(out.len <= garbage.len);
}
