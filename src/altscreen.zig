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
// Tests — extracted to `altscreen_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("altscreen_tests.zig");
}
