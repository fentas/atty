//! Tests for `modules/guardrail/match.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("match.zig");

// Re-binds of pub decls so test bodies stay short.
const globMatch = mod.globMatch;
const Match = mod.Match;
const matches = mod.matches;

// ===========================================================================
// Tests
// ===========================================================================

test "glob: simple star and question" {
    try testing.expect(globMatch("rm *", "rm foo"));
    try testing.expect(globMatch("rm *", "rm "));
    try testing.expect(!globMatch("rm *", "rmfoo"));
    try testing.expect(globMatch("?at", "cat"));
    try testing.expect(!globMatch("?at", "cats"));
    try testing.expect(globMatch("*", ""));
    try testing.expect(globMatch("a*b", "ab"));
    try testing.expect(globMatch("a*b", "aXYZb"));
    try testing.expect(!globMatch("a*b", "axyzc"));
}

test "glob: anchored on both ends" {
    try testing.expect(!globMatch("rm", "rm foo"));
    try testing.expect(!globMatch("foo", "echo foo"));
}

test "matches: prefix scans from start only" {
    try testing.expect(matches(.{ .prefix = "rm " }, "rm -rf"));
    try testing.expect(!matches(.{ .prefix = "rm " }, "sudo rm -rf"));
}

test "matches: substring is indexOf semantics" {
    try testing.expect(matches(.{ .substring = "danger" }, "very danger zone"));
    try testing.expect(!matches(.{ .substring = "danger" }, "safe path"));
}

test "matches: glob dispatches to globMatch" {
    try testing.expect(matches(.{ .glob = "rm *" }, "rm foo"));
    try testing.expect(!matches(.{ .glob = "rm *" }, "echo rm foo"));
}
