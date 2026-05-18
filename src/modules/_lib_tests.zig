//! Tests for `modules/_lib.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("_lib.zig");

// Re-binds of pub decls so test bodies stay short.
const ListBuilder = mod.ListBuilder;
const nowMs = mod.nowMs;

// ===========================================================================
// Tests
// ===========================================================================

test "nowMs returns monotonically non-decreasing values" {
    const a = nowMs();
    const b = nowMs();
    try testing.expect(b >= a);
}

test "ListBuilder.tryAdd appends until cap is reached" {
    var b = ListBuilder(3){};
    try testing.expect(b.tryAdd("a", null));
    try testing.expect(b.tryAdd("b", null));
    try testing.expect(b.tryAdd("c", null));
    try testing.expect(!b.tryAdd("d", null)); // cap hit
    try testing.expectEqual(@as(usize, 3), b.items().len);
    try testing.expect(b.full());
}

test "ListBuilder.tryAdd skips empty entries silently" {
    var b = ListBuilder(3){};
    try testing.expect(!b.tryAdd("", null));
    try testing.expectEqual(@as(usize, 0), b.items().len);
}

test "ListBuilder.tryAdd dedupes by content" {
    var b = ListBuilder(5){};
    _ = b.tryAdd("foo", null);
    try testing.expect(!b.tryAdd("foo", null));
    _ = b.tryAdd("bar", null);
    try testing.expect(!b.tryAdd("foo", null));
    try testing.expectEqual(@as(usize, 2), b.items().len);
    try testing.expectEqualStrings("foo", b.items()[0]);
    try testing.expectEqualStrings("bar", b.items()[1]);
}

test "ListBuilder.tryAdd respects the skip parameter (inline-ghost gating)" {
    var b = ListBuilder(5){};
    try testing.expect(!b.tryAdd("git status", "git status"));
    try testing.expect(b.tryAdd("git push", "git status"));
    try testing.expectEqual(@as(usize, 1), b.items().len);
    try testing.expectEqualStrings("git push", b.items()[0]);
}

test "ListBuilder.reset clears the cache" {
    var b = ListBuilder(3){};
    _ = b.tryAdd("a", null);
    _ = b.tryAdd("b", null);
    b.reset();
    try testing.expectEqual(@as(usize, 0), b.items().len);
    try testing.expect(b.tryAdd("a", null)); // dedup state also cleared
}
