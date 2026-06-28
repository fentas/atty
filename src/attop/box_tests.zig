const std = @import("std");
const testing = std.testing;
const mod = @import("box.zig");

test "drawBox: borders, title, content rows" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const lines = [_][]const u8{ "pid       4242", "shell     bash" };
    try mod.drawBox(&w, "Session", &lines, 80);
    const out = buf[0..w.end];

    // Corners + the title present.
    try testing.expect(std.mem.indexOf(u8, out, "\u{250C}") != null); // ┌
    try testing.expect(std.mem.indexOf(u8, out, "\u{2510}") != null); // ┐
    try testing.expect(std.mem.indexOf(u8, out, "\u{2514}") != null); // └
    try testing.expect(std.mem.indexOf(u8, out, "\u{2518}") != null); // ┘
    try testing.expect(std.mem.indexOf(u8, out, "Session") != null);
    // Both content rows.
    try testing.expect(std.mem.indexOf(u8, out, "pid       4242") != null);
    try testing.expect(std.mem.indexOf(u8, out, "shell     bash") != null);
    // One vertical bar per side per content row → at least 2 rows × 2 bars.
    try testing.expect(std.mem.count(u8, out, "\u{2502}") >= 4);
}

test "drawBox: narrow width clamps without overflow" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const lines = [_][]const u8{"a-very-long-content-line-that-exceeds-the-cap"};
    // max_cols=20 → inner capped to 12; the long line is byte-truncated.
    try mod.drawBox(&w, "T", &lines, 20);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "a-very-long-") != null); // truncated head
    try testing.expect(std.mem.indexOf(u8, out, "exceeds") == null); // tail dropped
}
