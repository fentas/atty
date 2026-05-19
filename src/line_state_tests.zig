//! Tests for `line_state.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("line_state.zig");

// Re-binds of pub decls so test bodies stay short.
const Author = mod.Author;
const LineState = mod.LineState;
const max_line = mod.max_line;

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

test "Left/Right/Home set cursor_moved; End clears it (lands provably at EOL)" {
    // Left/Right/Home leave the cursor potentially mid-buffer, so
    // ghost rendering at the new position would overwrite the
    // character to its right (looks like deletion). End lands the
    // cursor at EOL by definition — clearing the flag lets the user
    // re-engage ghost after navigating back to EOL via End.
    var l = LineState{};
    _ = l.applyInput("hello");
    try std.testing.expect(!l.cursor_moved);

    _ = l.applyInput("\x1B[D"); // Left
    try std.testing.expect(l.cursor_moved);

    l.cursor_moved = false; // simulate a fresh prompt for the next case
    _ = l.applyInput("\x1B[C"); // Right — only ±1, no EOL guarantee
    try std.testing.expect(l.cursor_moved);

    l.cursor_moved = false;
    _ = l.applyInput("\x1B[H"); // Home
    try std.testing.expect(l.cursor_moved);

    // End (xterm cursor-style) — provably at EOL, clears the flag.
    _ = l.applyInput("\x1B[F");
    try std.testing.expect(!l.cursor_moved);

    // Sticky flag + End should clear too.
    l.cursor_moved = true;
    _ = l.applyInput("\x1B[F");
    try std.testing.expect(!l.cursor_moved);
}

test "End VT-form (`\\x1b[4~` / `\\x1b[8~`) clears cursor_moved" {
    // VT-form End is what xterm + libvte-based terminals send by
    // default. Both `4~` (xterm End) and `8~` (vt220 End) must clear
    // the flag — same EOL guarantee as the cursor-style `F`.
    var l = LineState{};
    _ = l.applyInput("hello");
    _ = l.applyInput("\x1B[D"); // Left → cursor_moved=true
    try std.testing.expect(l.cursor_moved);
    _ = l.applyInput("\x1B[4~"); // End
    try std.testing.expect(!l.cursor_moved);

    l.cursor_moved = true;
    _ = l.applyInput("\x1B[8~"); // vt220 End
    try std.testing.expect(!l.cursor_moved);

    // Home VT-form still SETS the flag.
    _ = l.applyInput("\x1B[1~");
    try std.testing.expect(l.cursor_moved);
}

test "Ctrl-A / Ctrl-B / Ctrl-F set cursor_moved; Ctrl-E clears it" {
    // Readline cursor-motion bindings encoded as single control bytes
    // (legacy, no kitty kbd). The bash redraw after Ctrl-A leaves the
    // line CONTENT unchanged — `syncFromCapture` would then clear
    // `uncertain`, and without `cursor_moved` set the ghost would
    // re-engage and over-paint the rest of the line. Regression for
    // "Arrow Up + Ctrl-A + type → ghost hides recalled tail".
    var l = LineState{};
    _ = l.applyInput("hello");
    try std.testing.expect(!l.cursor_moved);

    _ = l.applyInput("\x01"); // Ctrl-A — BOL
    try std.testing.expect(l.cursor_moved);

    l.cursor_moved = false;
    _ = l.applyInput("\x02"); // Ctrl-B — back 1
    try std.testing.expect(l.cursor_moved);

    l.cursor_moved = false;
    _ = l.applyInput("\x06"); // Ctrl-F — forward 1
    try std.testing.expect(l.cursor_moved);

    // Ctrl-E lands provably at EOL — clears even when sticky.
    l.cursor_moved = true;
    _ = l.applyInput("\x05");
    try std.testing.expect(!l.cursor_moved);
}

test "Ctrl-A on empty buffer does NOT set cursor_moved" {
    // Empty buffer → cursor already at col 1 == EOL == BOL.
    // Same skip rationale as the CSI cursor-motion path: don't
    // stickily suppress ghost at an empty prompt.
    var l = LineState{};
    _ = l.applyInput("\x01");
    try std.testing.expect(!l.cursor_moved);
}

test "Arrow Up does NOT set cursor_moved (history recall replaces buffer)" {
    // Up/Down change buffer content (history navigation) so the
    // existing `uncertain → syncFromCapture` recovery path handles
    // them. They are NOT mid-line cursor motion. Don't tag them so
    // the ghost can re-render on the new content after sync.
    var l = LineState{};
    _ = l.applyInput("ls");
    _ = l.applyInput("\x1B[A"); // Up — history recall
    try std.testing.expect(l.uncertain);
    try std.testing.expect(!l.cursor_moved);
}

test "submit / reset clear cursor_moved" {
    var l = LineState{};
    _ = l.applyInput("hello");
    _ = l.applyInput("\x1B[D"); // Left → cursor_moved
    try std.testing.expect(l.cursor_moved);

    _ = l.applyInput("\r"); // Enter → submit
    try std.testing.expect(!l.cursor_moved);

    _ = l.applyInput("again");
    _ = l.applyInput("\x1B[D");
    try std.testing.expect(l.cursor_moved);
    l.reset();
    try std.testing.expect(!l.cursor_moved);
}

test "VT-form CSI ~ also sets cursor_moved (xterm/libvte Home/End)" {
    // Many terminals encode Home as `\x1b[1~` and End as `\x1b[4~`
    // (VT-style) instead of the xterm cursor-style `\x1b[H` / `\x1b[F`.
    // Either form should suppress ghost.
    var l = LineState{};
    _ = l.applyInput("hello");
    _ = l.applyInput("\x1b[1~"); // Home (VT form)
    try std.testing.expect(l.cursor_moved);
}

