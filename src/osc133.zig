//! OSC 133 — semantic prompt-zone markers.
//!
//! The wire protocol (originated in iTerm, adopted by VS Code, kitty,
//! Ghostty's shell-integration, ble.sh, zsh4humans, fig, …):
//!
//!     \x1b]133;A\x07       — prompt start
//!     \x1b]133;B\x07       — input region begins (user can type)
//!     \x1b]133;C\x07       — command execution starts (user pressed Enter)
//!     \x1b]133;D[;<code>]\x07 — command finished
//!
//! Terminators: BEL (0x07) or ST (ESC '\'). atty handles both.
//!
//! Why we care: between `;B` and `;C`, anything printable the shell
//! emits is the user's INPUT line as the shell sees it — including
//! history-recalled text. Atty's keystroke tracking goes blind on
//! Up-arrow / Tab-completion / paste / `!!` expansion; the markers
//! close that gap with zero guessing.
//!
//! Fallback: if the shell never emits 133 markers, `active` stays
//! false and the proxy keeps using its keystroke-based line model.
//! The user enables them shell-side; atty auto-detects and adopts.

const std = @import("std");

pub const Osc133 = struct {
    allocator: std.mem.Allocator,
    /// True once we've seen any well-formed 133 marker. Sticky for
    /// the lifetime of the session — the gate the proxy uses to
    /// decide whether to trust currentInput() over its keystroke
    /// buffer.
    active: bool = false,
    /// Captured printable bytes between the last `;B` and now. CR
    /// (line redraw) clears it; BS drops one byte; other CSI/OSC
    /// sequences are absorbed without polluting it.
    input: std.ArrayList(u8) = .empty,

    state: State = .ground,
    phase: Phase = .idle,
    osc_buf: [256]u8 = undefined,
    osc_len: usize = 0,

    /// Bounded ring of phase-transition edges that fired during the
    /// most recent `feed()` calls — cleared by `drainEdges()`. The
    /// proxy uses this to drive its subprocess stack push/pop: a
    /// SINGLE `read()` chunk may contain multiple markers (a fast
    /// command emitting `;C;D` back-to-back, several prompt redraws,
    /// the local shell flushing a queued PROMPT_COMMAND…), and
    /// post-feed phase comparison alone misses intermediate edges.
    /// 32 is plenty — one keystroke produces at most one marker in
    /// practice; pasted scripts that batch-execute are the realistic
    /// upper bound and a `;C;D` pair per line for ~16 lines fits.
    /// Overflow is silently dropped (rare; would only mis-attribute
    /// some subprocess frames in a pathological burst).
    edges: [32]Edge = undefined,
    /// Byte offset within the current feed where each edge fired.
    /// The proxy uses these offsets to interleave OSC 7 cwd updates
    /// (which fire from a separate `Osc7` tracker on the same byte
    /// stream) with OSC 133 push/pop in the order they actually
    /// appeared in `output`. Without offsets, applying all OSC 7
    /// after all edges (or vice versa) mis-attributes the cwd to
    /// the wrong frame when `OSC 7` and `;C` co-occur in a single
    /// read chunk.
    edge_offsets: [32]u32 = undefined,
    /// `usize` rather than `u8` despite the bounded array size so
    /// `edges[0..edge_count]` slicing and `edgeOffset(idx)` indexing
    /// don't need explicit casts at every call site. The 32-entry
    /// ring caps the value far below `u8` range anyway.
    edge_count: usize = 0,
    /// Byte index within the current `feed()` call. Stamped onto
    /// each edge in `edge_offsets`. Reset at the start of every
    /// `feed()` invocation; the proxy reads it indirectly via the
    /// stamped offsets and otherwise ignores it.
    feed_byte_index: u32 = 0,

    const State = enum {
        ground, // regular input-byte processing (when in input phase)
        esc, // saw 0x1B; next byte chooses sub-state
        csi, // inside `\x1b[…final`
        osc, // inside `\x1b]…`
        osc_esc, // saw 0x1B inside osc; awaiting '\' (ST)
    };
    pub const Phase = enum {
        /// Outside any prompt / command zone. Initial state, and the
        /// state after `;D`.
        idle,
        /// Prompt is drawing or open for input, but `;B` hasn't been
        /// seen so we don't know where the user-input region begins.
        /// `inInputPhase()` returns TRUE here so gates that ask "are
        /// we at the prompt right now?" (ghost text, line_state
        /// override, recording) fire correctly even for partial
        /// emitters (Ghostty's default OSC 133 integration emits
        /// only `;A` + `;C`, never `;B` / `;D`). Byte capture for
        /// `currentInput()` does NOT activate here — PS1 bytes
        /// drawn between `;A` and `;B` aren't user input.
        at_prompt,
        /// Between `;B` and `;C` — strict user-typing region. Byte
        /// capture is active so `currentInput()` reflects what the
        /// shell has drawn (history recall, completion expansion,
        /// paste).
        in_input,
        /// Between `;C` and `;D` — command is running, ignore output
        /// for input-capture purposes.
        in_command,
    };
    /// Edge events the proxy consumes via `drainEdges()`. We only
    /// surface the two markers that drive subprocess-context push/pop;
    /// `;A` / `;B` are still observed for the phase state machine
    /// but don't need separate edges (the proxy only needs to know
    /// when commands start + end).
    pub const Edge = enum {
        cmd_start, // ;C — push a subprocess frame
        cmd_end, // ;D — pop the top frame
    };

    pub fn init(allocator: std.mem.Allocator) Osc133 {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Osc133) void {
        self.input.deinit(self.allocator);
    }

    /// Read of the captured input region. Empty when no `;B` has
    /// fired yet, or when the line was just cleared via CR.
    pub fn currentInput(self: *const Osc133) []const u8 {
        return self.input.items;
    }

    /// True iff the user is currently at the prompt — either we've
    /// passed `;A` (prompt is drawing or open for input) OR we've
    /// passed `;B` (strict user-typing region). Both cases mean
    /// "the user is at the prompt and may be typing." The proxy
    /// uses this to gate ghost-text painting, the `line_state`
    /// override path, and the subprocess `pending_launches` push.
    ///
    /// Returning true for `.at_prompt` is the key fix that makes
    /// PR #15's ghost-text gate work with PARTIAL OSC 133 emitters
    /// — Ghostty's default `shell-integration-features = osc-133`
    /// emits only `;A` and `;C`, never `;B` or `;D`, so a stricter
    /// `phase == .in_input` gate suppressed ghost text for the
    /// entire shell session.
    ///
    /// **Do NOT use this to gate `syncFromCapture`** — that path
    /// overwrites `line_state` from `currentInput()`, and
    /// `currentInput()` is empty in `.at_prompt` (capture only
    /// activates after `;B`). For partial emitters that means
    /// every iteration would clobber the user's keystroke-tracked
    /// buffer with the empty capture. Use `captureActive()` for
    /// that gate.
    pub fn inInputPhase(self: *const Osc133) bool {
        return self.phase == .in_input or self.phase == .at_prompt;
    }

    /// True iff byte capture for `currentInput()` is currently
    /// active. Distinct from `inInputPhase()` because we want
    /// gates that ask "user is at the prompt" (ghost text,
    /// recording) to fire for partial emitters too, but the
    /// `syncFromCapture` gate must only fire when `currentInput()`
    /// reflects ground-truth shell-drawn content — which is only
    /// the case between `;B` and `;C`.
    pub fn captureActive(self: *const Osc133) bool {
        return self.phase == .in_input;
    }

    /// Feed master-output bytes. Idempotent + safe across partial
    /// sequences (state survives feed calls). Each edge pushed by
    /// this call is stamped with its byte offset within `bytes`
    /// (`feed_byte_index`) so callers can interleave it with other
    /// per-byte events captured during the same feed.
    pub fn feed(self: *Osc133, bytes: []const u8) void {
        self.feed_byte_index = 0;
        for (bytes) |b| {
            self.feedByte(b);
            self.feed_byte_index += 1;
        }
    }

    fn feedByte(self: *Osc133, b: u8) void {
        switch (self.state) {
            .ground => {
                if (b == 0x1B) {
                    self.state = .esc;
                    return;
                }
                if (self.phase != .in_input) return;
                self.processInputByte(b);
            },
            .esc => switch (b) {
                ']' => {
                    self.state = .osc;
                    self.osc_len = 0;
                },
                '[' => self.state = .csi,
                else => self.state = .ground,
            },
            .csi => {
                // Skip the CSI body — its bytes don't belong in
                // the input region. The final byte is in 0x40..0x7E.
                if (b >= 0x40 and b <= 0x7E) self.state = .ground;
            },
            .osc => {
                if (b == 0x07) {
                    self.dispatchOsc();
                    self.state = .ground;
                } else if (b == 0x1B) {
                    self.state = .osc_esc;
                } else if (self.osc_len < self.osc_buf.len) {
                    self.osc_buf[self.osc_len] = b;
                    self.osc_len += 1;
                }
            },
            .osc_esc => {
                if (b == '\\') {
                    self.dispatchOsc();
                    self.state = .ground;
                } else {
                    self.state = .ground;
                }
            },
        }
    }

    fn processInputByte(self: *Osc133, b: u8) void {
        switch (b) {
            0x0D => self.input.clearRetainingCapacity(), // CR — line redraw
            0x08 => if (self.input.items.len > 0) {
                _ = self.input.pop();
            }, // BS — drop last
            else => {
                // Capture printable ASCII (0x20..0x7E) AND any high
                // byte (>= 0x80). The high range covers UTF-8
                // continuation + lead bytes for non-ASCII content —
                // accented characters, CJK, emoji, … — which the
                // shell renders verbatim on the prompt and we have
                // to preserve so the continuous `line_state` sync
                // doesn't strip user input on non-ASCII locales.
                // C0 controls (< 0x20), DEL (0x7F), and CSI escape
                // bodies are handled by the surrounding state
                // machine, not here.
                if ((b >= 0x20 and b < 0x7F) or b >= 0x80) {
                    self.input.append(self.allocator, b) catch return;
                }
            },
        }
    }

    fn dispatchOsc(self: *Osc133) void {
        const body = self.osc_buf[0..self.osc_len];
        if (!std.mem.startsWith(u8, body, "133;")) return;
        if (body.len < 5) return;
        self.active = true;
        switch (body[4]) {
            'A' => {
                // Prompt drawing / open. We're "at the prompt" but
                // PS1 bytes haven't ended yet (no `;B`), so byte
                // capture stays off. For partial emitters that
                // never send `;B` (Ghostty's default integration),
                // this is the closest "user is at the prompt"
                // signal we get; for full emitters, `;B` follows
                // shortly and switches us into strict input capture.
                //
                // **If we were in `.in_command`, synthesize a
                // `.cmd_end` edge first.** Partial emitters that
                // never send `;D` (Ghostty) close commands by
                // emitting the NEXT prompt's `;A` directly after
                // the command output. Without this synthesis the
                // subprocess tracker would never pop the frame
                // pushed on `;C` — the stack would leak `.none`
                // frames for ordinary commands and, worse, leave a
                // recognised ssh / kubectl / sudo frame "active"
                // after the user is back at the local prompt,
                // mis-attributing every subsequent command.
                //
                // Gated on `.in_command` so full emitters (which
                // arrive at `;A` from `.idle` after `;D`) don't
                // synthesize a second pop.
                if (self.phase == .in_command) {
                    self.pushEdge(.cmd_end);
                }
                // **Clear `self.input` too** — without this, a
                // sequence `;B…ls…;C…;D…;A` (the previous command
                // committed, command ran, returned to a new
                // prompt) would leave "ls" sitting in
                // `currentInput()`. The proxy's `syncFromCapture`
                // path trusts `.at_prompt` as "user is at prompt",
                // so without the clear it would re-paint the
                // previous command's text into `line_state` as if
                // the user had just typed it.
                self.phase = .at_prompt;
                self.input.clearRetainingCapacity();
            },
            'B' => {
                self.phase = .in_input;
                self.input.clearRetainingCapacity();
            },
            'C' => {
                self.phase = .in_command;
                self.pushEdge(.cmd_start);
            },
            'D' => {
                self.phase = .idle;
                self.pushEdge(.cmd_end);
            },
            else => {}, // unknown 133 subtype
        }
    }

    fn pushEdge(self: *Osc133, edge: Edge) void {
        if (self.edge_count >= self.edges.len) return; // overflow — drop
        self.edges[self.edge_count] = edge;
        self.edge_offsets[self.edge_count] = self.feed_byte_index;
        self.edge_count += 1;
    }

    /// Drain the edge ring. Returns a slice into `self.edges`
    /// valid until the next `feed()` (which may overwrite). The
    /// proxy walks the slice synchronously between feeds, so the
    /// borrow is safe.
    pub fn drainEdges(self: *Osc133) []const Edge {
        const out = self.edges[0..self.edge_count];
        self.edge_count = 0;
        return out;
    }

    /// Byte offset (within the most recent `feed()`) where edge
    /// `idx` was emitted. Used by the proxy to interleave OSC 7
    /// promotion with OSC 133 push/pop in source order.
    pub fn edgeOffset(self: *const Osc133, idx: usize) u32 {
        return self.edge_offsets[idx];
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Osc133: active stays false until any 133 marker arrives" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("hello \x1b[1;36mcolor\x1b[0m \x1b]0;title\x07more");
    try testing.expect(!o.active);
    try testing.expectEqual(@as(usize, 0), o.currentInput().len);
}

test "Osc133: 133;B turns active on, starts capturing input" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07$ \x1b]133;B\x07");
    try testing.expect(o.active);
    o.feed("ls -la");
    try testing.expectEqualStrings("ls -la", o.currentInput());
}

