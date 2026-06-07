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
    // Cursor-motion CSIs maintain `cursor_pos`; `cursor_moved` is
    // derived as `(cursor_pos != len)`. Left mid-buffer flips it
    // on; End jumps cursor to len and flips it off.
    var l = LineState{};
    _ = l.applyInput("hello");
    try std.testing.expect(!l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 5), l.cursor_pos);

    _ = l.applyInput("\x1B[D"); // Left → cursor_pos 5→4
    try std.testing.expect(l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 4), l.cursor_pos);

    // Right moves cursor_pos forward by 1; lands at len → clears.
    _ = l.applyInput("\x1B[C"); // Right → cursor_pos 4→5 (EOL)
    try std.testing.expect(!l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 5), l.cursor_pos);

    _ = l.applyInput("\x1B[H"); // Home → cursor_pos = 0
    try std.testing.expect(l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 0), l.cursor_pos);

    // End — cursor_pos jumps to len, flag clears.
    _ = l.applyInput("\x1B[F");
    try std.testing.expect(!l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 5), l.cursor_pos);
}

test "End VT-form (`\\x1b[4~` / `\\x1b[8~`) clears cursor_moved" {
    // VT-form End is what xterm + libvte-based terminals send by
    // default. Both `4~` (xterm End) and `8~` (vt220 End) must clear
    // the flag — same EOL guarantee as the cursor-style `F`.
    var l = LineState{};
    _ = l.applyInput("hello");
    _ = l.applyInput("\x1B[D"); // Left → cursor_pos=4, cursor_moved=true
    try std.testing.expect(l.cursor_moved);
    _ = l.applyInput("\x1B[4~"); // End → cursor_pos=5, flag clears
    try std.testing.expect(!l.cursor_moved);

    _ = l.applyInput("\x1B[D"); // Left again → cursor_pos=4
    try std.testing.expect(l.cursor_moved);
    _ = l.applyInput("\x1B[8~"); // vt220 End → cursor_pos=5
    try std.testing.expect(!l.cursor_moved);

    // Home VT-form still SETS the flag (cursor_pos = 0).
    _ = l.applyInput("\x1B[1~");
    try std.testing.expect(l.cursor_moved);
}

test "Ctrl-A / Ctrl-B / Ctrl-F maintain cursor_pos; Ctrl-E jumps to EOL" {
    // Readline cursor-motion bindings encoded as single control bytes
    // (legacy, no kitty kbd). Each updates `cursor_pos`; `cursor_moved`
    // derives from `(cursor_pos != len)`. Regression for
    // "Arrow Up + Ctrl-A + type → ghost hides recalled tail" AND for
    // "Right-stepping back to EOL re-engages ghost".
    var l = LineState{};
    _ = l.applyInput("hello");
    try std.testing.expect(!l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 5), l.cursor_pos);

    _ = l.applyInput("\x01"); // Ctrl-A — cursor_pos = 0
    try std.testing.expect(l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 0), l.cursor_pos);

    _ = l.applyInput("\x06"); // Ctrl-F — cursor_pos = 1
    try std.testing.expect(l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 1), l.cursor_pos);

    _ = l.applyInput("\x02"); // Ctrl-B — cursor_pos = 0
    try std.testing.expect(l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 0), l.cursor_pos);

    // Ctrl-E — cursor_pos = len, flag clears.
    _ = l.applyInput("\x05");
    try std.testing.expect(!l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 5), l.cursor_pos);
}