test "killLine clears cursor_moved (empty buffer == EOL)" {
    var l = LineState{};
    _ = l.applyInput("hello");
    _ = l.applyInput("\x1B[D"); // Left → cursor_moved=true
    try std.testing.expect(l.cursor_moved);
    _ = l.applyInput("\x15"); // Ctrl+U → killLine
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expect(!l.cursor_moved);
}

test "empty buffer + Right/Home does NOT set cursor_moved" {
    // Empty prompt + cursor-motion key is a no-op in shells (cursor
    // is already at col 1 == BOL == EOL). Setting cursor_moved here
    // would stickily suppress ghost for the rest of the line the
    // user is about to type. Skip the flag when buffer is empty.
    var l = LineState{};
    _ = l.applyInput("\x1b[C"); // Right at empty prompt
    try std.testing.expect(!l.cursor_moved);
    _ = l.applyInput("\x1b[H"); // Home at empty prompt
    try std.testing.expect(!l.cursor_moved);
    // Once the user types something, the flag stays correct.
    _ = l.applyInput("hi");
    _ = l.applyInput("\x1b[D"); // Left mid-buffer → flag fires
    try std.testing.expect(l.cursor_moved);
}

test "killWord-to-empty clears cursor_moved" {
    var l = LineState{};
    _ = l.applyInput("hello");
    _ = l.applyInput("\x1B[D"); // Left → cursor_moved=true
    try std.testing.expect(l.cursor_moved);
    _ = l.applyInput("\x17"); // Ctrl+W → killWord, buffer goes to "" (one word)
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expect(!l.cursor_moved);
}

test "backspace-to-empty clears cursor_moved" {
    var l = LineState{};
    _ = l.applyInput("hi");
    _ = l.applyInput("\x1B[D"); // Left
    try std.testing.expect(l.cursor_moved);
    _ = l.applyInput("\x7F\x7F"); // backspace twice → empty
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expect(!l.cursor_moved);
}

test "syncFromCapture does NOT touch cursor_moved" {
    // The fix's core invariant: OSC 133 sync clears `uncertain` based
    // on bash's content view, but it does NOT clear `cursor_moved`
    // because OSC 133 carries no cursor-position info. renderGhost
    // gates on `cursor_moved` independently, so a Left arrow stays
    // ghost-suppressed even after sync re-confirms the content.
    var l = LineState{};
    _ = l.applyInput("hello");
    _ = l.applyInput("\x1B[D"); // Left
    try std.testing.expect(l.uncertain);
    try std.testing.expect(l.cursor_moved);

    l.syncFromCapture("hello"); // same content from OSC 133
    try std.testing.expect(!l.uncertain); // sync cleared it
    try std.testing.expect(l.cursor_moved); // but NOT cursor_moved
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

test "Ctrl-W (kill last word) drops pending author when it empties the buffer" {
    var l = LineState{};
    l.setCommitAuthor(.llm);
    // Single word, Ctrl-W wipes it → buffer empty → author drops.
    _ = l.applyInput("staged\x17");
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "Ctrl-W keeps pending author when the buffer is still non-empty afterward" {
    var l = LineState{};
    l.setCommitAuthor(.llm);
    // Two words; Ctrl-W kills only the last, buffer still has "ls ".
    _ = l.applyInput("ls suggested\x17");
    try std.testing.expect(l.len > 0);
    // The line still represents the LLM-staged suggestion — leave it.
    try std.testing.expectEqual(Author.llm, l.pending_author);
}

test "Ctrl-U on an empty buffer still drops a staged pending_author" {
    // Pins the empty-buffer-early-return path: a user can stage
    // `.llm` then immediately hit Ctrl-U before any chars arrive;
    // the no-op edit must still clear the tag so the next
    // user-typed line isn't mis-attributed.
    var l = LineState{};
    l.setCommitAuthor(.llm);
    try std.testing.expectEqual(@as(usize, 0), l.len);
    _ = l.applyInput("\x15");
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "Ctrl-W on an empty buffer still drops a staged pending_author" {
    var l = LineState{};
    l.setCommitAuthor(.llm);
    _ = l.applyInput("\x17");
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "Backspace on an empty buffer still drops a staged pending_author" {
    var l = LineState{};
    l.setCommitAuthor(.llm);
    _ = l.applyInput("\x7f");
    try std.testing.expectEqual(Author.user, l.pending_author);
}

test "submit-then-setCommitted preserves the snapshotted author" {
    // After `submit()` has snapshotted `pending_author` →
    // `committed_author`, a subsequent non-empty `setCommitted`
    // (buffer override) must NOT clobber the author.
    var l = LineState{};
    l.setCommitAuthor(.llm);
    _ = l.applyInput("ls\r");
    try std.testing.expectEqual(Author.llm, l.committedAuthor());

    l.setCommitted("ls -la");
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

test "setCommitted with non-empty content does not snapshot pending_author" {
    // Pins the API contract: only `submit()` snapshots
    // `pending_author` → `committed_author`. `setCommitted` is a
    // buffer-only override; calling it with a non-empty payload
    // leaves `committed_author` at whatever value it had
    // (default `.user` here, since no `submit()` ran first) and
    // leaves the staged `pending_author` intact.
    var l = LineState{};
    l.setCommitAuthor(.llm);
    l.setCommitted("echo hi");
    try std.testing.expectEqual(Author.user, l.committedAuthor());
    try std.testing.expectEqual(Author.llm, l.pending_author);
}
