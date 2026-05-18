//! Tests for `ghost.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("ghost.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const ansi = @import("ansi.zig");

// Re-binds of pub decls so test bodies stay short.
const Ghost = mod.Ghost;
const nextSectionEnd = mod.nextSectionEnd;
const Style = mod.Style;

// ===========================================================================
// Tests
// ===========================================================================

test "trailing returns suffix" {
    try std.testing.expectEqualSlices(u8, " -la", Ghost.trailing("ls", "ls -la").?);
}

test "trailing rejects mismatch" {
    try std.testing.expect(Ghost.trailing("ls", "cd ..") == null);
}

test "trailing rejects shorter suggestion" {
    try std.testing.expect(Ghost.trailing("lsla", "ls") == null);
}

test "nextSectionEnd: rooted path peels segment + slash" {
    try std.testing.expectEqual(@as(usize, 6), nextSectionEnd("/home/fentas/x"));
}

test "nextSectionEnd: non-slash ghost stops at space-run (legacy behaviour)" {
    try std.testing.expectEqual(@as(usize, 4), nextSectionEnd("git checkout master"));
}

test "nextSectionEnd: trailing slash included" {
    try std.testing.expectEqual(@as(usize, 4), nextSectionEnd("foo/"));
}

test "nextSectionEnd: no slash, no trailing space → whole word" {
    try std.testing.expectEqual(@as(usize, 3), nextSectionEnd("foo"));
}

test "nextSectionEnd: empty input → 0" {
    try std.testing.expectEqual(@as(usize, 0), nextSectionEnd(""));
}

test "nextSectionEnd: leading slash alone" {
    try std.testing.expectEqual(@as(usize, 4), nextSectionEnd("/foo"));
}

test "nextSectionEnd: double slash" {
    // `//foo` — opening `/`, body is empty (next char is also `/`),
    // boundary slash consumed. Net 2; next press peels `foo`.
    try std.testing.expectEqual(@as(usize, 2), nextSectionEnd("//foo"));
}

test "nextSectionEnd: walks a full path through successive calls" {
    var s: []const u8 = "/home/fentas/github/atty";
    const e1 = nextSectionEnd(s);
    try std.testing.expectEqualStrings("/home/", s[0..e1]);
    s = s[e1..];
    const e2 = nextSectionEnd(s);
    try std.testing.expectEqualStrings("fentas/", s[0..e2]);
    s = s[e2..];
    const e3 = nextSectionEnd(s);
    try std.testing.expectEqualStrings("github/", s[0..e3]);
    s = s[e3..];
    const e4 = nextSectionEnd(s);
    try std.testing.expectEqualStrings("atty", s[0..e4]);
}

test "show then clear toggles visibility" {
    var g = Ghost.init(std.testing.allocator, .{});
    defer g.deinit();

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try std.testing.expect(!g.visible);
    try g.show(&w, " -la");
    try std.testing.expect(g.visible);
    try std.testing.expectEqualSlices(u8, " -la", g.rendered.items);

    try g.clear(&w);
    try std.testing.expect(!g.visible);
}
