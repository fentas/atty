//! Shell-safe command formatting for mouse_links' editor launch.
//!
//! The module injects `<editor> [+LINE] '<path>'\n` into the shell's
//! input stream (via `pollShellInput`) — the shell runs the command
//! through its normal parser, so the path needs POSIX shell quoting.
//! Single-quote with the `'\''` escape handles every byte safely
//! including `*`, `?`, `;`, `$`, backtick, newline-via-name-collision,
//! etc.
//!
//! `+LINE` is the lowest-common-denominator line-jump syntax:
//! vim/nvim/vi, emacs (-Q +LINE file works), nano, helix (`hx :42`
//! doesn't work; helix accepts `hx file:42` only — but for the bare
//! `+LINE` form helix ignores it and opens at top, which is acceptable
//! degraded behaviour). The user can pass an `editor_argv` override
//! later if they want vscode-style `--goto`; the default form covers
//! the dominant ttys.
//!
//! Column is discarded by this formatter even when the detector
//! captured it — `+LINE` carries no column convention across
//! editors, and a bare `:COL` after `+LINE` would be misparsed by
//! vim as part of the next ex command.

const std = @import("std");

pub const Hit = struct {
    path: []const u8,
    line: ?u32 = null,
};

pub const FormatError = error{Overflow};

/// Format the injection payload into `buf`. Returns the slice that
/// should be written to the PTY master. Always ends in `\n`. Always
/// starts with `\x15` (readline kill-line) to clear any half-typed
/// prompt the user had open. Returns `error.Overflow` if `buf` is
/// too small — caller sizes a buffer that can comfortably hold the
/// editor name + `+LINE` + 2×path length + a few framing bytes.
pub fn format(buf: []u8, editor: []const u8, hit: Hit) FormatError![]const u8 {
    var w: usize = 0;
    try writeByte(buf, &w, 0x15);

    if (editor.len == 0) return error.Overflow;
    try writeSlice(buf, &w, editor);
    try writeByte(buf, &w, ' ');

    if (hit.line) |line_n| {
        try writeByte(buf, &w, '+');
        var num_buf: [11]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{line_n}) catch
            return error.Overflow;
        try writeSlice(buf, &w, num);
        try writeByte(buf, &w, ' ');
    }

    try writeByte(buf, &w, '\'');
    for (hit.path) |c| {
        if (c == '\'') {
            try writeSlice(buf, &w, "'\\''");
        } else {
            try writeByte(buf, &w, c);
        }
    }
    try writeByte(buf, &w, '\'');
    try writeByte(buf, &w, '\n');

    return buf[0..w];
}

fn writeByte(buf: []u8, w: *usize, b: u8) FormatError!void {
    if (w.* >= buf.len) return error.Overflow;
    buf[w.*] = b;
    w.* += 1;
}

fn writeSlice(buf: []u8, w: *usize, s: []const u8) FormatError!void {
    if (w.* + s.len > buf.len) return error.Overflow;
    @memcpy(buf[w.* .. w.* + s.len], s);
    w.* += s.len;
}

test {
    _ = @import("inject_tests.zig");
}