test "Up + sync(recall) + Ctrl-A + End + type 'e' preserves recalled line content" {
    // User-reported follow-up to the Ctrl-A fix: after Arrow-Up
    // (history recall), Ctrl-A, End, then typing 'e' — the ghost
    // overlay matches against just "e", not against the recalled
    // line + 'e'. Root cause: the End CSI called markUncertain,
    // which then let the proxy sync from a stale OSC capture
    // (just "e", or "") and clobber the keystroke buffer.
    var l = LineState{};

    // Step 1: Arrow Up — markUncertain because Arrow Up changes
    // buffer content (history recall is unmodeled until OSC 133
    // or syncFromCapture restores it).
    _ = l.applyInput("\x1B[A");
    try std.testing.expect(l.uncertain);
    try std.testing.expectEqualSlices(u8, "", l.current());

    // Step 2: shell echoes recall → OSC 133 capture region picks
    // it up → proxy calls syncFromCapture with the recalled line.
    l.syncFromCapture("which pvcontrol");
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "which pvcontrol", l.current());

    // Step 3: Ctrl-A — cursor to BOL; buffer unchanged.
    _ = l.applyInput("\x01");
    try std.testing.expect(l.cursor_moved);
    try std.testing.expectEqualSlices(u8, "which pvcontrol", l.current());

    // Step 4: End (xterm cursor-style) — cursor lands at EOL;
    // cursor_moved cleared; buffer preserved AND uncertain stays
    // false because End doesn't change buffer content.
    _ = l.applyInput("\x1B[F");
    try std.testing.expect(!l.cursor_moved);
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "which pvcontrol", l.current());

    // Step 5: type 'e' — appends at EOL. Buffer is the full
    // recalled line plus 'e'.
    _ = l.applyInput("e");
    try std.testing.expectEqualSlices(u8, "which pvcontrole", l.current());
}

test "mid-line append + backspace splice the buffer (mirror bash readline)" {
    // The keystroke model splices mid-line edits into `buffer` so it
    // stays in sync with what bash actually has on the prompt — modern
    // readline uses ICH for inserts and `\b<rest> <CSI back>` for
    // deletes (only the changed bytes hit the wire), so OSC 133 alone
    // can't restore the post-edit truth. Without the splice, the
    // model would diverge and ghost text would query a stale prefix
    // of the line.
    var l = LineState{};
    _ = l.applyInput("hello world");
    _ = l.applyInput("\x01"); // Ctrl-A → cursor_pos = 0
    try std.testing.expect(l.cursor_moved);

    // Mid-line insert at position 0: 'X' splices in, tail shifts right.
    _ = l.applyInput("X");
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "Xhello world", l.current());
    try std.testing.expectEqual(@as(usize, 12), l.len);
    try std.testing.expectEqual(@as(usize, 1), l.cursor_pos);
    try std.testing.expect(l.cursor_moved); // 1 != 12 → still mid-line

    // Mid-line backspace: remove byte at cursor_pos - 1, shift left.
    l.reset();
    _ = l.applyInput("hello world");
    _ = l.applyInput("\x01"); // Ctrl-A → cursor_pos = 0
    _ = l.applyInput("\x06"); // Ctrl-F → cursor_pos = 1
    _ = l.applyInput("\x06"); // Ctrl-F → cursor_pos = 2 (between 'e' and 'l')
    _ = l.applyInput("\x7F"); // Backspace deletes 'e' at position 1
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "hllo world", l.current());
    try std.testing.expectEqual(@as(usize, 1), l.cursor_pos);

    // killWord still markUncertains mid-line — the readline kill-word
    // scan from end-of-buffer is wrong when cursor is mid-line, and
    // the model doesn't yet implement the splice for it. Documented
    // as a deliberate gap until a user-visible symptom motivates it.
    l.reset();
    _ = l.applyInput("hello world");
    _ = l.applyInput("\x01"); // Ctrl-A
    _ = l.applyInput("\x17"); // Ctrl-W
    try std.testing.expect(l.uncertain);
    try std.testing.expectEqualSlices(u8, "hello world", l.current());
}

test "splice boundary: insert just before last byte (cursor_pos == len - 1)" {
    // The classic off-by-one boundary for `copyBackwards`. Insert at
    // `len - 1` shifts a single tail byte right by 1 and writes the
    // new byte one in from EOL.
    var l = LineState{};
    _ = l.applyInput("ls foo");
    _ = l.applyInput("\x1B[D"); // ← × 1 → cursor_pos = 5 (between 'o' at byte[4] and 'o' at byte[5])
    try std.testing.expectEqual(@as(usize, 5), l.cursor_pos);
    _ = l.applyInput("X");
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "ls foXo", l.current());
    try std.testing.expectEqual(@as(usize, 6), l.cursor_pos);
}