test "Osc133: ST terminator (ESC backslash) works as well as BEL" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;B\x1b\\hello");
    try testing.expect(o.active);
    try testing.expectEqualStrings("hello", o.currentInput());
}

test "Osc133: CR during input clears the captured line (redraw incoming)" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;B\x07ls -la");
    try testing.expectEqualStrings("ls -la", o.currentInput());
    o.feed("\r\x1b[K$ rm -rf /tmp/test");
    // The CR cleared; the `\x1b[K` is CSI (skipped); the prompt
    // re-emit at column 0 starts fresh. With OSC 133 we DON'T
    // know where the prompt ends inside the redraw — we capture
    // the whole displayed line including the prompt prefix.
    // Callers who care can strip a known prefix; for our use
    // case (guardrail matching) substring matching works on the
    // longer string too.
    try testing.expectEqualStrings("$ rm -rf /tmp/test", o.currentInput());
}

test "Osc133: backspace drops the last captured byte" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;B\x07abc\x08");
    try testing.expectEqualStrings("ab", o.currentInput());
}

test "Osc133: CSI sequences during input are skipped, not captured" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;B\x07ls\x1b[1;36m -la\x1b[0m");
    try testing.expectEqualStrings("ls -la", o.currentInput());
}

test "Osc133: 133;C transitions to in_command — subsequent bytes don't update input" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;B\x07ls\x1b]133;C\x07");
    // Command output bytes flow but we stop capturing.
    o.feed("file1 file2 file3");
    try testing.expectEqualStrings("ls", o.currentInput());
}

