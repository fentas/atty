//! Pure I/O helpers extracted out of `proxy.zig` so the proxy event
//! loop stays focused on multiplexing and the byte-level write
//! semantics live in one self-contained file.

const std = @import("std");
const posix = std.posix;

/// True when `bytes` contains a CR or LF — the proxy uses this to
/// recognise an Enter keystroke regardless of which legacy
/// encoding the terminal sent.
pub fn containsEnter(bytes: []const u8) bool {
    for (bytes) |b| if (b == 0x0D or b == 0x0A) return true;
    return false;
}

/// Shared write loop used by every fd-target write in the proxy.
/// `INTR` is retried (signal arrived mid-syscall); every other
/// errno propagates as `error.WriteFailed`. A 0-byte return from
/// `write()` (peer hung up cleanly mid-write) surfaces as
/// `error.EndOfFile` so callers can distinguish a closed fd from a
/// real failure. Notably `EAGAIN` is **not** retried — every fd we
/// write to is blocking by design (pty.master, stdout for ghost
/// overlays), so `EAGAIN` indicates the caller flipped the fd to
/// non-blocking and we should surface it explicitly rather than
/// tight-loop until a future POLLOUT. `EBADF` / `EIO` from PTY
/// teardown is the other path this gate guards against — those
/// used to spin at 100% CPU.
pub fn writeFully(fd: posix.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = std.c.write(fd, bytes[i..].ptr, bytes.len - i);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.EndOfFile;
        i += @intCast(rc);
    }
}

/// Alias kept for readability at call sites that don't want to
/// emphasise the partial-write retry; semantically identical to
/// `writeFully`.
pub fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    return writeFully(fd, bytes);
}

/// Thin Writer adapter so `keymap.translateCsiUStream` (which
/// speaks the generic Writer interface) can target the PTY master
/// directly, without an intermediate buffer. Delegates to
/// `writeFully` so the errno-gated retry policy is the only
/// implementation of the write loop.
pub const PtmWriter = struct {
    fd: posix.fd_t,
    pub fn writeAll(self: PtmWriter, bytes: []const u8) !void {
        return writeFully(self.fd, bytes);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "containsEnter: CR detected" {
    try testing.expect(containsEnter("abc\r"));
    try testing.expect(containsEnter("\rabc"));
}

test "containsEnter: LF detected" {
    try testing.expect(containsEnter("abc\n"));
}

test "containsEnter: plain bytes return false" {
    try testing.expect(!containsEnter("abcdef"));
    try testing.expect(!containsEnter(""));
}

test "containsEnter: CSI byte alone is not Enter" {
    // 0x1B is ESC, the lead byte for CSI — must not falsely
    // register as Enter.
    try testing.expect(!containsEnter("\x1B[A"));
}

test "writeFully: empty input is a no-op (no syscall, no error)" {
    // Guards the fast path: writing zero bytes shouldn't enter the
    // retry loop at all, otherwise an empty paint cycle would still
    // pay a syscall per iteration.
    try writeFully(-1, "");
}

test "writeFully: write to a pipe whose reader closed returns error.WriteFailed (no spin)" {
    // Regression for the 100%-CPU runaway observed on a long-lived
    // session whose stdout pipe lost its reader: the kernel returns
    // -1 + EPIPE on every write. The errno gate must surface this
    // as error.WriteFailed so the caller can shut down, not retry.
    //
    // Install SIG_IGN for SIGPIPE locally so the kernel's default
    // disposition (terminate) doesn't kill the test runner. atty's
    // main() does the same at startup; the test pins it explicitly
    // so the assertion holds independent of the Zig runtime's
    // historical SIGPIPE handler.
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var prev: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, &sa, &prev);
    defer std.posix.sigaction(std.posix.SIG.PIPE, &prev, null);

    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.pipe2(&fds, .{});
    try testing.expectEqual(@as(c_int, 0), rc);
    // Close the read end so the write end is a "broken pipe".
    _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    // A previous version of writeFully retried any negative rc
    // unconditionally — that path would loop forever here.
    try testing.expectError(error.WriteFailed, writeFully(fds[1], "x"));
}
