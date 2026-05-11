//! ANSI / CSI / SGR helpers — the minimum subset we need to render
//! ghost text without corrupting the terminal.
//!
//! All sequences here are widely supported across modern terminal
//! emulators (xterm, Ghostty, Alacritty, kitty, foot, tmux 3.x).

const std = @import("std");

// Single-byte CSI introducer — works in 7-bit and 8-bit modes.
pub const ESC: u8 = 0x1B;
pub const csi_intro = "\x1B[";

// ---------------------------------------------------------------------------
// Cursor save/restore
//
// We use DECSC/DECRC (ESC 7 / ESC 8) rather than the SCO sequences (CSI s /
// CSI u) because the former save *more* state (cursor + attributes +
// character set). xterm and Ghostty both implement DECSC correctly; some
// older terminals don't, but those aren't the audience for atty.
pub const save_cursor = "\x1B7";
pub const restore_cursor = "\x1B8";

// Clear to end of line — used to wipe an existing ghost-text overlay.
pub const erase_to_eol = "\x1B[K";

// SGR codes
pub const sgr_reset = "\x1B[0m";
/// Dim/faint — what we use to render ghost text. Most terminals render
/// this as ~50% intensity.
pub const sgr_dim = "\x1B[2m";
/// Italic — useful as a secondary cue alongside dim. Skipped by some
/// terminals; behavior degrades to plain dim, which is fine.
pub const sgr_italic = "\x1B[3m";

/// Wraps `text` in dim/italic SGR codes and appends to writer.
pub fn writeGhost(writer: anytype, text: []const u8) !void {
    try writer.writeAll(save_cursor);
    try writer.writeAll(sgr_dim);
    try writer.writeAll(sgr_italic);
    try writer.writeAll(text);
    try writer.writeAll(sgr_reset);
    try writer.writeAll(restore_cursor);
}

/// Emit the sequence to undo a previously rendered ghost overlay.
/// Idempotent — safe to call when no overlay is present.
pub fn writeClearGhost(writer: anytype) !void {
    try writer.writeAll(save_cursor);
    try writer.writeAll(erase_to_eol);
    try writer.writeAll(restore_cursor);
}

/// Strip ANSI escape sequences from `input`, writing plain bytes to
/// `out`. Used by tests that want to compare the textual payload of
/// shell output. Handles CSI, OSC (terminated by BEL or ST), and lone
/// ESC introducers conservatively.
pub fn stripEscapes(input: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const b = input[i];
        if (b != ESC) {
            try out.append(b);
            continue;
        }
        // ESC followed by '[' — CSI: consume until a final byte in 0x40..0x7E.
        if (i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len) : (i += 1) {
                if (input[i] >= 0x40 and input[i] <= 0x7E) break;
            }
            continue;
        }
        // ESC followed by ']' — OSC: consume until BEL (0x07) or ESC \ (ST).
        if (i + 1 < input.len and input[i + 1] == ']') {
            i += 2;
            while (i < input.len) : (i += 1) {
                if (input[i] == 0x07) break;
                if (input[i] == ESC and i + 1 < input.len and input[i + 1] == '\\') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        // Lone ESC or unknown two-byte escape: skip the ESC and one more byte.
        if (i + 1 < input.len) i += 1;
    }
}

// ===========================================================================
// Tests
// ===========================================================================

test "writeGhost wraps text" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try writeGhost(buf.writer(), "hello");
    const s = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, sgr_dim) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, save_cursor) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, restore_cursor) != null);
}

test "stripEscapes removes CSI" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try stripEscapes("\x1B[31mred\x1B[0m text", &out);
    try std.testing.expectEqualSlices(u8, "red text", out.items);
}

test "stripEscapes removes OSC" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try stripEscapes("\x1B]0;title\x07hello", &out);
    try std.testing.expectEqualSlices(u8, "hello", out.items);
}
