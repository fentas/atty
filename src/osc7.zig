//! OSC 7 — current working directory reports.
//!
//! Many shell-integration emitters announce the shell's cwd via:
//!
//!     \x1b]7;file://<host>/<path>\x07         (BEL-terminated)
//!     \x1b]7;file://<host>/<path>\x1b\\       (ST-terminated)
//!
//! Sources we've seen in the wild emitting OSC 7:
//!   - Ghostty's `shell-integration-features = cursor`
//!   - VS Code's shell integration
//!   - ble.sh
//!   - zsh4humans
//!   - kitty's shell integration
//!   - many ad-hoc PROMPT_COMMAND snippets
//!
//! When the user is inside `ssh remote` and the remote shell sources
//! one of these, the OSC 7 bytes flow through atty's local PTY in
//! the master→stdout stream. We parse them and feed the resulting
//! path into `subprocess.Tracker.onRemoteCwd` so subsequent
//! recorded commits can be tagged with the actual remote cwd.
//!
//! This tracker is a tiny state machine — partial-sequence safe
//! across `feed()` calls. We deliberately don't try to validate the
//! URI's host part: atty already knows the resolved host from the
//! `;C` ssh parse, the OSC 7 host is redundant info. We only
//! need the path so the modules' `--cwd` builders can append it.

const std = @import("std");

pub const Osc7 = struct {
    state: State = .ground,
    /// Buffer for the OSC payload between `\x1b]7;` and the
    /// terminator. Capped at the same size as Osc133's payload buffer.
    body: [512]u8 = undefined,
    body_len: usize = 0,
    /// Filled in by `dispatchOsc` when a well-formed `file://...`
    /// arrives. Caller reads via `takeCwd()` which clears the buffer.
    cwd_buf: [512]u8 = undefined,
    cwd_len: usize = 0,
    cwd_pending: bool = false,
    /// Byte offset within the most recent `feed()` where the
    /// pending cwd was captured. The proxy reads this to interleave
    /// the cwd promotion with OSC 133 push/pop in source order
    /// (otherwise an OSC 7 captured BEFORE a `;C` in the same chunk
    /// would land on the new frame instead of the old one).
    cwd_offset: u32 = 0,
    /// Byte index within the current `feed()` call — incremented
    /// per byte. Reset on every feed.
    feed_byte_index: u32 = 0,

    const State = enum {
        ground,
        esc, // saw 0x1B
        osc, // inside `\x1b]…`
        osc_esc, // saw 0x1B inside osc; awaiting `\` for ST
    };

    pub fn init() Osc7 {
        return .{};
    }

    /// Read + clear the pending cwd if one arrived. Empty slice when
    /// there's nothing new. Caller copies before next `feed()` if it
    /// wants to keep the bytes.
    pub fn takeCwd(self: *Osc7) []const u8 {
        if (!self.cwd_pending) return &[_]u8{};
        self.cwd_pending = false;
        return self.cwd_buf[0..self.cwd_len];
    }

    /// Feed master-output bytes. State survives partial sequences
    /// across calls so the parser is robust to `read()` boundaries.
    pub fn feed(self: *Osc7, bytes: []const u8) void {
        self.feed_byte_index = 0;
        for (bytes) |b| {
            self.feedByte(b);
            self.feed_byte_index += 1;
        }
    }

    fn feedByte(self: *Osc7, b: u8) void {
        switch (self.state) {
            .ground => {
                if (b == 0x1B) self.state = .esc;
            },
            .esc => {
                if (b == ']') {
                    self.state = .osc;
                    self.body_len = 0;
                } else {
                    self.state = .ground;
                }
            },
            .osc => {
                if (b == 0x07) {
                    self.dispatchOsc();
                    self.state = .ground;
                } else if (b == 0x1B) {
                    self.state = .osc_esc;
                } else if (self.body_len < self.body.len) {
                    self.body[self.body_len] = b;
                    self.body_len += 1;
                }
            },
            .osc_esc => {
                if (b == '\\') {
                    self.dispatchOsc();
                }
                self.state = .ground;
            },
        }
    }

    fn dispatchOsc(self: *Osc7) void {
        const payload = self.body[0..self.body_len];
        // We accept `7;file://...` (the standard form) and the
        // bare-path variant `7;/some/path` some emitters use.
        // Reject anything else — other OSC numbers (0/1/2 title,
        // 8 hyperlink, 133 prompt markers, …) flow through the
        // local proxy unmodified; they're handled elsewhere or
        // just forwarded.
        //
        // Minimum valid payload is `7;/` (3 bytes, root cwd in
        // bare form) — the earlier `payload.len < 4` guard
        // rejected that valid case. Now: just require the `7;`
        // prefix and a non-empty path after parsing.
        if (!std.mem.startsWith(u8, payload, "7;")) return;
        const after = payload[2..];
        // Some emitters (rare) omit the file:// prefix and just send
        // a bare path. We accept both forms.
        const path: []const u8 = if (std.mem.startsWith(u8, after, "file://")) blk: {
            const after_scheme = after["file://".len..];
            const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return;
            break :blk after_scheme[slash..];
        } else after;
        if (path.len == 0) return;
        const n = @min(path.len, self.cwd_buf.len);
        @memcpy(self.cwd_buf[0..n], path[0..n]);
        self.cwd_len = n;
        self.cwd_pending = true;
        self.cwd_offset = self.feed_byte_index;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Osc7: plain output leaves state untouched" {
    var o = Osc7.init();
    o.feed("hello world\r\n");
    o.feed("\x1b[1;36mcolored\x1b[0m");
    try testing.expectEqual(@as(usize, 0), o.takeCwd().len);
}

test "Osc7: BEL-terminated file:// URI is captured" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://host.example.com/home/me/code\x07");
    try testing.expectEqualStrings("/home/me/code", o.takeCwd());
}

