//! Tests for `keymap/parser.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("parser.zig");

// Re-binds of pub decls so test bodies stay short.
const key = mod.key;

test "key resolves named keys" {
    try std.testing.expectEqualStrings("\x1b[C", key("Right"));
    try std.testing.expectEqualStrings("\x1b[F", key("End"));
    try std.testing.expectEqualStrings("\t", key("Tab"));
    try std.testing.expectEqualStrings("\x1b[Z", key("Shift+Tab"));
    try std.testing.expectEqualStrings("\x1b[9;5u", key("Ctrl+Tab"));
}

test "key resolves multi-modifier arrows" {
    try std.testing.expectEqualStrings("\x1b[1;5C", key("Ctrl+Right"));
    try std.testing.expectEqualStrings("\x1b[1;2D", key("Shift+Left"));
    try std.testing.expectEqualStrings("\x1b[1;6A", key("Ctrl+Shift+Up"));
    try std.testing.expectEqualStrings("\x1b[1;7B", key("Ctrl+Alt+Down"));
}

test "key resolves Ctrl+Shift+letter via kitty kbd encoding" {
    // i = 105
    try std.testing.expectEqualStrings("\x1B[105;6u", key("Ctrl+Shift+I"));
    try std.testing.expectEqualStrings("\x1B[105;6u", key("Ctrl+Shift+i"));
    // a = 97, z = 122
    try std.testing.expectEqualStrings("\x1B[97;6u", key("Ctrl+Shift+A"));
    try std.testing.expectEqualStrings("\x1B[122;6u", key("Ctrl+Shift+z"));
}

test "key folds Ctrl+letter to control byte" {
    try std.testing.expectEqualStrings("\x01", key("Ctrl+A"));
    try std.testing.expectEqualStrings("\x06", key("Ctrl+f"));
    try std.testing.expectEqualStrings("\x1a", key("Ctrl+Z"));
}

test "key handles Alt+char" {
    try std.testing.expectEqualStrings("\x1bf", key("Alt+f"));
    try std.testing.expectEqualStrings("\x1b.", key("Alt+."));
}

test "key resolves Ctrl+<digit> (kitty kbd CSI-u)" {
    try std.testing.expectEqualStrings("\x1b[49;5u", key("Ctrl+1"));
    try std.testing.expectEqualStrings("\x1b[53;5u", key("Ctrl+5"));
    try std.testing.expectEqualStrings("\x1b[57;5u", key("Ctrl+9"));
}

test "key resolves Esc+<digit> (legacy ESC+digit, doubles as Alt+digit on non-kitty)" {
    try std.testing.expectEqualStrings("\x1b1", key("Esc+1"));
    try std.testing.expectEqualStrings("\x1b9", key("Esc+9"));
}

test "key handles function keys" {
    try std.testing.expectEqualStrings("\x1bOP", key("F1"));
    try std.testing.expectEqualStrings("\x1b[24~", key("F12"));
}
