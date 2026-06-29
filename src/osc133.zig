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

    /// Synthesize the command-start the shell omitted. An integration that
    /// emits `;A`/`;B` but no `;C` — a starship-style PROMPT_COMMAND wrapper,
    /// or an init that lost its DEBUG-trap `;C` (atty's shipped `init bash` is
    /// a full emitter and does NOT hit this; a partial emitter that also omits
    /// `;B`, like Ghostty's default, never reaches `.in_input` so this is a
    /// no-op there) — leaves the tracker in `.in_input` through command
    /// execution, CAPTURING the command's OUTPUT. Normally the next prompt's
    /// `;A`/`;B` clears that before anyone reads it, but a master read
    /// fragmented mid-stream can leave the output sitting in `input`, where the
    /// next line's commit / `syncFromCapture` absorbs it (#525). The proxy
    /// calls this on stdin submit — when it KNOWS a command started — to end
    /// capture deterministically. Clears `input` too: the submitted line has
    /// already been read for the commit, and leaving it would let
    /// `syncFromCapture` re-absorb a stale line.
    ///
    /// Intentionally diverges from `;C` handling (`dispatchOsc` 'C'): that
    /// pushes a `cmd_start` edge and does NOT clear `input`; this clears
    /// `input` and pushes NO edge — pushing one here would pop a
    /// `pending_launch` and create a phantom subprocess frame. Don't "dedupe"
    /// the two. No-op outside `.in_input`; a real `;C` that follows (full
    /// emitters) is harmless (phase is already `.in_command`, no edge dup).
    pub fn endInputCapture(self: *Osc133) void {
        if (self.phase == .in_input) {
            self.phase = .in_command;
            self.input.clearRetainingCapacity();
        }
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
    pub fn onFastPath(self: *Osc133, n: usize) void {
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
// Tests — extracted to `osc133_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("osc133_tests.zig");
}
