const std = @import("std");
const testing = std.testing;
const help = @import("help.zig");
const i18n = @import("i18n.zig");

test "Help lists every screen + the env reference" {
    var buf: [4096]u8 = undefined;
    const out = help.renderHelp(&buf, 120, 40);
    // Each screen name (multi-char → robust; single-char keys would match
    // unrelated text, so the key→screen pairing is asserted in the
    // screenshot test against the SGR-stripped grid instead).
    for ([_][]const u8{ "Home", "Guard", "Fleet", "Setup", "Help", "Quit" }) |scr| {
        try testing.expect(std.mem.indexOf(u8, out, scr) != null);
    }
    try testing.expect(std.mem.indexOf(u8, out, "ATTOP_THEME") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ATTOP_LANG") != null);
    try testing.expect(std.mem.indexOf(u8, out, "atty-guard daemon") != null);
}

test "Help section labels follow the active locale" {
    const prev = i18n.active;
    defer i18n.active = prev;
    i18n.active = i18n.de;
    var buf: [4096]u8 = undefined;
    const out = help.renderHelp(&buf, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "Tasten") != null); // Keys → de
    try testing.expect(std.mem.indexOf(u8, out, "Keys") == null);
}
