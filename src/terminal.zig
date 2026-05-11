//! Termios raw-mode RAII guard for our *upstream* terminal (the one the
//! user is actually looking at). The child process gets its own termios
//! managed by the kernel inside the PTY — we only touch our own stdin.
//!
//! Why raw mode?
//!
//! By default the kernel does line-buffered cooked I/O on a TTY: it
//! echoes characters, translates \r → \n, blocks reads until newline, and
//! converts Ctrl-C → SIGINT. For a proxy this would be disastrous — every
//! keystroke would be doubled (we'd see it, then the shell would echo it
//! again over the PTY), and we couldn't intercept Enter before the shell
//! does. So we drop our stdin into raw mode and the child shell inside
//! the PTY runs whatever cooked/raw mode *it* wants.
//!
//! The guard restores the previous termios on deinit even on panic
//! paths, which is critical: a crashed atty must not leave the user's
//! terminal echoless.

const std = @import("std");
const posix = std.posix;

pub const Error = error{
    NotATty,
    TermiosGetFailed,
    TermiosSetFailed,
};

pub const RawMode = struct {
    fd: posix.fd_t,
    original: posix.termios,

    pub fn enter(fd: posix.fd_t) Error!RawMode {
        const original = posix.tcgetattr(fd) catch |err| switch (err) {
            error.NotATerminal => return Error.NotATty,
            else => return Error.TermiosGetFailed,
        };

        var raw = original;
        makeRaw(&raw);

        posix.tcsetattr(fd, .FLUSH, raw) catch return Error.TermiosSetFailed;

        return .{ .fd = fd, .original = original };
    }

    pub fn deinit(self: *RawMode) void {
        // Best-effort: if restoration fails (e.g. fd already closed) we
        // can't do anything useful, and propagating the error from a
        // deinit is awkward. The terminal will be reset by the next
        // `reset(1)` invocation in the worst case.
        posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
        self.* = undefined;
    }
};

/// In-place equivalent of `cfmakeraw(3)`. We model it after the spec
/// (POSIX.1-2008 Issue 7) so the exact flag set is auditable.
///
/// Mnemonic for the flag groups:
///   iflag — Input  processing (translate \r, parity strip, XON/XOFF…)
///   oflag — Output processing (\n → \r\n…)
///   cflag — Control modes     (byte size, parity bits…)
///   lflag — Line discipline   (canonical mode, echo, signals…)
///   cc    — Control characters (VINTR, VEOF, VMIN, VTIME…)
fn makeRaw(t: *posix.termios) void {
    // Input: keep bytes verbatim. No CR/NL translation, no XON/XOFF.
    t.iflag.IGNBRK = false;
    t.iflag.BRKINT = false;
    t.iflag.PARMRK = false;
    t.iflag.ISTRIP = false;
    t.iflag.INLCR = false;
    t.iflag.IGNCR = false;
    t.iflag.ICRNL = false;
    t.iflag.IXON = false;

    // Output: pass bytes through unchanged. The shell inside the PTY
    // already emits well-formed terminal escapes; we must not mangle them.
    t.oflag.OPOST = false;

    // Local: turn off echo, canonical line buffering, signal generation,
    // and extended input processing. We will deliver Ctrl-C as a literal
    // 0x03 byte and let the shell decide what to do with it.
    t.lflag.ECHO = false;
    t.lflag.ECHONL = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;

    // Control: 8-bit characters, no parity.
    t.cflag.CSIZE = .CS8;
    t.cflag.PARENB = false;

    // VMIN=1, VTIME=0 means read() blocks until at least 1 byte is
    // available with no inter-byte timer. Combined with our poll() loop,
    // this gives us per-keystroke wakeups.
    t.cc[@intFromEnum(posix.V.MIN)] = 1;
    t.cc[@intFromEnum(posix.V.TIME)] = 0;
}

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
