//! Tests for `pty.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("pty.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const posix = std.posix;
const linux = std.os.linux;
const version = @import("version.zig").version;

// Re-binds of pub decls so test bodies stay short.
const Error = mod.Error;
const Pty = mod.Pty;
const TIOCGWINSZ = mod.TIOCGWINSZ;
const TIOCSCTTY = mod.TIOCSCTTY;
const TIOCSWINSZ = mod.TIOCSWINSZ;
const WinSize = mod.WinSize;

test "Pty.open allocates a master and slave path" {
    var pty = try Pty.open(std.testing.allocator);
    defer pty.deinit();

    try std.testing.expect(pty.master >= 0);
    try std.testing.expect(std.mem.startsWith(u8, pty.slave_path, "/dev/pts/"));
}

test "Pty.setSize round-trips through ioctl" {
    var pty = try Pty.open(std.testing.allocator);
    defer pty.deinit();

    try pty.setSize(.{ .rows = 24, .cols = 80 });
    const got = try Pty.querySize(pty.master);
    try std.testing.expectEqual(@as(u16, 24), got.rows);
    try std.testing.expectEqual(@as(u16, 80), got.cols);
}
