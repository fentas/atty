const std = @import("std");
const testing = std.testing;
const mod = @import("main.zig");

test "paintTabBar lists every panel + reverse-videos the focused one" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try mod.paintTabBar(&w, 0); // focus on the first panel (Home)
    const out = buf[0..w.end];

    // All five default panels appear, with their nav-key hint.
    for ([_][]const u8{ "[h]Home", "[g]Guard", "[f]Fleet", "[s]Setup", "[?]Help" }) |label| {
        try testing.expect(std.mem.indexOf(u8, out, label) != null);
    }
    // The focused panel is wrapped in reverse video (SGR 7 / 27).
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[7m [h]Home \x1b[27m") != null);
    // A non-focused panel is NOT reverse-videoed.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[7m [g]Guard") == null);
}

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