test "Osc133.captureActive: TRUE only between ;B and ;C, FALSE for .at_prompt" {
    // Regression: the proxy's `syncFromCapture` path must NOT fire
    // when capture isn't active, otherwise an empty `currentInput()`
    // (which is what `.at_prompt` always returns — capture hasn't
    // started yet) would clobber the keystroke-derived line_state
    // buffer on every iteration, killing ghost text for partial
    // emitters. `captureActive()` is the dedicated narrower gate.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    // No markers yet: not active, not capturing.
    try testing.expect(!o.captureActive());
    o.feed("\x1b]133;A\x07");
    // .at_prompt: inInputPhase TRUE (ghost text fires) but
    // captureActive FALSE (sync stays off).
    try testing.expect(o.inInputPhase());
    try testing.expect(!o.captureActive());
    o.feed("\x1b]133;B\x07");
    // .in_input: BOTH gates fire.
    try testing.expect(o.inInputPhase());
    try testing.expect(o.captureActive());
    o.feed("\x1b]133;C\x07");
    // .in_command: NEITHER fires.
    try testing.expect(!o.inInputPhase());
    try testing.expect(!o.captureActive());
}

test "Osc133.inInputPhase: ;A alone (Ghostty-style partial integration) puts us in input phase" {
    // Regression: Ghostty's `shell-integration-features = osc-133` (the
    // out-of-the-box flag) emits only `;A` and `;C` — no `;B` and no
    // `;D`. With our previous mapping `;A → .idle`, `inInputPhase()`
    // returned false for the *entire* lifetime of the shell session
    // when running under Ghostty's built-in integration. PR #15's
    // ghost-text gate (`inSubprocess(alt, osc) → drop`) then
    // suppressed suggestions at the local prompt because
    // `osc.active && !osc.inInputPhase()` was always true.
    //
    // Fix: `;A` puts us in input phase. A subsequent `;B` (if the
    // emitter sends one) just stays in input phase, no harm done.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07$ ");
    try testing.expect(o.inInputPhase());
}

