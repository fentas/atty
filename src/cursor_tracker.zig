//! Cursor-position tracker — maintains the shell-side cursor row + col
//! by parsing master→stdout bytes. Sibling to `altscreen.zig` /
//! `osc133.zig`: same state-machine shape, same "swallow nothing, just
//! observe" pattern.
//!
//! ## Why both row + col
//!
//! Row alone covers the statusbar-band concept (top vs bottom of
//! screen) but the inline chat panel needs col too: on Ctrl+Up the
//! cursor must park at the end of the shell PS1, not at column 1. The
//! honest answer for "where IS the cursor" is `\x1B[6n` (DSR) but that
//! costs a terminal round-trip. The tracker covers the common case
//! synchronously; consumers can fall back to DSR at sensitive moments
//! (panel open, SIGWINCH, post-command `;D`) when the model might have
//! drifted.
//!
//! ## What is tracked
//!
//! Row + col (both 1-based), capped at `max_rows` / `max_cols`. UTF-8
//! aware: only leading bytes advance the column (continuation bytes
//! don't). Wide-character columns are NOT tracked — every visible
//! codepoint counts as one column.
//!
//! ## OSC 133 anchors
//!
//! At the start of every shell prompt, bash emits `\x1B]133;A\x07`.
//! Some terminals (and our line_state) treat that as "cursor is at
//! column 1 of the prompt row" — the terminal hasn't moved the cursor,
//! but everything BEFORE `;A` was the previous command's output, so
//! col=1 is the post-CR truth. We mirror that: on `;A`, reset col to 1.
//! On `;B`, snapshot the current col as `prompt_end_col` — that's
//! where bash's input region starts, so consumers (e.g. inline chat's
//! Ctrl+Up restore) can land the cursor there directly.
//!
//! ## What is NOT tracked
//!
//! - Save / restore cursor (`\x1B[s` / `\x1B[u`, `\x1B 7` / `\x1B 8`).
//!   Acceptable: bash's readline doesn't use save/restore for prompt
//!   work.
//! - Alt-screen state. The proxy's `alt_screen` tracker owns that;
//!   consumers ignore tracker values while alt-screen is active.
//! - Scroll regions (DECSTBM). The proxy initialises `max_rows` to
//!   `sb.effectiveRows()`, so LF at the bottom saturates correctly.
//!   Shell-emitted DECSTBM (rare) is not compensated for.
//! - Wide-glyph (CJK, emoji) widths — every codepoint counts as 1 col.
//!   Over-counts narrow space, under-counts wide; the prompt-end_col
//!   from OSC 133 `;B` is the load-bearing value and is anchored by
//!   the terminal's `;B` marker emission, not by our advance arithmetic.
//! - Reverse-video / DECRC restoration of saved positions.
//!
//! ## Update rules (1-based; r/c = current; n = parsed param, default 1)
//!
//! ### Movement / control bytes
//! - `\x07` (BEL) → unchanged.
//! - `\x08` (BS)  → `c = max(1, c - 1)`.
//! - `\x09` (HT)  → `c = next_tab_stop` (cols 9, 17, 25, …).
//! - `\x0A` (LF)  → `r = min(max_rows, r + 1)`.
//! - `\x0D` (CR)  → `c = 1`.
//! - printable (`0x20..0x7E` or UTF-8 lead `>= 0xC0`) → `c += 1`; on
//!   wrap (`c > max_cols`), `c = 1`, `r = min(max_rows, r + 1)`.
//! - UTF-8 continuation bytes (`0x80..0xBF`) → unchanged.
//!
//! ### CSI sequences
//! - `CSI <n> A` (CUU) → `r = max(1, r - n)`.
//! - `CSI <n> B` (CUD) → `r = min(max_rows, r + n)`.
//! - `CSI <n> C` (CUF) → `c = min(max_cols, c + n)`.
//! - `CSI <n> D` (CUB) → `c = max(1, c - n)`.
//! - `CSI <n> E` (CNL) → `r = min(max_rows, r + n)`, `c = 1`.
//! - `CSI <n> F` (CPL) → `r = max(1, r - n)`, `c = 1`.
//! - `CSI <n> G` (CHA), `CSI <n> \`` (HPA) → `c = clamp(n, 1, max_cols)`.
//! - `CSI <r> ; <c> H` (CUP), `CSI <r> ; <c> f` (HVP) → both clamped.
//! - `CSI <n> d` (VPA) → `r = clamp(n, 1, max_rows)`.
//! - everything else → consumed, no position change.
//!
//! ### OSC 133 anchors (bash `atty init bash` markers)
//! - `\x1B]133;A\x07` (prompt-start) → `c = 1` (CR-implied).
//! - `\x1B]133;B\x07` (prompt-end / input region start) → snapshot
//!   `prompt_end_col = c`.

