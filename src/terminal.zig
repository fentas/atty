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

/// True iff the slave PTY is in **canonical hidden-input** mode —
/// the termios signature `getpass(3)` / `readpassphrase(3)` / sudo
/// / ssh / `passwd` / shell `read -s` all use to read a password:
/// `ICANON=on AND ECHO=off`. Kernel line-buffers the input AND
/// suppresses screen echo.
///
/// This is **not** the same as "ECHO=off." Interactive shells with
/// readline / zle (bash, zsh, fish) also drop ECHO — but they ALSO
/// drop ICANON because the line editor handles echoing and editing
/// itself. Gating redaction on bare `!ECHO` mistakes every
/// interactive keystroke for a password and silently bypasses
/// CSI-u translation + keymap handling (regression observed as
/// Ctrl+C / Ctrl+D producing `9;5u` / `0;5u` mojibake — the
/// untranslated CSI-u sequence flows raw to the shell).
///
/// Truth table for (ICANON, ECHO):
///
///   ICANON  ECHO   meaning                            redact?
///   ─────   ────   ────────────────────────────────   ───────
///     1      1     POSIX cooked mode (`sh`, no RL)     no
///     0      0     readline / zle interactive shell    no
///     0      1     atypical raw-with-echo              no
///     1      0     getpass / sudo / `read -s`          YES
///
/// Pass the master fd: on Linux + POSIX the slave's termios is
/// visible from either end of the pair, so we don't need to hold
/// the slave fd open after fork.
///
/// **Fail-closed semantics**: returns `true` on tcgetattr failure.
/// This is a security gate, so "we couldn't tell" is treated as
/// "assume the worst, redact." The cost is a partial history-
/// tracking regression when the master fd is in an error state
/// (itself an already-degraded scenario); the proxy will recover
/// as soon as tcgetattr succeeds again on the next read.
pub fn slaveIsHiddenInput(master_fd: posix.fd_t) bool {
    const t = posix.tcgetattr(master_fd) catch return true;
    return t.lflag.ICANON and !t.lflag.ECHO;
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
