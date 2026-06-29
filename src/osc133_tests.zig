//! Tests for `osc133.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("osc133.zig");

// Re-binds of pub decls so test bodies stay short.
const Osc133 = mod.Osc133;

// ===========================================================================
// Tests
// ===========================================================================

test "Osc133: active stays false until any 133 marker arrives" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("hello \x1b[1;36mcolor\x1b[0m \x1b]0;title\x07more");
    try testing.expect(!o.active);
    try testing.expectEqual(@as(usize, 0), o.currentInput().len);
}

test "Osc133: REPRO — prior command output must not bleed into the next capture under fragmentation" {
    // Integration with no ;C (starship-style): phase stays .in_input from ;B
    // through command execution, so the echo OUTPUT is captured; the next
    // prompt's ;A + ;B must clear it. This must hold no matter how the byte
    // stream is chunked across feed() calls.
    const seq =
        "\x1b]133;B\x07" ++ // input phase opens
        "starship-survived-" ++ // prior command's OUTPUT (captured, no ;C)
        "\x1b]133;D;0\x07" ++ // command done
        "\x1b]133;A\x07$ " ++ // next prompt start (clears) + PS1
        "\x1b]133;B\x07" ++ // next input phase (clears)
        "cat /tmp/x"; // the next command, echoed

    { // whole feed
        var o = Osc133.init(testing.allocator);
        defer o.deinit();
        o.feed(seq);
        try testing.expectEqualStrings("cat /tmp/x", o.currentInput());
    }
    { // one byte per feed — the worst-case fragmentation
        var o = Osc133.init(testing.allocator);
        defer o.deinit();
        for (seq) |b| o.feed(&[_]u8{b});
        try testing.expectEqualStrings("cat /tmp/x", o.currentInput());
    }
}

test "Osc133: endInputCapture (synthesized ;C) stops the command output being captured" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("\x1b]133;B\x07"); // input phase opens
    o.feed("echo hi"); // user types
    try testing.expectEqualStrings("echo hi", o.currentInput());

    o.endInputCapture(); // proxy: stdin Enter, the shell will execute (no ;C from the shell)
    try testing.expect(!o.captureActive());
    try testing.expectEqualStrings("", o.currentInput()); // submitted line cleared

    o.feed("hi\r\n"); // command OUTPUT — must NOT be captured
    try testing.expectEqualStrings("", o.currentInput());

    o.feed("\x1b]133;A\x07$ \x1b]133;B\x07cat x"); // next prompt + next command
    try testing.expectEqualStrings("cat x", o.currentInput());
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

test "Osc133.canFastPath + onFastPath — proxy fast-path contract" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    try testing.expect(o.canFastPath());
    o.onFastPath(1024);
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
