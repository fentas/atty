const std = @import("std");
const testing = std.testing;
const fio = @import("io.zig");

test "io: writeFile then readFileAlloc round-trips (incl. mkdir of the parent)" {
    // PID-unique path so concurrent test processes can't collide in /tmp.
    var pbuf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pbuf, "/tmp/atty-ttysnap-io-{d}/sub/round-trip.txt", .{std.c.getpid()});
    try fio.writeFile(path, "hello\nworld\x00binary");
    const got = try fio.readFileAlloc(testing.allocator, path, 1 << 20);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello\nworld\x00binary", got);
    _ = std.c.unlink(path);
}

test "io: readFileAlloc errors on a missing file" {
    try testing.expectError(
        error.FileNotFound,
        fio.readFileAlloc(testing.allocator, "/tmp/atty-ttysnap-definitely-not-here-xyz", 1 << 20),
    );
}
