const std = @import("std");
const testing = std.testing;
const ss = @import("snapshotter.zig");
const fio = @import("../io.zig");
const vt = @import("vt");

test "snapshotter: update writes a golden; compare matches, mismatches, and flags missing" {
    const dir = "/tmp/atty-harness-snap-test";

    var grid = try vt.Grid.init(testing.allocator, 4, 20);
    defer grid.deinit();
    grid.feed("hello world");

    // update mode → (re)write the golden, never errors.
    const U = ss.snapshotter(.{ .dir = dir, .update = true });
    var urt = try U.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 20, .rows = 4 });
    try U.onSnapshot(&urt, "snap", &grid);

    // compare mode → same screen matches (no error).
    const C = ss.snapshotter(.{ .dir = dir, .update = false });
    var crt = try C.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 20, .rows = 4 });
    try C.onSnapshot(&crt, "snap", &grid);

    // Change the screen → mismatch.
    grid.feed("\r\nDIFFERENT-LINE");
    try testing.expectError(ss.Error.SnapshotMismatch, C.onSnapshot(&crt, "snap", &grid));

    // A checkpoint with no golden fails loudly (rather than silently passing).
    try testing.expectError(ss.Error.SnapshotGoldenMissing, C.onSnapshot(&crt, "never-written", &grid));

    _ = std.c.unlink("/tmp/atty-harness-snap-test/snap.txt");
    _ = std.c.unlink("/tmp/atty-harness-snap-test/snap.actual.txt");
    _ = std.c.unlink("/tmp/atty-harness-snap-test/never-written.actual.txt");
}

test "snapshotter: a screen full of multi-byte glyphs is not truncated" {
    const dir = "/tmp/atty-harness-snap-mb";
    var grid = try vt.Grid.init(testing.allocator, 2, 8);
    defer grid.deinit();
    grid.feed("é" ** 8); // 8 cells, 2 bytes each = 16 bytes on row 0

    const U = ss.snapshotter(.{ .dir = dir, .update = true });
    var urt = try U.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 8, .rows = 2 });
    try U.onSnapshot(&urt, "mb", &grid);

    // A 1-byte/cell buffer would truncate row 0 to ~4 é's; the 4x buffer keeps all 8.
    const golden = try fio.readFileAlloc(testing.allocator, "/tmp/atty-harness-snap-mb/mb.txt", 1 << 20);
    defer testing.allocator.free(golden);
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, golden, "é"));

    _ = std.c.unlink("/tmp/atty-harness-snap-mb/mb.txt");
}
