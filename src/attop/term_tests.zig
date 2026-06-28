const std = @import("std");
const testing = std.testing;
const term = @import("term.zig");

test "size falls back to 80x24 on an invalid fd" {
    // fd -1 → ioctl fails → sane fallback dims so layout always has bounds.
    const s = term.size(-1);
    try testing.expectEqual(@as(u16, 24), s.rows);
    try testing.expectEqual(@as(u16, 80), s.cols);
}

test "screen escapes are the alt-screen + cursor sequences" {
    try testing.expect(std.mem.indexOf(u8, term.enter_screen, "?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, term.enter_screen, "?25l") != null);
    try testing.expect(std.mem.indexOf(u8, term.exit_screen, "?1049l") != null);
    try testing.expect(std.mem.indexOf(u8, term.exit_screen, "?25h") != null);
}
