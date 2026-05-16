//! Alternate-screen-buffer tracker.
//!
//! Full-screen TUIs (k9s, vim, less, htop, top, btm, helix, lazygit,
//! man, …) swap to the **alternate screen buffer** while running and
//! swap back on exit. The protocol bytes:
//!
//!     \x1B[?1049h   ─▶ enter alt screen + save cursor + clear     (xterm/modern)
//!     \x1B[?1049l   ─▶ exit alt screen + restore cursor
//!     \x1B[?47h     ─▶ enter alt screen (legacy)
//!     \x1B[?47l     ─▶ exit alt screen  (legacy)
//!     \x1B[?1047h   ─▶ enter alt screen (xterm intermediate)
//!     \x1B[?1047l   ─▶ exit alt screen
//!
//! While the alt screen is active the app expects the WHOLE terminal:
//! every row from 1..N, no DECSTBM clipping, no overlay painting from
//! the proxy. atty's statusbar reservation does the opposite — it
//! pins DECSTBM to a slimmed row range AND repaints the bottom row
//! every iteration. The user observes (a) k9s/vim drawing clipped a
//! row or two from the bottom and (b) `atty | atuin` bleeding through
//! the app's UI.
//!
//! This tracker watches master→stdout bytes, flips an `active` flag
//! around the alt-screen window, and surfaces a transition edge so
//! the proxy can pop DECSTBM + suspend statusbar painting on enter,
//! and re-apply them on exit. The parser is a small state machine
//! that survives partial sequences across reads (one CSI may straddle
//! a read boundary).
//!
//! Only DECSET / DECRST for the three modes above are recognised.
//! Every other CSI (SGR, CUP, ED, …) passes through unchanged — the
//! parser only tracks the modes it cares about and ignores the rest.

const std = @import("std");

pub const AltScreen = struct {
    active: bool = false,
    /// Set to true whenever `active` flips since the last
    /// `takeTransition()` call. The proxy reads + clears this each
    /// iteration so it can converge the slave PTY size + statusbar
    /// state to the new `active` value. Multiple enter/exit toggles
    /// arriving in one `feed()` collapse into a single flag — the
    /// proxy only needs to converge to the FINAL state, not replay
    /// each intermediate flip (replaying would do redundant
    /// `pty.setSize` + `sb.reactivate` calls back-to-back for zero
    /// user-visible benefit; the final state already converges).
    transitioned: bool = false,

    state: State = .ground,
    /// Decimal value of the CSI parameter currently being parsed
    /// (after `?`). Capped at u16 — kitty / xterm DEC private modes
    /// fit comfortably.
    param: u16 = 0,
    /// True while we're inside a `\x1B[?…` private-mode CSI. The
    /// final byte (`h` set / `l` reset) decides what to do with the
    /// accumulated params. Other CSIs (without `?`) are skipped.
    is_private: bool = false,
    /// True if any param we've seen in the *current* CSI matched an
    /// alt-screen mode (47, 1047, 1049). The final `h`/`l` toggles
    /// `active` iff this is true. Tracking it as a sticky flag lets
    /// us handle multi-mode DECSET (`ESC[?1049;1000h`, mouse +
    /// alt-screen in one go) without buffering every param.
    saw_alt_mode: bool = false,

    const State = enum {
        ground,
        esc, // saw 0x1B
        csi, // saw '[' — parameters follow
    };

    pub fn init() AltScreen {
        return .{};
    }

    /// Feed master-output bytes. Idempotent + safe across partial
    /// sequences (state survives feed calls).
    pub fn feed(self: *AltScreen, bytes: []const u8) void {
        for (bytes) |b| self.feedByte(b);
    }

    /// Returns the transition flag and clears it. Use this from the
    /// proxy each iteration:
    ///
    ///     if (alt.takeTransition()) {
    ///         if (alt.active) { ... tear down decstbm ... }
    ///         else            { ... re-apply decstbm + statusbar ... }
    ///     }
    pub fn takeTransition(self: *AltScreen) bool {
        const t = self.transitioned;
        self.transitioned = false;
        return t;
    }

    /// True iff the next escape-free byte chunk is a guaranteed
    /// no-op — the AltScreen state machine only leaves `.ground`
    /// on ESC, so a ground tracker + no-escape chunk produces no
    /// state changes.
    pub fn canFastPath(self: *const AltScreen) bool {
        return self.state == .ground;
    }

    /// No-op skip — AltScreen carries no per-feed counters that
    /// need maintenance during the proxy's fast-path. Defined
    /// for symmetry with `Osc133.onFastPath` / `Osc7.onFastPath`
    /// so the call sites all have the same shape.
    pub fn onFastPath(self: *AltScreen, n: usize) void {
        _ = self;
        _ = n;
    }

    fn feedByte(self: *AltScreen, b: u8) void {
        switch (self.state) {
            .ground => {
                if (b == 0x1B) self.state = .esc;
            },
            .esc => {
                if (b == '[') {
                    self.state = .csi;
                    self.param = 0;
                    self.is_private = false;
                    self.saw_alt_mode = false;
                } else {
                    self.state = .ground;
                }
            },
            .csi => switch (b) {
                '?' => self.is_private = true,
                '0'...'9' => {
                    // Saturating accumulate. Real DEC modes are ≤ ~9999.
                    const d: u16 = b - '0';
                    self.param = self.param *| 10 +| d;
                },
                ';', ':' => {
                    // Multi-parameter CSI separator. xterm combines
                    // private modes — `ESC[?1049;1000h` enables alt
                    // screen AND mouse tracking in one go. Latch
                    // whether THIS param matched an alt-screen mode,
                    // then reset for the next. `is_private` is kept
                    // so subsequent params are still in DEC space.
                    if (self.is_private and isAltMode(self.param)) {
                        self.saw_alt_mode = true;
                    }
                    self.param = 0;
                },
                'h', 'l' => {
                    if (self.is_private) {
                        // Final param hasn't been latched yet — check
                        // it now together with anything we saw earlier
                        // in the sequence.
                        const hit = self.saw_alt_mode or isAltMode(self.param);
                        if (hit) self.applyTransition(b == 'h');
                    }
                    self.state = .ground;
                },
                else => {
                    // Any CSI intermediate / final byte we don't
                    // recognise. 0x40..0x7E is the terminator range;
                    // anything in there ends the CSI.
                    if (b >= 0x40 and b <= 0x7E) self.state = .ground;
                },
            },
        }
    }

    fn applyTransition(self: *AltScreen, set: bool) void {
        if (self.active == set) return; // idempotent set/reset is silent
        self.active = set;
        self.transitioned = true;
    }
};

fn isAltMode(mode: u16) bool {
    return switch (mode) {
        47, 1047, 1049 => true,
        else => false,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

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
