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

test "syncFromCapture clears uncertain without bumping generation when buffer matches" {
    var l = LineState{};
    _ = l.applyInput("ls\x1B[A");
    // Buffer is "ls" + uncertain=true. Sync with the same bytes —
    // content matches; clear uncertain but DON'T bump generation
    // (no buffer change → no provider recompute needed) and DON'T
    // clamp cursor_pos (the OSC stream carries no cursor info, so
    // forcing EOL would falsely re-engage ghost when the user
    // was mid-line — see the Tab-no-match regression test).
    const gen_before = l.generation;
    l.syncFromCapture("ls");
    try std.testing.expectEqual(gen_before, l.generation);
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

test "mid-line backspace splices buffer + preserves cursor accurately" {
    // Mid-line BS splices the byte at `cursor_pos - 1` out of the
    // buffer and decrements both `len` and `cursor_pos`. No drift,
    // no `uncertain` set, no need for a post-edit OSC 133 redraw to
    // restore the truth — the keystroke model is now authoritative
    // for the splice itself.
    var l = LineState{};
    // Simulate the in-flight "comand tesd aaa" state (15 bytes).
    l.syncFromCapture("comand tesd aaa");
    // Arrow-Left × 4 lands cursor at position 11 (between 'd' at
    // byte[10] and ' ' at byte[11]).
    _ = l.applyInput("\x1B[D\x1B[D\x1B[D\x1B[D");
    try std.testing.expectEqual(@as(usize, 11), l.cursor_pos);
    try std.testing.expect(!l.uncertain);
    try std.testing.expect(l.cursor_moved);

    // Backspace mid-line — splice removes 'd' at byte[10].
    _ = l.applyInput("\x7F");
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "comand tes aaa", l.current());
    try std.testing.expectEqual(@as(usize, 10), l.cursor_pos);
    try std.testing.expect(l.cursor_moved); // 10 != 14 → still mid-line

    // A subsequent same-content OSC sync is a no-op via the early
    // return path; cursor stays at 10.
    l.syncFromCapture("comand tes aaa");
    try std.testing.expect(!l.uncertain);
    try std.testing.expect(l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 10), l.cursor_pos);
}

test "syncFromCapture lands cursor at new EOL when prior cursor WAS at EOL" {
    // Sibling of the mid-line-delete test above: when the cursor
    // was at EOL before the sync (typical append-at-end path —
    // tab-completion that grew the buffer, paste at the end), the
    // new cursor lands at the new EOL. Without this branch the
    // ghost wouldn't re-engage after a successful completion.
    var l = LineState{};
    l.syncFromCapture("ls "); // cursor at EOL (pos 3)
    try std.testing.expectEqual(@as(usize, 3), l.cursor_pos);
    try std.testing.expect(!l.cursor_moved);

    // Tab keystroke (0x09) lands here — applyInput marks
    // uncertain because Tab triggers completion, an
    // unmodelled buffer change.
    _ = l.applyInput("\x09");
    try std.testing.expect(l.uncertain);

    // Completion succeeded: bash redraws with "ls foo.txt"
    // (longer; cursor at the new EOL).
    l.syncFromCapture("ls foo.txt");
    try std.testing.expect(!l.uncertain);
    try std.testing.expect(!l.cursor_moved);
    try std.testing.expectEqual(@as(usize, 10), l.cursor_pos);
}

