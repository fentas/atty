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
    /// Byte index of the leading `ESC` of the OSC sequence
    /// currently being parsed (state transition .ground → .esc).
    /// Captured here so `pushEdge` can stamp the START of the
    /// marker into `edge_offsets`, not its terminator — callers
    /// need to slice the markup OUT cleanly and otherwise have
    /// to walk backwards looking for an ESC, which is fragile
    /// across feed boundaries.
    osc_start_index: u32 = 0,

    /// Cumulative bytes fed across the lifetime of the tracker. Used
    /// by the LLM module's diagnostic error path (`Alt+S` without
    /// active OSC 133) to distinguish "shell never wrote a byte" from
    /// "shell wrote bytes but no 133 marker among them". Never used
    /// for correctness — purely a sticky observability counter.
    total_bytes_fed: u64 = 0,
    /// Cumulative OSC 133 dispatches seen (any marker — A/B/C/D).
    /// Diagnostic only.
    total_dispatches: u32 = 0,

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
    /// Edge events the proxy consumes via `drainEdges()`. Three
    /// variants — `;C` opens a command; `;D` explicitly closes it;
    /// and an *implicit* close fires when `;A` arrives while we
    /// were still in `.in_command` (partial OSC 133 emitters
    /// skip `;D` entirely).
    pub const Edge = enum {
        /// `;C` — push a subprocess frame.
        cmd_start,
        /// `;D` — explicit close. Always pops the top frame
        /// regardless of kind (the shell told us the command
        /// ended, full stop).
        cmd_end,
        /// `;A` arriving while phase was `.in_command` (Ghostty-
        /// style partial emitters skip `;D` and just emit the
        /// next prompt's `;A` directly after the command output).
        /// The proxy treats this as "the command FINISHED" but
        /// MUST NOT pop recognised launcher frames (ssh / sudo /
        /// kubectl): a remote shell with its own OSC 133
        /// integration will emit its OWN `;A` shortly after we
        /// connect — that's NOT the local launcher exiting. The
        /// proxy walks the stack from the top and pops trailing
        /// `.none` frames only (ordinary local/remote commands
        /// that finished); the recognised frame underneath stays.
        prompt_start_implicit_end,
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

    /// True iff the next escape-free byte chunk is a guaranteed
    /// no-op — the proxy can fast-path past it without invoking
    /// the per-byte state machine.
    ///
    /// Two conditions must hold:
    ///   - `state == .ground` (no half-parsed CSI / OSC).
    ///   - `phase != .in_input` (between `;B` and `;C`, plain ASCII
    ///     bytes ARE processed in the `.ground` arm — they feed
    ///     `processInputByte()` which mutates the captured-input
    ///     buffer the proxy's syncFromCapture reads. Fast-pathing
    ///     here would silently desync atty's view of what the
    ///     user typed from the shell's echo.)
    pub fn canFastPath(self: *const Osc133) bool {
        return self.state == .ground and self.phase != .in_input;
    }

    /// Account for `n` skipped bytes when the proxy fast-paths
    /// past an escape-free chunk. Bumps `total_bytes_fed` so the
    /// "OSC 133 needs setup" diagnostic stays accurate; no edges
    /// produced, no input captured. Caller must have verified
    /// `canFastPath()` first.
    pub fn skipBytes(self: *Osc133, n: usize) void {
        self.total_bytes_fed +%= n;
    }

    /// Feed master-output bytes. Idempotent + safe across partial
    /// sequences (state survives feed calls). Each edge pushed by
    /// this call is stamped with its byte offset within `bytes`
    /// (`feed_byte_index`) so callers can interleave it with other
    /// per-byte events captured during the same feed.
    pub fn feed(self: *Osc133, bytes: []const u8) void {
        self.feed_byte_index = 0;
        self.total_bytes_fed +%= bytes.len;
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
                    self.osc_start_index = self.feed_byte_index;
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
        self.total_dispatches +%= 1;
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
                // **If we were in `.in_command`, emit a
                // `.prompt_start_implicit_end` edge.** Partial
                // emitters skip `;D` and just send the next
                // prompt's `;A` directly after the command output.
                // The proxy treats this edge as "the in-progress
                // command finished" — but it WON'T blindly pop the
                // subprocess top: a remote shell with its own
                // OSC 133 integration emits its OWN `;A` shortly
                // after we connect, which is NOT the local ssh
                // launcher exiting. The proxy walks down and pops
                // trailing `.none` frames only. See `Edge` doc.
                //
                // Gated on `.in_command` so full emitters (which
                // arrive at `;A` from `.idle` after `;D`) don't
                // emit a redundant implicit-end.
                if (self.phase == .in_command) {
                    self.pushEdge(.prompt_start_implicit_end);
                }
                // **Clear `self.input` too** — even though
                // `syncFromCapture` is now gated on `captureActive()`
                // (strict `.in_input`) and so won't repaint
                // `line_state` from `.at_prompt`, callers that
                // expose `currentInput()` directly (or tests that
                // assert against it) must see an empty buffer in
                // `.at_prompt`. Without the clear, a sequence
                // `;B…ls…;C…;D…;A` leaves "ls" sitting in
                // `currentInput()` even though the user is now at
                // a fresh prompt — a stale read for anything that
                // queries the tracker between feeds.
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
        // Stamp the START of the OSC marker (the leading ESC), not
        // its terminator (BEL / ST). Lets callers cleanly slice the
        // marker bytes OUT of the captured stream without an
        // error-prone backwards walk across feed boundaries.
        self.edge_offsets[self.edge_count] = self.osc_start_index;
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

    /// Byte offset (within the most recent `feed()`) of the
    /// leading `ESC` (`\x1b`) of the marker that produced edge
    /// `idx`. Slicing `bytes[0..edgeOffset(i)]` yields pre-marker
    /// content; `bytes[edgeOffset(i)..]` starts at the marker
    /// itself. Used by the proxy to interleave OSC 7 promotion
    /// with OSC 133 push/pop in source order, and by the LLM
    /// module to extract command output between `;C` and `;D`
    /// without manually walking back through terminator bytes.
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

test "Osc133: partial emitter ;A after ;C emits prompt_start_implicit_end" {
    // Regression: Ghostty-style partial emitters send `;A` + `;C`
    // but no `;D`. Without an implicit-end edge here, the
    // subprocess tracker would never pop the frame pushed on `;C`
    // — stack leaks `.none` frames per command. The proxy's
    // edge handler treats `.prompt_start_implicit_end` as
    // "pop trailing `.none` frames only" so recognised launcher
    // frames (ssh, sudo, kubectl) survive — a remote shell
    // emitting its OWN `;A` after we connect MUST NOT pop the
    // local launcher's frame.
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
        const edges = o.drainEdges();
        try testing.expectEqual(@as(usize, 1), edges.len);
        try testing.expectEqual(Osc133.Edge.prompt_start_implicit_end, edges[0]);
    }
    try testing.expect(o.inInputPhase()); // .at_prompt again
}

test "Osc133: full emitter ;A after ;D does NOT synthesize an implicit-end edge" {
    // Full emitters emit `;D` then `;A`. The `;D` already pushed
    // .cmd_end; the `;A` MUST NOT emit a redundant
    // .prompt_start_implicit_end or the proxy's subprocess Tracker
    // would needlessly walk the stack again. (Harmless given the
    // .none-only pop semantic, but emitting work for nothing.)
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
    // Pin the contract: after `;A`, `inInputPhase()` is true
    // (.at_prompt) but `currentInput()` is empty. Any direct
    // caller / test reading the tracker between feeds in
    // `.at_prompt` must NOT see prior-command text. (The proxy's
    // `syncFromCapture` path is already safe because round 2's
    // `captureActive()` split gates it on strict `.in_input`, but
    // we'd still expose stale state through `currentInput()` for
    // other consumers if `;A` didn't clear.)
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

test "Osc133.canFastPath + skipBytes — proxy fast-path contract" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    try testing.expect(o.canFastPath());
    o.skipBytes(1024);
    try testing.expectEqual(@as(usize, 1024), o.total_bytes_fed);
    try testing.expect(o.canFastPath());

    // Mid-sequence: not fast-pathable.
    o.feed("\x1b]133");
    try testing.expect(!o.canFastPath());
    o.feed(";A\x07"); // ;A → phase=.at_prompt, state→ground
    try testing.expect(o.canFastPath());
}

test "Osc133.canFastPath returns false in .in_input phase (regression: input capture)" {
    // After `;B` opens the input region, plain ASCII bytes
    // mutate the captured-input buffer via processInputByte —
    // the proxy's syncFromCapture reads this. Fast-pathing here
    // would silently desync atty's view of the user-typed
    // line from the shell's echo, breaking ghost text + Enter-
    // commit override after a long pasted prompt.
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;A\x07"); // prompt start
    o.feed("\x1b]133;B\x07"); // input region open
    try testing.expect(o.inInputPhase());
    try testing.expect(o.state == .ground); // parser is between sequences
    try testing.expect(!o.canFastPath()); // but in_input phase blocks fast-path
    o.feed("hello"); // captured into self.input via .ground arm
    try testing.expectEqualStrings("hello", o.currentInput());
}
