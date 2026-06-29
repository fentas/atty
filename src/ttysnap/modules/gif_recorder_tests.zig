const std = @import("std");
const testing = std.testing;
const gr = @import("gif_recorder.zig");
const vt = @import("vt");

fn freeFrames(rt: anytype) void {
    for (rt.frames.items) |f| testing.allocator.free(f);
    rt.frames.deinit(testing.allocator);
}

test "gif_recorder: dedups frames + renders one animated group per distinct frame" {
    const M = gr.gif_recorder(.{ .path = "x.svg", .frame_ms = 100 });
    var rt = try M.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 10, .rows = 2 });
    defer freeFrames(&rt);

    var grid = try vt.Grid.init(testing.allocator, 2, 10);
    defer grid.deinit();
    grid.feed("frame-one");
    M.onFrame(&rt, &grid); // frame 0
    M.onFrame(&rt, &grid); // identical → deduped
    grid.feed("\r\nrow2");
    M.onFrame(&rt, &grid); // frame 1 (changed)

    try testing.expectEqual(@as(usize, 2), rt.frames.items.len);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try M.render(&rt, testing.allocator, &out);
    const svg = out.items;
    try testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, svg, "<g visibility"));
    // 2 rows/frame × 2 frames = 4 <text> — no spurious empty row from the
    // trailing newline renderText emits.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, svg, "<text"));
    try testing.expect(std.mem.indexOf(u8, svg, "fill=\"freeze\"") != null); // last frame stays
    try testing.expect(std.mem.indexOf(u8, svg, "frame-one") != null);
}

test "gif_recorder: XML metacharacters in the screen are escaped" {
    const M = gr.gif_recorder(.{ .path = "x.svg" });
    var rt = try M.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 10, .rows = 1 });
    defer freeFrames(&rt);

    var grid = try vt.Grid.init(testing.allocator, 1, 10);
    defer grid.deinit();
    grid.feed("a<b>&\"c");
    M.onFrame(&rt, &grid);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try M.render(&rt, testing.allocator, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "&lt;b&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "&amp;") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "&quot;") != null);
    // The raw tag must NOT survive into the SVG text content.
    try testing.expect(std.mem.indexOf(u8, out.items, "<b>") == null);
}
