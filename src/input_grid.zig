//! Minimal 1-row terminal-grid emulator scoped to the prompt row.
//!
//! atty proxies every byte the shell emits. When the shell redraws
//! the prompt line (history recall, completion, expansion, paste,
//! prompt re-paint), the redraw is just a sequence of cursor-positioning
//! + erase + printable bytes — same VT-100 primitives a real terminal
//! interprets. We re-implement the *minimal subset* needed to track
//! "what's currently displayed at the prompt row" so we can read
//! the user's typed input from there instead of relying on
//! keystroke tracking (which goes blind during recall/completion).
//!
//! Scope is deliberately tight: ONE row, single-byte ASCII, the
//! sequences shells actually emit in their line editors. We skip
//! UTF-8, multi-row state, scrolling, scroll regions, color
//! semantics. If a shell does something exotic we mis-track the
//! line and fall back to the keystroke buffer — failure mode is
//! "guardrail might miss" not "atty crashes."
//!
//! Combined with `dsr.zig` (which gives us the `input_start` column
//! at fresh-prompt time), `currentInput()` returns the visible
//! input bytes between the prompt's end and the cursor.

const std = @import("std");

pub const InputGrid = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    /// Backing storage for the single row we track. Filled with
    /// `' '` (space) on clears; printable bytes overwrite cells.
    row: []u8,
    /// 0-based cursor column within `row`.
    cursor_col: u16 = 0,
    /// 1-based column at which the user's input region begins
    /// (= column right after the prompt). 0 = unknown; callers
    /// should not trust `currentInput()` until this is set.
    input_start: u16 = 0,
    /// CSI parser state.
    state: State = .ground,
    csi_buf: [32]u8 = undefined,
    csi_len: usize = 0,

    const State = enum { ground, esc, csi, osc };

    pub fn init(allocator: std.mem.Allocator, cols: u16) !InputGrid {
        const buf = try allocator.alloc(u8, cols);
        @memset(buf, ' ');
        return .{
            .allocator = allocator,
            .cols = cols,
            .row = buf,
        };
    }

    pub fn deinit(self: *InputGrid) void {
        self.allocator.free(self.row);
    }

    /// Update the column where the prompt ends + the user's input
    /// region begins. Caller obtains this via DSR after a fresh
    /// prompt. 1-based to match the wire protocol. Use 0 to mark
    /// "input boundary unknown" (e.g. after SIGWINCH; re-query
    /// expected before currentInput() is trustworthy again).
    pub fn setInputStart(self: *InputGrid, col_1based: u16) void {
        self.input_start = col_1based;
    }

    pub fn cursorCol(self: *const InputGrid) u16 {
        return self.cursor_col;
    }

    /// Resize the row buffer (call on SIGWINCH after TIOCGWINSZ
    /// reports the new cols). Resets cursor and clears content —
    /// the next DSR + shell redraw will rebuild.
    pub fn resize(self: *InputGrid, cols: u16) !void {
        if (cols == self.cols) return;
        self.allocator.free(self.row);
        self.row = try self.allocator.alloc(u8, cols);
        @memset(self.row, ' ');
        self.cols = cols;
        self.cursor_col = 0;
        self.input_start = 0;
        self.state = .ground;
        self.csi_len = 0;
    }

    /// Feed master-output bytes through the grid. Idempotent + safe
    /// to call with partial sequences (parser state is preserved).
    pub fn feed(self: *InputGrid, bytes: []const u8) void {
        for (bytes) |b| self.feedByte(b);
    }

    /// The bytes currently displayed in the user's input region.
    /// Reads the actual row content from `input_start` to the last
    /// non-space cell — NOT the cursor position, because the cursor
    /// might be mid-line if the user is editing. Trailing spaces
    /// are trimmed (shells often pad with spaces during redraws).
    /// Empty when `input_start` hasn't been set, or when nothing
    /// is displayed past the prompt.
    pub fn currentInput(self: *const InputGrid) []const u8 {
        if (self.input_start == 0) return &.{};
        const start: usize = @as(usize, self.input_start) - 1; // 1-based → 0-based
        if (start >= self.cols) return &.{};
        // Scan right from the end of the row to find the last
        // non-space cell. Anything between start..end is the
        // displayed input. Cursor position is irrelevant —
        // history-recalled lines fully populate the row regardless
        // of where the cursor lands within them.
        var end: usize = self.cols;
        while (end > start and self.row[end - 1] == ' ') : (end -= 1) {}
        if (end <= start) return &.{};
        return self.row[start..end];
    }

    fn feedByte(self: *InputGrid, b: u8) void {
        switch (self.state) {
            .ground => self.feedGround(b),
            .esc => self.feedEsc(b),
            .csi => self.feedCsi(b),
            .osc => self.feedOsc(b),
        }
    }

    fn feedGround(self: *InputGrid, b: u8) void {
        switch (b) {
            0x0D => self.cursor_col = 0, // CR
            0x08 => if (self.cursor_col > 0) {
                self.cursor_col -= 1;
            }, // BS
            0x1B => self.state = .esc,
            0x07, 0x0A, 0x0B, 0x0C => {}, // BEL, LF, VT, FF — ignored at row scope
            0x09 => self.tab(), // HT
            else => self.putPrintable(b),
        }
    }

    fn feedEsc(self: *InputGrid, b: u8) void {
        switch (b) {
            '[' => {
                self.state = .csi;
                self.csi_len = 0;
            },
            ']' => self.state = .osc,
            '7', '8' => self.state = .ground, // DECSC/DECRC — out of scope, ignore
            else => self.state = .ground,
        }
    }

    fn feedCsi(self: *InputGrid, b: u8) void {
        // Accumulate parameter bytes (digits, semicolons, optional
        // intermediates) until a final byte in 0x40..0x7E arrives.
        if (b >= 0x40 and b <= 0x7E) {
            self.dispatchCsi(b);
            self.state = .ground;
            return;
        }
        if (self.csi_len < self.csi_buf.len) {
            self.csi_buf[self.csi_len] = b;
            self.csi_len += 1;
        }
    }

    fn feedOsc(self: *InputGrid, b: u8) void {
        // OSC ends on BEL (0x07) or ST (ESC \). We don't care
        // about contents (title-set, hyperlinks, OSC 133 markers
        // are handled elsewhere).
        if (b == 0x07) {
            self.state = .ground;
        } else if (b == 0x1B) {
            // Likely ST start; consume the following byte loosely.
            self.state = .ground;
        }
    }

    fn dispatchCsi(self: *InputGrid, final: u8) void {
        const params = self.csi_buf[0..self.csi_len];
        switch (final) {
            'K' => self.eraseLine(parseFirst(params)),
            'C' => self.cursor_col = saturatingAddCol(self.cursor_col, @max(parseFirst(params), 1), self.cols),
            'D' => self.cursor_col = saturatingSub(self.cursor_col, @max(parseFirst(params), 1)),
            'G' => self.cursor_col = @intCast(@min(@as(u32, @max(parseFirst(params), 1)) - 1, @as(u32, self.cols) - 1)),
            'H', 'f' => {
                // CUP/HVP — set cursor to row;col. We only care about col.
                const ps = parsePair(params);
                self.cursor_col = @intCast(@min(@as(u32, @max(ps.b, 1)) - 1, @as(u32, self.cols) - 1));
            },
            'J' => self.eraseDisplay(parseFirst(params)),
            // Everything else (SGR, scroll, modes, etc.) is a no-op
            // at the row scope.
            else => {},
        }
    }

    fn eraseLine(self: *InputGrid, ps: u16) void {
        switch (ps) {
            0 => for (self.row[self.cursor_col..]) |*c| {
                c.* = ' ';
            },
            1 => for (self.row[0..@min(self.cursor_col + 1, self.cols)]) |*c| {
                c.* = ' ';
            },
            2 => @memset(self.row, ' '),
            else => {},
        }
    }

    fn eraseDisplay(self: *InputGrid, ps: u16) void {
        // ED 0/1/2 all imply our row is affected (clear-to-end-of-screen
        // includes the rest of the current row; clear-from-start-of-screen
        // includes the start of the current row; clear-screen clears all).
        // We model only our row; behaviors collapse to the same outcome.
        _ = ps;
        @memset(self.row, ' ');
        self.cursor_col = 0;
    }

    fn putPrintable(self: *InputGrid, b: u8) void {
        if (b < 0x20 or b >= 0x7F) return; // skip C0/C1 control + non-ASCII for now
        if (self.cursor_col < self.cols) {
            self.row[self.cursor_col] = b;
            self.cursor_col += 1;
        }
    }

    fn tab(self: *InputGrid) void {
        // Snap to next multiple of 8 (default tab stop).
        const next: u32 = (@as(u32, self.cursor_col) / 8 + 1) * 8;
        self.cursor_col = @intCast(@min(next, @as(u32, self.cols) - 1));
    }

    fn parseFirst(params: []const u8) u16 {
        var n: u32 = 0;
        for (params) |b| {
            switch (b) {
                '0'...'9' => n = n * 10 + (b - '0'),
                else => break,
            }
        }
        return @intCast(@min(n, 0xFFFF));
    }

    fn parsePair(params: []const u8) struct { a: u16, b: u16 } {
        var a: u32 = 0;
        var b: u32 = 0;
        var seen_semi = false;
        for (params) |c| {
            switch (c) {
                '0'...'9' => if (seen_semi) {
                    b = b * 10 + (c - '0');
                } else {
                    a = a * 10 + (c - '0');
                },
                ';' => seen_semi = true,
                else => break,
            }
        }
        return .{ .a = @intCast(@min(a, 0xFFFF)), .b = @intCast(@min(b, 0xFFFF)) };
    }

    fn saturatingAddCol(cur: u16, delta: u16, cols: u16) u16 {
        const sum: u32 = @as(u32, cur) + @as(u32, delta);
        const cap: u32 = @as(u32, cols) - 1;
        return @intCast(@min(sum, cap));
    }

    fn saturatingSub(a: u16, b: u16) u16 {
        return if (a > b) a - b else 0;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "InputGrid: printable ASCII fills the row, cursor advances" {
    var g = try InputGrid.init(testing.allocator, 20);
    defer g.deinit();
    g.feed("hello");
    try testing.expectEqual(@as(u16, 5), g.cursorCol());
    try testing.expectEqualStrings("hello               ", g.row);
}

test "InputGrid: CR resets cursor to column 0" {
    var g = try InputGrid.init(testing.allocator, 10);
    defer g.deinit();
    g.feed("abc");
    g.feed("\r");
    try testing.expectEqual(@as(u16, 0), g.cursorCol());
}

test "InputGrid: CSI K erases from cursor to end of line" {
    var g = try InputGrid.init(testing.allocator, 10);
    defer g.deinit();
    g.feed("abcdefghij");
    g.feed("\r\x1b[3C"); // cursor → col 3
    g.feed("\x1b[K");
    try testing.expectEqualStrings("abc       ", g.row);
}

test "InputGrid: backspace decrements cursor without erasing the cell" {
    var g = try InputGrid.init(testing.allocator, 10);
    defer g.deinit();
    g.feed("abc\x08");
    try testing.expectEqual(@as(u16, 2), g.cursorCol());
    // Cell 'c' is still there (BS doesn't erase per the spec).
    try testing.expectEqualStrings("abc       ", g.row);
}

test "InputGrid: CSI G moves cursor to column N (1-based)" {
    var g = try InputGrid.init(testing.allocator, 10);
    defer g.deinit();
    g.feed("\x1b[5G");
    try testing.expectEqual(@as(u16, 4), g.cursorCol()); // 1-based 5 → 0-based 4
}

test "InputGrid: CSI C/D move cursor forward/back with saturation" {
    var g = try InputGrid.init(testing.allocator, 10);
    defer g.deinit();
    g.feed("\x1b[5C");
    try testing.expectEqual(@as(u16, 5), g.cursorCol());
    g.feed("\x1b[3D");
    try testing.expectEqual(@as(u16, 2), g.cursorCol());
    g.feed("\x1b[10D"); // saturate at 0
    try testing.expectEqual(@as(u16, 0), g.cursorCol());
}

test "InputGrid: SGR codes are skipped, content lands correctly" {
    var g = try InputGrid.init(testing.allocator, 20);
    defer g.deinit();
    g.feed("\x1b[1;36m$\x1b[0m \x1b[32mhi\x1b[0m");
    try testing.expectEqual(@as(u16, 4), g.cursorCol());
    try testing.expectEqualStrings("$ hi                ", g.row);
}

test "InputGrid: OSC sequences are skipped" {
    var g = try InputGrid.init(testing.allocator, 10);
    defer g.deinit();
    g.feed("\x1b]0;title\x07hello");
    try testing.expectEqualStrings("hello     ", g.row);
}

test "InputGrid: currentInput returns the slice between input_start and cursor" {
    // Simulate: prompt "$ " ends at col 2 (1-based). User typed "ls -la".
    var g = try InputGrid.init(testing.allocator, 30);
    defer g.deinit();
    g.feed("$ ls -la");
    g.setInputStart(3); // input region starts at column 3 (after "$ ")
    try testing.expectEqualStrings("ls -la", g.currentInput());
}

test "InputGrid: currentInput trims trailing spaces (shell padding)" {
    var g = try InputGrid.init(testing.allocator, 30);
    defer g.deinit();
    g.feed("$ ls   ");
    g.setInputStart(3);
    try testing.expectEqualStrings("ls", g.currentInput());
}

test "InputGrid: currentInput is empty when input_start is unset" {
    var g = try InputGrid.init(testing.allocator, 30);
    defer g.deinit();
    g.feed("$ ls -la");
    try testing.expectEqual(@as(usize, 0), g.currentInput().len);
}

test "InputGrid: simulated history-recall redraw extracts the recalled line" {
    // The byte sequence below is what bash readline emits when the
    // user presses Up-arrow on a previously-empty line and the
    // recalled entry is "rm -rf /tmp/test":
    //   \r              — cursor to col 0
    //   \x1b[K          — erase to end of line
    //   "$ "            — prompt
    //   "rm -rf /tmp/test"  — recalled text
    var g = try InputGrid.init(testing.allocator, 40);
    defer g.deinit();
    // Initial empty prompt:
    g.feed("$ ");
    g.setInputStart(3);
    try testing.expectEqualStrings("", g.currentInput());

    // Now the redraw:
    g.feed("\r\x1b[K$ rm -rf /tmp/test");
    try testing.expectEqualStrings("rm -rf /tmp/test", g.currentInput());
}

test "InputGrid: cursor moves don't shrink currentInput — the row content is what counts" {
    // currentInput reads the row from input_start to the last
    // non-space cell, NOT to cursor_col. That lets us read the
    // recalled line even when the cursor is mid-line.
    var g = try InputGrid.init(testing.allocator, 40);
    defer g.deinit();
    g.feed("$ ls -la");
    g.setInputStart(3);
    // Move cursor to col 6 (1-based) = 5 (0-based) and overwrite
    // the '-' with 'x'. Cursor lands at col 6 (0-based), but the
    // row still reads "$ ls xla" at cols 0..8 — currentInput
    // returns everything past the prompt.
    g.feed("\x1b[6Gx");
    try testing.expectEqualStrings("ls xla", g.currentInput());
    // Move cursor back to col 3 — currentInput must NOT shrink.
    g.feed("\x1b[3G");
    try testing.expectEqualStrings("ls xla", g.currentInput());
}

test "InputGrid: history-recall redraw extracts the recalled line even when the cursor is at the start" {
    // Some shells (zsh, fish) redraw with `\r + EL + prompt + recalled-text`
    // and *don't* move the cursor to the end of the input — they
    // leave it at the prompt boundary. currentInput must still
    // surface the recalled bytes.
    var g = try InputGrid.init(testing.allocator, 40);
    defer g.deinit();
    g.feed("$ ");
    g.setInputStart(3);
    // Redraw with cursor explicitly left at col 3 (input start).
    g.feed("\r\x1b[K$ rm -rf /tmp\x1b[3G");
    try testing.expectEqualStrings("rm -rf /tmp", g.currentInput());
}
