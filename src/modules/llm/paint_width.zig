//! UTF-8 codepoint walker + display-width helper for the LLM chat
//! paint surface. The panel renders user/LLM text with raw column
//! arithmetic — slicing byte-prefixes (`text[0..max_visible]`) cuts
//! through multi-byte sequences and the terminal prints replacement
//! glyphs (e.g. `•` U+2022 = `0xE2 0x80 0xA2`; sliced at byte 2 the
//! tail is invalid UTF-8 and shows as `�`). Codepoint iteration plus
//! a coarse East-Asian-Width lookup fixes both problems: truncation
//! stops on a codepoint boundary, and wide glyphs (CJK, emoji) bill
//! 2 columns so trailing chrome doesn't get pushed off-row.
//!
//! Scope is deliberately minimal — enough range coverage for emoji /
//! CJK / Hangul / fullwidth forms / regional indicators, ASCII
//! fast-path, and a zero-width set for combining marks + variation
//! selectors. Ambiguous-width characters default to 1 col (suits
//! Western terminals); full UAX#11 would inflate the table for no
//! gain in the chat-panel use case.

const std = @import("std");

pub const Codepoint = struct {
    cp: u21,
    byte_len: usize,
    width: u8,
};

pub const Utf8Iterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn next(it: *Utf8Iterator) ?Codepoint {
        if (it.i >= it.bytes.len) return null;
        const start = it.i;
        const b0 = it.bytes[start];
        if (b0 < 0x80) {
            it.i = start + 1;
            const w: u8 = if (b0 == 0x09) 1 else if (b0 < 0x20 or b0 == 0x7F) 0 else 1;
            return .{ .cp = b0, .byte_len = 1, .width = w };
        }
        const seq_len_or_err = std.unicode.utf8ByteSequenceLength(b0);
        const seq_len: usize = seq_len_or_err catch {
            it.i = start + 1;
            return .{ .cp = 0xFFFD, .byte_len = 1, .width = 1 };
        };
        const slice = it.bytes[start..];
        if (seq_len > slice.len) {
            it.i = start + 1;
            return .{ .cp = 0xFFFD, .byte_len = 1, .width = 1 };
        }
        const cp_or_err = std.unicode.utf8Decode(slice[0..seq_len]);
        const cp: u21 = cp_or_err catch {
            it.i = start + 1;
            return .{ .cp = 0xFFFD, .byte_len = 1, .width = 1 };
        };
        it.i = start + seq_len;
        return .{ .cp = cp, .byte_len = seq_len, .width = displayWidth(cp) };
    }
};

pub fn utf8Iter(bytes: []const u8) Utf8Iterator {
    return .{ .bytes = bytes };
}

