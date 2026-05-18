//! ANSI / CSI / SGR helpers — the minimum subset we need to render
//! ghost text without corrupting the terminal.
//!
//! All sequences here are widely supported across modern terminal
//! emulators (xterm, Ghostty, Alacritty, kitty, foot, tmux 3.x).

const std = @import("std");
const Style = @import("style.zig").Style;

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
pub const sgr_bold = "\x1B[1m";
pub const sgr_dim = "\x1B[2m";
pub const sgr_italic = "\x1B[3m";
pub const sgr_underline = "\x1B[4m";
pub const sgr_reverse = "\x1B[7m";

/// Wraps `text` in the SGR sequence described by `style` and appends
/// to the writer. The cursor is saved before the overlay and restored
/// after, so the shell's actual cursor position is untouched.
pub fn writeGhost(w: *std.Io.Writer, text: []const u8, style: Style) std.Io.Writer.Error!void {
    try w.writeAll(save_cursor);
    try w.print("{f}", .{style});
    try w.writeAll(text);
    try w.writeAll(sgr_reset);
    try w.writeAll(restore_cursor);
}

/// Emit the sequence to undo a previously rendered ghost overlay.
/// Idempotent — safe to call when no overlay is present.
pub fn writeClearGhost(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(save_cursor);
    try w.writeAll(erase_to_eol);
    try w.writeAll(restore_cursor);
}

/// Strip ANSI escape sequences from `input`, writing plain bytes to
/// `out`. Used by tests that want to compare the textual payload of
/// shell output. Handles CSI, OSC (terminated by BEL or ST), and lone
/// ESC introducers conservatively.
pub fn stripEscapes(input: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const b = input[i];
        if (b != ESC) {
            try out.append(gpa, b);
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
// Tests — extracted to `ansi_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("ansi_tests.zig");
}