test "Osc7: ST-terminated file:// URI is captured" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://host/var/log\x1b\\");
    try testing.expectEqualStrings("/var/log", o.takeCwd());
}

test "Osc7: partial sequence across multiple feed calls" {
    var o = Osc7.init();
    o.feed("\x1b");
    o.feed("]7;file");
    o.feed("://host/tmp");
    o.feed("\x07");
    try testing.expectEqualStrings("/tmp", o.takeCwd());
}

test "Osc7: subsequent OSC 7 overrides the previous" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://h/a\x07");
    o.feed("\x1b]7;file://h/b\x07");
    try testing.expectEqualStrings("/b", o.takeCwd());
}

test "Osc7: takeCwd clears the pending flag" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://h/x\x07");
    _ = o.takeCwd();
    try testing.expectEqual(@as(usize, 0), o.takeCwd().len);
}

test "Osc7: bare path without file:// prefix is captured" {
    // Rare but seen in some integrations. We accept it.
    var o = Osc7.init();
    o.feed("\x1b]7;/opt/work\x07");
    try testing.expectEqualStrings("/opt/work", o.takeCwd());
}

test "Osc7: minimal bare-path `7;/` (root cwd) is accepted" {
    // Regression: an earlier `payload.len < 4` guard rejected the
    // 3-byte minimal valid bare-path payload `7;/`. Sessions
    // currently at root (common on containers / service images)
    // would silently never have their cwd captured.
    var o = Osc7.init();
    o.feed("\x1b]7;/\x07");
    try testing.expectEqualStrings("/", o.takeCwd());
}

test "Osc7: non-7 OSC sequences are ignored" {
    var o = Osc7.init();
    o.feed("\x1b]0;window title\x07");
    o.feed("\x1b]2;another title\x07");
    o.feed("\x1b]133;A\x07"); // prompt marker, handled elsewhere
    try testing.expectEqual(@as(usize, 0), o.takeCwd().len);
}

test "Osc7: malformed 7; without slash returns no cwd" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://nohost\x07");
    try testing.expectEqual(@as(usize, 0), o.takeCwd().len);
}

test "Osc7: truncated (no terminator yet) doesn't crash" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://h/path"); // no BEL or ST
    try testing.expectEqual(@as(usize, 0), o.takeCwd().len);
    // Now finish.
    o.feed("\x07");
    try testing.expectEqualStrings("/path", o.takeCwd());
}

test "Osc7: ESC inside OSC body that isn't ST terminator resets" {
    // `\x1b]7;file://h/path\x1bABC...` — the inner `\x1b` not followed
    // by `\` aborts the OSC. Subsequent input recovers.
    var o = Osc7.init();
    o.feed("\x1b]7;file://h/old\x1bX");
    try testing.expectEqual(@as(usize, 0), o.takeCwd().len);
    o.feed("\x1b]7;file://h/new\x07");
    try testing.expectEqualStrings("/new", o.takeCwd());
}
