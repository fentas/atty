//! Latches when the master PTY emits a DECSTBM sequence
//! (`CSI <params> r`). atty pins its own scroll region for the
//! reserved statusbar row; an inline TUI that resets or overrides
//! that region would otherwise let the reserved row scroll into
//! visible scrollback on the next `\n`. The proxy drains the latch
//! each tick and re-asserts atty's region via
//! `StatusBar.reassertDecstbm`.
//!
//! Why latch + re-assert per tick instead of intercepting: the
//! inner app's DECSTBM may be load-bearing for its own UI (paginator
//! viewport, split-pane layout). Letting the bytes through and
//! re-asserting on the next tick keeps atty's row pinned while
//! honoring the inner app's scroll-region intent for one redraw
//! cycle.
//!
//! Intermediate-byte filter: a CSI containing an intermediate byte
//! (0x20..0x2F) terminated by `r` — e.g. `CSI $ r` (DECRQSS) — is
//! NOT DECSTBM and must not flag. `saw_intermediate` distinguishes.

const std = @import("std");

pub const DecstbmWatcher = struct {
    clobbered: bool = false,
    state: State = .ground,
    /// Latched mid-CSI when any byte in the ECMA-48 intermediate
    /// range (0x20..0x2F) appears. DECSTBM uses only parameter bytes
    /// (0x30..0x3F) so a true here disqualifies the trailing `r`
    /// from flagging.
    saw_intermediate: bool = false,

    const State = enum { ground, esc, csi };

    pub fn init() DecstbmWatcher {
        return .{};
    }

    pub fn canFastPath(self: *const DecstbmWatcher) bool {
        return self.state == .ground;
    }

    pub fn onFastPath(self: *DecstbmWatcher, n: usize) void {
        _ = self;
        _ = n;
    }

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
                    self.saw_intermediate = false;
                } else {
                    self.state = .ground;
                }
            },
            .csi => {
                if (b >= 0x20 and b <= 0x2F) {
                    // Intermediate byte — sequence is not DECSTBM
                    // regardless of the final byte.
                    self.saw_intermediate = true;
                } else if (b == 'r') {
                    if (!self.saw_intermediate) self.clobbered = true;
                    self.state = .ground;
                } else if (b >= 0x40 and b <= 0x7E) {
                    // Any other terminator ends the CSI silently.
                    self.state = .ground;
                }
                // 0x30..0x3F (params) stay in .csi without side-effect.
            },
        }
    }
};

test {
    _ = @import("decstbm_watcher_tests.zig");
}