pub fn displayWidth(cp: u21) u8 {
    if (cp == 0x09) return 1;
    if (cp < 0x20 or cp == 0x7F) return 0;
    if (cp < 0x80) return 1;
    if (isZeroWidth(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

fn isZeroWidth(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F => true,
        0x0483...0x0489 => true,
        0x0591...0x05BD => true,
        0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7 => true,
        0x0610...0x061A => true,
        0x064B...0x065F, 0x0670 => true,
        0x06D6...0x06DC => true,
        0x06DF...0x06E4 => true,
        0x06E7, 0x06E8 => true,
        0x06EA...0x06ED => true,
        0x0711 => true,
        0x0730...0x074A => true,
        0x07A6...0x07B0 => true,
        0x07EB...0x07F3 => true,
        0x0816...0x0819 => true,
        0x081B...0x0823 => true,
        0x0825...0x0827 => true,
        0x0829...0x082D => true,
        0x0859...0x085B => true,
        0x08E3...0x0902 => true,
        0x093A, 0x093C => true,
        0x0941...0x0948, 0x094D => true,
        0x0951...0x0957 => true,
        0x0962, 0x0963 => true,
        0x200B...0x200F => true,
        0x202A...0x202E => true,
        0x2060...0x206F => true,
        0xFE00...0xFE0F => true,
        0xFEFF => true,
        0xE0000...0xE007F => true,
        0xE0100...0xE01EF => true,
        else => false,
    };
}

fn isWide(cp: u21) bool {
    if (cp < 0x1100) return false;
    return switch (cp) {
        0x1100...0x115F => true,
        0x231A, 0x231B => true,
        0x2329, 0x232A => true,
        0x23E9...0x23EC => true,
        0x23F0 => true,
        0x23F3 => true,
        0x25FD, 0x25FE => true,
        0x2614, 0x2615 => true,
        0x2648...0x2653 => true,
        0x267F => true,
        0x2693 => true,
        0x26A1 => true,
        0x26AA, 0x26AB => true,
        0x26BD, 0x26BE => true,
        0x26C4, 0x26C5 => true,
        0x26CE => true,
        0x26D4 => true,
        0x26EA => true,
        0x26F2, 0x26F3, 0x26F5 => true,
        0x26FA, 0x26FD => true,
        0x2705 => true,
        0x270A, 0x270B => true,
        0x2728 => true,
        0x274C, 0x274E => true,
        0x2753...0x2755 => true,
        0x2757 => true,
        0x2795...0x2797 => true,
        0x27B0 => true,
        0x27BF => true,
        0x2E80...0x303E => true,
        0x3041...0x33FF => true,
        0x3400...0x4DBF => true,
        0x4E00...0x9FFF => true,
        0xA000...0xA4CF => true,
        0xAC00...0xD7A3 => true,
        0xF900...0xFAFF => true,
        0xFE30...0xFE4F => true,
        0xFF00...0xFF60 => true,
        0xFFE0...0xFFE6 => true,
        0x1F1E6...0x1F1FF => true,
        0x1F300...0x1F64F => true,
        0x1F680...0x1F6FF => true,
        0x1F700...0x1F77F => true,
        0x1F780...0x1F7FF => true,
        0x1F800...0x1F8FF => true,
        0x1F900...0x1F9FF => true,
        0x1FA00...0x1FAFF => true,
        0x20000...0x2FFFD => true,
        0x30000...0x3FFFD => true,
        else => false,
    };
}

pub fn measureCols(bytes: []const u8) usize {
    var it = utf8Iter(bytes);
    var sum: usize = 0;
    while (it.next()) |c| sum += c.width;
    return sum;
}

pub fn truncateToCols(bytes: []const u8, max_cols: usize) []const u8 {
    if (max_cols == 0) return bytes[0..0];
    var it = utf8Iter(bytes);
    var used: usize = 0;
    var end: usize = 0;
    while (it.next()) |c| {
        if (used + c.width > max_cols) break;
        used += c.width;
        end = it.i;
    }
    return bytes[0..end];
}

/// Greedy word-wrap iterator. `next()` yields slices of `bytes` each at
/// most `cols` display columns wide, breaking at the last space inside
/// the slice when possible and hard-breaking on a codepoint boundary
/// otherwise. Trailing spaces between chunks are consumed (so wrapping
/// `"foo bar"` at cols=3 yields `"foo"`, `"bar"` — not `"foo"`, `" ba"`).
pub const WrapIterator = struct {
    bytes: []const u8,
    i: usize = 0,
    cols: usize,

    pub fn next(it: *WrapIterator) ?[]const u8 {
        if (it.i >= it.bytes.len) return null;
        // Drop runs of plain spaces that landed between wrap points.
        while (it.i < it.bytes.len and it.bytes[it.i] == ' ') it.i += 1;
        if (it.i >= it.bytes.len) return null;

        const start = it.i;
        var ci = utf8Iter(it.bytes[start..]);
        var used: usize = 0;
        var fit_end: usize = 0;
        var last_space_start: ?usize = null;
        var last_space_after: usize = 0;
        var before_step: usize = 0;
        while (ci.next()) |c| {
            const new_used = used + c.width;
            if (new_used > it.cols) break;
            if (c.cp == ' ') {
                last_space_start = before_step;
                last_space_after = ci.i;
            }
            used = new_used;
            fit_end = ci.i;
            before_step = ci.i;
        }

        if (start + fit_end >= it.bytes.len) {
            it.i = it.bytes.len;
            return it.bytes[start..it.bytes.len];
        }

        if (last_space_start) |sp| {
            if (sp > 0) {
                it.i = start + last_space_after;
                return it.bytes[start .. start + sp];
            }
        }

        // No space found inside this row — hard break.
        if (fit_end == 0) {
            var single = utf8Iter(it.bytes[start..]);
            if (single.next()) |c2| fit_end = c2.byte_len;
        }
        it.i = start + fit_end;
        return it.bytes[start .. start + fit_end];
    }
};

pub fn wrapIter(bytes: []const u8, cols: usize) WrapIterator {
    return .{ .bytes = bytes, .cols = if (cols == 0) 1 else cols };
}

/// Write `bytes` to `w` with C0 / C1 control characters
/// stripped (or, for `\t` / `\n` / `\r`, replaced with a space).
/// Preserves valid UTF-8 multi-byte sequences whose continuation
/// bytes happen to fall in the 0x80..0xBF range (em-dash,
/// emoji, CJK glyphs all survive).
///
/// Used everywhere ATTACKER- or MODEL-controlled text reaches
/// the terminal: chat overlay turn content, inline panel turn
/// content, and the LLM session-conclusion banner's reason
/// field. Without this, a `ESC[31m` JSON escape in an LLM
/// reply could re-colour the user's prompt, hide arbitrary
/// rows behind ANSI cursor-up sequences, or worse.
///
/// `\t` passes through; `\n` and `\r` collapse to a single
/// space so a multi-line value can't introduce a hard break
/// where the chrome doesn't expect one.
pub fn writeSanitized(w: *std.Io.Writer, bytes: []const u8) anyerror!void {
    var it = utf8Iter(bytes);
    while (it.next()) |c| {
        // Drop the Unicode replacement codepoint (U+FFFD).
        // `utf8Iter` yields this for any invalid sequence:
        // bare continuation byte, truncated multi-byte sequence,
        // overlong encoding, or an unmappable start byte. Without
        // this filter, the original raw byte gets emitted —
        // which lets a raw 0x9B (8-bit CSI) or other C1-range
        // byte slip through despite the explicit C1 check
        // below (which compares the DECODED codepoint, not the
        // raw byte). Dropping U+FFFD also tightens the contract:
        // "this filter emits only well-formed, printable
        // codepoints" — the terminal never sees malformed
        // UTF-8 bytes via this path.
        if (c.cp == 0xFFFD) continue;
        if (c.cp < 0x20 or c.cp == 0x7F) {
            if (c.cp == 0x09) {
                try w.writeAll("\t");
            } else if (c.cp == 0x0A or c.cp == 0x0D) {
                try w.writeAll(" ");
            }
            continue;
        }
        if (c.cp >= 0x80 and c.cp <= 0x9F) continue;
        const start = it.i - c.byte_len;
        try w.writeAll(bytes[start..it.i]);
    }
}

test {
    _ = @import("paint_width_tests.zig");
}
