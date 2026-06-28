const std = @import("std");
const testing = std.testing;
const Frame = @import("frame.zig").Frame;

fn newFrame() !*Frame {
    const f = try testing.allocator.create(Frame);
    f.* = .{};
    return f;
}

test "diff: first frame clears + paints every row" {
    const f = try newFrame();
    defer testing.allocator.destroy(f);
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try f.diff("a\r\nb\r\nc", 24, &w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J\x1b[H") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a") != null);
    try testing.expect(std.mem.indexOf(u8, out, "b") != null);
    try testing.expect(std.mem.indexOf(u8, out, "c") != null);
    try testing.expectEqual(@as(usize, 3), f.row_count);
}

test "diff: second frame emits ONLY the changed row" {
    const f = try newFrame();
    defer testing.allocator.destroy(f);
    var b1: [1024]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&b1);
    try f.diff("a\r\nb\r\nc", 24, &w1); // prime

    var b2: [1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&b2);
    try f.diff("a\r\nX\r\nc", 24, &w2); // row 2 changed
    const out = b2[0..w2.end];
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2;1H") != null); // CUP row 2
    try testing.expect(std.mem.indexOf(u8, out, "X") != null);
    // No full clear; rows 1 + 3 are untouched.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[3;1H") == null);
}

test "diff: identical frame emits nothing" {
    const f = try newFrame();
    defer testing.allocator.destroy(f);
    var b1: [1024]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&b1);
    try f.diff("a\r\nb", 24, &w1);
    var b2: [1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&b2);
    try f.diff("a\r\nb", 24, &w2);
    try testing.expectEqual(@as(usize, 0), w2.end);
}

test "diff: a shrunk frame erases the dropped rows" {
    const f = try newFrame();
    defer testing.allocator.destroy(f);
    var b1: [1024]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&b1);
    try f.diff("a\r\nb\r\nc", 24, &w1); // 3 rows
    var b2: [1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&b2);
    try f.diff("a\r\nb", 24, &w2); // c dropped
    try testing.expect(std.mem.indexOf(u8, b2[0..w2.end], "\x1b[3;1H\x1b[K") != null);
}

test "invalidate forces a full repaint" {
    const f = try newFrame();
    defer testing.allocator.destroy(f);
    var b1: [1024]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&b1);
    try f.diff("a\r\nb", 24, &w1);
    f.invalidate();
    var b2: [1024]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&b2);
    try f.diff("a\r\nb", 24, &w2); // same content, but invalidated
    try testing.expect(std.mem.indexOf(u8, b2[0..w2.end], "\x1b[2J") != null);
}

test "diff: cap bounds the rows considered" {
    const f = try newFrame();
    defer testing.allocator.destroy(f);
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try f.diff("r0\r\nr1\r\nr2\r\nr3", 2, &w); // cap 2
    try testing.expectEqual(@as(usize, 2), f.row_count);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "r2") == null);
}
