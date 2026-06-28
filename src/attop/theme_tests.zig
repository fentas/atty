const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const home = @import("home.zig");
const fleet = @import("fleet.zig");
const uds = @import("uds.zig");

test "byName maps known themes + rejects unknown" {
    try testing.expect(theme.byName("dark") != null);
    try testing.expect(theme.byName("light") != null);
    try testing.expect(theme.byName("high-contrast") != null);
    try testing.expect(theme.byName("high_contrast") != null);
    try testing.expect(theme.byName("mono") != null);
    try testing.expect(theme.byName("ascii") != null);
    try testing.expect(theme.byName("nope") == null);
}

test "looksLight reads the COLORFGBG background field" {
    try testing.expect(theme.looksLight("15;15"));
    try testing.expect(theme.looksLight("0;15"));
    try testing.expect(theme.looksLight("default;7"));
    try testing.expect(theme.looksLight("0;;15")); // the "fg;;bg" variant
    try testing.expect(!theme.looksLight("15;0"));
    try testing.expect(!theme.looksLight("15;;0"));
    try testing.expect(!theme.looksLight("7;0"));
    try testing.expect(!theme.looksLight("nodelim"));
}

test "ascii theme uses ascii glyphs; dark + mono use unicode" {
    try testing.expectEqualStrings("*", theme.ascii.glyph.protected);
    try testing.expectEqualStrings("\u{25CF}", theme.dark.glyph.protected);
    // mono is the NO_COLOR degrade: no color but glyphs kept.
    try testing.expectEqualStrings("\u{25CF}", theme.mono.glyph.protected);
    try testing.expectEqual(@as(?u8, null), theme.mono.ok.fg);
}

test "the active theme drives the render glyphs" {
    const prev = theme.active;
    defer theme.active = prev; // isolate: other tests expect the dark default
    const m = uds.Metrics{ .guard = .{ .profile = "session" } }; // protected

    theme.active = theme.ascii;
    var buf: [4096]u8 = undefined;
    const a = home.renderHome(&buf, m, 120, 40);
    try testing.expect(std.mem.indexOf(u8, a, "* Protected") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\u{25CF}") == null);

    theme.active = theme.dark;
    var buf2: [4096]u8 = undefined;
    const d = home.renderHome(&buf2, m, 120, 40);
    try testing.expect(std.mem.indexOf(u8, d, "\u{25CF} Protected") != null);
}

test "fleet truncation ellipsis follows the theme (ascii ... vs unicode …)" {
    const prev = theme.active;
    defer theme.active = prev;
    // A cwd long enough to truncate at 120 (> cwdBudget).
    var list = [_]uds.Instance{.{ .pid = 1, .shell = "bash", .cwd = "/HEADXYZ" ++ ("/abcdefghij" ** 12) ++ "/tail" }};

    theme.active = theme.ascii;
    var buf: [4096]u8 = undefined;
    const a = fleet.renderFleet(&buf, &list, 120, 40);
    try testing.expect(std.mem.indexOf(u8, a, "...") != null); // ascii ellipsis
    try testing.expect(std.mem.indexOf(u8, a, "\u{2026}") == null);

    theme.active = theme.dark;
    var buf2: [4096]u8 = undefined;
    const d = fleet.renderFleet(&buf2, &list, 120, 40);
    try testing.expect(std.mem.indexOf(u8, d, "\u{2026}") != null); // unicode …
}
