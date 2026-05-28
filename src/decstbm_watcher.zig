//! DECSTBM-clobber watcher (issue #249).
//!
//! atty pins a scroll region with `\x1B[1;<effectiveRows>r` so the
//! statusbar's reserved bottom row stays put when the shell scrolls.
//! Most TUIs respect this; some — notably **inline** TUIs like Claude
//! Code that paint over the primary screen rather than swapping to
//! the alt-screen buffer — emit their own DECSTBM (`\x1B[r` to reset
//! to full grid, or `\x1B[<top>;<bottom>r` for a custom region) and
//! atty's reservation evaporates. Subsequent `\n` from the inner app
//! scrolls atty's statusbar content into the visible scrollback,
//! producing the duplicate-statusbar artefact in #249.
//!
//! The alt-screen tracker doesn't help here because no `?1049h` is
//! ever emitted — the inner app never leaves the primary screen.
//! This watcher is the missing piece: it scans master→stdout bytes
//! for ANY CSI with final byte `r` (the DECSTBM terminator) and
//! latches a "DECSTBM has been touched by someone other than us"
//! flag. The proxy consumes the flag each tick and re-asserts atty's
//! own DECSTBM via `StatusBar.reassertDecstbm` so the next scroll
//! from the inner app stays inside our reserved region again.
//!
//! Why latch + re-assert per tick (vs. intercept the bytes before
//! forwarding): the inner app's DECSTBM may be load-bearing for its
//! own UI (a paginator's viewport region, for instance). Stripping
//! it would break the app. Letting it through + re-asserting on the
//! next tick keeps atty's row protected while honoring the app's
//! own scroll-region intent for a single redraw cycle. The visible
//! cost is one frame where atty's row could be scrolled into
//! scrollback — that's the trade-off for not interfering with the
//! inner app's terminal control.
//!
//! Mirrors `altscreen.zig`'s state-machine shape so the proxy can
//! invoke the same `canFastPath` / `onFastPath` / `feed` rhythm.

const std = @import("std");

pub const DecstbmWatcher = struct {
    /// Flipped to true on any external CSI...r. Cleared by
    /// `takeClobbered()`. atty's own DECSTBM emissions never go
    /// through `feed()` (they go directly to STDOUT), so this only
    /// flags inner-app activity.
    clobbered: bool = false,

    state: State = .ground,

    const State = enum {
        ground,
        esc,
        csi,
    };

    pub fn init() DecstbmWatcher {
        return .{};
    }

    /// True iff the next escape-free byte chunk is a guaranteed
    /// no-op — only ESC can leave `.ground`, so a ground watcher +
    /// no-escape chunk produces no state changes. Matches
    /// `AltScreen.canFastPath` so the proxy can guard both feeds
    /// behind a single ESC scan.
    pub fn canFastPath(self: *const DecstbmWatcher) bool {
        return self.state == .ground;
    }

    pub fn onFastPath(self: *DecstbmWatcher, n: usize) void {
        _ = self;
        _ = n;
    }

    /// Returns the clobbered flag and clears it. The proxy reads
    /// this each tick; if true, it calls
    /// `StatusBar.reassertDecstbm(writer)` before the next render
    /// so the inner app's scroll region override doesn't survive
    /// the next poll iteration.
    pub fn takeClobbered(self: *DecstbmWatcher) bool {
        const c = self.clobbered;
        self.clobbered = false;
        return c;
    }

    pub fn feed(self: *DecstbmWatcher, bytes: []const u8) void {
        for (bytes) |b| self.feedByte(b);
    }

    fn feedByte(self: *DecstbmWatcher, b: u8) void {
        switch (self.state) {
            .ground => {
                if (b == 0x1B) self.state = .esc;
            },
            .esc => {
                if (b == '[') {
                    self.state = .csi;
                } else {
                    self.state = .ground;
                }
            },
            .csi => {
                // Skip parameter bytes (0x30..0x3F) and intermediate
                // bytes (0x20..0x2F). 'r' is the DECSTBM final byte;
                // any other final byte (0x40..0x7E) ends the CSI
                // without flagging.
                if (b == 'r') {
                    self.clobbered = true;
                    self.state = .ground;
                } else if (b >= 0x40 and b <= 0x7E) {
                    self.state = .ground;
                }
                // else: still inside parameters/intermediates, stay
                // in .csi.
            },
        }
    }
};

test {
    _ = @import("decstbm_watcher_tests.zig");
}