test "syncFromCapture: mid-line GROW (paste) clamps cursor to min(prior, n) — still mid-line" {
    // Strengthens the @min(prior, n) branch beyond the shrink
    // case. Mid-line paste at cursor pos 4: buffer grows by 3
    // bytes. The modeled cursor stays at 4 (drifts left of the
    // physical cursor — which lands at 7 after the paste —
    // documented in syncFromCapture's docstring), critically
    // STAYS mid-line so ghost suppression holds. A regression
    // that flipped the if-condition would land cursor at n=11
    // and cursor_moved would falsely clear.
    var l = LineState{};
    l.syncFromCapture("ls a.txt"); // 8 bytes: l s _ a . t x t — cursor at 8 (EOL).
    _ = l.applyInput("\x1B[D\x1B[D\x1B[D\x1B[D"); // ← × 4 → pos 4 (between 'a' and '.').
    try std.testing.expectEqual(@as(usize, 4), l.cursor_pos);
    try std.testing.expect(l.cursor_moved);

    // Simulate a paste — applyInput would mark uncertain for an
    // unmodelled buffer change; reuse the Tab byte for the same
    // effect since both reach the markUncertain abort branch.
    _ = l.applyInput("\x09");
    try std.testing.expect(l.uncertain);

    // Bash redraws longer (paste of "XYZ" inserted at cursor
    // pos 4): "ls a" + "XYZ" + ".txt" = "ls aXYZ.txt" (11 bytes).
    l.syncFromCapture("ls aXYZ.txt");
    try std.testing.expect(!l.uncertain);
    try std.testing.expect(l.cursor_moved); // 4 != 11 → mid-line → ghost suppressed
    try std.testing.expectEqual(@as(usize, 4), l.cursor_pos);
}

test "applyInput: bulk-append printable run matches per-byte semantics" {
    // Bulk-append (one applyInput call) must produce the same
    // observable state as N per-byte calls. Run-scan + control-
    // byte boundary handling must not diverge from the old loop.
    var bulk = LineState{};
    _ = bulk.applyInput("hello world");
    var serial = LineState{};
    for ("hello world") |c| {
        var b: [1]u8 = .{c};
        _ = serial.applyInput(&b);
    }
    try std.testing.expectEqualStrings(bulk.current(), serial.current());
    try std.testing.expectEqual(bulk.cursor_pos, serial.cursor_pos);
    try std.testing.expectEqual(bulk.uncertain, serial.uncertain);
}

test "applyInput: bulk-append stops at control byte (Enter mid-paste)" {
    // Multi-line paste — bulk appends "echo foo", per-byte switch
    // sees `\n` and submits, next iteration bulk-appends "echo bar".
    var l = LineState{};
    _ = l.applyInput("echo foo\necho bar");
    try std.testing.expectEqualStrings("echo bar", l.current());
    try std.testing.expectEqualStrings("echo foo", l.lastCommitted().?);
}

test "applyInput: bulk-append splices mid-line insertion (mirrors per-byte append)" {
    // The bulk path runs the same splice as the per-byte `append`:
    // a paste landing mid-line shifts the tail right by `take` bytes
    // and writes the run at `cursor_pos`. Keeps the keystroke model
    // in sync with bash readline's ICH-based insert.
    var l = LineState{};
    _ = l.applyInput("ls foo");
    _ = l.applyInput("\x1B[D\x1B[D"); // ← × 2: cursor at position 4 (between 'f' and 'o').
    try std.testing.expectEqual(@as(usize, 4), l.cursor_pos);
    try std.testing.expect(!l.uncertain);

    _ = l.applyInput("INSERT");
    try std.testing.expect(!l.uncertain);
    try std.testing.expectEqualSlices(u8, "ls fINSERToo", l.current());
    try std.testing.expectEqual(@as(usize, 10), l.cursor_pos);
    try std.testing.expect(l.cursor_moved); // 10 != 12 → still mid-line
}

test "applyInput: bulk-append honours max_line capacity gate" {
    // Buffer overflow: the bulk copy takes only what fits and
    // sets uncertain for the rest — mirrors `append`'s bail.
    var l = LineState{};
    var huge: [4200]u8 = undefined;
    @memset(&huge, 'a');
    _ = l.applyInput(&huge);
    try std.testing.expect(l.uncertain);
    try std.testing.expect(l.len <= 4096); // max_line cap
}

test "applyInput: bulk-append accepts high-bit (UTF-8) bytes" {
    // £ = 0xC2 0xA3 — both bytes ≥ 0x80, pass the printable
    // filter. Raw bytes land in the buffer unchanged.
    var l = LineState{};
    _ = l.applyInput("price: \xc2\xa3" ++ "9");
    try std.testing.expectEqualStrings("price: \xc2\xa3" ++ "9", l.current());
}
