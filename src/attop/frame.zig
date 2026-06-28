//! Row-level diff rendering — repaint only the screen rows that actually
//! changed between frames, instead of clearing + repainting the whole screen
//! every tick/keystroke. Combined with synchronized output (DECSET 2026) this
//! is the "alive, never flickery" property from docs/dashboard.md: typing or a
//! metric tick rewrites one or two rows, not the entire dashboard.
//!
//! A "row" is a `\n`-separated line of the painted frame (a trailing `\r` is
//! trimmed). Rows are compared byte-for-byte INCLUDING their SGR/escape codes,
//! so a style-only change still redraws. attop is alt-screen + non-scrolling,
//! so logical row i maps to physical screen row i+1 (1-based CUP).

const std = @import("std");

pub const max_rows = 256;
pub const buf_size = 64 * 1024;

pub const Frame = struct {
    /// A copy of the previous frame's row bytes (the caller's paint buffer is
    /// reused next frame, so we can't borrow slices into it).
    buf: [buf_size]u8 = undefined,
    rows: [max_rows][]const u8 = undefined,
    row_count: usize = 0,
    /// False until the first frame is painted (or after `invalidate`): the
    /// next `diff` does a full clear + paint instead of a row diff.
    primed: bool = false,

    /// Emit to `w` only the rows of `next` that differ from the stored
    /// previous frame — each as `CUP(row);1H` + erase-line + content — then
    /// store `next` as the new previous. `cap` bounds the rows considered to
    /// the terminal height. The first call (or after `invalidate`) clears the
    /// screen and paints every row.
    pub fn diff(self: *Frame, next: []const u8, cap: usize, w: *std.Io.Writer) !void {
        var nr: [max_rows][]const u8 = undefined;
        const nrc = split(next, &nr, cap);

        if (!self.primed) {
            try w.writeAll("\x1b[2J\x1b[H");
            for (nr[0..nrc], 0..) |row, i| {
                if (i > 0) try w.writeAll("\r\n");
                try w.writeAll(row);
            }
            self.store(nr[0..nrc]);
            self.primed = true;
            return;
        }

        const n = @max(nrc, self.row_count);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const new_row: []const u8 = if (i < nrc) nr[i] else "";
            const old_row: []const u8 = if (i < self.row_count) self.rows[i] else "";
            if (!std.mem.eql(u8, new_row, old_row)) {
                // CUP to (row i+1, col 1), erase the line, write the new row.
                // A shrunk frame's trailing rows take new_row="" → the line is
                // just erased (stale content cleared).
                try w.print("\x1b[{d};1H\x1b[K", .{i + 1});
                try w.writeAll(new_row);
            }
        }
        self.store(nr[0..nrc]);
    }

    /// Force a full repaint on the next `diff` (e.g. after a resize, where
    /// absolute row positions all shift).
    pub fn invalidate(self: *Frame) void {
        self.primed = false;
    }

    fn store(self: *Frame, rows: []const []const u8) void {
        var off: usize = 0;
        self.row_count = 0;
        for (rows) |r| {
            if (self.row_count >= max_rows) break;
            const take = @min(r.len, buf_size - off);
            @memcpy(self.buf[off .. off + take], r[0..take]);
            self.rows[self.row_count] = self.buf[off .. off + take];
            off += take;
            self.row_count += 1;
        }
    }
};

/// Split `s` into rows on `\n`, trimming a trailing `\r`, up to `cap` rows.
fn split(s: []const u8, out: *[max_rows][]const u8, cap: usize) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (n >= cap or n >= max_rows) break;
        var row = line;
        if (row.len > 0 and row[row.len - 1] == '\r') row = row[0 .. row.len - 1];
        out[n] = row;
        n += 1;
    }
    return n;
}

test {
    _ = @import("frame_tests.zig");
}