test "splice boundary: backspace at BOL (cursor_pos == 0) is a no-op" {
    // Readline rings the bell terminal-side; the model leaves buffer
    // and generation untouched. Asserting the generation guards
    // against a future drift that bumps it on no-op paths.
    var l = LineState{};
    _ = l.applyInput("hello");
    _ = l.applyInput("\x01"); // Ctrl-A → cursor_pos = 0
    const gen_before = l.generation;
    _ = l.applyInput("\x7F"); // BS at BOL
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "hello", l.current());
    try std.testing.expectEqual(@as(usize, 0), l.cursor_pos);
    try std.testing.expectEqual(gen_before, l.generation);
}

test "splice + overflow: mid-line bulk insert past max_line caps + flags uncertain" {
    // Pre-fill the buffer to (max_line - 2), park cursor mid-line,
    // then paste a 10-byte run. `take` is capped at 2; the splice
    // path writes those 2 bytes at the cursor and marks `uncertain`
    // for the dropped suffix. Buffer must stay internally coherent
    // (no out-of-bounds memmove, len + cursor_pos still consistent).
    var l = LineState{};
    var fill: [max_line - 2]u8 = undefined;
    @memset(&fill, 'a');
    _ = l.applyInput(&fill);
    try std.testing.expectEqual(max_line - 2, l.len);
    _ = l.applyInput("\x1B[D"); // ← × 1: cursor_pos = max_line - 3 (mid-line)
    try std.testing.expectEqual(max_line - 3, l.cursor_pos);

    _ = l.applyInput("XYZABCDEFG"); // 10-byte run, only 2 fit
    try std.testing.expect(l.uncertain);
    try std.testing.expectEqual(max_line, l.len);
    try std.testing.expectEqual(max_line - 1, l.cursor_pos);
    // The two spliced bytes land at the cursor, the prior tail byte
    // 'a' got pushed right by 2 to byte[max_line - 1].
    try std.testing.expectEqual(@as(u8, 'X'), l.current()[max_line - 3]);
    try std.testing.expectEqual(@as(u8, 'Y'), l.current()[max_line - 2]);
    try std.testing.expectEqual(@as(u8, 'a'), l.current()[max_line - 1]);
}

test "uncertain + DIFFERENT content + Tab + sync still clamps cursor_pos (Tab-with-completion path)" {
    // Counterpart to the no-match guard below: Tab WITH a completion
    // that grew the buffer falls through to the rewrite branch and
    // clamps cursor_pos = new_len. Correct for the typical bash
    // completion shape (insert at cursor, cursor ends up at the end
    // of the inserted text — = new_len when the user didn't move
    // past EOL after Arrow-Up). Without this test a future "preserve
    // cursor_pos always" regression would silently break the common
    // Tab-completion path.
    var l = LineState{};
    _ = l.applyInput("\x1B[A");
    l.syncFromCapture("git st");
    _ = l.applyInput("\x09"); // Tab → markUncertain
    try std.testing.expect(l.uncertain);

    l.syncFromCapture("git status");
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqual(@as(usize, 10), l.cursor_pos);
    try std.testing.expect(!l.cursor_moved);
    try std.testing.expectEqualSlices(u8, "git status", l.current());
}

test "uncertain + same content + lone ESC + sync preserves cursor_pos (ESC-no-content guard)" {
    // Lone ESC (0x1B with no `[` follower) also calls markUncertain;
    // same shape as Tab-no-match. If the next syncFromCapture has
    // unchanged content, the cursor must stay mid-line.
    var l = LineState{};
    _ = l.applyInput("\x1B[A");
    l.syncFromCapture("which pvcontrol");

    _ = l.applyInput("\x1B[D"); // Left
    _ = l.applyInput("\x1B[D"); // Left → cursor_pos = 13
    try std.testing.expectEqual(@as(usize, 13), l.cursor_pos);

    _ = l.applyInput("\x1B"); // lone ESC → markUncertain
    try std.testing.expect(l.uncertain);
    try std.testing.expectEqual(@as(usize, 13), l.cursor_pos);

    l.syncFromCapture("which pvcontrol");
    try std.testing.expect(!l.uncertain);
    try std.testing.expect(l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 13), l.cursor_pos);
}

