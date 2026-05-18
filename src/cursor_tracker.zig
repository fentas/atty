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
//! - **Auto-wrap (soft-wrap)**: when a printable line exceeds the
//!   terminal's column count, the cursor advances by one row
//!   AUTOMATICALLY without the shell emitting any CSI or `\n`.
//!   We don't track columns, so we can't detect this — the row
//!   under-counts by however many wraps happened. Same applies
//!   to hard tabs that push past the right margin. This is the
//!   biggest practical inaccuracy source: any bash session
//!   running `ls -l` on a wide path or `cat`-ing a long line
//!   will wrap. Consumers should treat the row as "where the
//!   shell THINKS the cursor is" (modulo readline's view), not
//!   "where the cursor actually is on screen".
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
//! - Scroll regions (DECSTBM). The atty proxy emits DECSTBM
//!   whenever the statusbar is active (region = 1..effectiveRows).
//!   LF at the bottom of that region scrolls and the terminal's
//!   cursor stays put — the proxy compensates by initializing
//!   the tracker's `max_rows` to `sb.effectiveRows()` (not the
//!   physical screen height), so the LF-advance saturates at the
//!   right row. Updated on SIGWINCH too. Shell-emitted DECSTBM
//!   (rare) is NOT compensated for; if a future shell starts
//!   using its own scroll region, our row will drift past the
//!   sub-region's bottom.
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
        // Saturating accumulator — parsing into a fixed-width int
        // (even u64) errors out for sufficiently long digit runs
        // (20+ digits for u64, fewer for smaller). `parseUnsigned`
        // returns an error, the catch-default fires, and the param
        // becomes 0 → default 1 → CUD by 1 instead of "all the way
        // to the bottom". By saturating digit-by-digit we map any
        // arbitrarily-long numeric param to `max(u16)`, which the
        // downstream advance/retreat then clamps to `max_rows`.
        //
        // Non-digit bytes are silently skipped — the surrounding
        // state machine guarantees we only land here with digits,
        // but the defensive skip lets us tolerate any future CSI
        // sub-parameter weirdness without UB.
        var acc: u32 = 0;
        const cap: u32 = std.math.maxInt(u16);
        for (self.param_buf[0..self.param_len]) |b| {
            if (b < '0' or b > '9') continue;
            if (acc >= cap) {
                acc = cap;
                continue; // already saturated; consume remaining digits
            }
            const digit: u32 = b - '0';
            const next: u64 = @as(u64, acc) * 10 + digit;
            acc = if (next > cap) cap else @intCast(next);
        }
        self.param1 = @intCast(acc);
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

// ===========================================================================
// Tests — extracted to `cursor_tracker_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("cursor_tracker_tests.zig");
}
