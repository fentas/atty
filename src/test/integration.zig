//! Integration tests — exercise the real PTY plumbing.
//!
//! Run with: `zig build itest`
//!
//! These tests fork a child process, so they need a working /dev/ptmx.
//! That works on CI Linux runners but would fail in unusual sandboxes
//! (e.g. some container builders). We separate them from `zig build
//! test` so the regular test target stays trivially reproducible.

const std = @import("std");
const posix = std.posix;
const atty = @import("atty");

const Pty = atty.pty.Pty;

test "PTY round-trips bytes through /bin/echo" {
    const allocator = std.testing.allocator;

    var pty = try Pty.open(allocator);
    defer pty.deinit();

    const argv = comptime [_:null]?[*:0]const u8{
        "/bin/echo",
        "hello-from-pty",
        null,
    };
    const envp = comptime [_:null]?[*:0]const u8{null};

    const pid = try pty.spawn(@ptrCast(&argv), @ptrCast(&envp));

    // Read until EOF or a short timeout.
    var collected = std.ArrayList(u8).init(allocator);
    defer collected.deinit();

    const start = std.time.milliTimestamp();
    var buf: [256]u8 = undefined;
    while (std.time.milliTimestamp() - start < 2000) {
        var pfd = [_]posix.pollfd{.{ .fd = pty.master, .events = 0x001, .revents = 0 }};
        const n = posix.poll(&pfd, 200) catch 0;
        if (n == 0) {
            // No data; check whether child is dead.
            var status: u32 = 0;
            const wp = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
            if (wp == pid) break;
            continue;
        }
        if (pfd[0].revents & 0x001 != 0) {
            const r = posix.read(pty.master, &buf) catch 0;
            if (r == 0) break;
            try collected.appendSlice(buf[0..r]);
            if (std.mem.indexOf(u8, collected.items, "hello-from-pty") != null) break;
        }
        if (pfd[0].revents & 0x010 != 0) break;
    }

    // Reap if still running.
    _ = posix.kill(pid, posix.SIG.TERM) catch {};
    var status: u32 = 0;
    _ = std.os.linux.waitpid(pid, &status, 0);

    try std.testing.expect(std.mem.indexOf(u8, collected.items, "hello-from-pty") != null);
}
