//! Tests for `test/e2e/dsl.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("dsl.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const Allocator = std.mem.Allocator;

// Re-binds of pub decls so test bodies stay short.
const Cmd = mod.Cmd;
const keyBytes = mod.keyBytes;
const Kind = mod.Kind;
const parse = mod.parse;
const ParseError = mod.ParseError;
const Script = mod.Script;

test "DSL parses a minimal script" {
    const src =
        \\# header
        \\cols 80
        \\rows 24
        \\env FOO=bar
        \\spawn /bin/echo hello
        \\type "hi\n"
        \\snapshot first
        \\
    ;
    var s = try parse(std.testing.allocator, src);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 6), s.cmds.len);
    try std.testing.expectEqual(Kind.set_cols, s.cmds[0].kind);
    try std.testing.expectEqual(@as(i64, 80), s.cmds[0].int_arg);
    try std.testing.expectEqual(Kind.spawn, s.cmds[3].kind);
    try std.testing.expectEqual(@as(usize, 2), s.cmds[3].argv.len);
    try std.testing.expectEqualStrings("/bin/echo", s.cmds[3].argv[0]);
    try std.testing.expectEqualStrings("hi\n", s.cmds[4].str_arg);
    try std.testing.expectEqualStrings("first", s.cmds[5].str_arg);
}

test "DSL string escapes" {
    const src = "type \"a\\tb\\nc\\x41\"\n";
    var s = try parse(std.testing.allocator, src);
    defer s.deinit();
    try std.testing.expectEqualStrings("a\tb\ncA", s.cmds[0].str_arg);
}
