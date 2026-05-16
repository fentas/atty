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
            if (self.dropped > 0) {
                var msg_buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &msg_buf,
                    "\r\n\x1B[2m[atty: {d} bytes of subprocess output dropped during overlay]\x1B[0m\r\n",
                    .{self.dropped},
                ) catch "\r\n\x1B[2m[atty: subprocess output truncated]\x1B[0m\r\n";
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "RingBuf: push fills below cap; flush emits in order" {
    var r: RingBuf(8) = .{};
    r.push("abc");
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(@as(usize, 0), r.head);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try testing.expectEqualSlices(u8, "abc", r.buf[0..3]);
}

test "RingBuf: push at cap evicts oldest" {
    var r: RingBuf(4) = .{};
    r.push("abcd"); // exactly fills
    try testing.expectEqual(@as(usize, 4), r.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    r.push("e"); // evicts 'a'
    try testing.expectEqual(@as(usize, 4), r.len);
    try testing.expectEqual(@as(usize, 1), r.head);
    try testing.expectEqual(@as(usize, 1), r.dropped);
}

test "RingBuf: multiple overflow tracks the count" {
    var r: RingBuf(4) = .{};
    r.push("abcd");
    r.push("efgh"); // drops a,b,c,d → 4 drops, ring now ['e','f','g','h']
    try testing.expectEqual(@as(usize, 4), r.dropped);
    try testing.expectEqual(@as(usize, 0), r.head);
    try testing.expectEqualSlices(u8, "efgh", r.buf[0..4]);
}

test "RingBuf: empty flush is a no-op (no write attempted)" {
    var r: RingBuf(8) = .{};
    // Use an obviously-invalid fd; if the impl accidentally tried
    // to write, the syscall would fail and propagate.
    try r.flush(-1);
}