test "uncertain + same content + Tab + sync preserves cursor_pos (Tab-no-match guard)" {
    // User-reported: Arrow-Up → Arrow-Left × N → Tab (no completion
    // match) → ghost text appeared mid-line, overlaying the text
    // to the right of the cursor. Root cause: Tab → markUncertain;
    // the proxy then called syncFromCapture with the unchanged OSC
    // 133 input region, which used to unconditionally clamp
    // cursor_pos = n (= EOL) even when the buffer hadn't changed.
    // The "buffer-already-matches" early-return now clears
    // `uncertain` but preserves `cursor_pos` so the cursor_moved
    // gate keeps ghost suppressed until the user actually walks
    // back to EOL.
    var l = LineState{};
    _ = l.applyInput("\x1B[A"); // Arrow Up
    l.syncFromCapture("which pvcontrol"); // OSC 133 recall sync
    try std.testing.expect(!l.uncertain);
    try std.testing.expect(!l.cursor_moved);

    _ = l.applyInput("\x1B[D"); // Left
    _ = l.applyInput("\x1B[D"); // Left
    _ = l.applyInput("\x1B[D"); // Left → cursor_pos = 12
    try std.testing.expectEqual(@as(usize, 12), l.cursor_pos);
    try std.testing.expect(l.cursor_moved);

    _ = l.applyInput("\x09"); // Tab → markUncertain
    try std.testing.expect(l.uncertain);
    try std.testing.expectEqual(@as(usize, 12), l.cursor_pos); // cursor untouched

    // Shell didn't insert anything (no completion match). OSC 133
    // input region still holds the recalled line. Sync fires
    // because `uncertain` triggered branch (a) of the gate.
    l.syncFromCapture("which pvcontrol");
    try std.testing.expect(!l.uncertain); // sync cleared it
    try std.testing.expect(l.cursor_moved); // cursor STILL mid-line
    try std.testing.expectEqual(@as(usize, 12), l.cursor_pos);
}

test "mid-line + sync to shorter capture is refused (BS-poisoned OSC guard)" {
    // Bash echoes every Arrow-Left keystroke as `\b` on the master
    // fd, and `Osc133.processInputByte` currently pops a byte from
    // the captured-input region on BS — so the OSC capture shrinks
    // by one byte per arrow-left even though the on-screen content
    // didn't change. After N lefts on an Arrow-Up-recalled line, the
    // OSC capture has lost N bytes from the tail.
    //
    // If `syncFromCapture` then trusted that shrunk capture, the
    // `min(prior_cursor, n)` clamp would land cursor_pos at the new
    // EOL (because the user's prior cursor was inside the truncated
    // region), clearing `cursor_moved`. The ghost overlay would
    // re-engage and paint dim text over bash's right-side echo. The
    // guard refuses the rewrite entirely — keystroke buffer + cursor
    // are preserved; `uncertain` is already false here (the splice
    // path doesn't set it), so nothing else changes.
    //
    // Reproduces the scenario from
    // `tests/e2e/ghost_midline_insert_after_uparrow`: Arrow-Up →
    // syncFromCapture("open ./test/foo"); Arrow-Left × 11 →
    // cursor_pos = 4; mid-line space → applyInput splices in-place
    // (buffer grows to 16 chars, cursor 5, `uncertain` stays false);
    // bash echoes `\b` after its ICH insert, OSC pops down to "open".
    var l = LineState{};
    _ = l.applyInput("\x1B[A"); // Arrow-Up
    l.syncFromCapture("open ./test/foo");
    var k: usize = 0;
    while (k < 11) : (k += 1) _ = l.applyInput("\x1B[D");
    try std.testing.expectEqual(@as(usize, 4), l.cursor_pos);
    try std.testing.expect(l.cursor_moved);
    _ = l.applyInput(" "); // mid-line splice — buffer now 16 chars, cursor 5
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "open  ./test/foo", l.current());
    try std.testing.expectEqual(@as(usize, 5), l.cursor_pos);
    try std.testing.expect(l.cursor_moved);

    // Capture has been chewed down to "open" (4 chars) by `\b` echoes
    // from the prior Arrow-Lefts. Trusting it would set
    // cursor_pos = min(5, 4) = 4 == new_len → clear cursor_moved.
    // The guard skips the rewrite.
    l.syncFromCapture("open");
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "open  ./test/foo", l.current());
    try std.testing.expectEqual(@as(usize, 5), l.cursor_pos);
    try std.testing.expect(l.cursor_moved);
}

