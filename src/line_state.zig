//! Best-effort tracking of what the user has typed since the last
//! Enter/Ctrl-C/Ctrl-D, used to drive ghost-text and the guardrail.
//!
//! We are NOT trying to perfectly mirror the shell's internal line
//! editor — that's an unbounded problem (vi mode, history navigation
//! with arrow keys, multi-line continuations, custom keymaps…).
//! Instead, we approximate well enough for the common case of typing
//! a fresh command, and we *reset* on any sequence we don't fully
//! understand so we never present stale suggestions.
//!
//! What we model:
//!   - printable ASCII appends to the buffer at the cursor
//!   - backspace (0x7F, 0x08) and Ctrl-H delete one char
//!   - Ctrl-U (0x15) clears to start of line
//!   - Ctrl-W (0x17) deletes the previous word
//!   - Enter (CR/LF) → submit + clear
//!   - Ctrl-C (0x03) / Ctrl-D (0x04) → clear
//!   - any other control byte or escape sequence → mark "uncertain",
//!     which suppresses ghost text until the next newline
//!
//! Suppression-on-uncertainty is the key safety property: a stale
//! suggestion is worse than no suggestion. Arrow keys for history
//! navigation will trip this, which is exactly what we want.

const std = @import("std");

pub const max_line = 4096;

/// Who typed the line that's about to be committed?
///
/// Author state lives on `LineState` rather than a per-dispatch
/// type because staging happens potentially many dispatch cycles
/// before the commit — anything that holds it only for one tick
/// would lose the tag.
pub const Author = enum {
    /// Default. Human typed at the local prompt.
    user,
    /// Line was injected programmatically.
    llm,
};

