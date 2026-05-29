const std = @import("std");
const testing = std.testing;
const inject = @import("inject.zig");

fn fmt(buf: []u8, editor: []const u8, path: []const u8, line: ?u32) ![]const u8 {
    return try inject.format(buf, editor, .{ .path = path, .line = line });
}

test "bare path, no line" {
    var buf: [128]u8 = undefined;
    const out = try fmt(&buf, "nvim", "src/foo.zig", null);
    try testing.expectEqualStrings("\x15nvim 'src/foo.zig'\n", out);
}

test "path with line" {
    var buf: [128]u8 = undefined;
    const out = try fmt(&buf, "nvim", "src/foo.zig", 42);
    try testing.expectEqualStrings("\x15nvim +42 'src/foo.zig'\n", out);
}

test "path containing single quote is escaped" {
    var buf: [128]u8 = undefined;
    const out = try fmt(&buf, "vi", "it's.zig", 7);
    try testing.expectEqualStrings("\x15vi +7 'it'\\''s.zig'\n", out);
}

test "path with shell metacharacters quoted safely" {
    var buf: [256]u8 = undefined;
    const out = try fmt(&buf, "nvim", "src/$(rm -rf /).zig", null);
    try testing.expectEqualStrings("\x15nvim 'src/$(rm -rf /).zig'\n", out);
}

test "path with semicolon" {
    var buf: [128]u8 = undefined;
    const out = try fmt(&buf, "nvim", "a;b.zig", null);
    try testing.expectEqualStrings("\x15nvim 'a;b.zig'\n", out);
}

test "path with backtick" {
    var buf: [128]u8 = undefined;
    const out = try fmt(&buf, "nvim", "a`b.zig", null);
    try testing.expectEqualStrings("\x15nvim 'a`b.zig'\n", out);
}

test "path with newline gets quoted literally" {
    var buf: [128]u8 = undefined;
    const out = try fmt(&buf, "nvim", "a\nb.zig", null);
    try testing.expectEqualStrings("\x15nvim 'a\nb.zig'\n", out);
}

test "empty editor is overflow" {
    var buf: [128]u8 = undefined;
    try testing.expectError(error.Overflow, fmt(&buf, "", "src/foo.zig", null));
}

test "buffer too small returns overflow" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.Overflow, fmt(&buf, "nvim", "src/foo.zig", null));
}

test "vscode-style editor name passes through" {
    // Default `+LINE` format will misparse for vscode, but the
    // formatter doesn't try to detect; it's the user's responsibility
    // to set `config.editor` to something that grok's `+LINE`.
    var buf: [128]u8 = undefined;
    const out = try fmt(&buf, "code", "src/foo.zig", 1);
    try testing.expectEqualStrings("\x15code +1 'src/foo.zig'\n", out);
}

test "very large line number formats" {
    var buf: [128]u8 = undefined;
    const out = try fmt(&buf, "nvim", "f.zig", 4_000_000_000);
    try testing.expectEqualStrings("\x15nvim +4000000000 'f.zig'\n", out);
}
