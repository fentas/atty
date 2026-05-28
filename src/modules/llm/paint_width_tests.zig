const std = @import("std");
const testing = std.testing;
const mod = @import("paint_width.zig");

const displayWidth = mod.displayWidth;
const measureCols = mod.measureCols;
const truncateToCols = mod.truncateToCols;
const utf8Iter = mod.utf8Iter;
const writeSanitizedAllowSgr = mod.writeSanitizedAllowSgr;

test "displayWidth: ASCII printable = 1, control = 0" {
    try testing.expectEqual(@as(u8, 1), displayWidth('a'));
    try testing.expectEqual(@as(u8, 1), displayWidth(' '));
    try testing.expectEqual(@as(u8, 1), displayWidth('~'));
    try testing.expectEqual(@as(u8, 0), displayWidth(0x00));
    try testing.expectEqual(@as(u8, 0), displayWidth(0x1B));
    try testing.expectEqual(@as(u8, 0), displayWidth(0x7F));
}

test "displayWidth: tab billed as 1 col (writeSanitized passes it through)" {
    try testing.expectEqual(@as(u8, 1), displayWidth(0x09));
    try testing.expectEqual(@as(usize, 3), measureCols("a\tb"));
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

const wrapIter = mod.wrapIter;

fn collectWraps(allocator: std.mem.Allocator, text: []const u8, cols: usize) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var it = wrapIter(text, cols);
    while (it.next()) |chunk| try list.append(allocator, chunk);
    return list.toOwnedSlice(allocator);
}

test "wrapIter: short string fits in one chunk" {
    const out = try collectWraps(testing.allocator, "hi", 5);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualSlices(u8, "hi", out[0]);
}

test "wrapIter: breaks at word boundary, drops the wrapping space" {
    const out = try collectWraps(testing.allocator, "hello world", 5);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualSlices(u8, "hello", out[0]);
    try testing.expectEqualSlices(u8, "world", out[1]);
}

test "wrapIter: multi-word picks the last fitting space" {
    const out = try collectWraps(testing.allocator, "hello brave new world", 10);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualSlices(u8, "hello", out[0]);
    try testing.expectEqualSlices(u8, "brave new", out[1]);
    try testing.expectEqualSlices(u8, "world", out[2]);
}

test "wrapIter: long unbreakable token hard-breaks on codepoint boundary" {
    const out = try collectWraps(testing.allocator, "supercalifragilistic", 5);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqualSlices(u8, "super", out[0]);
    try testing.expectEqualSlices(u8, "calif", out[1]);
    try testing.expectEqualSlices(u8, "ragil", out[2]);
    try testing.expectEqualSlices(u8, "istic", out[3]);
}

test "wrapIter: respects display width — wide char fills row even alone" {
    const out = try collectWraps(testing.allocator, "\u{4E2D}\u{6587}", 2);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualSlices(u8, "\u{4E2D}", out[0]);
    try testing.expectEqualSlices(u8, "\u{6587}", out[1]);
}

test "wrapIter: empty input → no chunks" {
    const out = try collectWraps(testing.allocator, "", 10);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "wrapIter: all-whitespace input drops everything" {
    const out = try collectWraps(testing.allocator, "     ", 10);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "wrapIter: cols=0 falls back to 1-col, still terminates" {
    const out = try collectWraps(testing.allocator, "ab", 0);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
}

test "writeSanitized: strips C0 controls (incl. ESC) and emits no escape sequences" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Mixed input: plain text + ESC + a faux ANSI color escape +
    // BEL + DEL. Everything in the C0 range (except tab/CR/LF
    // which collapse to space or pass through) must be dropped.
    const input = "hello\x1B[31mworld\x07!\x7Fend";
    try mod.writeSanitized(&w, input);
    const out = buf[0..w.end];
    // No ESC byte (0x1B) survives.
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x1B) == null);
    // No BEL (0x07).
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null);
    // No DEL (0x7F).
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x7F) == null);
    // The text content (minus controls) survives in order.
    try testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, out, "world") != null);
    try testing.expect(std.mem.indexOf(u8, out, "end") != null);
}

test "writeSanitized: preserves multi-byte UTF-8 sequences" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Em-dash (—, U+2014, 3 bytes: 0xE2 0x80 0x94), continuation
    // bytes are in 0x80..0x9F range which is C1-shaped at the
    // byte level. The codepoint-aware filter must let these
    // through.
    const input = "before \u{2014} after";
    try mod.writeSanitized(&w, input);
    const out = buf[0..w.end];
    try testing.expectEqualStrings("before \u{2014} after", out);
}