pub const LineState = struct {
    buffer: [max_line]u8 = undefined,
    len: usize = 0,
    /// True after we observed an input byte/sequence we don't fully
    /// model. Stays true until the next `submit()`/`reset()`.
    uncertain: bool = false,
    /// True after the user pressed a cursor-motion key that left
    /// the cursor MID-LINE — Left arrow most importantly. We don't
    /// track exact column, only "the cursor isn't at the end of the
    /// displayed buffer anymore." Cleared on `submit()` (Enter) and
    /// `reset()` (Ctrl+C / new prompt) — i.e. when there's a fresh
    /// prompt where the cursor is back at the end of an empty line.
    ///
    /// Cached derivation of `cursor_pos != len` — "the cursor is
    /// mid-buffer, ghost would over-paint right-side text".
    /// `cursor_pos` is the source of truth; `syncCursorMoved()`
    /// updates this field after any operation that changes either.
    ///
    /// **Why we expose this as a flag:** `renderGhost` (proxy.zig)
    /// reads it as an extra gate beyond `uncertain`; keeping the
    /// derived form lets existing read-sites stay unchanged when
    /// the underlying tracking moved from "sticky on/off" to
    /// "explicit offset". Other line-state consumers (atuin ghost
    /// text producer, history, …) see `len`/`buffer` directly.
    cursor_moved: bool = false,
    /// Cursor offset from the start of the input buffer (0..=len).
    /// Bumped on append, decremented on backspace, and shifted by
    /// Ctrl-A/E/B/F + Left/Right/Home/End. `cursor_moved` is then
    /// just the cached form of `(cursor_pos != len)` — having both
    /// keeps existing call-sites that read `cursor_moved` unchanged.
    ///
    /// When this is < len (cursor is mid-line), ghost rendering
    /// would over-paint the right-side text. When it equals len,
    /// the cursor is at EOL and ghost can engage. Tracking explicit
    /// offset (instead of a sticky "moved" flag) lets us recognise
    /// that Right-stepping to EOL re-engages ghost — the original
    /// flag-only model couldn't tell when Right landed AT EOL.
    cursor_pos: usize = 0,
    /// Incremented every time the buffer changes. Providers can compare
    /// against a remembered generation to skip duplicate work.
    generation: u64 = 0,

    /// Snapshot of the line that was just committed (Enter pressed), held
    /// here for one dispatch pass so the proxy can fire onLineCommit
    /// hooks with the pre-submit content. `committed_len == 0` means no
    /// commit pending. Callers must call `clearLastCommitted` after they
    /// consume it.
    committed: [max_line]u8 = undefined,
    committed_len: usize = 0,
    committed_was_uncertain: bool = false,

    /// Author of the line currently being typed (pending).
    /// Reset to `.user` whenever the buffer's content is no longer
    /// attributable to a previously-staged author: on `submit()`
    /// (after the snapshot to committed_author), on `reset()`, on
    /// `markUncertain()`, and on `backspace` / `killLine` /
    /// `killWord` that empty the buffer.
    pending_author: Author = .user,
    /// Snapshot of `pending_author` at commit time. Lives until the
    /// next `clearLastCommitted()` or until `setCommitted("")`
    /// explicitly clears the commit slot.
    committed_author: Author = .user,
    /// Intent text staged for the next `submit()` — typically the
    /// LLM's one-line description of WHY this command was
    /// suggested. atuin can persist it via `--intent` so the
    /// history entry records "user asked for X" alongside the
    /// command. Optional — slot is empty (len=0) for user-typed
    /// commands. Same lifecycle as `pending_author`: cleared on
    /// `submit()` (after snapshot), `reset()`, `markUncertain()`,
    /// and buffer-emptying edits.
    pending_intent_buf: [256]u8 = undefined,
    pending_intent_len: usize = 0,
    /// Snapshot of `pending_intent_buf` at commit time. Cleared on
    /// `clearLastCommitted()` and `setCommitted("")`. Read by
    /// `committedIntent()`.
    committed_intent_buf: [256]u8 = undefined,
    committed_intent_len: usize = 0,

    pub fn current(self: *const LineState) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Returns the line that was just committed (Enter pressed) since
    /// the last clear, or null if no commit happened. The returned
    /// slice is valid until the next `submit()` or `clearLastCommitted`.
    pub fn lastCommitted(self: *const LineState) ?[]const u8 {
        if (self.committed_len == 0) return null;
        return self.committed[0..self.committed_len];
    }

    pub fn clearLastCommitted(self: *LineState) void {
        self.committed_len = 0;
        self.committed_was_uncertain = false;
        self.committed_author = .user;
        self.committed_intent_len = 0;
    }

    /// Sync the cached `cursor_moved` flag from `cursor_pos` / `len`.
    /// Call after any operation that changes either. Keeping the flag
    /// as a cached derivation lets existing read-sites stay unchanged
    /// while the new tracking gives accurate "is the cursor at EOL?"
    /// answers — Right-arrow stepping back to EOL now re-engages the
    /// ghost overlay (the old sticky-flag model couldn't tell).
    fn syncCursorMoved(self: *LineState) void {
        self.cursor_moved = self.cursor_pos != self.len;
    }

    pub fn reset(self: *LineState) void {
        self.len = 0;
        self.cursor_pos = 0;
        self.uncertain = false;
        self.cursor_moved = false;
        self.generation +%= 1;
        // reset() handles the explicit abort signals (Ctrl-C, Ctrl-D,
        // Ctrl-G) — drop the staged author too because the user is
        // starting a fresh line and any previously-staged LLM tag
        // should NOT apply. (CSI / Tab / other unmodelled bytes
        // don't pass through here — applyInput routes them through
        // markUncertain() which drops pending_author on its own.)
        self.pending_author = .user;
        self.pending_intent_len = 0;
    }

    /// Stage the author for the next `submit()` to snapshot into
    /// `committed_author`. Must be called BEFORE the Enter that
    /// produces the commit. `setCommitted()` deliberately does NOT
    /// honour `pending_author` in the non-empty case — it preserves
    /// whatever `committed_author` was last set to (typically by
    /// the preceding `submit()`).
    pub fn setCommitAuthor(self: *LineState, author: Author) void {
        self.pending_author = author;
    }

    /// Author of the line currently in `committed[0..committed_len]`,
    /// or `.user` when nothing is committed.
    pub fn committedAuthor(self: *const LineState) Author {
        return self.committed_author;
    }

    /// Stage intent text for the next `submit()` to snapshot into
    /// `committed_intent`. Truncated to fit `pending_intent_buf`
    /// (256 bytes). Pass empty to clear. Typically called by the
    /// LLM module right after setting `pending_author = .llm`, so
    /// the suggested-command's description rides through Enter
    /// alongside the author tag.
    pub fn setCommitIntent(self: *LineState, intent: []const u8) void {
        const n = @min(intent.len, self.pending_intent_buf.len);
        @memcpy(self.pending_intent_buf[0..n], intent[0..n]);
        self.pending_intent_len = n;
    }

    /// Intent of the line currently in
    /// `committed[0..committed_len]`, or null when nothing is
    /// committed or the line was user-typed (no LLM context).
    pub fn committedIntent(self: *const LineState) ?[]const u8 {
        if (self.committed_intent_len == 0) return null;
        return self.committed_intent_buf[0..self.committed_intent_len];
    }

    /// Force-write the committed buffer from an externally-observed
    /// source (OSC 133 marker stream, when the shell emits them).
    /// The proxy calls this on Enter to override applyInput's own
    /// keystroke-derived commit — closes the history-recall gap.
    /// Sets `committed_was_uncertain = false` because the marker
    /// stream is the truth.
    pub fn setCommitted(self: *LineState, content: []const u8) void {
        const n = @min(content.len, max_line);
        @memcpy(self.committed[0..n], content[0..n]);
        self.committed_len = n;
        self.committed_was_uncertain = false;
        // Non-empty content overrides the BUFFER only; `committed_author`
        // is unchanged (it's owned exclusively by `submit()`). An empty
        // payload is the explicit "no commit" signal — drop the author
        // too so `committedAuthor()` doesn't return stale state.
        if (n == 0) {
            self.committed_author = .user;
            self.committed_intent_len = 0;
        }
    }

    /// Replace the live input buffer from an externally-observed
    /// source — used by the proxy when the OSC 133 tracker is in
    /// its `in_input` phase. Bytes the shell has actually drawn on
    /// the prompt are the ground truth for what the user is editing
    /// right now, including content that didn't come from keystrokes:
    /// Arrow-Up history recall, completion expansion, paste, and
    /// any other shell-side redraw.
    ///
    /// Different from `applyInput` (which models keystrokes one at
    /// a time) and `setCommitted` (which only writes the commit
    /// snapshot, never the live buffer). Sets `uncertain = false`
    /// because the marker stream IS the truth; bumps `generation`
    /// so ghost-text providers know to recompute.
    pub fn syncFromCapture(self: *LineState, content: []const u8) void {
        const n = @min(content.len, max_line);
        // Buffer already matches the capture region. Two sub-cases:
        //   1. !uncertain — already in sync, nothing to do.
        //   2.  uncertain — keystroke tracker hit something unmodelled
        //       (Tab, lone ESC, …) but the capture region tells us
        //       no bytes actually changed. Clear `uncertain` so
        //       ghost can re-engage, but PRESERVE `cursor_pos`.
        //       The OSC 133 stream carries no cursor info; clamping
        //       to EOL would make mid-line cases (Arrow-Left × N →
        //       Tab with no completion match) paint ghost over the
        //       text-to-right because the physical cursor is still
        //       wherever the user left it.
        //
        //       `pending_author` / `pending_intent_len` are already
        //       cleared by `markUncertain()` (the only path that
        //       lands here with uncertain=true), so the early-return
        //       doesn't need to touch them.
        if (self.len == n and std.mem.eql(u8, self.buffer[0..self.len], content[0..n])) {
            self.uncertain = false;
            return;
        }
        @memcpy(self.buffer[0..n], content[0..n]);
        self.len = n;
        self.uncertain = false;
        // Bash's redraw lands the cursor at the EOL of the input
        // region by the time `;B` fires + the input is echoed.
        // Clamp cursor_pos to len so callers see "cursor at EOL"
        // after a successful sync. (If something downstream knows
        // better — e.g. a DSR-6n reply — it can overwrite.)
        self.cursor_pos = n;
        self.syncCursorMoved();
        self.generation +%= 1;
    }

    /// Apply a byte slice as input. Returns true if the line buffer
    /// actually changed (callers may use this to gate ghost-text
    /// recomputation).
    pub fn applyInput(self: *LineState, input: []const u8) bool {
        const start_gen = self.generation;
        var i: usize = 0;
        while (i < input.len) {
            const b = input[i];
            // Multi-byte escape sequence: ESC [ ...final-byte
            if (b == 0x1B and i + 1 < input.len and input[i + 1] == '[') {
                // Skip until we find a byte in 0x40..0x7E (CSI final).
                var j: usize = i + 2;
                while (j < input.len) : (j += 1) {
                    const c = input[j];
                    if (c >= 0x40 and c <= 0x7E) break;
                }
                // Classify the CSI before deciding whether to set
                // `uncertain`. Cursor-motion CSIs (Left/Right/Home/End
                // and their VT-style siblings) only move the cursor —
                // they DON'T change buffer content. Marking them
                // uncertain forces the proxy's syncFromCapture
                // recovery path to fire, which can clobber the
                // keystroke buffer when the OSC 133 input region is
                // stale (mid-typing PS1 redraw, bash's history recall
                // not echoed into the capture region, ...). Set
                // `cursor_moved` for ghost suppression instead and
                // leave `uncertain` alone. All other CSIs (Arrow
                // Up/Down history recall, Delete, F-keys, ...) may
                // change buffer content — markUncertain so the proxy
                // can resync.
                //
                // Final-byte taxonomy:
                //   D = Left, C = Right (xterm cursor-style)
                //   H = Home, F = End (xterm cursor-style)
                //   ~ = VT-style — the parameter distinguishes
                //       1/7=Home, 4/8=End, 5/6=PageUp/Down (all
                //       cursor-motion), 2=Insert, 3=Delete (both
                //       edit buffer).
                //   A/B = Arrow Up/Down (history recall — buffer
                //       changes)
                //   Other = unknown, conservative markUncertain.
                var content_changing = true;
                if (j < input.len) {
                    switch (input[j]) {
                        'D', 'C', 'H', 'F' => content_changing = false,
                        '~' => {
                            const param = input[i + 2 .. j];
                            if (std.mem.eql(u8, param, "4") or std.mem.eql(u8, param, "8") or // End
                                std.mem.eql(u8, param, "1") or std.mem.eql(u8, param, "7") or // Home
                                std.mem.eql(u8, param, "5") or std.mem.eql(u8, param, "6")) // PgUp/PgDn
                            {
                                content_changing = false;
                            }
                            // 2~ / 3~ (Insert / Delete) and the F-keys
                            // (>= 15) edit the buffer — content_changing
                            // stays true.
                        },
                        else => {},
                    }
                }
                if (content_changing) {
                    // CSI we don't model — drop `pending_author` too:
                    // a CSI like Arrow-Up could replace the buffer
                    // with content we haven't seen, and a staged
                    // `.llm` author on that line would be wrong.
                    self.markUncertain();
                }
                // Update cursor_pos for the modeled cursor-motion CSIs.
                // Right (`C`) explicitly increments instead of jumping
                // to EOL — N consecutive Rights land at min(cursor + N,
                // len), so a sequence of Rights after Ctrl-A reaches
                // EOL exactly when N == len. That's what re-engages
                // ghost after the user steps back to EOL without
                // pressing End. Skip the update on empty buffer:
                // cursor is already at col 1 == EOL == BOL.
                if (j < input.len and self.len > 0) {
                    switch (input[j]) {
                        'D' => if (self.cursor_pos > 0) {
                            self.cursor_pos -= 1; // Left
                        },
                        'C' => if (self.cursor_pos < self.len) {
                            self.cursor_pos += 1; // Right
                        },
                        'H' => self.cursor_pos = 0, // Home
                        'F' => self.cursor_pos = self.len, // End
                        '~' => {
                            const param = input[i + 2 .. j];
                            if (std.mem.eql(u8, param, "4") or std.mem.eql(u8, param, "8")) {
                                self.cursor_pos = self.len; // End
                            } else if (std.mem.eql(u8, param, "1") or std.mem.eql(u8, param, "7")) {
                                self.cursor_pos = 0; // Home
                            }
                            // 5~/6~ (PgUp/PgDn): no col change.
                        },
                        else => {},
                    }
                    self.syncCursorMoved();
                }
                i = j + 1;
                continue;
            }

            switch (b) {
                // Enter — submit the current line, then reset.
                0x0D, 0x0A => self.submit(),
                // Backspace (^?) and ^H
                0x7F, 0x08 => self.backspace(),
                // Ctrl-C / Ctrl-D / Ctrl-G — abort/EOF/bell, line cleared
                0x03, 0x04, 0x07 => self.reset(),
                // Ctrl-U — kill line
                0x15 => self.killLine(),
                // Ctrl-W — kill previous word
                0x17 => self.killWord(),
                // Tab — completion is shell-driven; we lose track.
                0x09 => self.markUncertain(),
                // Readline cursor-motion bindings. We model them like
                // the CSI cursor-motion siblings: update `cursor_pos`,
                // sync the cached `cursor_moved` flag. Ctrl-F (forward)
                // increments; N Ctrl-F presses from BOL land at EOL
                // exactly, re-engaging ghost.
                0x01 => {
                    self.cursor_pos = 0; // Ctrl-A: cursor to BOL
                    self.syncCursorMoved();
                },
                0x05 => {
                    self.cursor_pos = self.len; // Ctrl-E: cursor to EOL
                    self.syncCursorMoved();
                },
                0x02 => {
                    if (self.cursor_pos > 0) self.cursor_pos -= 1; // Ctrl-B
                    self.syncCursorMoved();
                },
                0x06 => {
                    if (self.cursor_pos < self.len) self.cursor_pos += 1; // Ctrl-F
                    self.syncCursorMoved();
                },
                // Any other control byte we don't model. The ranges are
                // carefully carved around the codes we *do* handle above.
                0x00, 0x0B, 0x0C, 0x0E...0x14, 0x16, 0x18, 0x19, 0x1A, 0x1C...0x1F => {
                    self.markUncertain();
                },
                // Lone ESC (no '[' follower).
                0x1B => self.markUncertain(),
                // Printable.
                else => self.append(b),
            }
            i += 1;
        }
        return self.generation != start_gen or self.uncertain;
    }

    /// Set `uncertain = true` AND drop any staged `pending_author`.
    /// We pair the two because every "unmodelled keystroke" path
    /// (CSI, Tab, lone ESC, exotic control bytes) potentially
    /// replaces the buffer with content we haven't seen — keeping
    /// an `.llm` tag staged would mis-attribute the next commit.
    fn markUncertain(self: *LineState) void {
        self.uncertain = true;
        self.pending_author = .user;
        self.pending_intent_len = 0;
    }

    fn append(self: *LineState, b: u8) void {
        if (self.len >= max_line) {
            self.uncertain = true;
            return;
        }
        // Mid-line insertion isn't modeled: bash splices the byte
        // at cursor_pos and shifts the tail right; we'd need a
        // memmove and bookkeeping we don't have. Mark uncertain
        // so a subsequent OSC 133 capture restores the post-insert
        // truth. Without this, len would lag the screen while
        // cursor_pos slid back to len via Right-stepping, and
        // ghost would re-engage on a stale buffer.
        if (self.cursor_pos != self.len) {
            self.markUncertain();
            return;
        }
        self.buffer[self.len] = b;
        self.len += 1;
        self.cursor_pos = self.len;
        self.syncCursorMoved();
        self.generation +%= 1;
    }

    fn backspace(self: *LineState) void {
        // Empty-buffer no-op: still drop any staged `pending_author`.
        // The invariant is "line-editing intent on an empty buffer
        // means the user is starting fresh" — without this the
        // sequence `setCommitAuthor(.llm)` + Ctrl-H (with empty
        // buffer) + new typing would leak the .llm tag onto a
        // user-typed line. Editing a non-empty buffer keeps the
        // staged author until / unless the edit reduces `len` to
        // zero (handled by the second drop below).
        if (self.len == 0) {
            self.pending_author = .user;
            self.pending_intent_len = 0;
            return;
        }
        // Mid-line backspace isn't modeled: bash removes at
        // `cursor_pos - 1` and shifts the tail left. We'd be
        // dropping the LAST byte of the buffer (wrong) — over time
        // the buffer + screen would diverge silently. Mark
        // uncertain and let OSC 133 resync. Same rationale as the
        // append() mid-line guard above.
        if (self.cursor_pos != self.len) {
            self.markUncertain();
            return;
        }
        self.len -= 1;
        self.cursor_pos = self.len;
        if (self.len == 0) {
            self.uncertain = false;
            // Buffer just emptied — drop the staged author too.
            self.pending_author = .user;
            self.pending_intent_len = 0;
        }
        self.syncCursorMoved();
        self.generation +%= 1;
    }

    fn killLine(self: *LineState) void {
        // Empty-buffer Ctrl-U is a no-op for `len`/`uncertain`, but
        // we still drop a staged `pending_author` for the same
        // reason as `backspace` — line-editing on an empty buffer
        // signals the user is starting fresh.
        if (self.len == 0) {
            self.pending_author = .user;
            self.pending_intent_len = 0;
            return;
        }
        self.len = 0;
        self.cursor_pos = 0;
        self.uncertain = false;
        // Same rationale as `backspace`-to-empty above — the line is
        // gone, so the cursor's "mid-line"ness is meaningless.
        self.cursor_moved = false;
        self.pending_author = .user;
        self.pending_intent_len = 0;
        self.generation +%= 1;
    }

    fn killWord(self: *LineState) void {
        // Empty-buffer Ctrl-W: drop staged author (no-op intent
        // signals "user starting fresh", see `backspace`). The
        // non-empty path preserves the staged author when the kill
        // leaves the buffer non-empty (still represents the
        // LLM-staged line, just edited) and drops it only when the
        // kill empties the buffer.
        if (self.len == 0) {
            self.pending_author = .user;
            self.pending_intent_len = 0;
            return;
        }
        // Mid-line Ctrl-W (readline kills the word BEFORE the
        // cursor, leaving the tail intact). The keystroke model
        // here scans from the end of the buffer — wrong when the
        // cursor is mid-line. Mark uncertain and let OSC 133 sync.
        // Same rationale as the append/backspace mid-line guards.
        if (self.cursor_pos != self.len) {
            self.markUncertain();
            return;
        }
        // Skip trailing spaces, then the word characters.
        var end = self.len;
        while (end > 0 and self.buffer[end - 1] == ' ') : (end -= 1) {}
        while (end > 0 and self.buffer[end - 1] != ' ') : (end -= 1) {}
        if (end != self.len) {
            self.len = end;
            self.cursor_pos = self.len;
            if (self.len == 0) {
                self.uncertain = false;
                self.pending_author = .user;
                self.pending_intent_len = 0;
            }
            self.syncCursorMoved();
            self.generation +%= 1;
        }
    }

    fn submit(self: *LineState) void {
        // Snapshot the pre-Enter line so onLineCommit hooks can fire
        // after applyInput. Overwrites any prior un-consumed snapshot —
        // if two Enters land in one read, only the latest non-empty
        // line is recorded, which matches what a human would expect.
        //
        // `pending_author` is also snapshotted here and reset, so a
        // subsequent line starts fresh under `.user` even if the
        // previous commit was tagged `.llm`. A module that wants the
        // NEXT line tagged differently must re-call `setCommitAuthor`
        // after this snapshot fires.
        if (self.len > 0) {
            @memcpy(self.committed[0..self.len], self.buffer[0..self.len]);
            self.committed_len = self.len;
            self.committed_was_uncertain = self.uncertain;
            self.committed_author = self.pending_author;
            // Snapshot the staged intent alongside the author. Same
            // lifecycle — module that wants the NEXT line tagged
            // with a different intent must re-call `setCommitIntent`
            // after this snapshot fires.
            @memcpy(self.committed_intent_buf[0..self.pending_intent_len], self.pending_intent_buf[0..self.pending_intent_len]);
            self.committed_intent_len = self.pending_intent_len;
        }
        self.len = 0;
        self.cursor_pos = 0;
        self.uncertain = false;
        self.cursor_moved = false;
        self.pending_author = .user;
        self.pending_intent_len = 0;
        self.generation +%= 1;
    }
};

// ===========================================================================
// Tests — extracted to `line_state_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("line_state_tests.zig");
}
