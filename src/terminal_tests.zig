//! Tests for `terminal.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("terminal.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const posix = std.posix;

// Re-binds of pub decls so test bodies stay short.
const Error = mod.Error;
const makeRaw = mod.makeRaw;
const RawMode = mod.RawMode;
const slaveIsHiddenInput = mod.slaveIsHiddenInput;

test "makeRaw zeroes the documented flag set" {
    var t = std.mem.zeroes(posix.termios);
    t.iflag.ICRNL = true;
    t.oflag.OPOST = true;
    t.lflag.ECHO = true;
    t.lflag.ICANON = true;
    t.lflag.ISIG = true;

    makeRaw(&t);

    try std.testing.expect(!t.iflag.ICRNL);
    try std.testing.expect(!t.oflag.OPOST);
    try std.testing.expect(!t.lflag.ECHO);
    try std.testing.expect(!t.lflag.ICANON);
    try std.testing.expect(!t.lflag.ISIG);
    try std.testing.expectEqual(@as(u8, 1), t.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), t.cc[@intFromEnum(posix.V.TIME)]);
}

test "slaveIsHiddenInput: fresh PTY (ICANON=on, ECHO=on) is NOT hidden input" {
    // The kernel default for a freshly opened PTY is cooked mode:
    // ICANON=on, ECHO=on. That's POSIX `sh` territory — not a
    // password prompt. The redaction gate must stay off.
    var pty = try @import("pty.zig").Pty.open(std.testing.allocator);
    defer pty.deinit();
    try std.testing.expect(!slaveIsHiddenInput(pty.master));
}

test "slaveIsHiddenInput: getpass signature (ICANON=on, ECHO=off) IS hidden input" {
    // The signature `getpass(3)` / `sudo` / `ssh` / `passwd` /
    // shell `read -s` all use: drop ECHO, keep canonical line
    // buffering. The gate must fire so atty redacts the bytes
    // out of line_state + ghost-suggest queries + history.
    var pty = try @import("pty.zig").Pty.open(std.testing.allocator);
    defer pty.deinit();
    var t = try posix.tcgetattr(pty.master);
    t.lflag.ECHO = false;
    t.lflag.ICANON = true;
    try posix.tcsetattr(pty.master, .NOW, t);
    try std.testing.expect(slaveIsHiddenInput(pty.master));
}

test "slaveIsHiddenInput: interactive-shell raw mode (ICANON=off, ECHO=off) is NOT hidden input" {
    // Regression guard: bash + readline / zsh + zle / fish drop
    // BOTH ICANON and ECHO during normal interactive editing so
    // the line editor can handle echo + editing itself. The
    // earlier gate (`!ECHO` alone) mistook this for a password
    // prompt on every keystroke, silently routing all input down
    // the fast-path and skipping CSI-u translation. The user
    // observed Ctrl+C / Ctrl+D producing `9;5u` / `0;5u` mojibake.
    var pty = try @import("pty.zig").Pty.open(std.testing.allocator);
    defer pty.deinit();
    var t = try posix.tcgetattr(pty.master);
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    try posix.tcsetattr(pty.master, .NOW, t);
    try std.testing.expect(!slaveIsHiddenInput(pty.master));
}

test "slaveIsHiddenInput: round-trip across a getpass-style session" {
    // Pin the full sequence the proxy sees during `sudo`:
    //   prompt (ICANON=off, ECHO=off — interactive shell)
    //     ↓ sudo invoked
    //   password (ICANON=on, ECHO=off — gate fires)
    //     ↓ sudo finishes
    //   prompt (ICANON=off, ECHO=off — gate releases)
    var pty = try @import("pty.zig").Pty.open(std.testing.allocator);
    defer pty.deinit();

    var t = try posix.tcgetattr(pty.master);
    // Interactive shell setup.
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    try posix.tcsetattr(pty.master, .NOW, t);
    try std.testing.expect(!slaveIsHiddenInput(pty.master));

    // sudo drops ECHO + raises ICANON for the password.
    t.lflag.ECHO = false;
    t.lflag.ICANON = true;
    try posix.tcsetattr(pty.master, .NOW, t);
    try std.testing.expect(slaveIsHiddenInput(pty.master));

    // Restore interactive shell.
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    try posix.tcsetattr(pty.master, .NOW, t);
    try std.testing.expect(!slaveIsHiddenInput(pty.master));
}