test "writeSanitized: \\t passes through; \\n and \\r collapse to space" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try mod.writeSanitized(&w, "a\tb\nc\rd");
    const out = buf[0..w.end];
    try testing.expectEqualStrings("a\tb c d", out);
}

test "writeSanitized: invalid UTF-8 + raw C1 bytes are dropped, not pass-through" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Inputs covering each invalid-UTF-8 shape utf8Iter can yield
    // U+FFFD for:
    //   - 0x9B: bare 8-bit CSI byte (was leaking pre-fix because
    //     decoded cp=U+FFFD bypasses the 0x80..0x9F C1 check)
    //   - 0xC2 alone: incomplete 2-byte start
    //   - 0xE2 0x80: truncated 3-byte sequence (em-dash leading
    //     2 bytes, missing the 0x94 trailer)
    //   - 0xFF: unmappable start byte
    const input = "before\x9B[31m\xC2_\xE2\x80_\xFFafter";
    try mod.writeSanitized(&w, input);
    const out = buf[0..w.end];
    // Output must not carry any byte ≥ 0x80 that came from the
    // mid-string invalid sequences. The surrounding ASCII text
    // ("before"/"after"/"_"/"_" + the `[31m` chunk that follows
    // the 0x9B) DOES survive — the filter only drops the
    // malformed bytes themselves, not their neighbours.
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x9B) == null);
    try testing.expect(std.mem.indexOfScalar(u8, out, 0xC2) == null);
    try testing.expect(std.mem.indexOfScalar(u8, out, 0xE2) == null);
    try testing.expect(std.mem.indexOfScalar(u8, out, 0xFF) == null);
    // U+FFFD itself (the replacement glyph) must NOT appear —
    // we drop it entirely rather than emit its 3-byte UTF-8
    // encoding (ef bf bd).
    try testing.expect(std.mem.indexOf(u8, out, "\u{FFFD}") == null);
    // ASCII context survives.
    try testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try testing.expect(std.mem.indexOf(u8, out, "after") != null);
}

test "writeSanitizedAllowSgr: passes SGR through unchanged (#311)" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeSanitizedAllowSgr(&w, "\x1B[31merror:\x1B[0m bad");
    try testing.expectEqualStrings("\x1B[31merror:\x1B[0m bad", buf[0..w.end]);
}

test "writeSanitizedAllowSgr: strips cursor-motion + clear CSIs" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // `\x1B[H` (cursor home), `\x1B[2J` (clear screen),
    // `\x1B[K` (clear-to-EOL) all dropped; surrounding text + SGR
    // survive.
    try writeSanitizedAllowSgr(&w, "\x1B[Hbefore\x1B[2J\x1B[32mok\x1B[0m\x1B[Kafter");
    try testing.expectEqualStrings("before\x1B[32mok\x1B[0mafter", buf[0..w.end]);
}

test "writeSanitizedAllowSgr: preserves newlines (unlike strict sanitizer)" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeSanitizedAllowSgr(&w, "line1\nline2\r\nline3");
    try testing.expectEqualStrings("line1\nline2\r\nline3", buf[0..w.end]);
}

test "writeSanitizedAllowSgr: drops bare ESC + lone C0 + DEL" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeSanitizedAllowSgr(&w, "a\x1Bb\x01c\x7Fd");
    try testing.expectEqualStrings("abcd", buf[0..w.end]);
}

test "writeSanitizedAllowSgr: drops malformed CSI (non-final byte in param range)" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // Truncated CSI with no final byte at EOF — the function
    // should drop the lead and skip the rest.
    try writeSanitizedAllowSgr(&w, "a\x1B[31");
    try testing.expectEqualStrings("a", buf[0..w.end]);
}

test "writeSanitizedAllowSgr: keeps multi-byte UTF-8" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // £ = 0xC2 0xA3, ✓ = 0xE2 0x9C 0x93 — both pass through.
    try writeSanitizedAllowSgr(&w, "price \xc2\xa3" ++ "5 \xe2\x9c\x93");
    try testing.expectEqualStrings("price \xc2\xa3" ++ "5 \xe2\x9c\x93", buf[0..w.end]);
}
