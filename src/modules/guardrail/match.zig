//! Pattern primitive for guardrail rules: the `Match` union and its
//! evaluator. Lifted out of `guardrail.zig` so the matcher logic
//! (especially the iterative glob walker) lives in one
//! self-contained file with its tests, leaving the parent module
//! focused on the rule list + framework hooks.

const std = @import("std");

/// How a rule decides whether the committed line is a hit. `prefix`
/// and `substring` are O(n) byte scans; `glob` runs an iterative
/// `*`-backtrack matcher (no character classes, no recursion).
pub const Match = union(enum) {
    /// Line starts with this exact byte sequence.
    prefix: []const u8,
    /// `std.mem.indexOf` non-null.
    substring: []const u8,
    /// Shell-style: `*` = any (greedy) run, `?` = any single byte.
    /// Anchored to both ends of the line.
    glob: []const u8,
};

/// Decide whether `line` is a hit against `match`.
pub fn matches(match: Match, line: []const u8) bool {
    return switch (match) {
        .prefix => |p| std.mem.startsWith(u8, line, p),
        .substring => |s| std.mem.indexOf(u8, line, s) != null,
        .glob => |g| globMatch(g, line),
    };
}

/// Iterative `*` / `?` matcher with backtracking to the most recent
/// `*`. Anchored to both ends — same shape as shell globs (no
/// `[abc]` classes). No recursion: O(pattern × line) worst case,
/// constant stack.
pub fn globMatch(pattern: []const u8, line: []const u8) bool {
    var pi: usize = 0;
    var li: usize = 0;
    var star_pi: ?usize = null;
    var star_li: usize = 0;
    while (li < line.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_li = li;
            pi += 1;
        } else if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == line[li])) {
            pi += 1;
            li += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_li += 1;
            li = star_li;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

// ===========================================================================
// Tests — extracted to `match_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("match_tests.zig");
}
