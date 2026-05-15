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
/// errno propagates as `error.WriteFailed`. Notably `EAGAIN` is
/// **not** retried — every fd we write to is blocking by design
/// (pty.master, stdout for ghost overlays), so `EAGAIN` indicates
/// the caller flipped the fd to non-blocking and we should surface
/// it explicitly rather than tight-loop until a future POLLOUT.
/// `EBADF` / `EIO` from PTY teardown is the other path this gate
/// guards against — those used to spin at 100% CPU.
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
