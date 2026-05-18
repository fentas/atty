//! Drop-oldest ring buffer for PTY-master output captured while a
//! module's alt-screen overlay is open on the user's terminal.
//!
//! When the chat overlay (or future module overlays) is active,
//! atty's outer-terminal stdout is in alt-screen mode — writing
//! shell output there would clobber the overlay's painted content.
//! The proxy diverts master-read bytes here instead; on overlay
//! close, the buffer flushes to stdout in order so the user sees
//! whatever the subprocess produced during the interlude.
//!
//! Drop semantics: oldest-first (FIFO eviction). A subprocess
//! producing 1 MB/s into a 64 KB ring keeps the most recent 64 KB,
//! drops the head. A "[N bytes dropped]" marker prefixes the
//! flush so the user knows there was overflow.
//!
//! Sized to ~64 KB by default — matches Linux's typical PTY pipe
//! buffer, so single chatty bursts don't drop unnecessarily.
//!
//! **Partial-escape hazard.** Drop-oldest can split a multi-byte
//! sequence (UTF-8 codepoint, CSI parameter string, OSC body).
//! After eviction the buffer may start mid-codepoint or mid-
//! escape; the terminal then either renders U+FFFD for partial
//! UTF-8 or — worse — treats the leftover `\x1B[…` head as an
//! unterminated escape that swallows subsequent printable bytes
//! as parameters. The flush prefix below emits a hard SGR reset
//! AND an ST (`\x1B\\`) before the dropped-byte marker to
//! forcibly close any dangling OSC/CSI that survived eviction.
//! Mid-codepoint UTF-8 is accepted as a known cosmetic issue
//! (single garbled glyph at the boundary).

const std = @import("std");
const writeAll = @import("proxy/io.zig").writeAll;

pub const default_size = 64 * 1024;

pub fn RingBuf(comptime cap: comptime_int) type {
    return struct {
        const Self = @This();

        buf: [cap]u8 = undefined,
        /// Index of the oldest byte. Advances by one on overflow.
        head: usize = 0,
        /// Bytes currently stored. `len == cap` means the ring is
        /// full and the next push overwrites the oldest byte.
        len: usize = 0,
        /// Cumulative byte count dropped due to overflow since the
        /// last flush. Surfaced as a "[N bytes dropped]" marker
        /// when the buffer flushes.
        dropped: usize = 0,

        /// Append bytes to the ring. Drop-oldest on overflow.
        pub fn push(self: *Self, bytes: []const u8) void {
            for (bytes) |b| {
                if (self.len < cap) {
                    self.buf[(self.head + self.len) % cap] = b;
                    self.len += 1;
                } else {
                    self.buf[self.head] = b;
                    self.head = (self.head + 1) % cap;
                    self.dropped += 1;
                }
            }
        }

        /// Flush the ring's contents (oldest-first) to `fd` and
        /// reset. Emits a dim-styled "[N bytes dropped]" marker
        /// when `dropped > 0` so the user sees that the
        /// underlying subprocess produced more output than the
        /// buffer could hold.
        pub fn flush(self: *Self, fd: std.posix.fd_t) !void {
            // Preamble before any captured bytes:
            //   `\x1B\\` (ST) — forcibly close any dangling OSC/DCS
            //     that started before eviction (no harmful effect
            //     if no such escape was pending).
            //   `\x1B[0m` — full SGR reset so a half-applied colour
            //     attribute from a truncated CSI doesn't bleed.
            //   `\r\n` — start the marker on its own row.
            //
            // Only emitted when there's something to flush
            // (`dropped > 0` OR `len > 0`); empty-flush stays a
            // pure no-op.
            const has_dropped = self.dropped > 0;
            const has_content = self.len > 0;
            if (has_dropped or has_content) {
                try writeAll(fd, "\x1B\\\x1B[0m\r\n");
            }
            if (has_dropped) {
                var msg_buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &msg_buf,
                    "\x1B[2m[atty: {d} bytes of subprocess output dropped during overlay]\x1B[0m\r\n",
                    .{self.dropped},
                ) catch "\x1B[2m[atty: subprocess output truncated]\x1B[0m\r\n";
                try writeAll(fd, msg);
            }
            // Two segments: head..min(head+len,cap) then 0..wrap.
            const tail = @min(self.head + self.len, cap);
            if (tail > self.head) try writeAll(fd, self.buf[self.head..tail]);
            const wrapped = self.head + self.len - tail;
            if (wrapped > 0) try writeAll(fd, self.buf[0..wrapped]);
            self.head = 0;
            self.len = 0;
            self.dropped = 0;
        }
    };
}

// ===========================================================================
// Tests — extracted to `overlay_ring_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("overlay_ring_tests.zig");
}