const std = @import("std");

pub const CursorTracker = struct {
    row: u16 = 1,
    col: u16 = 1,
    max_rows: u16 = 80,
    max_cols: u16 = 80,

    /// Column of the cursor right after the last OSC 133 `;B` marker —
    /// i.e. where bash's input region starts. 0 means "not yet seen".
    /// Resets to 0 only via `reset()`; subsequent `;B` markers
    /// overwrite. Consumers that want "where does the user's input
    /// land?" should prefer this over `col`.
    prompt_end_col: u16 = 0,
    /// Row of the cursor at the last OSC 133 `;A` marker.  Lets
    /// consumers see "is the cursor still on the prompt row?".
    prompt_row: u16 = 0,

    state: State = .ground,
    /// CSI parameter accumulators. We track the first TWO params now
    /// (CUP / HVP need both).
    param_buf: [16]u8 = undefined,
    param_len: u8 = 0,
    params: [2]u16 = .{ 0, 0 },
    param_idx: u8 = 0,
    /// OSC accumulator — just enough to recognise `133;A` / `133;B`.
    /// Bounded; longer OSCs get truncated but still consumed.
    osc_buf: [32]u8 = undefined,
    osc_len: u8 = 0,
    /// Introducer byte that opened the current string-mode escape:
    /// `]` for OSC, `P` for DCS, `_` for APC, `X` for SOS, `^` for
    /// PM. `handleOsc()` only dispatches the OSC 133 markers when
    /// `osc_intro == ']'` — a DCS / APC body that happens to start
    /// with `133;A` must NOT falsely mark a prompt start.
    osc_intro: u8 = 0,

    const State = enum { ground, esc, csi, osc, osc_esc };

    pub fn init(rows: u16, cols: u16) CursorTracker {
        return .{
            .row = 1,
            .col = 1,
            .max_rows = if (rows == 0) 1 else rows,
            .max_cols = if (cols == 0) 1 else cols,
        };
    }

    pub fn setMaxRows(self: *CursorTracker, rows: u16) void {
        self.max_rows = if (rows == 0) 1 else rows;
        if (self.row > self.max_rows) self.row = self.max_rows;
    }

    pub fn setMaxCols(self: *CursorTracker, cols: u16) void {
        self.max_cols = if (cols == 0) 1 else cols;
        if (self.col > self.max_cols) self.col = self.max_cols;
    }

    pub fn currentRow(self: *const CursorTracker) u16 {
        return self.row;
    }

    pub fn currentCol(self: *const CursorTracker) u16 {
        return self.col;
    }

    /// External "I know where the cursor is" — used by the proxy
    /// after a DSR-6n reply so the model picks up the truth.
    pub fn setPosition(self: *CursorTracker, row: u16, col: u16) void {
        self.row = if (row == 0 or row > self.max_rows) self.max_rows else row;
        self.col = if (col == 0 or col > self.max_cols) self.max_cols else col;
    }

    /// True iff the shell is mid-escape — i.e., we've seen the leading
    /// `\x1B` (or a `\x1B[` / `\x1B]` / `\x1BP` / `\x1B_` / `\x1BX` /
    /// `\x1B^` introducer) and have not yet seen the terminator. atty
    /// must NOT write its own ANSI between two halves of one shell
    /// escape: terminals abort the in-progress sequence on a fresh
    /// `\x1B`, so the tail bytes of the shell's sequence end up
    /// rendered as plain text. Used to gate `renderStatus` and any
    /// other atty-side stdout write that fires inside the master-output
    /// poll path.
    pub fn inEscape(self: *const CursorTracker) bool {
        return self.state != .ground;
    }

    pub fn feed(self: *CursorTracker, bytes: []const u8) void {
        for (bytes) |b| self.feedByte(b);
    }

    /// Skip the per-byte parse, just account for the chunk's row
    /// envelope. Used on the fast-path output drain when atty hasn't
    /// claimed any tick state — the trade-off is row precision (LF
    /// counts only). Callers should NOT use this when col precision
    /// matters; they should `feed` the full bytes.
    pub fn onFastPath(self: *CursorTracker, byte_count: usize) void {
        _ = self;
        _ = byte_count;
        // No-op for now: when used, the caller has already decided it
        // doesn't care about precision. Keep the symbol for ABI
        // compatibility with the other trackers.
    }

    fn feedByte(self: *CursorTracker, b: u8) void {
        switch (self.state) {
            .ground => self.groundByte(b),
            .esc => switch (b) {
                '[' => {
                    self.state = .csi;
                    self.param_len = 0;
                    self.params = .{ 0, 0 };
                    self.param_idx = 0;
                },
                // OSC `]`, DCS `P`, SOS `X`, PM `^`, APC `_`. All
                // four share the same termination semantics (BEL or
                // ST = `\x1B\\`), so funnel them into the same
                // string-mode states. `.osc_buf` content is only
                // dispatched for `]133;…` markers; bytes from the
                // others are absorbed without being parsed, which is
                // what we want — the tracker only needs to know that
                // a string sequence is OPEN so atty's paints stay
                // off-stream.
                ']', 'P', '_', 'X', '^' => {
                    self.state = .osc;
                    self.osc_len = 0;
                    self.osc_intro = b;
                },
                else => self.state = .ground,
            },
            .csi => self.csiByte(b),
            .osc => switch (b) {
                0x07 => { // BEL — OSC terminator
                    self.handleOsc();
                    self.state = .ground;
                    self.osc_intro = 0;
                },
                0x1B => self.state = .osc_esc,
                else => {
                    if (self.osc_len < self.osc_buf.len) {
                        self.osc_buf[self.osc_len] = b;
                        self.osc_len += 1;
                    }
                },
            },
            .osc_esc => switch (b) {
                '\\' => { // ESC '\' — OSC ST terminator
                    self.handleOsc();
                    self.state = .ground;
                    self.osc_intro = 0;
                },
                else => {
                    // Bogus ESC inside OSC — abandon, treat as ground.
                    self.state = .ground;
                    self.osc_intro = 0;
                },
            },
        }
    }

    fn groundByte(self: *CursorTracker, b: u8) void {
        switch (b) {
            0x07 => {}, // BEL
            0x08 => { // BS
                if (self.col > 1) self.col -= 1;
            },
            0x09 => { // HT — next 8-col tab stop
                const next: u32 = ((@as(u32, self.col) - 1) | 7) + 1 + 1;
                self.col = if (next > self.max_cols) self.max_cols else @intCast(next);
            },
            0x0A => { // LF
                self.advanceRow(1);
            },
            0x0B, 0x0C => self.advanceRow(1), // VT, FF — treat as LF
            0x0D => { // CR
                self.col = 1;
            },
            0x1B => self.state = .esc,
            0x20...0x7E => self.advanceCol(1), // printable ASCII
            0x7F => {}, // DEL
            // UTF-8: only LEAD bytes (>= 0xC0) advance one column.
            // Continuation bytes (0x80..0xBF) belong to the same
            // codepoint and don't advance the cursor.
            0xC0...0xFF => self.advanceCol(1),
            0x80...0xBF => {}, // UTF-8 continuation
            else => {}, // C0 controls we don't model
        }
    }

    fn csiByte(self: *CursorTracker, b: u8) void {
        if (b >= 0x40 and b <= 0x7E) {
            // Final byte — flush last param and dispatch.
            self.flushParamFromBuf();
            self.dispatchCsi(b);
            self.state = .ground;
            return;
        }
        if (b == ';') {
            self.flushParamFromBuf();
            if (self.param_idx + 1 < self.params.len) self.param_idx += 1;
            return;
        }
        // Private-marker bytes (`?`, `>`, `=`, etc.) at the start are
        // OK to ignore — they don't affect row/col arithmetic for the
        // sequences we model. Same for intermediate `!`/`"`/etc.
        if (b >= '0' and b <= '9' and self.param_len < self.param_buf.len) {
            self.param_buf[self.param_len] = b;
            self.param_len += 1;
        }
    }

    fn flushParamFromBuf(self: *CursorTracker) void {
        // Saturating decimal parse — same shape as the prior version.
        if (self.param_len == 0 and self.param_idx < self.params.len) {
            // Leave params[idx] = 0 to mean "absent / default".
            return;
        }
        var acc: u32 = 0;
        const cap: u32 = std.math.maxInt(u16);
        for (self.param_buf[0..self.param_len]) |c| {
            if (c < '0' or c > '9') continue;
            if (acc >= cap) {
                acc = cap;
                continue;
            }
            const digit: u32 = c - '0';
            const next: u64 = @as(u64, acc) * 10 + digit;
            acc = if (next > cap) cap else @intCast(next);
        }
        if (self.param_idx < self.params.len) {
            self.params[self.param_idx] = @intCast(acc);
        }
        self.param_len = 0;
    }

    fn dispatchCsi(self: *CursorTracker, final: u8) void {
        const p1: u16 = if (self.params[0] == 0) 1 else self.params[0];
        switch (final) {
            'A' => self.retreatRow(p1), // CUU
            'B' => self.advanceRow(p1), // CUD
            'C' => self.advanceCol(p1), // CUF
            'D' => self.retreatCol(p1), // CUB
            'E' => {
                self.advanceRow(p1);
                self.col = 1;
            }, // CNL
            'F' => {
                self.retreatRow(p1);
                self.col = 1;
            }, // CPL
            'G' => self.gotoCol(self.params[0]), // CHA
            '`' => self.gotoCol(self.params[0]), // HPA
            'H', 'f' => { // CUP, HVP
                self.gotoRow(self.params[0]);
                self.gotoCol(self.params[1]);
            },
            'd' => self.gotoRow(self.params[0]), // VPA
            else => {}, // SGR, ED, EL, etc — no row/col change
        }
    }

    fn handleOsc(self: *CursorTracker) void {
        // Only true OSC ( `\x1B]…` ) gets the `133;A`/`;B` dispatch.
        // DCS / APC / SOS / PM share the `.osc` state machine for
        // termination detection (BEL / ST), but their bodies are not
        // OSC — a DCS body of `133;A` must not be mistaken for a
        // prompt marker.
        if (self.osc_intro != ']') return;
        const body = self.osc_buf[0..self.osc_len];
        if (std.mem.startsWith(u8, body, "133;A")) {
            // Prompt start. The terminal places the cursor at the
            // beginning of the prompt's row (post-CR), so reset col.
            self.col = 1;
            self.prompt_row = self.row;
        } else if (std.mem.startsWith(u8, body, "133;B")) {
            // Input region start. Snapshot where the PS1 ended.
            self.prompt_end_col = self.col;
        }
    }

    fn advanceCol(self: *CursorTracker, n: u16) void {
        const new: u32 = @as(u32, self.col) + @as(u32, n);
        if (new <= self.max_cols) {
            self.col = @intCast(new);
        } else {
            // Soft-wrap: drop into the next row at column 1. Most
            // terminals do this transparently; we mirror.
            self.col = 1;
            self.advanceRow(1);
        }
    }

    fn retreatCol(self: *CursorTracker, n: u16) void {
        self.col = if (n >= self.col) 1 else self.col - n;
    }

    fn gotoCol(self: *CursorTracker, col: u16) void {
        const c: u16 = if (col == 0) 1 else col;
        self.col = if (c > self.max_cols) self.max_cols else c;
    }

    fn advanceRow(self: *CursorTracker, n: u16) void {
        const new = @as(u32, self.row) + @as(u32, n);
        self.row = if (new > self.max_rows) self.max_rows else @intCast(new);
    }

    fn retreatRow(self: *CursorTracker, n: u16) void {
        self.row = if (n >= self.row) 1 else self.row - n;
    }

    fn gotoRow(self: *CursorTracker, row: u16) void {
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
