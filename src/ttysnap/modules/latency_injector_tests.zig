const std = @import("std");
const testing = std.testing;
const li = @import("latency_injector.zig");

test "latency_injector: beforeRead never caps (delays only, returns want)" {
    const M = li.latency_injector(.{ .read_ms = 0 });
    var rt = try M.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 80, .rows = 24 });
    try testing.expectEqual(@as(usize, 100), M.beforeRead(&rt, 100));
    try testing.expectEqual(@as(usize, 4096), M.beforeRead(&rt, 4096));
}