test "Osc133: partial emitter ;A after ;C synthesizes a .cmd_end edge" {
    // Regression: Ghostty-style partial emitters send `;A` + `;C`
    // but no `;D`. Without synthesizing the close-edge here, the
    // subprocess tracker would never pop the frame pushed on `;C`
    // — stack leaks `.none` frames per command, and worse, a
    // recognised ssh / kubectl / sudo frame stays "active" after
    // the user is back at the local prompt, mis-attributing every
    // subsequent command's `--cwd`.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07$ ls\x1b]133;C\x07");
    // First ;A: idle → .at_prompt, no edge. First ;C: push cmd_start.
    {
        const edges = o.drainEdges();
        try testing.expectEqual(@as(usize, 1), edges.len);
        try testing.expectEqual(Osc133.Edge.cmd_start, edges[0]);
    }
    // Now the partial emitter skips ;D and goes straight to next ;A:
    o.feed("output from ls\x1b]133;A\x07");
    {
        // Synthesized cmd_end fires here so the tracker's stack
        // can pop the frame.
        const edges = o.drainEdges();
        try testing.expectEqual(@as(usize, 1), edges.len);
        try testing.expectEqual(Osc133.Edge.cmd_end, edges[0]);
    }
    try testing.expect(o.inInputPhase()); // .at_prompt again
}

