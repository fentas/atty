//! Pure response-parsing + sanitization helpers for the LLM module.
//!
//! These functions are bytes-in / bytes-out — they don't reach for
//! any `cfg` field, don't touch the Runtime, and don't allocate.
//! Lifted out of the comptime `configure()` return-struct so the
//! parent module stays focused on the framework hooks (attach,
//! detach, onInput, onLineCommit, …) and the security-critical
//! sanitizers live in one self-contained file with their tests.
//!
//! **Security note**: writing a `\r` (CR) or `\n` (LF) byte to the
//! PTY acts as Enter — the shell would immediately execute whatever
//! sits in its readline buffer. `decodeContent` drops `\r` at JSON
//! decode time; `sanitizeCommand` repeats the strip as defence in
//! depth. Both also drop C1 controls (raw 0x80-0x9F and UTF-8
//! 0xC2 0x80-0x9F) so a model can't sneak a CSI escape past us.

const std = @import("std");

/// Minimal extractor that pulls the JSON `"content"` field of an
/// OpenAI-style chat-completion response into a flat byte buffer.
/// Drops `\r` for security, decodes `\n` / `\t` / `\"` / `\\` /
/// `\/`, skips `\uXXXX` and other escapes. Returns 0 when the field
/// is missing or the body is malformed.
pub fn decodeContent(body: []const u8, out: []u8) usize {
    // Robust JSON parsing would be nicer but std.json's Scanner is
    // heavyweight; for the OpenAI / Ollama shape this matches both
    // compact (`"content":"…"`) and pretty-printed (`"content":
    // "…"`) formatting that some compatible servers emit.
    const key = "\"content\"";
    const start = std.mem.indexOf(u8, body, key) orelse return 0;
    var i: usize = start + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) i += 1;
    if (i >= body.len or body[i] != ':') return 0;
    i += 1;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) i += 1;
    if (i >= body.len or body[i] != '"') return 0;
    i += 1;
    var n: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) {
            const e = body[i + 1];
            switch (e) {
                '"', '\\', '/', 'n', 't' => {
                    const decoded: u8 = switch (e) {
                        '"' => '"',
                        '\\' => '\\',
                        '/' => '/',
                        'n' => '\n',
                        't' => '\t',
                        else => unreachable,
                    };
                    if (n < out.len) {
                        out[n] = decoded;
                        n += 1;
                    }
                    i += 1;
                },
                // Drop \r — writing CR to the PTY acts as Enter,
                // so a partial command would auto-execute without
                // user review.
                'r' => i += 1,
                'u' => {
                    // `\uXXXX` — skip up to 4 hex digits after the
                    // `u`, but bail early at a closing quote or
                    // backslash so malformed JSON (fewer than 4 hex
                    // digits) cannot cause us to skip past the
                    // content boundary into the next field.
                    i += 1;
                    var k: usize = 0;
                    while (k < 4 and i + 1 < body.len) : (k += 1) {
                        const h = body[i + 1];
                        if (h == '"' or h == '\\') break;
                        i += 1;
                    }
                },
                else => i += 1,
            }
            continue;
        }
        if (c == '"') break;
        if (n < out.len) {
            out[n] = c;
            n += 1;
        }
    }
    return n;
}

