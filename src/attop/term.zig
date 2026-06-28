//! attop terminal control — the full-screen-TUI bits beyond the proxy's
//! `terminal.zig`: alt-screen + cursor, terminal size, and SIGWINCH. Raw
//! mode reuses the proxy's audited `cfmakeraw` guard (atty.terminal).

const std = @import("std");
const atty = @import("atty");
const posix = std.posix;

/// Reuse the proxy's audited RawMode (enter applies cfmakeraw; deinit
/// restores the original termios — even on panic).
pub const RawMode = atty.terminal.RawMode;

pub const Size = struct { rows: u16, cols: u16 };

/// Enter the alt-screen, hide the cursor, clear+home. Inverse on exit. The
/// caller writes these so teardown can run on every exit path (defer).
pub const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H";
pub const exit_screen = "\x1b[?25h\x1b[?1049l";

// <asm-generic/ioctls.h> — hardcoded like pty.zig so we don't @cImport.
const TIOCGWINSZ: c_int = 0x5413;

extern "c" fn ioctl(fd: c_int, request: c_int, ...) c_int;

/// Terminal size via TIOCGWINSZ, falling back to 80x24 when unavailable
/// (ioctl error / zero dims) so layout always has sane bounds.
pub fn size(fd: posix.fd_t) Size {
    var ws: posix.winsize = undefined;
    if (ioctl(fd, TIOCGWINSZ, &ws) != 0 or ws.row == 0 or ws.col == 0) {
        return .{ .rows = 24, .cols = 80 };
    }
    return .{ .rows = ws.row, .cols = ws.col };
}

/// SIGWINCH latch — the handler sets it; the loop polls + clears it to
/// re-query the size and repaint. Atomic so the handler's write is visible.
pub var resized = std.atomic.Value(bool).init(false);

fn onWinch(_: c_int) callconv(.c) void {
    resized.store(true, .seq_cst);
}

pub fn installWinch() void {
    const sa = posix.Sigaction{
        .handler = .{ .handler = onWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
}

pub fn isatty(fd: posix.fd_t) bool {
    return std.c.isatty(fd) != 0;
}

test {
    _ = @import("term_tests.zig");
}