test "Osc133: full emitter ;A after ;D does NOT double-synthesize cmd_end" {
    // Full emitters emit `;D` then `;A`. The `;D` already pushed
    // cmd_end; the `;A` must NOT synthesize a second one or the
    // proxy's subprocess Tracker would over-pop.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07$ \x1b]133;B\x07ls\x1b]133;C\x07out\x1b]133;D\x07");
    {
        const edges = o.drainEdges();
        try testing.expectEqual(@as(usize, 2), edges.len);
        try testing.expectEqual(Osc133.Edge.cmd_start, edges[0]);
        try testing.expectEqual(Osc133.Edge.cmd_end, edges[1]);
    }
    // Now the next ;A arrives — we were in .idle (post-;D), so
    // NO synthesis should fire.
    o.feed("\x1b]133;A\x07");
    {
        const edges = o.drainEdges();
        try testing.expectEqual(@as(usize, 0), edges.len);
    }
}

test "Osc133: B → typed → C → D → A leaves currentInput() empty (not stale)" {
    // Regression guard for the `;A`-doesn't-clear bug: without
    // clearing `self.input` on `;A`, the captured input region
    // from the PREVIOUS prompt's `;B`-to-`;C` window would leak
    // forward into the new prompt's `.at_prompt` state. The proxy
    // would then `syncFromCapture(currentInput())` and paint the
    // previous command's text into `line_state` as if the user
    // had just typed it again.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;B\x07ls -la\x1b]133;C\x07command output here\x1b]133;D\x07");
    // Between B and C, "ls -la" was captured. After C/D it's not
    // cleared (we only clear on B). Now the next prompt fires `;A`:
    o.feed("\x1b]133;A\x07");
    // .at_prompt + currentInput() empty → proxy's syncFromCapture
    // is a no-op (it guards on len > 0), no stale paint.
    try testing.expect(o.inInputPhase());
    try testing.expectEqual(@as(usize, 0), o.currentInput().len);
}

