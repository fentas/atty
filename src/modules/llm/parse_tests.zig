//! Tests for `modules/llm/parse.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("parse.zig");

// Re-binds of pub decls so test bodies stay short.
const decodeContent = mod.decodeContent;
const sanitizeCommand = mod.sanitizeCommand;
const sanitizeExplanation = mod.sanitizeExplanation;
const stripControlBytes = mod.stripControlBytes;

// ===========================================================================
// Tests
// ===========================================================================

test "decodeContent returns 0 on unterminated content string (regression)" {
    // Truncated JSON: closing quote never seen. Pre-fix this would
    // walk to end-of-buffer and return whatever it had partially
    // decoded as if it were a valid command — a model could exploit
    // this by emitting an unterminated string that ends with a
    // dangerous prefix and the upstream sanitiser would still let
    // it through as "valid extraction".
    var out: [128]u8 = undefined;
    const truncated = "{\"choices\":[{\"message\":{\"content\":\"rm -rf /home";
    try testing.expectEqual(@as(usize, 0), decodeContent(truncated, &out));

    // Empty unterminated still 0.
    const empty_truncated = "{\"content\":\"";
    try testing.expectEqual(@as(usize, 0), decodeContent(empty_truncated, &out));

    // Properly terminated still works (control).
    const ok = "{\"content\":\"echo hi\"}";
    const n = decodeContent(ok, &out);
    try testing.expectEqualStrings("echo hi", out[0..n]);
}

test "sanitizeCommand handles fence + whitespace combinations" {
    var out: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 6), sanitizeCommand("  ls -la  ", &out));
    try testing.expectEqualStrings("ls -la", out[0..6]);

    try testing.expectEqual(@as(usize, 6), sanitizeCommand("```bash\nls -la\n```", &out));
    try testing.expectEqualStrings("ls -la", out[0..6]);
}

test "sanitizeCommand strips raw control bytes — defence in depth (security)" {
    var out: [128]u8 = undefined;
    const n = sanitizeCommand("ls -la\r ; rm -rf /", &out);
    try testing.expectEqualStrings("ls -la ; rm -rf /", out[0..n]);
    for (out[0..n]) |b| try testing.expect(b != '\r');

    const n2 = sanitizeCommand("ls\x00 -la\x08\x7Fextra", &out);
    try testing.expectEqualStrings("ls -laextra", out[0..n2]);
}

test "sanitizeCommand strips C1 control codepoints — terminal-escape injection (security)" {
    var out: [128]u8 = undefined;

    // U+009B (UTF-8 0xC2 0x9B) followed by an SGR-style payload.
    // Both bytes must vanish.
    const n = sanitizeCommand("ls\xC2\x9B31mred", &out);
    try testing.expectEqualStrings("ls31mred", out[0..n]);

    // Standalone 0x9B (Latin-1 / invalid-UTF-8 path).
    const n2 = sanitizeCommand("rm\x9B -rf /tmp", &out);
    try testing.expectEqualStrings("rm -rf /tmp", out[0..n2]);

    // Sweep the whole C1 block (U+0080..U+009F).
    var cp: u8 = 0x80;
    while (cp <= 0x9F) : (cp += 1) {
        const input = [_]u8{ 'a', 0xC2, cp, 'b' };
        const m_n = sanitizeCommand(&input, &out);
        try testing.expectEqualStrings("ab", out[0..m_n]);
    }

    // Legitimate UTF-8 with continuation bytes in 0x80..0x9F
    // (NOT C1 controls — they're continuation bytes of a
    // multi-byte sequence) must survive intact.
    const n4 = sanitizeCommand("ƒoo", &out);
    try testing.expectEqualStrings("ƒoo", out[0..n4]);

    const n5 = sanitizeCommand("café", &out);
    try testing.expectEqualStrings("café", out[0..n5]);
}

test "sanitizeExplanation flattens newlines + strips control bytes" {
    var out: [128]u8 = undefined;

    const n = sanitizeExplanation("Line one.\nLine two.\nLine three.", &out);
    try testing.expectEqualStrings("Line one. Line two. Line three.", out[0..n]);

    const n2 = sanitizeExplanation("hello\x00\x07world\x7F", &out);
    try testing.expectEqualStrings("helloworld", out[0..n2]);

    const n3 = sanitizeExplanation("a   b\t\tc\n\nd", &out);
    try testing.expectEqualStrings("a b c d", out[0..n3]);
}

test "sanitizeExplanation strips C1 codepoints — terminal-escape injection (security)" {
    var out: [128]u8 = undefined;

    const n = sanitizeExplanation("hello\xC2\x9B31mworld", &out);
    try testing.expectEqualStrings("hello31mworld", out[0..n]);

    const n2 = sanitizeExplanation("foo\x9Bbar", &out);
    try testing.expectEqualStrings("foobar", out[0..n2]);

    const n3 = sanitizeExplanation("ƒoo", &out);
    try testing.expectEqualStrings("ƒoo", out[0..n3]);
}
