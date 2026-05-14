//! Cursor-Y tracker — maintains the shell-side cursor row by parsing
//! master→stdout bytes. Sibling to `altscreen.zig` / `osc133.zig`: same
//! state-machine shape, same "swallow nothing, just observe" pattern.
//!
//! ## Why
//!
//! Future dynamic-statusbar work (flip top/bottom based on where the
//! prompt currently lives) needs to know "is the prompt near the top or
//! near the bottom of the screen?". The honest answer comes from
//! `\x1b[6n` (DSR) — but DSR is a request/reply round-trip across the
//! terminal boundary, which atty would have to filter on the way back
//! (so the shell doesn't see the reply meant for atty). That's
//! complexity we don't need: bubbletea / ultraviolet sidestep DSR
//! entirely by maintaining an in-memory cell grid, and the cursor's
//! row is derivable from the grid. We don't need the grid — just the
//! row — so this tracker parses the cursor-moving CSI sequences and
//! `LF` / `CR` / `BS` out of the byte stream and updates a single u16.
//!
//! ## What is tracked
//!
//! Row only (1-based), capped at `max_rows`. Column is not tracked —
//! atty's statusbar reservation is a horizontal-band concept, so row is
//! all that matters. Tracking column would double the LOC for zero
//! consumer.
//!
//! ## What is NOT tracked
//!
//! - Save / restore cursor (`\x1B[s` / `\x1B[u`, `\x1B 7` / `\x1B 8`).
//!   When the shell saves and restores, this tracker doesn't know.
//!   Acceptable: bash's readline doesn't use save/restore for prompt
//!   work; alt-screen-using TUIs are gated separately (renderGhost
//!   skipped while `alt_screen.active`).
//! - Alt-screen state. The proxy's `alt_screen` tracker owns that;
//!   while alt-screen is active, the cursor tracker's row continues
//!   to update for the alt buffer's coordinates, but consumers should
//!   ignore the value (just like they ignore the statusbar render
//!   path). We don't try to be smart about saving/restoring our row
//!   across alt-screen toggles.
//! - Scroll regions (DECSTBM). The atty proxy emits DECSTBM but the
//!   shell rarely does; if a future shell side does, our row will
//!   under-count when content scrolls within a sub-region.
//! - Wide-character handling. `\n` / `\r` / CSI are ASCII; any
//!   multi-byte UTF-8 the shell emits never affects row.
//!
//! ## Update rules (all 1-based; `r` = current row; `n` = parsed param,
//! default 1)
//!
//! - `\x0A` (LF) → `r = min(max_rows, r + 1)`
//! - `\x0D` (CR) → unchanged
//! - `\x08` (BS) → unchanged
//! - `CSI <n> A` (CUU) → `r = max(1, r - n)`
//! - `CSI <n> B` (CUD) → `r = min(max_rows, r + n)`
//! - `CSI <r> ; <c> H` (CUP) → `r = clamp(param1, 1, max_rows)` (param1
//!   defaults to 1; missing params handled)
//! - `CSI <r> ; <c> f` (HVP) → same as CUP
//! - `CSI <n> d` (VPA) → `r = clamp(n, 1, max_rows)`
//! - `CSI <n> E` (CNL) → `r = min(max_rows, r + n)`
//! - `CSI <n> F` (CPL) → `r = max(1, r - n)`
//! - everything else → just consume bytes, no row change.

const std = @import("std");

