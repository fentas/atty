//! DSR — Device Status Report.
//!
//! We send `\x1b[6n` to the terminal; the terminal replies via our
//! stdin with `\x1b[<row>;<col>R`. The reply is intercepted in the
//! stdin handler before it reaches the shell — the shell doesn't
//! speak DSR replies and would echo them as mojibake.
//!
//! The (row, col) is 1-based, matches the visible cursor position
//! at the moment of the query. Combined with sending the query at
//! a known state (e.g. just after a fresh prompt appears, before
//! the user types anything), it tells us **where the input region
//! starts** without needing to parse the prompt itself.

const std = @import("std");

/// Bytes to write to stdout when we want the terminal's current
/// cursor position. Sized inline at compile time so the proxy can
/// emit it without allocation.
pub const query_bytes = "\x1b[6n";

pub const Reply = struct {
    row: u16,
    col: u16,
};

pub const ExtractResult = struct {
    /// Input slice with DSR replies stripped out.
    cleaned: []const u8,
    /// The most-recent reply found in the chunk, or null. If the
    /// chunk contained several (multiple outstanding queries), the
    /// last wins — we only ever care about "current position now."
    reply: ?Reply,
};

/// Scan `input` for DSR-reply byte sequences of the form
/// `\x1b[<digits>;<digits>R`. Copy everything else into `scratch`
/// and return a slice over the copied bytes + the last reply (if
/// any). Caller is responsible for `scratch.len >= input.len`.
///
/// We accept slight slop (e.g. `R` immediately following `[` with
/// no digits) by failing the match and falling through to copy —
/// false positives are unlikely from normal stdin and the cost of
/// a wrong drop is much worse than letting an odd byte through.
pub fn extract(input: []const u8, scratch: []u8) ExtractResult {
    var out_len: usize = 0;
    var i: usize = 0;
    var last_reply: ?Reply = null;

    while (i < input.len) {
        // Try to recognise a DSR reply starting at i.
        if (input[i] == 0x1B and i + 1 < input.len and input[i + 1] == '[') {
            var j = i + 2;
            var row: u32 = 0;
            var have_row_digit = false;
            while (j < input.len and input[j] >= '0' and input[j] <= '9') : (j += 1) {
                row = row * 10 + (input[j] - '0');
                have_row_digit = true;
            }
            if (have_row_digit and j < input.len and input[j] == ';') {
                var col: u32 = 0;
                var have_col_digit = false;
                var k = j + 1;
                while (k < input.len and input[k] >= '0' and input[k] <= '9') : (k += 1) {
                    col = col * 10 + (input[k] - '0');
                    have_col_digit = true;
                }
                if (have_col_digit and k < input.len and input[k] == 'R') {
                    // Match. Skip the whole sequence in the output.
                    last_reply = .{
                        .row = @intCast(@min(row, 0xFFFF)),
                        .col = @intCast(@min(col, 0xFFFF)),
                    };
                    i = k + 1;
                    continue;
                }
            }
        }
        // Not a DSR reply — copy this byte and move on.
        if (out_len < scratch.len) {
            scratch[out_len] = input[i];
            out_len += 1;
        }
        i += 1;
    }
    return .{ .cleaned = scratch[0..out_len], .reply = last_reply };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "extract: pure DSR reply yields empty cleaned + populated reply" {
    var scratch: [64]u8 = undefined;
    const res = extract("\x1b[24;1R", &scratch);
    try testing.expectEqual(@as(usize, 0), res.cleaned.len);
    try testing.expect(res.reply != null);
    try testing.expectEqual(@as(u16, 24), res.reply.?.row);
    try testing.expectEqual(@as(u16, 1), res.reply.?.col);
}

test "extract: DSR reply embedded mid-typing is stripped, surrounding bytes survive" {
    var scratch: [64]u8 = undefined;
    const res = extract("ab\x1b[7;15Rcd", &scratch);
    try testing.expectEqualSlices(u8, "abcd", res.cleaned);
    try testing.expect(res.reply != null);
    try testing.expectEqual(@as(u16, 7), res.reply.?.row);
    try testing.expectEqual(@as(u16, 15), res.reply.?.col);
}

test "extract: multiple DSR replies — last wins" {
    var scratch: [64]u8 = undefined;
    const res = extract("\x1b[1;1Rmid\x1b[9;5R", &scratch);
    try testing.expectEqualSlices(u8, "mid", res.cleaned);
    try testing.expectEqual(@as(u16, 9), res.reply.?.row);
    try testing.expectEqual(@as(u16, 5), res.reply.?.col);
}

test "extract: similar-looking bytes that aren't DSR pass through unchanged" {
    var scratch: [64]u8 = undefined;
    // CUF (cursor forward) — same prefix, wrong terminator.
    const res = extract("\x1b[5C", &scratch);
    try testing.expectEqualSlices(u8, "\x1b[5C", res.cleaned);
    try testing.expectEqual(@as(?Reply, null), res.reply);
}

test "extract: malformed DSR-shaped sequences pass through, never drop user bytes" {
    var scratch: [64]u8 = undefined;
    // Missing semicolon.
    const r1 = extract("\x1b[24R", &scratch);
    try testing.expectEqualSlices(u8, "\x1b[24R", r1.cleaned);
    try testing.expectEqual(@as(?Reply, null), r1.reply);
    // Empty params.
    const r2 = extract("\x1b[;R", &scratch);
    try testing.expectEqualSlices(u8, "\x1b[;R", r2.cleaned);
    try testing.expectEqual(@as(?Reply, null), r2.reply);
}

test "extract: typed user input never confused with DSR" {
    var scratch: [256]u8 = undefined;
    // Plain ASCII, control chars, CSI cursor moves.
    const sample = "echo hi\r\x1b[A\x1b[C\x1b[1;5Cx";
    const res = extract(sample, &scratch);
    try testing.expectEqualSlices(u8, sample, res.cleaned);
    try testing.expectEqual(@as(?Reply, null), res.reply);
}