test "mid-line + sync to capture that grows past cursor still rewrites" {
    // Counterpart to the BS-poisoned-OSC guard above: when the new
    // content reaches PAST the prior cursor, the OSC capture has
    // genuinely caught up (paste, completion-fragment, mid-line
    // redraw with full content). Sync as normal.
    var l = LineState{};
    _ = l.applyInput("\x1B[A");
    l.syncFromCapture("hello world");
    _ = l.applyInput("\x1B[D"); // cursor 10
    _ = l.applyInput("\x1B[D"); // cursor 9
    _ = l.applyInput("\x1B[D"); // cursor 8
    try std.testing.expectEqual(@as(usize, 8), l.cursor_pos);

    // Capture stayed at full length; rewrite proceeds; cursor
    // preserved at 8 (mid-line) and stays mid-line.
    l.syncFromCapture("hello world!");
    try std.testing.expectEqualSlices(u8, "hello world!", l.current());
    try std.testing.expectEqual(@as(usize, 8), l.cursor_pos);
    try std.testing.expect(l.cursor_moved);
}

test "uncertain + same content + Left + sync preserves cursor_pos (mid-typing redraw guard)" {
    // The proxy-side gate (`osc_input.len >= line.len` OR
    // `uncertain`) lets bash's mid-typing PS1 redraws sync back —
    // but `syncFromCapture` itself has an early-return when the
    // content matches AND !uncertain. With this guard in place,
    // a Left arrow inside a "redraw cycle that doesn't touch
    // content" preserves cursor_pos: Left set cursor_pos < len
    // BEFORE sync, and sync's early-return skips clobbering it.
    var l = LineState{};
    _ = l.applyInput("hello world");
    _ = l.applyInput("\x1B[D"); // Left → cursor_pos = 10
    _ = l.applyInput("\x1B[D"); // Left → cursor_pos = 9
    try std.testing.expectEqual(@as(usize, 9), l.cursor_pos);
    try std.testing.expect(l.cursor_moved);

    // bash redraws the prompt with no content change — sync's
    // early-return skips the write. cursor_pos survives.
    l.syncFromCapture("hello world");
    try std.testing.expectEqual(@as(usize, 9), l.cursor_pos);
    try std.testing.expect(l.cursor_moved);
}

test "Right-stepping to EOL + backspace re-engages ghost (cursor stays at EOL)" {
    // User-reported follow-up #2: after Arrow-Up recall, Ctrl-A
    // (BOL), Arrow-Right ×N to step back to EOL, then backspace —
    // the user expects ghost suggestions for the shortened line.
    // Current behavior: cursor_moved stays true (sticky from
    // Right-arrow's "±1, no EOL guarantee" setting), so ghost
    // remains suppressed until the buffer empties entirely.
    //
    // The root issue is that Right-arrow can't tell when it
    // LANDS at EOL — it only moves ±1. Without tracking cursor
    // offset explicitly, line_state can't know the cursor is
    // back at EOL.
    var l = LineState{};
    _ = l.applyInput("\x1B[A"); // Up
    l.syncFromCapture("which pvcontrol"); // OSC 133 sync
    _ = l.applyInput("\x01"); // Ctrl-A
    try std.testing.expect(l.cursor_moved);

    // Right ×15 to reach EOL (cursor steps back through each char).
    var i: usize = 0;
    while (i < 15) : (i += 1) _ = l.applyInput("\x1B[C");

    // Backspace at EOL — cursor stays at the new EOL.
    _ = l.applyInput("\x7F");
    try std.testing.expectEqualSlices(u8, "which pvcontro", l.current());

    // Cursor is at the new EOL. Ghost SHOULD engage.
    // DESIRED: cursor_moved cleared. (Currently fails — sticky.)
    try std.testing.expect(!l.cursor_moved);
}

