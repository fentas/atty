//! Tests for `test/e2e/vt.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("vt.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const Allocator = std.mem.Allocator;

// Re-binds of pub decls so test bodies stay short.
const Attrs = mod.Attrs;
const Cell = mod.Cell;
const Color = mod.Color;
const Grid = mod.Grid;

test "Grid prints plain ascii" {
    var g = try Grid.init(std.testing.allocator, 3, 10);
    defer g.deinit();
    g.feed("hi\r\nworld");
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderText(&w);
    try std.testing.expectEqualStrings("hi\nworld\n\n", w.buffered());
}

test "Grid handles CSI cursor and erase" {
    var g = try Grid.init(std.testing.allocator, 2, 10);
    defer g.deinit();
    g.feed("hello\x1b[1;1H\x1b[K");
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderText(&w);
    try std.testing.expectEqualStrings("\n\n", w.buffered());
}

test "Grid SGR colors a run of text" {
    var g = try Grid.init(std.testing.allocator, 1, 20);
    defer g.deinit();
    g.feed("\x1b[31mfoo\x1b[0m bar");
    var sgr_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&sgr_buf);
    try g.renderSgr(&w);
    try std.testing.expectEqualStrings("R0 C0-2 fg=1\n", w.buffered());
}

test "Grid ESC 7 / ESC 8 save and restore cursor" {
    var g = try Grid.init(std.testing.allocator, 3, 10);
    defer g.deinit();
    g.feed("ab\x1b7\r\nXY\x1b8cd");
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderText(&w);
    try std.testing.expectEqualStrings("abcd\nXY\n\n", w.buffered());
}

test "Grid wraps at row width and CR + LF advance correctly" {
    var g = try Grid.init(std.testing.allocator, 2, 4);
    defer g.deinit();
    g.feed("abcdef"); // 4 fit on row 0, 2 wrap to row 1
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderText(&w);
    try std.testing.expectEqualStrings("abcd\nef\n", w.buffered());
}

test "Grid backspace moves cursor one column left without erasing" {
    var g = try Grid.init(std.testing.allocator, 1, 6);
    defer g.deinit();
    // Type "ab", backspace once, type "X" — overwrites the 'b'.
    g.feed("ab\x08X");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderText(&w);
    try std.testing.expectEqualStrings("aX\n", w.buffered());
}

test "Grid SGR dim is observable in renderSgr (the ghost-text canary)" {
    var g = try Grid.init(std.testing.allocator, 1, 16);
    defer g.deinit();
    g.feed("ls\x1B[2m -la\x1B[0m");
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderSgr(&w);
    // Dim attribute should land on the trailing run, not on "ls".
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "dim") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "R0 C2-5 dim") != null);
}

test "Grid SGR 256-color fg is captured" {
    var g = try Grid.init(std.testing.allocator, 1, 10);
    defer g.deinit();
    g.feed("\x1B[38;5;244mhi\x1B[0m");
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderSgr(&w);
    try std.testing.expectEqualStrings("R0 C0-1 fg=244\n", w.buffered());
}

test "Grid CUP positions cursor; subsequent writes land at the new spot" {
    var g = try Grid.init(std.testing.allocator, 3, 8);
    defer g.deinit();
    // CUP to row 2, col 3 then write "XY". Row indices in VT are 1-based.
    g.feed("\x1B[2;3HXY");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderText(&w);
    try std.testing.expectEqualStrings("\n  XY\n\n", w.buffered());
}

test "Grid ED 2 clears the visible screen" {
    var g = try Grid.init(std.testing.allocator, 2, 6);
    defer g.deinit();
    g.feed("abc\r\nxyz\x1B[2J");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderText(&w);
    try std.testing.expectEqualStrings("\n\n", w.buffered());
}

test "Grid SGR italic is captured (atty.style.italic emits \\x1B[3m)" {
    var g = try Grid.init(std.testing.allocator, 1, 16);
    defer g.deinit();
    g.feed("\x1B[3mx\x1B[0m");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderSgr(&w);
    try std.testing.expectEqualStrings("R0 C0-0 italic\n", w.buffered());
}

test "Grid SGR 0 reset clears all attrs and colors mid-line" {
    // The guardrail warning style is dim+italic; ansi.writeGhost
    // wraps in sgr_reset; statusbar.render emits sgr_reset between
    // its text and the restore_cursor. If reset didn't actually
    // clear, trailing cells would inherit the dim attribute and our
    // e2e grid.sgr diffs would be noisy.
    var g = try Grid.init(std.testing.allocator, 1, 16);
    defer g.deinit();
    g.feed("\x1B[2;3mdim\x1B[0m clr");
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderSgr(&w);
    // First run carries dim + italic; second run is plain (no entry
    // emitted because Cell.isBlankDefault skips the default run).
    try std.testing.expectEqualStrings("R0 C0-2 dim italic\n", w.buffered());
}

test "Grid DECSTBM is parsed without crashing (no grid effect today)" {
    // Statusbar emits `\x1B[1;22r` to confine scrolling to rows 1..22.
    // The VT grid doesn't model scroll regions, so the directive is a
    // no-op — but it MUST NOT crash the parser or leave bytes in the
    // buffer. If a future change adds DECSTBM semantics, the assert
    // here gives us a concrete signal to update.
    var g = try Grid.init(std.testing.allocator, 4, 6);
    defer g.deinit();
    g.feed("\x1B[1;3rabc"); // DECSTBM then ASCII
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderText(&w);
    // "abc" lands on row 0; DECSTBM is silently consumed.
    try std.testing.expectEqualStrings("abc\n\n\n\n", w.buffered());
}

test "Grid resize preserves top-left content and clamps the cursor" {
    var g = try Grid.init(std.testing.allocator, 3, 10);
    defer g.deinit();
    g.feed("hello\r\nworld"); // cursor → row 1, col 5

    try g.resize(5, 20); // grow
    try testing.expectEqual(@as(u16, 5), g.rows);
    try testing.expectEqual(@as(u16, 20), g.cols);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try g.renderText(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "hello") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "world") != null);

    try g.resize(2, 3); // shrink — cols clamp content, cursor clamps in-bounds
    try testing.expectEqual(@as(u16, 2), g.rows);
    try testing.expectEqual(@as(u16, 3), g.cols);
    try testing.expect(g.cur_row < 2 and g.cur_col < 3);
    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try g.renderText(&w2);
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "hel") != null); // row 0, first 3 cols
}
