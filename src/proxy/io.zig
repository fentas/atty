//! Pure I/O helpers extracted out of `proxy.zig` so the proxy event
//! loop stays focused on multiplexing and the byte-level write
//! semantics live in one self-contained file.

const std = @import("std");
const posix = std.posix;
const debug_recorder = @import("../debug_recorder.zig");

/// Optional debug recorder. When set (config.debug.enabled), every write to
/// STDOUT — atty's final byte stream to the terminal, including its own
/// statusbar / ghost / overlay injections — is teed into the `term` stream so a
/// capture reproduces what atty actually emitted, not just what the shell
/// produced. Null (the default) is a single branch, zero cost.
pub var recorder: ?*debug_recorder.Recorder = null;

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
    if (recorder) |r| {
        if (fd == posix.STDOUT_FILENO) r.pushNow(.term, bytes);
    }
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
// Tests — extracted to `io_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("io_tests.zig");
}
