//! Tests for `overlay_ring.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("overlay_ring.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const writeAll = @import("proxy/io.zig").writeAll;

// Re-binds of pub decls so test bodies stay short.
const default_size = mod.default_size;
const RingBuf = mod.RingBuf;

// ============================================================================
// Tests
// ============================================================================

test "RingBuf: push fills below cap; flush emits in order" {
    var r: RingBuf(8) = .{};
    r.push("abc");
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(@as(usize, 0), r.head);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try testing.expectEqualSlices(u8, "abc", r.buf[0..3]);
}

test "RingBuf: push at cap evicts oldest" {
    var r: RingBuf(4) = .{};
    r.push("abcd"); // exactly fills
    try testing.expectEqual(@as(usize, 4), r.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    r.push("e"); // evicts 'a'
    try testing.expectEqual(@as(usize, 4), r.len);
    try testing.expectEqual(@as(usize, 1), r.head);
    try testing.expectEqual(@as(usize, 1), r.dropped);
}

test "RingBuf: multiple overflow tracks the count" {
    var r: RingBuf(4) = .{};
    r.push("abcd");
    r.push("efgh"); // drops a,b,c,d → 4 drops, ring now ['e','f','g','h']
    try testing.expectEqual(@as(usize, 4), r.dropped);
    try testing.expectEqual(@as(usize, 0), r.head);
    try testing.expectEqualSlices(u8, "efgh", r.buf[0..4]);
}

test "RingBuf: empty flush is a no-op (no write attempted)" {
    var r: RingBuf(8) = .{};
    // Use an obviously-invalid fd; if the impl accidentally tried
    // to write, the syscall would fail and propagate.
    try r.flush(-1);
}
