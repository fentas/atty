const std = @import("std");
const testing = std.testing;
const mod = @import("main.zig");

test "banner notes the atty session and is bounded" {
    var buf: [160]u8 = undefined;

    const in_session = mod.banner(&buf, true);
    try testing.expect(std.mem.indexOf(u8, in_session, "in atty session") != null);
    try testing.expect(std.mem.indexOf(u8, in_session, "attop") != null);
    // Genuinely bounded — the formatted line fits the caller's buffer.
    try testing.expect(in_session.len <= buf.len);

    const standalone = mod.banner(&buf, false);
    try testing.expect(std.mem.indexOf(u8, standalone, "in atty session") == null);
    try testing.expect(std.mem.indexOf(u8, standalone, "attop") != null);
    try testing.expect(standalone.len <= buf.len);
}
