const std = @import("std");
const testing = std.testing;
const ss = @import("snapshotter.zig");
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
