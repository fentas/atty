const std = @import("std");
const testing = std.testing;
const mod = @import("main.zig");

test "classifyInput: quit keys, screen switches, nav/Esc-sequences" {
    // quit: q / Ctrl-C only (NOT Esc — a split arrow seq must not quit)
    try testing.expectEqual(mod.Input.quit, mod.classifyInput("q"));
    try testing.expectEqual(mod.Input.quit, mod.classifyInput(&.{0x03}));
    try testing.expectEqual(mod.Input.none, mod.classifyInput(&.{0x1b})); // lone Esc → none
    // screen switches
    try testing.expectEqual(mod.Input.guard, mod.classifyInput("g"));
    try testing.expectEqual(mod.Input.home, mod.classifyInput("h"));
    // a multi-byte burst still acts (first recognized command wins)
    try testing.expectEqual(mod.Input.guard, mod.classifyInput("gx"));
    // a multi-byte Esc sequence (arrow) is nav, not quit
    try testing.expectEqual(mod.Input.none, mod.classifyInput("\x1b[A"));
    // nav stubs + nothing
    try testing.expectEqual(mod.Input.none, mod.classifyInput("j"));
    try testing.expectEqual(mod.Input.none, mod.classifyInput(""));
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
