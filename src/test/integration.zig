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

    // ED 2 — clear the visible screen so atty starts on a clean slate
    // (no stray outer-shell content above the new prompt).
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[2J") != null);
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

test "RawMode.enter applies raw flags + deinit restores the saved termios" {
    const RawMode = atty.terminal.RawMode;

    var pty = try Pty.open(std.testing.allocator);
    defer pty.deinit();

    // Open the slave side — that's a real TTY we can tcgetattr on.
    const slave_path_z = pty.slave_path; // already sentinel-terminated
    const slave_fd = std.c.open(slave_path_z.ptr, @bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true }), @as(std.c.mode_t, 0));
    try std.testing.expect(slave_fd >= 0);
    defer _ = std.c.close(slave_fd);

    const before = try std.posix.tcgetattr(slave_fd);

    var guard = try RawMode.enter(slave_fd);
    {
        // Raw-mode flags should be reflected on the live fd.
        const during = try std.posix.tcgetattr(slave_fd);
        try std.testing.expect(!during.iflag.ICRNL);
        try std.testing.expect(!during.oflag.OPOST);
        try std.testing.expect(!during.lflag.ECHO);
        try std.testing.expect(!during.lflag.ICANON);
        try std.testing.expect(!during.lflag.ISIG);
    }
    guard.deinit();

    const after = try std.posix.tcgetattr(slave_fd);
    // After deinit the flags we changed should match what was there
    // before — RawMode keeps a snapshot and restores it on the way out.
    try std.testing.expectEqual(before.iflag.ICRNL, after.iflag.ICRNL);
    try std.testing.expectEqual(before.lflag.ECHO, after.lflag.ECHO);
    try std.testing.expectEqual(before.lflag.ICANON, after.lflag.ICANON);
    try std.testing.expectEqual(before.lflag.ISIG, after.lflag.ISIG);
}

test "RawMode.enter on a non-TTY fd surfaces NotATty" {
    const RawMode = atty.terminal.RawMode;
    var pipe_fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.pipe2(&pipe_fds, .{});
    try std.testing.expectEqual(@as(c_int, 0), rc);
    defer {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
    }
    try std.testing.expectError(error.NotATty, RawMode.enter(pipe_fds[0]));
}

test "ghost.list_count ships off (0) by default — matches docs" {
    // Regression pin for audit #426: the shipped default drifted to 2
    // while the field's own doc comment, config.def.zig, and
    // docs/architecture.md all document 0 (pick-list off). Assert the
    // TYPE default (not the resolved value, which a user's config.zig
    // may override) so the canonical default can't silently drift again.
    // `atty.Ghost` re-exports `defaults.Ghost` through the config module.
    try std.testing.expectEqual(@as(u8, 0), (atty.Ghost{}).list_count);
}