test "Osc133: ;A without ;B doesn't capture prompt-drawing bytes" {
    // After we treat `;A → input phase`, the byte-capture for
    // `currentInput()` must NOT activate yet — those bytes are the
    // shell drawing PS1, not user typing. The capture region only
    // opens with `;B` (full emitters) or stays empty for partial
    // emitters that never send `;B`. Both behaviours protect the
    // line_state override path in proxy.zig from getting polluted
    // by PS1 characters.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07[user@host ~]$ ");
    try testing.expect(o.inInputPhase());
    try testing.expectEqual(@as(usize, 0), o.currentInput().len);
}

test "Osc133.inInputPhase reflects the A → B → C → D transitions" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    // No marker yet: tracker is idle, not in input.
    try testing.expect(!o.inInputPhase());
    o.feed("\x1b]133;A\x07$ ");
    // After A: AT THE PROMPT. inInputPhase returns true so ghost
    // text / line_state override / pending_launches push gates
    // fire correctly for partial emitters that never send `;B`.
    try testing.expect(o.inInputPhase());
    o.feed("\x1b]133;B\x07");
    // After B: strict input phase, byte capture active.
    try testing.expect(o.inInputPhase());
    o.feed("ls");
    try testing.expect(o.inInputPhase());
    try testing.expectEqualStrings("ls", o.currentInput());
    o.feed("\x1b]133;C\x07");
    // After C: in_command, not in input — proxy must NOT sync
    // line_state from currentInput while we're in this phase,
    // because the password prompts of sudo/ssh/passwd live here.
    try testing.expect(!o.inInputPhase());
    o.feed("\x1b]133;D\x07");
    try testing.expect(!o.inInputPhase());
}

test "Osc133.drainEdges captures every ;C / ;D in order, across a single chunk" {
    // Subprocess-stack push/pop relies on this. A shell that emits
    // `;A;B …;C…;D` for a fast command — or a paste of a script
    // that runs several lines in one flush — will deliver several
    // markers in a single read chunk. Post-feed phase comparison
    // alone collapsed all of them into one (or none) transition
    // edge; the ring captures each in order.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07\x1b]133;B\x07echo hi\x1b]133;C\x07hi\r\n\x1b]133;D\x07\x1b]133;A\x07");
    const edges = o.drainEdges();
    try testing.expectEqual(@as(usize, 2), edges.len);
    try testing.expectEqual(Osc133.Edge.cmd_start, edges[0]);
    try testing.expectEqual(Osc133.Edge.cmd_end, edges[1]);
    // Second drain is empty — the ring was consumed.
    try testing.expectEqual(@as(usize, 0), o.drainEdges().len);
}

