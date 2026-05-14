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
/// Two answers today: `.user` (human at the prompt — the default)
/// or `.llm` (an LLM-driven module injected the line, set via
/// `LineState.setCommitAuthor(.llm)` BEFORE the injection).
/// Recording and policy modules read the snapshot at commit time
/// via `committedAuthor()` so they can tag entries or apply
/// different rules per author.
///
/// Author state lives here rather than on `Context` because an
/// async LLM round-trip can span many dispatch cycles between
/// flipping the author and the actual commit; per-dispatch
/// Context storage would lose the staging.
pub const Author = enum {
    /// Human typed at the local prompt. Default for every line.
    user,
    /// Line was injected by an LLM-driven module.
    llm,
};

pub const LineState = struct {
    buffer: [max_line]u8 = undefined,
    len: usize = 0,
    /// True after we observed an input byte/sequence we don't fully
    /// model. Stays true until the next `submit()`/`reset()`.
    uncertain: bool = false,
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
    /// LLM-driven modules flip this to `.llm` via
    /// `setCommitAuthor` BEFORE injecting a suggested command so
    /// the resulting commit lands with the right author tag.
    ///
    /// Reset to `.user` by:
    ///   • `submit()` (Enter snapshots pending → committed, then resets)
    ///   • `reset()` (Ctrl-C / Ctrl-D / Ctrl-G clear the line)
    ///   • `markUncertain()` (CSI / Tab / unmodelled control byte —
    ///     line model lost track; a staged author can no longer be
    ///     attributed to a specific buffer content)
    ///   • `backspace` / `killLine` / `killWord` when they leave
    ///     the buffer empty (the user wiped the staged line; the
    ///     next thing they type is theirs)
    pending_author: Author = .user,
    /// Snapshot of `pending_author` at commit time. Read via
    /// `committedAuthor()` from `onLineCommit`. Reset to `.user` by
    /// `clearLastCommitted()` (after consumers drain the commit)
    /// and by `setCommitted("")` (explicit "no commit" clear).
    committed_author: Author = .user,

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
    }

    pub fn reset(self: *LineState) void {
        self.len = 0;
        self.uncertain = false;
        self.generation +%= 1;
        // `pending_author` resets on reset (Ctrl-C / Ctrl-D / unknown
        // CSI) — the user is starting a fresh line, so a previously-
        // staged LLM author tag should be dropped. The LLM module
        // re-flips to `.llm` if it triggers another suggestion.
        self.pending_author = .user;
    }

    /// Upgrade the pending commit's author. Called by LLM-driven
    /// modules (`src/modules/llm.zig`) BEFORE injecting a suggested
    /// command so the resulting commit lands with `committed_author`
    /// equal to `author` when Enter eventually fires.
    pub fn setCommitAuthor(self: *LineState, author: Author) void {
        self.pending_author = author;
    }

    /// Author of the line currently in `committed[0..committed_len]`,
    /// or `.user` when nothing is committed. Modules read this from
    /// `onLineCommit` to attribute the recorded line.
    pub fn committedAuthor(self: *const LineState) Author {
        return self.committed_author;
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
        // Author is owned by `submit()` (the keystroke-derived commit
        // path) — `setCommitted` is the OSC 133 override that
        // refines the BUFFER content of the same commit. Touching
        // `committed_author` here would clobber an `.llm` tag that
        // submit() already snapshotted from `pending_author` before
        // resetting it (proxy calls applyInput("\r") BEFORE
        // setCommitted, so by the time we land here pending is
        // already reset). Exception: when callers explicitly clear
        // via `setCommitted("")`, the snapshot becomes "no commit"
        // and the author should reset too — otherwise
        // `committedAuthor()` would expose stale state.
        if (n == 0) self.committed_author = .user;
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
        // Skip the write when the buffer is already in sync — avoids
        // unnecessary generation bumps that would force ghost-text
        // providers to redo their work each tick.
        if (self.len == n and std.mem.eql(u8, self.buffer[0..self.len], content[0..n]) and !self.uncertain) return;
        @memcpy(self.buffer[0..n], content[0..n]);
        self.len = n;
        self.uncertain = false;
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
                // Treat any CSI as uncertainty — most likely a cursor
                // movement or history navigation we don't model. We
                // also drop `pending_author` here: a CSI we don't
                // model could be Arrow-Up (history recall) which
                // replaces the buffer with content we haven't seen,
                // and a staged `.llm` author on that line would be
                // wrong. Caller re-stages if it still wants the tag.
                self.markUncertain();
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
                // Any other control byte we don't model. The ranges are
                // carefully carved around the codes we *do* handle above.
                0x00, 0x01, 0x02, 0x05, 0x06, 0x0B, 0x0C, 0x0E...0x14, 0x16, 0x18, 0x19, 0x1A, 0x1C...0x1F => {
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
    }

    fn append(self: *LineState, b: u8) void {
        if (self.len >= max_line) {
            self.uncertain = true;
            return;
        }
        self.buffer[self.len] = b;
        self.len += 1;
        self.generation +%= 1;
    }

    fn backspace(self: *LineState) void {
        if (self.len == 0) return;
        self.len -= 1;
        // Reaching an empty buffer is the user telling us they've
        // cleaned house — drop the uncertain flag so ghost suggestions
        // come back, AND drop any staged `pending_author`. After
        // wiping an LLM-staged suggestion, the next thing the user
        // types is theirs, not the model's.
        if (self.len == 0) {
            self.uncertain = false;
            self.pending_author = .user;
        }
        self.generation +%= 1;
    }

    fn killLine(self: *LineState) void {
        if (self.len == 0) return;
        self.len = 0;
        self.uncertain = false;
        // Drop the staged author too — Ctrl-U after an LLM
        // suggestion means the user wiped it; whatever they type
        // next is theirs, not the model's.
        self.pending_author = .user;
        self.generation +%= 1;
    }

    fn killWord(self: *LineState) void {
        if (self.len == 0) return;
        // Skip trailing spaces, then the word characters.
        var end = self.len;
        while (end > 0 and self.buffer[end - 1] == ' ') : (end -= 1) {}
        while (end > 0 and self.buffer[end - 1] != ' ') : (end -= 1) {}
        if (end != self.len) {
            self.len = end;
            if (self.len == 0) {
                self.uncertain = false;
                self.pending_author = .user;
            }
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
        }
        self.len = 0;
        self.uncertain = false;
        self.pending_author = .user;
        self.generation +%= 1;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "printable input appends" {
    var l = LineState{};
    _ = l.applyInput("ls -la");
    try std.testing.expectEqualSlices(u8, "ls -la", l.current());
    try std.testing.expect(!l.uncertain);
}

test "backspace removes a char" {
    var l = LineState{};
    _ = l.applyInput("ls");
    _ = l.applyInput("\x7F");
    try std.testing.expectEqualSlices(u8, "l", l.current());
}

test "ctrl-u clears the line" {
    var l = LineState{};
    _ = l.applyInput("danger");
    _ = l.applyInput("\x15");
    try std.testing.expectEqualSlices(u8, "", l.current());
}

test "ctrl-w kills word" {
    var l = LineState{};
    _ = l.applyInput("rm -rf /");
    _ = l.applyInput("\x17");
    try std.testing.expectEqualSlices(u8, "rm -rf ", l.current());
}

test "enter resets" {
    var l = LineState{};
    _ = l.applyInput("ls\r");
    try std.testing.expectEqualSlices(u8, "", l.current());
}

test "CSI escape marks uncertain" {
    var l = LineState{};
    _ = l.applyInput("ls");
    _ = l.applyInput("\x1B[A"); // up arrow
    try std.testing.expect(l.uncertain);
}

test "Tab marks uncertain (shell completion changes the line behind atty's back)" {
    // Regression-document: Tab is in the "we don't model this" bucket
    // because the shell does completion and atty has no way to follow
    // what the shell wrote. The ghost overlay stays suppressed until
    // the line resets. If a future change unsuppresses this without
    // first growing an output-side tracker (OSC 133 or full VT
    // grid), the test will catch it.
    var l = LineState{};
    _ = l.applyInput("ec");
    try std.testing.expect(!l.uncertain);
    _ = l.applyInput("\t");
    try std.testing.expect(l.uncertain);
}

test "backspace to empty clears uncertain (recovery from arrow/Tab)" {
    // After the user gets stuck in uncertain mode (e.g. accidentally
    // pressed an arrow), they should be able to recover by holding
    // backspace until the buffer is empty — the rationale being that
    // an empty buffer can't be wrong about its content.
    var l = LineState{};
    _ = l.applyInput("ls");
    _ = l.applyInput("\x1B[A"); // arrow → uncertain
    try std.testing.expect(l.uncertain);
    _ = l.applyInput("\x7F\x7F"); // backspace twice → len reaches 0
    try std.testing.expect(l.len == 0);
    try std.testing.expect(!l.uncertain);
}

test "ctrl-u clears uncertain when killing the line" {
    // Same motivation as backspace-to-empty: a deliberate kill-line
    // also means "I'm starting fresh".
    var l = LineState{};
    _ = l.applyInput("ls");
    _ = l.applyInput("\t"); // tab → uncertain
    try std.testing.expect(l.uncertain);
    _ = l.applyInput("\x15"); // ctrl-u
    try std.testing.expect(l.len == 0);
    try std.testing.expect(!l.uncertain);
}

test "generation increments on real changes only" {
    var l = LineState{};
    const g0 = l.generation;
    _ = l.applyInput("a");
    try std.testing.expect(l.generation != g0);
    const g1 = l.generation;
    _ = l.applyInput("\x7F\x7F"); // overshoot backspace
    try std.testing.expect(l.generation != g1);
    const g2 = l.generation;
    _ = l.applyInput("\x7F"); // already empty
    try std.testing.expectEqual(g2, l.generation);
}

test "ctrl-w deletes the last word, preserving leading content" {
    var l = LineState{};
    _ = l.applyInput("git add foo");
    _ = l.applyInput("\x17"); // ctrl-w → delete "foo"
    try std.testing.expectEqualSlices(u8, "git add ", l.current());
}

test "ctrl-w with trailing spaces eats the spaces first" {
    var l = LineState{};
    _ = l.applyInput("git add foo   ");
    _ = l.applyInput("\x17");
    try std.testing.expectEqualSlices(u8, "git add ", l.current());
}

test "ctrl-w on an empty line is a no-op" {
    var l = LineState{};
    _ = l.applyInput("\x17");
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expect(!l.uncertain);
}

test "lastCommitted surfaces the pre-Enter line until cleared" {
    var l = LineState{};
    _ = l.applyInput("ls\r");
    const c = l.lastCommitted().?;
    try std.testing.expectEqualSlices(u8, "ls", c);
    try std.testing.expect(!l.committed_was_uncertain);
    l.clearLastCommitted();
    try std.testing.expectEqual(@as(?[]const u8, null), l.lastCommitted());
}

test "committed_was_uncertain flag tracks the pre-Enter state" {
    var l = LineState{};
    _ = l.applyInput("ls");
    _ = l.applyInput("\x1B[A"); // arrow → uncertain
    _ = l.applyInput("\r");
    try std.testing.expect(l.lastCommitted() != null);
    try std.testing.expect(l.committed_was_uncertain);
}

test "Enter on an empty line does not surface a commit" {
    var l = LineState{};
    _ = l.applyInput("\r");
    try std.testing.expectEqual(@as(?[]const u8, null), l.lastCommitted());
}

test "buffer overflow marks uncertain instead of writing past end" {
    var l = LineState{};
    var i: usize = 0;
    while (i < max_line + 16) : (i += 1) _ = l.applyInput("a");
    try std.testing.expectEqual(max_line, l.len);
    try std.testing.expect(l.uncertain);
}

test "Ctrl+C resets the buffer cleanly without marking uncertain" {
    // Ctrl+C is a legacy control byte the shell expects verbatim
    // (it gets translated to SIGINT or to bash's line-abort under
    // readline). atty's line_state must drop the partial input and
    // return to a clean state so the next keystroke gets a fresh
    // ghost suggestion — not "uncertain" mode (which would suppress
    // suggestions until the next Enter).
    var l = LineState{};
    _ = l.applyInput("rm -rf /home/user");
    try std.testing.expect(!l.uncertain);
    _ = l.applyInput("\x03"); // Ctrl+C
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expect(!l.uncertain);
    // No commit was produced — Ctrl+C is an abort, not a submission.
    try std.testing.expectEqual(@as(?[]const u8, null), l.lastCommitted());
}

test "Ctrl+D on an empty line is a no-op for the buffer (the shell handles EOF)" {
    // Ctrl+D is the shell's EOF signal when the line is empty —
    // line_state treats it the same as Ctrl+C (reset, no commit).
    // We rely on the proxy forwarding the byte; line_state just
    // doesn't get confused by it.
    var l = LineState{};
    _ = l.applyInput("\x04");
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expect(!l.uncertain);
}

test "setCommitted overrides the committed buffer + drops uncertain" {
    var l = LineState{};
    _ = l.applyInput("ls\r"); // applyInput-derived commit
    try std.testing.expectEqualSlices(u8, "ls", l.lastCommitted().?);
    l.setCommitted("rm -rf /tmp/recalled");
    try std.testing.expectEqualSlices(u8, "rm -rf /tmp/recalled", l.lastCommitted().?);
    try std.testing.expect(!l.committed_was_uncertain);
}

test "setCommitted with empty content yields no lastCommitted" {
    var l = LineState{};
    _ = l.applyInput("ls\r");
    l.setCommitted("");
    try std.testing.expectEqual(@as(?[]const u8, null), l.lastCommitted());
}

test "multiple CSI sequences in one read each mark uncertain" {
    var l = LineState{};
    _ = l.applyInput("\x1B[A\x1B[B");
    try std.testing.expect(l.uncertain);
}

test "syncFromCapture replaces buffer + clears uncertain (Arrow Up recall path)" {
    var l = LineState{};
    // User types "ls", then presses Up — applyInput marks uncertain.
    _ = l.applyInput("ls\x1B[A");
    try std.testing.expect(l.uncertain);

    // Shell redraws prompt with the recalled command. proxy.zig
    // calls syncFromCapture with the OSC 133 tracker's view of
    // the current input region.
    l.syncFromCapture("git status");
    try std.testing.expectEqualSlices(u8, "git status", l.current());
    try std.testing.expect(!l.uncertain);
}

test "syncFromCapture is a no-op when buffer is already in sync" {
    var l = LineState{};
    _ = l.applyInput("ls");
    const gen_before = l.generation;
    l.syncFromCapture("ls");
    // No generation bump → providers can skip recomputation.
    try std.testing.expectEqual(gen_before, l.generation);
}

test "syncFromCapture still bumps generation when uncertain was true" {
    var l = LineState{};
    _ = l.applyInput("ls\x1B[A");
    // Buffer is "ls" + uncertain=true. Sync with the same bytes —
    // content matches but uncertainty doesn't, so we must repaint
    // and recompute.
    const gen_before = l.generation;
    l.syncFromCapture("ls");
    try std.testing.expect(l.generation != gen_before);
    try std.testing.expect(!l.uncertain);
}

test "syncFromCapture with empty content clears the buffer" {
    var l = LineState{};
    _ = l.applyInput("ls -la");
    l.syncFromCapture("");
    try std.testing.expectEqualSlices(u8, "", l.current());
    try std.testing.expect(!l.uncertain);
}

test "syncFromCapture truncates oversized content to max_line" {
    var l = LineState{};
    // Build a slice longer than max_line.
    var oversized: [max_line + 64]u8 = undefined;
    @memset(&oversized, 'x');
    l.syncFromCapture(&oversized);
    try std.testing.expectEqual(@as(usize, max_line), l.len);
}

test "Author defaults to .user, persists across uneventful applyInput" {
    var l = LineState{};
    try std.testing.expectEqual(Author.user, l.pending_author);
    try std.testing.expectEqual(Author.user, l.committedAuthor());

    _ = l.applyInput("ls");
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "setCommitAuthor stages the next commit's author; submit() snapshots it" {
    var l = LineState{};
    l.setCommitAuthor(.llm);
    try std.testing.expectEqual(Author.llm, l.pending_author);

    _ = l.applyInput("ls\r");
    // After commit: committed_author carries the staged author;
    // pending_author resets so the NEXT line starts fresh.
    try std.testing.expectEqual(Author.llm, l.committedAuthor());
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "clearLastCommitted resets committed_author to .user" {
    var l = LineState{};
    l.setCommitAuthor(.llm);
    _ = l.applyInput("ls\r");
    try std.testing.expectEqual(Author.llm, l.committedAuthor());

    l.clearLastCommitted();
    try std.testing.expectEqual(Author.user, l.committedAuthor());
}

test "reset() drops pending author (Ctrl-C / Ctrl-D / Ctrl-G)" {
    var l = LineState{};
    l.setCommitAuthor(.llm);

    // Ctrl-C — caller-facing reset.
    _ = l.applyInput("partial\x03");
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "CSI sequences drop pending author (Arrow-Up history recall is unknown content)" {
    var l = LineState{};
    l.setCommitAuthor(.llm);

    // Up arrow — shell will redraw with a recalled command we
    // haven't observed. Can't keep the `.llm` tag on a buffer
    // the user might commit as their own.
    _ = l.applyInput("\x1b[A");
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "Tab / lone ESC / unmodelled control bytes drop pending author" {
    inline for (.{ "\x09", "\x1b", "\x16" }) |seq| {
        var l = LineState{};
        l.setCommitAuthor(.llm);
        _ = l.applyInput(seq);
        try std.testing.expectEqual(Author.user, l.pending_author);
    }
}

test "Ctrl-U (kill line) drops pending author so a fresh user command isn't mis-tagged" {
    var l = LineState{};
    l.setCommitAuthor(.llm);
    _ = l.applyInput("llm-staged content\x15");
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "backspace to empty drops pending author" {
    var l = LineState{};
    l.setCommitAuthor(.llm);
    // Type two chars under .llm, then backspace both → empty.
    _ = l.applyInput("ab\x7f\x7f");
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "setCommitted preserves the author submit() snapshotted (OSC 133 override path)" {
    // Simulates the proxy flow: applyInput("\r") fires submit (which
    // snapshots pending → committed and resets pending), then proxy
    // calls setCommitted with the OSC 133 capture. The override must
    // keep the `.llm` author submit() already recorded.
    var l = LineState{};
    l.setCommitAuthor(.llm);
    _ = l.applyInput("ls\r");
    try std.testing.expectEqual(Author.llm, l.committedAuthor());

    l.setCommitted("ls -la"); // OSC 133 capture refines the buffer
    try std.testing.expectEqual(Author.llm, l.committedAuthor());
    try std.testing.expectEqualSlices(u8, "ls -la", l.lastCommitted().?);
}

test "setCommitted(\"\") resets committed_author (no-commit signal)" {
    var l = LineState{};
    l.setCommitAuthor(.llm);
    _ = l.applyInput("ls\r");
    try std.testing.expectEqual(Author.llm, l.committedAuthor());

    l.setCommitted(""); // explicit clear via the OSC 133 path
    try std.testing.expectEqual(Author.user, l.committedAuthor());
}

test "setCommitted called WITHOUT a prior submit leaves pending_author untouched" {
    // The OSC 133 override path is the only legitimate caller, and
    // it always runs AFTER applyInput("\r") → submit() has already
    // snapshotted the author. A bare `setCommitted` (no prior
    // submit) is a degenerate case — we leave `pending_author` as
    // staged and the caller can call `submit()` itself or accept
    // the default `.user` for `committed_author`.
    var l = LineState{};
    l.setCommitAuthor(.llm);
    l.setCommitted("echo hi");
    // committed_author stays .user (no submit() ran to snapshot
    // pending → committed).
    try std.testing.expectEqual(Author.user, l.committedAuthor());
    // pending stays staged — caller still owns it.
    try std.testing.expectEqual(Author.llm, l.pending_author);
}
