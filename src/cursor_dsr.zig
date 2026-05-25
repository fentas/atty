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
    /// Set by `markQuerySent` after the proxy emits a `\x1B[6n` query
    /// to the terminal; cleared on the next successful reply parse OR
    /// any abort (`.esc` / `.csi` / `.row_done` non-matching byte).
    /// **Critical for lone-ESC keystrokes.** Without this gate, every
    /// `\x1B` (including a user's bare Esc with no follow-up byte in
    /// the same read) drops into `.esc` state and sits in `pending_buf`
    /// indefinitely — the proxy's `\x1B`-then-nothing read filters to
    /// 0 bytes and the keymap match never fires. Result: Esc bindings
    /// (`llm_exec_cancel`, future vim-mode triggers) silently dead.
    /// Gating on outstanding queries keeps cross-chunk DSR-reply
    /// reassembly working for the legitimate case (terminal's reply
    /// to atty's query, arriving immediately after the query write)
    /// while passing through stray ESCs unchanged.
    ///
    /// Worst-case window where a user-typed Esc would still be eaten:
    /// `proxy.tick_interval_ms` (100 ms by default) between the
    /// `writeQuery` and the next poll wake that delivers the reply.
    /// Two of atty's query-emit sites fire at known-cool moments
    /// (reserve-rows toggle, OSC 133 `;C` cmd_end); the window is
    /// also bounded by clearing the gate on abort so a user's stray
    /// keystroke during the query window aborts the buffered sequence
    /// and unsticks subsequent ESCs immediately.
    expecting_reply: bool = false,

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
                    // Only intercept `\x1B` when atty has explicitly
                    // queried the terminal for a reply. Outside that
                    // window every ESC is either a user keystroke
                    // (Esc-bound action like `llm_exec_cancel`) or
                    // the lead byte of an unrelated CSI sequence the
                    // shell will parse — pass it through immediately
                    // so the keymap matcher can do its job.
                    if (b == 0x1B and self.expecting_reply) {
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
                        // downstream see the original sequence. Clear
                        // `expecting_reply` too: an aborted parse
                        // means the query that armed this state
                        // either won't be answered (terminal didn't
                        // reply yet, or the user got there first with
                        // their own keystroke). Leaving the gate set
                        // would re-arm the buffer on the next ESC
                        // — every ESC after a single missed-reply
                        // would be re-eaten.
                        w += self.flushPending(out[w..]);
                        out[w] = b;
                        w += 1;
                        self.state = .ground;
                        self.expecting_reply = false;
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
                        // pending + the abort byte verbatim. Clear
                        // the gate (see comment in the `.esc` abort
                        // branch).
                        w += self.flushPending(out[w..]);
                        out[w] = b;
                        w += 1;
                        self.state = .ground;
                        self.expecting_reply = false;
                    }
                },
                .row_done => {
                    if (b >= '0' and b <= '9' and self.digits_len < self.digits_buf.len) {
                        self.digits_buf[self.digits_len] = b;
                        self.digits_len += 1;
                        self.pushPending(b);
                    } else if (b == 'R') {
                        // Full reply received — drop pending buffer
                        // (the DSR sequence is consumed) and clear
                        // the expecting-reply gate so subsequent
                        // ESCs pass through immediately.
                        self.col = parseClamped(self.digits_buf[0..self.digits_len]);
                        result_pos = .{ .row = self.row, .col = self.col };
                        self.pending_len = 0;
                        self.state = .ground;
                        self.digits_len = 0;
                        self.expecting_reply = false;
                    } else {
                        // Malformed (no terminator) — abandon, flush
                        // pending + the abort byte. Clear the gate
                        // (see comment in the `.esc` abort branch).
                        w += self.flushPending(out[w..]);
                        out[w] = b;
                        w += 1;
                        self.state = .ground;
                        self.expecting_reply = false;
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
    ///
    /// **`self` form (recommended).** Pairs the query-emit with the
    /// parser's `expecting_reply` gate so subsequent `feed` calls
    /// know to buffer the reply's `\x1B[…R` shape. Without this gate
    /// the parser would pass through `\x1B` immediately and the
    /// reply would leak to bash as if the user had typed `[24;1R`.
    pub fn writeQuery(self: *DsrParser, w: *std.Io.Writer) !void {
        try w.writeAll("\x1B[6n");
        self.expecting_reply = true;
    }

    /// Mark a DSR query as sent without emitting the bytes — used
    /// when the caller writes the query through a different channel
    /// (e.g. raw POSIX write to stdout).
    pub fn markQuerySent(self: *DsrParser) void {
        self.expecting_reply = true;
    }
};

/// Strip well-formed CPR replies that atty didn't query for.
///
/// Single-chunk only: stateful cross-chunk withholding would
/// re-engage the lone-Esc-eater problem that `expecting_reply`
/// exists to prevent. In practice terminals emit CPR as one
/// pty write so split-across-reads is vanishingly rare.
///
/// `alt_screen_active=true` is a verbatim pass-through — the
/// running TUI owns its own DSR/CPR protocol. Callers that
/// already know they don't need the scrub should skip the
/// call entirely to avoid the copy.
///
/// `out` must be at least `input.len` bytes; debug-asserted.
/// In-place (`out.ptr == input.ptr`) is safe in both branches:
/// the alt-screen path uses `@memmove`, and the scrub loop's
/// write index `w` never gets ahead of its read index `i` (CPR
/// matches skip ahead in `input` without writing). Partial
/// overlap where `out` starts somewhere inside `input` is
/// undefined.
pub fn dropWellFormedCpr(input: []const u8, out: []u8, alt_screen_active: bool) usize {
    std.debug.assert(out.len >= input.len);
    if (alt_screen_active) {
        @memmove(out[0..input.len], input);
        return input.len;
    }
    var w: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (i + 6 <= input.len and input[i] == 0x1B and input[i + 1] == '[') {
            if (matchCprAt(input, i)) |after| {
                i = after;
                continue;
            }
        }
        out[w] = input[i];
        w += 1;
        i += 1;
    }
    return w;
}

/// Return the index one past the CPR reply starting at `start`,
/// or null if the bytes at `start` don't form a complete
/// `\x1B[<digits>;<digits>R` sequence. Requires at least one
/// digit on each side of the `;`. Digit count is capped (16 each
/// side) so a hostile stream can't loop the scanner.
fn matchCprAt(input: []const u8, start: usize) ?usize {
    var p: usize = start + 2;
    const len = input.len;
    var d1: usize = 0;
    while (p < len and d1 < 16 and input[p] >= '0' and input[p] <= '9') : (p += 1) d1 += 1;
    if (d1 == 0 or p >= len or input[p] != ';') return null;
    p += 1;
    var d2: usize = 0;
    while (p < len and d2 < 16 and input[p] >= '0' and input[p] <= '9') : (p += 1) d2 += 1;
    if (d2 == 0 or p >= len or input[p] != 'R') return null;
    return p + 1;
}

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
