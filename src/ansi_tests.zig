//! Tests for `ansi.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("ansi.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const Style = @import("style.zig").Style;

// Re-binds of pub decls so test bodies stay short.
const csi_intro = mod.csi_intro;
const erase_to_eol = mod.erase_to_eol;
const ESC = mod.ESC;
const restore_cursor = mod.restore_cursor;
const save_cursor = mod.save_cursor;
const sgr_bold = mod.sgr_bold;
const sgr_dim = mod.sgr_dim;
const sgr_italic = mod.sgr_italic;
const sgr_reset = mod.sgr_reset;
const sgr_reverse = mod.sgr_reverse;
const sgr_underline = mod.sgr_underline;
const stripEscapes = mod.stripEscapes;
const writeClearGhost = mod.writeClearGhost;
const writeGhost = mod.writeGhost;

// ===========================================================================
// Tests
// ===========================================================================

test "writeGhost wraps text in the requested style" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeGhost(&w, "hello", .{ .dim = true });
    const s = buf[0..w.end];
    try std.testing.expect(std.mem.indexOf(u8, s, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, sgr_dim) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, save_cursor) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, restore_cursor) != null);
}

test "writeGhost honours italic + fg color when set" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeGhost(&w, "x", .{ .italic = true, .fg = 244 });
    const s = buf[0..w.end];
    try std.testing.expect(std.mem.indexOf(u8, s, sgr_italic) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1B[38;5;244m") != null);
}

test "writeGhost emits nothing extra when style is fully default" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeGhost(&w, "x", .{ .dim = false });
    const s = buf[0..w.end];
    // Still wraps with save/restore + reset, but no SGR attrs in between.
    try std.testing.expect(std.mem.indexOf(u8, s, sgr_dim) == null);
    try std.testing.expect(std.mem.indexOf(u8, s, sgr_italic) == null);
}

test "stripEscapes removes CSI" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try stripEscapes("\x1B[31mred\x1B[0m text", &out, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "red text", out.items);
}

test "stripEscapes removes OSC" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try stripEscapes("\x1B]0;title\x07hello", &out, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "hello", out.items);
}

test "stripEscapes handles ESC-ST terminated OSC" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try stripEscapes("\x1B]2;t\x1B\\done", &out, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "done", out.items);
}

test "writeClearGhost emits save_cursor + erase_to_eol + restore_cursor" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClearGhost(&w);
    const s = buf[0..w.end];
    try std.testing.expect(std.mem.indexOf(u8, s, save_cursor) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, erase_to_eol) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, restore_cursor) != null);
}
