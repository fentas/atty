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

extern "c" fn clock_gettime(clk_id: c_int, tp: *posix.timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;

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
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(allocator);

    var start_ts: posix.timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &start_ts);
    const start_ms: i64 = @as(i64, start_ts.sec) * 1000 + @divFloor(@as(i64, start_ts.nsec), 1_000_000);
    var buf: [256]u8 = undefined;
    while (true) {
        var now_ts: posix.timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &now_ts);
        const now_ms: i64 = @as(i64, now_ts.sec) * 1000 + @divFloor(@as(i64, now_ts.nsec), 1_000_000);
        if (now_ms - start_ms >= 2000) break;
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
            try collected.appendSlice(allocator, buf[0..r]);
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

test "StatusBar activate emits DECSTBM + clears reserved rows, render lays text on the last row" {
    const StatusBar = atty.statusbar.StatusBar;
    const Style = atty.Style;

    var bar = StatusBar.init(24, 80, 2, Style{ .dim = true });
    bar.setText("atty | atuin");

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try bar.activate(&w);
    try bar.render(&w);
    const out = buf[0..w.end];

    // DECSTBM: scroll bounded to rows 1..22 (24 - 2 reserved).
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[1;22r") != null);
    // Reserved rows (23 + 24) cleared so prior shell content doesn't
    // bleed into the gap above the status text.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[23;1H\x1B[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[24;1H\x1B[K") != null);
    // Cursor parked at (1,1) so the shell's first output doesn't land
    // in the reserved area below.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[1;1H") != null);
    // CUP to last row (24), column 1, before painting.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[24;1H") != null);
    // Dim SGR is emitted from the Style.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[2m") != null);
    // The actual text.
    try std.testing.expect(std.mem.indexOf(u8, out, "atty | atuin") != null);
}

test "StatusBar.activate parks the cursor inside the scroll region" {
    // Regression: clear-reserved-rows used to run AFTER DECSTBM, which
    // left the cursor at the bottom of the screen. The shell's first
    // output then landed in the reserved area instead of at the top
    // of the scroll region, so the prompt was invisible and got
    // immediately overwritten by the next status-bar paint.
    const StatusBar = atty.statusbar.StatusBar;
    var bar = StatusBar.init(24, 80, 2, .{});

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try bar.activate(&w);
    const out = buf[0..w.end];

    // The LAST cursor-positioning command in the output should be
    // CUP-home (\x1B[1;1H), not any of the row N-1 / N CUPs from the
    // clear loop.
    const last_home = std.mem.lastIndexOf(u8, out, "\x1B[1;1H").?;
    const last_reserved = blk: {
        const a = std.mem.lastIndexOf(u8, out, "\x1B[23;1H") orelse 0;
        const b = std.mem.lastIndexOf(u8, out, "\x1B[24;1H") orelse 0;
        break :blk @max(a, b);
    };
    try std.testing.expect(last_home > last_reserved);
}

test "StatusBar deactivate clears reserved rows and resets scroll" {
    const StatusBar = atty.statusbar.StatusBar;
    var bar = StatusBar.init(10, 40, 2, .{});

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try bar.deactivate(&w);
    const out = buf[0..w.end];

    // Clears rows 9 and 10 (the two reserved at the bottom).
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[9;1H\x1B[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[10;1H\x1B[K") != null);
    // Resets the scroll region.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[r") != null);
}
