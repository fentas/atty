const std = @import("std");
const testing = std.testing;
const cr = @import("cast_recorder.zig");

test "cast_recorder.render emits a v2 header + escaped output/input events" {
    const M = cr.cast_recorder(.{ .path = "unused-in-test.cast" });
    var rt = try M.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 80, .rows = 24 });
    // Record directly; skip detach (it would write a file).
    M.onOutput(&rt, "hi\r\n\x1b[0m");
    M.onInput(&rt, "q");
    defer {
        for (rt.events.items) |e| testing.allocator.free(e.data);
        rt.events.deinit(testing.allocator);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try M.render(&rt, testing.allocator, &out);
    const s = out.items;

    try testing.expect(std.mem.indexOf(u8, s, "\"version\":2") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"width\":80") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"height\":24") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"o\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"i\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\\r\\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\\u001b") != null);
}