/// Flatten prose to a single line, strip control bytes, truncate
/// to `out.len`. Multi-line explanations join with a single space
/// rather than dropping the trailing lines — the hint row only
/// fits one line but the user gets the gist.
pub fn sanitizeExplanation(raw: []const u8, out: []u8) usize {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    // Two-pass: first collapse whitespace + drop C0/DEL into a
    // scratch buffer, then run the C1-aware UTF-8 stripper over
    // that. We can't merge the passes because the whitespace
    // collapsing needs to see the trimmed bytes before any
    // sequence-boundary scanning, and the C1 stripper needs to see
    // all bytes (including legitimate UTF-8 continuations) to
    // track sequence length. Splitting keeps each step simple and
    // reuses the same C1 logic the command path is hardened with.
    var scratch: [1024]u8 = undefined;
    const scratch_cap = @min(scratch.len, out.len);
    var s_n: usize = 0;
    var last_was_space = false;
    for (trimmed) |b| {
        if (b == '\n' or b == '\r' or b == '\t' or b == ' ') {
            if (last_was_space) continue;
            if (s_n >= scratch_cap) break;
            scratch[s_n] = ' ';
            s_n += 1;
            last_was_space = true;
            continue;
        }
        // Drop C0 controls + DEL early. C1 stripping is delegated
        // to `stripControlBytes` below so the logic stays in one
        // place (defence in depth — a raw 0x9B byte would
        // otherwise reach the terminal as CSI).
        if (b < 0x20 or b == 0x7F) continue;
        if (s_n >= scratch_cap) break;
        scratch[s_n] = b;
        s_n += 1;
        last_was_space = false;
    }
    // Trim a trailing whitespace introduced by the join above.
    while (s_n > 0 and scratch[s_n - 1] == ' ') s_n -= 1;

    return stripControlBytes(scratch[0..s_n], out);
}

/// UTF-8-aware filter that drops:
///   - C0 controls (< 0x20) and DEL (0x7F)
///   - C1 controls U+0080..U+009F as raw bytes (Latin-1 /
///     invalid-UTF-8 interpretation) AND as UTF-8 (`0xC2`
///     followed by `0x80..0x9F`).
/// Legitimate UTF-8 multi-byte sequences pass through whole;
/// continuation bytes in `0x80..0xBF` that aren't standalone are
/// preserved (e.g. "ƒ" = `0xC6 0x92`, where 0x92 is a continuation,
/// not a C1 codepoint). Malformed / truncated sequences drop just
/// the bad lead byte and continue.
///
/// Used by both `sanitizeCommand` (PTY-bound bytes) and
/// `sanitizeExplanation` (terminal-bound bytes) — both destinations
/// honour C1 controls, so both need the strip.
pub fn stripControlBytes(s: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            if (b < 0x20 or b == 0x7F) {
                i += 1;
                continue;
            }
            if (n >= out.len) break;
            out[n] = b;
            n += 1;
            i += 1;
            continue;
        }
        const seq_len: usize = if (b >= 0xC2 and b <= 0xDF) 2 else if (b >= 0xE0 and b <= 0xEF) 3 else if (b >= 0xF0 and b <= 0xF4) 4 else 0;
        if (seq_len == 0 or i + seq_len > s.len) {
            i += 1;
            continue;
        }
        if (seq_len == 2 and b == 0xC2 and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F) {
            i += 2;
            continue;
        }
        var ok = true;
        var k: usize = 1;
        while (k < seq_len) : (k += 1) {
            if (s[i + k] < 0x80 or s[i + k] > 0xBF) {
                ok = false;
                break;
            }
        }
        if (!ok) {
            i += 1;
            continue;
        }
        if (n + seq_len > out.len) break;
        @memcpy(out[n .. n + seq_len], s[i .. i + seq_len]);
        n += seq_len;
        i += seq_len;
    }
    return n;
}

/// Trim markdown fences (```bash … ```) + whitespace + take the
/// first non-empty line + strip remaining control bytes. Some
/// models stubbornly wrap in fences.
///
/// **Security**: defence-in-depth strip for any control byte that
/// survives JSON decoding (incl. embedded NUL / BEL / BS / HT / CR
/// / LF / 0x01..0x1F / 0x7F + C1 controls via stripControlBytes).
pub fn sanitizeCommand(raw: []const u8, out: []u8) usize {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, s, "```")) {
        if (std.mem.indexOfScalar(u8, s, '\n')) |nl| {
            s = s[nl + 1 ..];
        } else {
            s = s[3..];
        }
    }
    if (std.mem.endsWith(u8, s, "```")) {
        s = s[0 .. s.len - 3];
    }
    s = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s = s[0..nl];
    s = std.mem.trim(u8, s, " \t\r");
    return stripControlBytes(s, out);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

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
