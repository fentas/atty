const std = @import("std");
const testing = std.testing;
const ss = @import("snapshotter.zig");
const fio = @import("../io.zig");
const vt = @import("vt");

// The snapshotter's dir is comptime (factory config); make the snapshot NAMES
// PID-unique so concurrent test processes don't collide on golden files.
const dir = "/tmp/atty-ttysnap-snap-test";

fn uniq(buf: []u8, prefix: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}-{d}", .{ prefix, std.c.getpid() }) catch prefix;
}

fn cleanup(name: []const u8) void {
    var b: [256]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&b, "{s}/{s}.txt", .{ dir, name }) catch return).ptr);
    _ = std.c.unlink((std.fmt.bufPrintZ(&b, "{s}/{s}.actual.txt", .{ dir, name }) catch return).ptr);
}

test "snapshotter: update writes a golden; compare matches, mismatches, and flags missing" {
    var nb: [64]u8 = undefined;
    const name = uniq(&nb, "snap");
    defer cleanup(name);

    var grid = try vt.Grid.init(testing.allocator, 4, 20);
    defer grid.deinit();
    grid.feed("hello world");

    // update mode → (re)write the golden, never errors.
    const U = ss.snapshotter(.{ .dir = dir, .update = true });
    var urt = try U.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 20, .rows = 4 });
    try U.onSnapshot(&urt, name, &grid);

    // compare mode → same screen matches (no error).
    const C = ss.snapshotter(.{ .dir = dir, .update = false });
    var crt = try C.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 20, .rows = 4 });
    try C.onSnapshot(&crt, name, &grid);

    // Change the screen → mismatch.
    grid.feed("\r\nDIFFERENT-LINE");
    try testing.expectError(ss.Error.SnapshotMismatch, C.onSnapshot(&crt, name, &grid));

    // A checkpoint with no golden fails loudly (rather than silently passing).
    var mb: [64]u8 = undefined;
    const missing = uniq(&mb, "never-written");
    defer cleanup(missing);
    try testing.expectError(ss.Error.SnapshotGoldenMissing, C.onSnapshot(&crt, missing, &grid));
}

test "snapshotter: a screen full of multi-byte glyphs is not truncated" {
    var nb: [64]u8 = undefined;
    const name = uniq(&nb, "mb");
    defer cleanup(name);

    var grid = try vt.Grid.init(testing.allocator, 2, 8);
    defer grid.deinit();
    grid.feed("é" ** 8); // 8 cells, 2 bytes each = 16 bytes on row 0

    const U = ss.snapshotter(.{ .dir = dir, .update = true });
    var urt = try U.attach(testing.allocator, .{ .argv = &.{"x"}, .cols = 8, .rows = 2 });
    try U.onSnapshot(&urt, name, &grid);

    // A 1-byte/cell buffer would truncate row 0 to ~4 é's; the 4x buffer keeps all 8.
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pb, "{s}/{s}.txt", .{ dir, name });
    const golden = try fio.readFileAlloc(testing.allocator, path, 1 << 20);
    defer testing.allocator.free(golden);
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, golden, "é"));
}
