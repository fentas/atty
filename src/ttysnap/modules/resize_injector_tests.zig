const std = @import("std");
const testing = std.testing;
const ri = @import("resize_injector.zig");

test "resize_injector: cadence triggers every Nth chunk and cycles sizes" {
    const A = ri.Size{ .cols = 120, .rows = 40 };
    const B = ri.Size{ .cols = 80, .rows = 24 };
    const M = ri.resize_injector(.{ .every = 2, .sizes = &.{ A, B } });
    var rt = try M.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 80, .rows = 24 });
    // chunks 1..6 → trigger at 2,4,6 → A,B,A
    try testing.expect(M.shouldResize(&rt) == null);
    try testing.expectEqual(A, M.shouldResize(&rt).?);
    try testing.expect(M.shouldResize(&rt) == null);
    try testing.expectEqual(B, M.shouldResize(&rt).?);
    try testing.expect(M.shouldResize(&rt) == null);
    try testing.expectEqual(A, M.shouldResize(&rt).?);
}

test "resize_injector: empty sizes is inert" {
    const M = ri.resize_injector(.{ .sizes = &.{} });
    var rt = try M.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 80, .rows = 24 });
    try testing.expect(M.shouldResize(&rt) == null);
}
