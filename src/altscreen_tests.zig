//! Tests for `altscreen.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("altscreen.zig");

// Re-binds of pub decls so test bodies stay short.
const AltScreen = mod.AltScreen;

// ===========================================================================
// Tests
// ===========================================================================

test "AltScreen: stays inactive on plain output" {
    var a = AltScreen.init();
    a.feed("hello world\r\n");
    a.feed("\x1b[1;36mcolored\x1b[0m");
    a.feed("\x1b]0;set title\x07");
    try testing.expect(!a.active);
    try testing.expect(!a.takeTransition());
}

test "AltScreen: ?1049h flips active true with a transition edge" {
    var a = AltScreen.init();
    a.feed("\x1b[?1049h");
    try testing.expect(a.active);
    try testing.expect(a.takeTransition());
    // takeTransition clears the edge — second call returns false.
    try testing.expect(!a.takeTransition());
}

test "AltScreen: ?1049l after enter flips back with a transition edge" {
    var a = AltScreen.init();
    a.feed("\x1b[?1049h");
    _ = a.takeTransition();
    a.feed("\x1b[?1049l");
    try testing.expect(!a.active);
    try testing.expect(a.takeTransition());
}

test "AltScreen: legacy ?47h and ?1047h both flip active" {
    var a = AltScreen.init();
    a.feed("\x1b[?47h");
    try testing.expect(a.active);
    a.feed("\x1b[?47l");
    try testing.expect(!a.active);
    a.feed("\x1b[?1047h");
    try testing.expect(a.active);
    a.feed("\x1b[?1047l");
    try testing.expect(!a.active);
}

test "AltScreen: redundant ?1049h while active is not a transition" {
    var a = AltScreen.init();
    a.feed("\x1b[?1049h");
    _ = a.takeTransition();
    a.feed("\x1b[?1049h");
    try testing.expect(a.active);
    try testing.expect(!a.takeTransition()); // no edge
}

test "AltScreen: non-private CSIs don't toggle (no `?` prefix)" {
    // `\x1b[1049h` (without `?`) is a totally different sequence.
    // We must NOT confuse it with a DECSET on mode 1049.
    var a = AltScreen.init();
    a.feed("\x1b[1049h");
    try testing.expect(!a.active);
}

test "AltScreen: unrelated private modes leave state untouched" {
    var a = AltScreen.init();
    a.feed("\x1b[?25l"); // hide cursor
    a.feed("\x1b[?7h"); // wraparound
    a.feed("\x1b[?2004h"); // bracketed paste
    try testing.expect(!a.active);
    try testing.expect(!a.takeTransition());
}

test "AltScreen: sequence split across feed calls still parses" {
    var a = AltScreen.init();
    a.feed("\x1b");
    a.feed("[?10");
    a.feed("49");
    a.feed("h");
    try testing.expect(a.active);
    try testing.expect(a.takeTransition());
}

test "AltScreen: realistic enter→exit round-trip mixed with other output" {
    var a = AltScreen.init();
    a.feed("$ k9s\r\n");
    a.feed("\x1b[?25l\x1b[?1049h"); // hide cursor + enter alt
    try testing.expect(a.active);
    try testing.expect(a.takeTransition());
    // k9s draws...
    a.feed("\x1b[1;1H\x1b[2J\x1b[1;36msome k9s ui\x1b[0m");
    try testing.expect(a.active);
    try testing.expect(!a.takeTransition()); // no further edges
    // k9s exits
    a.feed("\x1b[?1049l\x1b[?25h");
    try testing.expect(!a.active);
    try testing.expect(a.takeTransition());
}

test "AltScreen: malformed CSI doesn't strand the parser" {
    // Truncated, garbage in the middle, recover on next sequence.
    var a = AltScreen.init();
    a.feed("\x1b[?garbage"); // bogus letter mid-param — ends the CSI
    try testing.expect(!a.active);
    a.feed("\x1b[?1049h"); // should still work
    try testing.expect(a.active);
}

test "AltScreen: multi-mode DECSET — alt-screen + mouse in one CSI" {
    // xterm combines private modes with `;` separators. Common in the
    // wild: `ESC[?1049;1000h` (enter alt screen + enable mouse), the
    // matching `ESC[?1049;1000l` on exit. Older flag arrangements use
    // `?47;1000h`. atty must detect the alt-screen toggle regardless
    // of which co-mode it's combined with.
    var a = AltScreen.init();
    a.feed("\x1b[?1049;1000h");
    try testing.expect(a.active);
    try testing.expect(a.takeTransition());

    a.feed("\x1b[?1049;1000l");
    try testing.expect(!a.active);
    try testing.expect(a.takeTransition());
}

test "AltScreen: multi-mode DECSET — alt-screen at the back of the param list" {
    // Param order isn't fixed by the spec — `?1000;1049h` is just as
    // valid as `?1049;1000h`. The latch must work regardless of which
    // position the alt-screen mode appears in.
    var a = AltScreen.init();
    a.feed("\x1b[?1000;1049h");
    try testing.expect(a.active);
    try testing.expect(a.takeTransition());
}

test "AltScreen: multi-mode DECSET — only co-modes, no alt-screen, leaves state untouched" {
    // `ESC[?1000;1002;1006h` — modern mouse setup, no alt-screen.
    // saw_alt_mode must stay false; no transition emitted.
    var a = AltScreen.init();
    a.feed("\x1b[?1000;1002;1006h");
    try testing.expect(!a.active);
    try testing.expect(!a.takeTransition());
}

test "AltScreen.canFastPath — fast-path contract" {
    var a = AltScreen.init();
    try testing.expect(a.canFastPath());
    a.feed("plain text with no escapes");
    try testing.expect(a.canFastPath());
    a.feed("\x1b[?"); // mid-sequence
    try testing.expect(!a.canFastPath());
    a.feed("1049h");
    try testing.expect(a.canFastPath());
    // onFastPath is a no-op for altscreen — no state churn.
    a.onFastPath(4096);
    try testing.expect(a.canFastPath());
}
