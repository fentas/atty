//! OSC 133 — semantic prompt-zone markers.
//!
//! The wire protocol (originated in iTerm, adopted by VS Code, kitty,
//! Ghostty's shell-integration, ble.sh, zsh4humans, fig, …):
//!
//!     \x1b]133;A\x07       — prompt start
//!     \x1b]133;B\x07       — input region begins (user can type)
//!     \x1b]133;C\x07       — command execution starts (user pressed Enter)
//!     \x1b]133;D[;<code>]\x07 — command finished
//!
//! Terminators: BEL (0x07) or ST (ESC '\'). atty handles both.
//!
//! Why we care: between `;B` and `;C`, anything printable the shell
//! emits is the user's INPUT line as the shell sees it — including
//! history-recalled text. Atty's keystroke tracking goes blind on
//! Up-arrow / Tab-completion / paste / `!!` expansion; the markers
//! close that gap with zero guessing.
//!
//! Fallback: if the shell never emits 133 markers, `active` stays
//! false and the proxy keeps using its keystroke-based line model.
//! The user enables them shell-side; atty auto-detects and adopts.

const std = @import("std");

pub const Osc133 = struct {
    allocator: std.mem.Allocator,
    /// True once we've seen any well-formed 133 marker. Sticky for
    /// the lifetime of the session — the gate the proxy uses to
    /// decide whether to trust currentInput() over its keystroke
    /// buffer.
    active: bool = false,
    /// Captured printable bytes between the last `;B` and now. CR
    /// (line redraw) clears it; BS drops one byte; other CSI/OSC
    /// sequences are absorbed without polluting it.
    input: std.ArrayList(u8) = .empty,

    state: State = .ground,
    phase: Phase = .idle,
    osc_buf: [256]u8 = undefined,
    osc_len: usize = 0,

    const State = enum {
        ground, // regular input-byte processing (when in input phase)
        esc, // saw 0x1B; next byte chooses sub-state
        csi, // inside `\x1b[…final`
        osc, // inside `\x1b]…`
        osc_esc, // saw 0x1B inside osc; awaiting '\' (ST)
    };
    const Phase = enum {
        idle, // outside any prompt/command zone
        in_input, // between ;B and ;C — capturing input
        in_command, // between ;C and ;D — command running, ignore output
    };

    pub fn init(allocator: std.mem.Allocator) Osc133 {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Osc133) void {
        self.input.deinit(self.allocator);
    }

    /// Read of the captured input region. Empty when no `;B` has
    /// fired yet, or when the line was just cleared via CR.
    pub fn currentInput(self: *const Osc133) []const u8 {
        return self.input.items;
    }

    /// Feed master-output bytes. Idempotent + safe across partial
    /// sequences (state survives feed calls).
    pub fn feed(self: *Osc133, bytes: []const u8) void {
        for (bytes) |b| self.feedByte(b);
    }

    fn feedByte(self: *Osc133, b: u8) void {
        switch (self.state) {
            .ground => {
                if (b == 0x1B) {
                    self.state = .esc;
                    return;
                }
                if (self.phase != .in_input) return;
                self.processInputByte(b);
            },
            .esc => switch (b) {
                ']' => {
                    self.state = .osc;
                    self.osc_len = 0;
                },
                '[' => self.state = .csi,
                else => self.state = .ground,
            },
            .csi => {
                // Skip the CSI body — its bytes don't belong in
                // the input region. The final byte is in 0x40..0x7E.
                if (b >= 0x40 and b <= 0x7E) self.state = .ground;
            },
            .osc => {
                if (b == 0x07) {
                    self.dispatchOsc();
                    self.state = .ground;
                } else if (b == 0x1B) {
                    self.state = .osc_esc;
                } else if (self.osc_len < self.osc_buf.len) {
                    self.osc_buf[self.osc_len] = b;
                    self.osc_len += 1;
                }
            },
            .osc_esc => {
                if (b == '\\') {
                    self.dispatchOsc();
                    self.state = .ground;
                } else {
                    self.state = .ground;
                }
            },
        }
    }

    fn processInputByte(self: *Osc133, b: u8) void {
        switch (b) {
            0x0D => self.input.clearRetainingCapacity(), // CR — line redraw
            0x08 => if (self.input.items.len > 0) {
                _ = self.input.pop();
            }, // BS — drop last
            else => {
                if (b >= 0x20 and b < 0x7F) {
                    self.input.append(self.allocator, b) catch return;
                }
                // Skip everything else (LF, control bytes, non-ASCII for now).
            },
        }
    }

    fn dispatchOsc(self: *Osc133) void {
        const body = self.osc_buf[0..self.osc_len];
        if (!std.mem.startsWith(u8, body, "133;")) return;
        if (body.len < 5) return;
        self.active = true;
        switch (body[4]) {
            'A' => self.phase = .idle, // prompt drawing — input not yet open
            'B' => {
                self.phase = .in_input;
                self.input.clearRetainingCapacity();
            },
            'C' => self.phase = .in_command,
            'D' => self.phase = .idle,
            else => {}, // unknown 133 subtype
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Osc133: active stays false until any 133 marker arrives" {
    var o = Osc133.init(testing.allocator);
    defer o.deinit();
    o.feed("hello \x1b[1;36mcolor\x1b[0m \x1b]0;title\x07more");
    try testing.expect(!o.active);
    try testing.expectEqual(@as(usize, 0), o.currentInput().len);
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