test "cursor-motion CSIs do NOT set uncertain (content unchanged)" {
    // End/Home/Left/Right only move the cursor. Marking the buffer
    // uncertain would force a syncFromCapture recovery path that
    // can clobber the keystroke buffer when the OSC 133 input
    // region is stale.
    var l = LineState{};
    _ = l.applyInput("hello world");
    try std.testing.expect(!l.uncertain);

    // xterm cursor-style: D=Left, C=Right, H=Home, F=End.
    _ = l.applyInput("\x1B[D");
    try std.testing.expect(!l.uncertain);
    _ = l.applyInput("\x1B[C");
    try std.testing.expect(!l.uncertain);
    _ = l.applyInput("\x1B[H");
    try std.testing.expect(!l.uncertain);
    _ = l.applyInput("\x1B[F");
    try std.testing.expect(!l.uncertain);

    // VT-style: 1~/7~ = Home, 4~/8~ = End, 5~/6~ = PageUp/Down.
    _ = l.applyInput("\x1B[1~");
    try std.testing.expect(!l.uncertain);
    _ = l.applyInput("\x1B[4~");
    try std.testing.expect(!l.uncertain);
    _ = l.applyInput("\x1B[5~");
    try std.testing.expect(!l.uncertain);

    // Sanity: buffer-changing CSIs DO set uncertain.
    _ = l.applyInput("\x1B[A"); // Arrow Up
    try std.testing.expect(l.uncertain);
    l.syncFromCapture("hello world"); // back to certain
    try std.testing.expect(!l.uncertain);
    _ = l.applyInput("\x1B[3~"); // Delete
    try std.testing.expect(l.uncertain);
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

test "killWord-to-empty clears cursor_moved (EOL case)" {
    // EOL killWord-to-empty: Ctrl-W on "hello" with cursor at EOL
    // deletes the whole word, buffer goes empty, cursor_moved
    // clears. Mid-line Ctrl-W is unmodeled (markUncertain — see
    // the mid-line-guard test above).
    var l = LineState{};
    _ = l.applyInput("hello");
    try std.testing.expect(!l.cursor_moved);
    _ = l.applyInput("\x17"); // Ctrl+W at EOL → kills "hello"
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expect(!l.cursor_moved);
}

test "backspace-to-empty clears cursor_moved (EOL case)" {
    // EOL backspace-to-empty: cursor at EOL, backspace twice
    // drains the buffer. Mid-line backspace markUncertain's
    // instead (see mid-line-guard test above).
    var l = LineState{};
    _ = l.applyInput("hi");
    try std.testing.expect(!l.cursor_moved);
    _ = l.applyInput("\x7F\x7F"); // backspace twice from EOL → empty
    try std.testing.expectEqual(@as(usize, 0), l.len);
    try std.testing.expect(!l.cursor_moved);
}

test "syncFromCapture lands cursor at EOL of the captured content" {
    // After a recovery sync (Arrow-Up recall, Tab completion, ...)
    // bash echoes the new line and the cursor ends at the EOL of
    // that line. The sync mirrors that: `cursor_pos = len`, so
    // `cursor_moved` clears and ghost can re-engage on what bash
    // just drew. Previous model "sync doesn't know cursor" caused
    // the post-recall ghost to be suppressed forever.
    var l = LineState{};
    l.syncFromCapture("recalled line");
    try std.testing.expect(!l.uncertain);
    try std.testing.expect(!l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 13), l.cursor_pos);

    // A subsequent Left arrow still moves cursor mid-line and
    // sets cursor_moved. The next sync with same content + no
    // uncertainty is short-circuited by the early-return guard,
    // so Left's effect survives.
    _ = l.applyInput("\x1B[D");
    try std.testing.expect(l.cursor_moved);
    l.syncFromCapture("recalled line"); // same content, !uncertain → skip
    try std.testing.expect(l.cursor_moved); // Left's effect preserved
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
