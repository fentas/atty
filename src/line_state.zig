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
    }

    pub fn reset(self: *LineState) void {
        self.len = 0;
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
                // movement or history navigation we don't model.
                self.uncertain = true;
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
                0x09 => self.uncertain = true,
                // Any other control byte we don't model. The ranges are
                // carefully carved around the codes we *do* handle above.
                0x00, 0x01, 0x02, 0x05, 0x06, 0x0B, 0x0C, 0x0E...0x14, 0x16, 0x18, 0x19, 0x1A, 0x1C...0x1F => {
                    self.uncertain = true;
                },
                // Lone ESC (no '[' follower).
                0x1B => self.uncertain = true,
                // Printable.
                else => self.append(b),
            }
            i += 1;
        }
        return self.generation != start_gen or self.uncertain;
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
        self.generation +%= 1;
    }

    fn killLine(self: *LineState) void {
        if (self.len == 0) return;
        self.len = 0;
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
            self.generation +%= 1;
        }
    }

    fn submit(self: *LineState) void {
        // Snapshot the pre-Enter line so onLineCommit hooks can fire
        // after applyInput. Overwrites any prior un-consumed snapshot —
        // if two Enters land in one read, only the latest non-empty
        // line is recorded, which matches what a human would expect.
        if (self.len > 0) {
            @memcpy(self.committed[0..self.len], self.buffer[0..self.len]);
            self.committed_len = self.len;
            self.committed_was_uncertain = self.uncertain;
        }
        self.len = 0;
        self.uncertain = false;
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
