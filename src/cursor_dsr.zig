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
    /// Bytes accumulated while we're parsing a possible reply.
    /// They DON'T appear in `feed`'s output until either:
    ///   - the reply completes successfully → drop the whole buffer
    ///   - the sequence aborts → flush the buffer to output verbatim
    /// Withholding here is required for cross-chunk splits: a reply
    /// like `\x1B[12;` (chunk 1) + `45R` (chunk 2) would otherwise
    /// leak the 5 chunk-1 bytes to bash before we know it's a reply.
    /// 32 bytes covers the largest legitimate DSR reply (`\x1B[<5
    /// digits>;<5 digits>R` = 13) with comfort.
    pending_buf: [32]u8 = undefined,
    pending_len: u8 = 0,

    const State = enum { ground, esc, csi, row_done };

    /// Build the output slice by filtering the input through the
    /// parser. Bytes that BELONG to a successful DSR reply are
    /// dropped; everything else is preserved. Returns the position
    /// parsed (if any) and the filtered byte count.
    ///
    /// `out` must be at least `input.len` bytes. Caller passes a
    /// scratch buffer they're already writing to.
    ///
    /// Bytes that are part of an in-flight (not yet
    /// completed-or-aborted) sequence are NOT written to `out` —
    /// they live in the parser's internal `pending_buf` and either
    /// vanish (success) or get flushed (abort) on a later feed call.
    pub fn feed(self: *DsrParser, input: []const u8, out: []u8) struct { filtered_len: usize, pos: ?Position } {
        var w: usize = 0;
        var result_pos: ?Position = null;

        for (input) |b| {
            switch (self.state) {
                .ground => {
                    if (b == 0x1B) {
                        self.state = .esc;
                        self.pushPending(b);
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
                        self.pushPending(b);
                    } else {
                        // Not the shape we want — flush pending +
                        // current byte verbatim so keymap matchers
                        // downstream see the original sequence.
                        w += self.flushPending(out[w..]);
                        out[w] = b;
                        w += 1;
                        self.state = .ground;
                    }
                },
                .csi => {
                    if (b >= '0' and b <= '9' and self.digits_len < self.digits_buf.len) {
                        self.digits_buf[self.digits_len] = b;
                        self.digits_len += 1;
                        self.pushPending(b);
                    } else if (b == ';') {
                        self.row = parseClamped(self.digits_buf[0..self.digits_len]);
                        self.digits_len = 0;
                        self.state = .row_done;
                        self.pushPending(b);
                    } else {
                        // Anything else aborts (including a stray
                        // 'R' with no `;` — malformed reply). Flush
                        // pending + the abort byte verbatim.
                        w += self.flushPending(out[w..]);
                        out[w] = b;
                        w += 1;
                        self.state = .ground;
                    }
                },
                .row_done => {
                    if (b >= '0' and b <= '9' and self.digits_len < self.digits_buf.len) {
                        self.digits_buf[self.digits_len] = b;
                        self.digits_len += 1;
                        self.pushPending(b);
                    } else if (b == 'R') {
                        // Full reply received — drop pending buffer
                        // (the DSR sequence is consumed).
                        self.col = parseClamped(self.digits_buf[0..self.digits_len]);
                        result_pos = .{ .row = self.row, .col = self.col };
                        self.pending_len = 0;
                        self.state = .ground;
                        self.digits_len = 0;
                    } else {
                        // Malformed (no terminator) — abandon, flush
                        // pending + the abort byte.
                        w += self.flushPending(out[w..]);
                        out[w] = b;
                        w += 1;
                        self.state = .ground;
                    }
                },
            }
        }

        return .{ .filtered_len = w, .pos = result_pos };
    }

    fn pushPending(self: *DsrParser, b: u8) void {
        if (self.pending_len < self.pending_buf.len) {
            self.pending_buf[self.pending_len] = b;
            self.pending_len += 1;
        }
        // Overflow: silently drop bytes past the buffer. A
        // legitimate DSR is ≤ 13 bytes; if we overflow we're
        // looking at a hostile / malformed sequence that wasn't
        // going to complete cleanly anyway.
    }

    fn flushPending(self: *DsrParser, out: []u8) usize {
        const n: usize = self.pending_len;
        if (n > 0) @memcpy(out[0..n], self.pending_buf[0..n]);
        self.pending_len = 0;
        return n;
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
