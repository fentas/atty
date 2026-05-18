//! DSR-6n (Device Status Report — cursor position) reply interceptor.
//!
//! `\x1B[6n` is the standard ECMA-48 / VT100 query: the terminal
//! replies on stdin with `\x1B[<row>;<col>R`. atty uses this to
//! ground-truth the cursor at sensitive moments (inline panel open,
//! SIGWINCH, post-command `;D`) when the passive `cursor_tracker`
//! model might have drifted. Reply parsing has to happen BEFORE the
//! stdin bytes reach the keymap / dispatchInput pipeline — otherwise
//! the reply gets forwarded to bash as if the user typed `[24;1R`.
//!
//! ## State machine
//!
//! Same shape as `osc133.zig`'s parser: walk bytes, drop into a
//! `csi_reply` state on `\x1B[`, accumulate digits + `;`, terminate
//! on `R` (success) or anything outside the accepted alphabet (abort
//! and pass through). Bytes that PARTICIPATE in a successful reply
//! are CONSUMED — `consumed_indices` records them so the caller can
//! filter the input slice.
//!
//! ## Scope of "consumed"
//!
//! We only consume bytes when we matched the FULL `\x1B[<digits>;<digits>R`
//! shape. Partial-match abandonment (e.g. user types `\x1B[A` for
//! Up-arrow — same prefix but different final) leaves the bytes in
//! the original stream so legacy keymap matching still works. The
//! consequence: a DSR reply gets parsed only when it's complete in
//! one chunk OR carries over correctly across two chunks (the
//! `pending` state handles that). Mid-stream partial matches that
//! abandon don't get retroactively re-fed.
//!
//! ## Non-goals
//!
//! - Multi-reply pipelining. atty fires DSR at most once per "key
//!   moment" and waits for the reply (or times out) before firing
//!   another. The parser only handles one in-flight reply at a time.
//! - Other DSR variants (DSR-5 status, DSR-15 printer). Not used.

const std = @import("std");

pub const Position = struct { row: u16, col: u16 };

pub const DsrParser = struct {
    state: State = .ground,
    digits_buf: [16]u8 = undefined,
    digits_len: u8 = 0,
    row: u16 = 0,
    col: u16 = 0,
    /// True while we've started parsing a `\x1B[…` sequence — the
    /// caller should withhold these bytes from downstream until we
    /// either complete or abort.
    pending: bool = false,
    /// Bytes since the last consumed reply that contributed to the
    /// pending sequence. Indexes into the caller's slice are
    /// recomputed each `feed` call (no persistent indices).
    pending_byte_count: usize = 0,

    const State = enum { ground, esc, csi, row_done };

    /// Build the output slice by filtering the input through the
    /// parser. Bytes that BELONG to a successful DSR reply are
    /// dropped; everything else is preserved. Returns the position
    /// parsed (if any) and a side-buffer of the filtered bytes.
    ///
    /// `out` must be at least `input.len` bytes. Caller passes a
    /// scratch buffer they're already writing to.
    pub fn feed(self: *DsrParser, input: []const u8, out: []u8) struct { filtered_len: usize, pos: ?Position } {
        var w: usize = 0;
        var result_pos: ?Position = null;
        // Track the start index of the current pending sequence in
        // `out` so we can rewind the filtered write if the sequence
        // turns out to NOT be a DSR reply (abort path).
        var pending_w_start: usize = 0;

        for (input) |b| {
            switch (self.state) {
                .ground => {
                    if (b == 0x1B) {
                        self.state = .esc;
                        self.pending = true;
                        pending_w_start = w;
                        out[w] = b;
                        w += 1;
                    } else {
                        out[w] = b;
                        w += 1;
                    }
                },
                .esc => {
                    if (b == '[') {
                        self.state = .csi;
                        self.digits_len = 0;
                        self.row = 0;
                        self.col = 0;
                        out[w] = b;
                        w += 1;
                    } else {
                        // Not the shape we want. Pass through.
                        self.state = .ground;
                        self.pending = false;
                        out[w] = b;
                        w += 1;
                    }
                },
                .csi => {
                    if (b >= '0' and b <= '9' and self.digits_len < self.digits_buf.len) {
                        self.digits_buf[self.digits_len] = b;
                        self.digits_len += 1;
                        out[w] = b;
                        w += 1;
                    } else if (b == ';') {
                        self.row = parseClamped(self.digits_buf[0..self.digits_len]);
                        self.digits_len = 0;
                        self.state = .row_done;
                        out[w] = b;
                        w += 1;
                    } else if (b == 'R' or b == 'n') {
                        // 'R' is a malformed reply (no `;`) — treat
                        // as abort. 'n' would be DSR query itself
                        // (we don't care). Both abort.
                        self.state = .ground;
                        self.pending = false;
                        out[w] = b;
                        w += 1;
                    } else {
                        // Unknown CSI body byte — abandon DSR parse,
                        // keep bytes in the output stream so keymap
                        // matchers / readline see them.
                        self.state = .ground;
                        self.pending = false;
                        out[w] = b;
                        w += 1;
                    }
                },
                .row_done => {
                    if (b >= '0' and b <= '9' and self.digits_len < self.digits_buf.len) {
                        self.digits_buf[self.digits_len] = b;
                        self.digits_len += 1;
                        out[w] = b;
                        w += 1;
                    } else if (b == 'R') {
                        // Full reply received — rewind the filtered
                        // buffer to before the `\x1B`, dropping the
                        // entire DSR sequence from the stream.
                        self.col = parseClamped(self.digits_buf[0..self.digits_len]);
                        result_pos = .{ .row = self.row, .col = self.col };
                        w = pending_w_start;
                        self.state = .ground;
                        self.pending = false;
                        self.digits_len = 0;
                    } else {
                        // Malformed (no terminator) — abandon.
                        self.state = .ground;
                        self.pending = false;
                        out[w] = b;
                        w += 1;
                    }
                },
            }
        }

        return .{ .filtered_len = w, .pos = result_pos };
    }

    /// Emit the DSR-6n query sequence into `w`. Caller writes the
    /// result to STDOUT; the terminal replies on stdin which `feed`
    /// will parse.
    pub fn writeQuery(w: *std.Io.Writer) !void {
        try w.writeAll("\x1B[6n");
    }
};

fn parseClamped(digits: []const u8) u16 {
    var acc: u32 = 0;
    const cap: u32 = std.math.maxInt(u16);
    for (digits) |b| {
        if (b < '0' or b > '9') continue;
        if (acc >= cap) {
            acc = cap;
            continue;
        }
        const d: u32 = b - '0';
        const next: u64 = @as(u64, acc) * 10 + d;
        acc = if (next > cap) cap else @intCast(next);
    }
    return @intCast(acc);
}

test {
    _ = @import("cursor_dsr_tests.zig");
}