test "Osc133.drainEdges: rapid C/D/C/D preserves order" {
    // Pathological-ish: a script that batches two short commands.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;C\x07\x1b]133;D\x07\x1b]133;C\x07\x1b]133;D\x07");
    const edges = o.drainEdges();
    try testing.expectEqual(@as(usize, 4), edges.len);
    try testing.expectEqual(Osc133.Edge.cmd_start, edges[0]);
    try testing.expectEqual(Osc133.Edge.cmd_end, edges[1]);
    try testing.expectEqual(Osc133.Edge.cmd_start, edges[2]);
    try testing.expectEqual(Osc133.Edge.cmd_end, edges[3]);
}

test "Osc133.drainEdges: only ;A/;B markers produce no edges" {
    // Prompt-drawing markers fire phase transitions but no subprocess
    // edges (we only care about command boundaries).
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07$ \x1b]133;B\x07");
    try testing.expectEqual(@as(usize, 0), o.drainEdges().len);
    try testing.expect(o.inInputPhase());
}

test "Osc133: CR-then-redraw captures the recalled line (Arrow Up shape)" {
    // Simulates what bash does on Arrow Up: emit CR (which the
    // tracker treats as a line clear), then the recalled command.
    // The tracker should end up with the recalled string as
    // currentInput, ready for proxy.syncFromCapture to mirror.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07$ \x1b]133;B\x07ls");
    try testing.expectEqualStrings("ls", o.currentInput());
    // User presses Up — shell rewrites the line.
    o.feed("\r\x1b[Kgit status");
    try testing.expectEqualStrings("git status", o.currentInput());
    try testing.expect(o.inInputPhase());
}

test "Osc133: UTF-8 input bytes are captured (regression — non-ASCII users)" {
    // Without this, the continuous line_state sync would overwrite
    // a correctly-typed `café` (which keystroke tracking has as
    // `c a f é` = `0x63 0x61 0x66 0xC3 0xA9`) with the lossy
    // capture `caf` — silently dropping the accented character
    // from every consumer of `ctx.line.current()`. Accented
    // characters, CJK, emoji all go through the same UTF-8
    // continuation-byte path, so we exercise a few.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07$ \x1b]133;B\x07");

    // "café" — 2-byte UTF-8 for é (0xC3 0xA9).
    o.feed("café");
    try testing.expectEqualStrings("café", o.currentInput());

    // Clear via CR + type CJK — 3-byte sequences (0xE4 0xBA 0xBA etc.).
    o.feed("\r人");
    try testing.expectEqualStrings("人", o.currentInput());

    // Clear + emoji — 4-byte sequence (0xF0 0x9F 0x98 0x80).
    o.feed("\r😀 hello");
    try testing.expectEqualStrings("😀 hello", o.currentInput());
}

test "Osc133: subsequent 133;B clears the buffer (fresh prompt)" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;B\x07ls\x1b]133;C\x07output\x1b]133;D\x07");
    o.feed("\x1b]133;A\x07$ \x1b]133;B\x07");
    try testing.expectEqualStrings("", o.currentInput());
    o.feed("cd /tmp");
    try testing.expectEqualStrings("cd /tmp", o.currentInput());
}

test "Osc133: partial sequence across feed boundaries works" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133");
    o.feed(";B");
    o.feed("\x07hi");
    try testing.expect(o.active);
    try testing.expectEqualStrings("hi", o.currentInput());
}

test "Osc133: non-133 OSC sequences (title-set, hyperlinks) don't change phase" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]0;my title\x07");
    o.feed("\x1b]8;;file:///tmp\x1b\\link text\x1b]8;;\x1b\\");
    try testing.expect(!o.active);
}

test "Osc133: malformed 133 (no terminator yet) doesn't crash + keeps state" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;B"); // no terminator
    try testing.expect(!o.active); // dispatch hasn't fired yet
    o.feed("\x07"); // arrives later
    try testing.expect(o.active);
}