pub const CursorTracker = struct {
    row: u16 = 1,
    max_rows: u16 = 80,

    state: State = .ground,
    /// CSI parameter accumulator. Bounded — overflow drops further
    /// digits, which is fine: the longest legitimate CUP we care about
    /// is `\x1B[<rows>;<cols>H` and `rows` fits in 5 digits for any
    /// terminal we'll see.
    param_buf: [16]u8 = undefined,
    param_len: u8 = 0,
    /// Parsed numeric value of `param_buf`. Reset when a new CSI starts.
    param1: u16 = 0,
    /// `;` seen since the last CSI start. We only use param1 (the row),
    /// so we just skip everything after `;` until the final byte.
    saw_semicolon: bool = false,

    const State = enum { ground, esc, csi };

    pub fn init(rows: u16) CursorTracker {
        return .{ .row = 1, .max_rows = if (rows == 0) 1 else rows };
    }

    pub fn setMaxRows(self: *CursorTracker, rows: u16) void {
        self.max_rows = if (rows == 0) 1 else rows;
        if (self.row > self.max_rows) self.row = self.max_rows;
    }

    pub fn currentRow(self: *const CursorTracker) u16 {
        return self.row;
    }

    pub fn feed(self: *CursorTracker, bytes: []const u8) void {
        for (bytes) |b| self.feedByte(b);
    }

    fn feedByte(self: *CursorTracker, b: u8) void {
        switch (self.state) {
            .ground => switch (b) {
                0x0A => self.advance(1), // LF
                0x1B => self.state = .esc,
                else => {}, // CR, BS, printable, UTF-8 — no row change
            },
            .esc => switch (b) {
                '[' => {
                    self.state = .csi;
                    self.param_len = 0;
                    self.param1 = 0;
                    self.saw_semicolon = false;
                },
                else => self.state = .ground,
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7E) {
                    // Final byte — flush param1 and dispatch.
                    if (!self.saw_semicolon) self.flushParamFromBuf();
                    self.dispatch(b);
                    self.state = .ground;
                } else if (b == ';') {
                    // We only care about param1; flush what we have
                    // and stop accumulating.
                    self.flushParamFromBuf();
                    self.saw_semicolon = true;
                } else if (!self.saw_semicolon and self.param_len < self.param_buf.len) {
                    self.param_buf[self.param_len] = b;
                    self.param_len += 1;
                }
                // Other intermediate/private-marker bytes ignored.
            },
        }
    }

    fn flushParamFromBuf(self: *CursorTracker) void {
        if (self.param_len == 0) return;
        self.param1 = std.fmt.parseUnsigned(u16, self.param_buf[0..self.param_len], 10) catch 0;
        self.param_len = 0;
    }

    fn dispatch(self: *CursorTracker, final: u8) void {
        const n: u16 = if (self.param1 == 0) 1 else self.param1;
        switch (final) {
            'A' => self.retreat(n), // CUU
            'B' => self.advance(n), // CUD
            'E' => self.advance(n), // CNL
            'F' => self.retreat(n), // CPL
            'H', 'f' => self.gotoRow(self.param1), // CUP / HVP — row from param1
            'd' => self.gotoRow(self.param1), // VPA
            else => {}, // SGR / ED / EL / others: row unchanged
        }
    }

    fn advance(self: *CursorTracker, n: u16) void {
        const new = @as(u32, self.row) + @as(u32, n);
        self.row = if (new > self.max_rows) self.max_rows else @intCast(new);
    }

    fn retreat(self: *CursorTracker, n: u16) void {
        if (n >= self.row) {
            self.row = 1;
        } else {
            self.row -= n;
        }
    }

    fn gotoRow(self: *CursorTracker, row: u16) void {
        // Param of 0 (or missing) means "row 1" for CUP/HVP/VPA in
        // every VT/xterm document.
        const r: u16 = if (row == 0) 1 else row;
        self.row = if (r > self.max_rows) self.max_rows else r;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "CursorTracker: starts at row 1" {
    var c = CursorTracker.init(24);
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: LF advances row, capped at max_rows" {
    var c = CursorTracker.init(5);
    c.feed("\n\n\n");
    try testing.expectEqual(@as(u16, 4), c.currentRow());
    c.feed("\n\n\n\n\n");
    try testing.expectEqual(@as(u16, 5), c.currentRow()); // capped
}

test "CursorTracker: CR does not change row" {
    var c = CursorTracker.init(24);
    c.feed("\n\n");
    try testing.expectEqual(@as(u16, 3), c.currentRow());
    c.feed("\r");
    try testing.expectEqual(@as(u16, 3), c.currentRow());
}

test "CursorTracker: CUP sets row from param1" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[10;5H");
    try testing.expectEqual(@as(u16, 10), c.currentRow());
    c.feed("\x1B[3;1H");
    try testing.expectEqual(@as(u16, 3), c.currentRow());
}

test "CursorTracker: CUP with no params goes to row 1" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[5;5H");
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[H");
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: CUP with only row param" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[7H");
    try testing.expectEqual(@as(u16, 7), c.currentRow());
}

test "CursorTracker: HVP (`f`) is equivalent to CUP" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[12;3f");
    try testing.expectEqual(@as(u16, 12), c.currentRow());
}

test "CursorTracker: CUU subtracts, floored at 1" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[10H");
    c.feed("\x1B[3A");
    try testing.expectEqual(@as(u16, 7), c.currentRow());
    c.feed("\x1B[100A");
    try testing.expectEqual(@as(u16, 1), c.currentRow());
}

test "CursorTracker: CUD adds, capped at max_rows" {
    var c = CursorTracker.init(20);
    c.feed("\x1B[5B");
    try testing.expectEqual(@as(u16, 6), c.currentRow());
    c.feed("\x1B[100B");
    try testing.expectEqual(@as(u16, 20), c.currentRow());
}

test "CursorTracker: VPA sets row absolutely" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[15d");
    try testing.expectEqual(@as(u16, 15), c.currentRow());
}

test "CursorTracker: CNL / CPL behave like CUD / CUU for row tracking" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[10;1H");
    c.feed("\x1B[3E"); // CNL — row + 3
    try testing.expectEqual(@as(u16, 13), c.currentRow());
    c.feed("\x1B[5F"); // CPL — row - 5
    try testing.expectEqual(@as(u16, 8), c.currentRow());
}

test "CursorTracker: SGR / ED / EL / unknown CSI do not move the row" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[5;1H");
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[2J"); // ED
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[K"); // EL
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[31;1m"); // SGR
    try testing.expectEqual(@as(u16, 5), c.currentRow());
    c.feed("\x1B[?25h"); // DECSET
    try testing.expectEqual(@as(u16, 5), c.currentRow());
}

test "CursorTracker: mixed prompt-like stream tracks correctly" {
    var c = CursorTracker.init(24);
    // Simulate: home + clear, then 5 lines of output, then prompt.
    c.feed("\x1B[H\x1B[2J");
    try testing.expectEqual(@as(u16, 1), c.currentRow());
    c.feed("line1\nline2\nline3\nline4\nline5\n");
    try testing.expectEqual(@as(u16, 6), c.currentRow());
    c.feed("$ "); // shell prompt — no movement
    try testing.expectEqual(@as(u16, 6), c.currentRow());
}

test "CursorTracker: setMaxRows on shrink clamps row" {
    var c = CursorTracker.init(40);
    c.feed("\x1B[30H");
    try testing.expectEqual(@as(u16, 30), c.currentRow());
    c.setMaxRows(20);
    try testing.expectEqual(@as(u16, 20), c.currentRow());
}

test "CursorTracker: param overflow drops extra digits, doesn't crash" {
    var c = CursorTracker.init(24);
    // 20-digit param — buffer is 16 bytes, extras dropped.
    c.feed("\x1B[12345678901234567890H");
    // Parsing the truncated digits — implementation-defined exact
    // value, but must not crash and must end in `ground`.
    _ = c.currentRow();
}

test "CursorTracker: lone ESC followed by non-`[` returns to ground" {
    var c = CursorTracker.init(24);
    c.feed("\x1B"); // pending ESC
    c.feed("M"); // RI — we don't model it; just consume + back to ground
    c.feed("\x1B[5;1H");
    try testing.expectEqual(@as(u16, 5), c.currentRow());
}

test "CursorTracker: CSI split across feeds reassembles correctly" {
    var c = CursorTracker.init(24);
    c.feed("\x1B[");
    c.feed("10");
    c.feed(";5H");
    try testing.expectEqual(@as(u16, 10), c.currentRow());
}
