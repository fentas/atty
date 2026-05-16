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
//!
//! Captures are ring-buffered per-feed so the proxy can interleave
//! them with OSC 133 edges in source order. Multiple OSC 7s in one
//! chunk (rare but possible — a shell that emits in both `;A` and
//! `;B` hooks, a pasted multi-line script) each land as a separate
//! captured entry with its own byte offset.

const std = @import("std");

/// Maximum number of OSC 7 captures retained per feed. Each
/// captured path uses `max_path_bytes` of fixed storage. Overflow
/// silently drops further captures (vanishingly rare; in practice
/// one chunk carries 0–2 OSC 7s).
pub const max_captures = 16;
pub const max_path_bytes = 512;

pub const Osc7 = struct {
    state: State = .ground,
    /// Buffer for the OSC payload between `\x1b]7;` and the
    /// terminator. Capped at the same size as Osc133's payload buffer.
    body: [max_path_bytes]u8 = undefined,
    body_len: usize = 0,
    /// Ring of cwd captures from the current feed. The proxy reads
    /// `count`, walks `path(i)` + `offsetAt(i)` for each index, and
    /// then implicitly drains by feeding the next chunk (which
    /// resets `count` to 0).
    cwd_buf: [max_captures][max_path_bytes]u8 = undefined,
    cwd_lens: [max_captures]usize = [_]usize{0} ** max_captures,
    cwd_offsets: [max_captures]u32 = undefined,
    /// `usize` (not `u8`) so the proxy's merge loop compares it
    /// against `usize` indices without coercion hoops. Capped at
    /// `max_captures` (16) — far below u8 range, but the type
    /// match keeps call sites clean.
    count: usize = 0,
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

    /// Path of the i-th capture in the current feed (0-indexed,
    /// 0 ≤ i < count). Borrow valid until the next `feed()` which
    /// may overwrite.
    pub fn path(self: *const Osc7, i: usize) []const u8 {
        return self.cwd_buf[i][0..self.cwd_lens[i]];
    }

    /// Byte offset within the current feed where capture `i` was
    /// produced. Used by the proxy to merge OSC 7 promotion with
    /// OSC 133 edges in source order.
    pub fn offsetAt(self: *const Osc7, i: usize) u32 {
        return self.cwd_offsets[i];
    }

    /// True iff the next escape-free byte chunk is a guaranteed
    /// no-op — Osc7 state machine only leaves `.ground` on ESC.
    pub fn canFastPath(self: *const Osc7) bool {
        return self.state == .ground;
    }

    /// Reset the per-feed capture ring to match what `feed()`
    /// would have done at entry. The proxy reads `count` after
    /// every dispatch and assumes it scopes to the latest chunk
    /// — without this reset, captures from the prior chunk would
    /// re-emit on every subsequent fast-pathed chunk until a
    /// non-fast-pathed feed cleared them. Caller must have
    /// verified `canFastPath()` first.
    pub fn onFastPath(self: *Osc7, n: usize) void {
        _ = n;
        self.count = 0;
    }

    /// Feed master-output bytes. Captures from prior feeds are
    /// cleared at the start so each `feed()` returns a fresh
    /// ring of captures bound to its own byte stream.
    pub fn feed(self: *Osc7, bytes: []const u8) void {
        self.feed_byte_index = 0;
        self.count = 0;
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
        const p: []const u8 = if (std.mem.startsWith(u8, after, "file://")) blk: {
            const after_scheme = after["file://".len..];
            const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return;
            break :blk after_scheme[slash..];
        } else after;
        if (p.len == 0) return;
        // Overflow: silently drop subsequent captures. The proxy
        // would otherwise process stale top-of-buffer cwds at
        // wrong offsets — better to lose the tail than to mis-
        // attribute.
        if (self.count >= max_captures) return;
        const n = @min(p.len, max_path_bytes);
        @memcpy(self.cwd_buf[self.count][0..n], p[0..n]);
        self.cwd_lens[self.count] = n;
        self.cwd_offsets[self.count] = self.feed_byte_index;
        self.count += 1;
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
    try testing.expectEqual(@as(usize, 0), o.count);
}

test "Osc7: BEL-terminated file:// URI is captured" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://host.example.com/home/me/code\x07");
    try testing.expectEqual(@as(usize, 1), o.count);
    try testing.expectEqualStrings("/home/me/code", o.path(0));
}

test "Osc7: ST-terminated file:// URI is captured" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://host/var/log\x1b\\");
    try testing.expectEqual(@as(usize, 1), o.count);
    try testing.expectEqualStrings("/var/log", o.path(0));
}

test "Osc7: partial sequence across multiple feed calls" {
    var o = Osc7.init();
    o.feed("\x1b");
    o.feed("]7;file");
    o.feed("://host/tmp");
    // Each feed RESETS captures; final feed lands the BEL.
    o.feed("\x07");
    try testing.expectEqual(@as(usize, 1), o.count);
    try testing.expectEqualStrings("/tmp", o.path(0));
}

test "Osc7: multiple captures in ONE feed are preserved in order" {
    // Regression: round-9 single-slot semantics silently dropped all
    // but the last OSC 7 in a chunk. The proxy's offset-merge with
    // OSC 133 edges relies on every OSC 7 surviving so it can land
    // on the correct subprocess frame.
    var o = Osc7.init();
    o.feed("\x1b]7;file://h/a\x07between\x1b]7;file://h/b\x07tail");
    try testing.expectEqual(@as(usize, 2), o.count);
    try testing.expectEqualStrings("/a", o.path(0));
    try testing.expectEqualStrings("/b", o.path(1));
    // Offsets are monotonic — second capture lands at a later byte.
    try testing.expect(o.offsetAt(0) < o.offsetAt(1));
}

test "Osc7: next feed resets the capture ring" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://h/x\x07");
    try testing.expectEqual(@as(usize, 1), o.count);
    o.feed("no marker here");
    try testing.expectEqual(@as(usize, 0), o.count);
}

test "Osc7: bare path without file:// prefix is captured" {
    // Rare but seen in some integrations. We accept it.
    var o = Osc7.init();
    o.feed("\x1b]7;/opt/work\x07");
    try testing.expectEqual(@as(usize, 1), o.count);
    try testing.expectEqualStrings("/opt/work", o.path(0));
}

test "Osc7: minimal bare-path `7;/` (root cwd) is accepted" {
    // Regression: an earlier `payload.len < 4` guard rejected the
    // 3-byte minimal valid bare-path payload `7;/`. Sessions
    // currently at root (common on containers / service images)
    // would silently never have their cwd captured.
    var o = Osc7.init();
    o.feed("\x1b]7;/\x07");
    try testing.expectEqual(@as(usize, 1), o.count);
    try testing.expectEqualStrings("/", o.path(0));
}

test "Osc7: non-7 OSC sequences are ignored" {
    var o = Osc7.init();
    o.feed("\x1b]0;window title\x07");
    o.feed("\x1b]2;another title\x07");
    o.feed("\x1b]133;A\x07"); // prompt marker, handled elsewhere
    try testing.expectEqual(@as(usize, 0), o.count);
}

test "Osc7: malformed 7; without slash returns no cwd" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://nohost\x07");
    try testing.expectEqual(@as(usize, 0), o.count);
}

test "Osc7: truncated (no terminator yet) doesn't crash" {
    var o = Osc7.init();
    o.feed("\x1b]7;file://h/path"); // no BEL or ST
    try testing.expectEqual(@as(usize, 0), o.count);
    // Now finish.
    o.feed("\x07");
    try testing.expectEqual(@as(usize, 1), o.count);
    try testing.expectEqualStrings("/path", o.path(0));
}

test "Osc7: ESC inside OSC body that isn't ST terminator resets" {
    // `\x1b]7;file://h/path\x1bABC...` — the inner `\x1b` not followed
    // by `\` aborts the OSC. Subsequent input recovers.
    var o = Osc7.init();
    o.feed("\x1b]7;file://h/old\x1bX");
    try testing.expectEqual(@as(usize, 0), o.count);
    o.feed("\x1b]7;file://h/new\x07");
    try testing.expectEqual(@as(usize, 1), o.count);
    try testing.expectEqualStrings("/new", o.path(0));
}

test "Osc7: capture overflow drops the tail (rare; 16 OSC 7s in one chunk)" {
    // Build a single feed buffer of N OSC 7s. The ring caps at
    // `max_captures` (16); the rest are silently dropped at the
    // tail (rare; in practice one chunk carries 0–2 OSC 7s).
    const each = "\x1b]7;/p\x07"; // 7 bytes
    const repeats: usize = max_captures + 3;
    var buf: [repeats * each.len]u8 = undefined;
    var off: usize = 0;
    var i: usize = 0;
    while (i < repeats) : (i += 1) {
        @memcpy(buf[off .. off + each.len], each);
        off += each.len;
    }
    var o = Osc7.init();
    o.feed(buf[0..off]);
    try testing.expectEqual(@as(usize, max_captures), o.count);
}

test "Osc7.canFastPath + onFastPath — fast-path contract" {
    var o = Osc7.init();
    try testing.expect(o.canFastPath());
    o.feed("plain output with no escapes\nstill no escapes\n");
    try testing.expect(o.canFastPath());
    o.feed("\x1b]7;file://"); // mid-OSC
    try testing.expect(!o.canFastPath());
    o.feed("host/path\x07");
    try testing.expect(o.canFastPath());
}

test "Osc7.onFastPath clears stale captures (regression: re-emit on fast-pathed chunk)" {
    // feed() resets `count` at entry; the proxy reads `count`
    // after each dispatch and assumes it scopes to the latest
    // chunk. Without onFastPath clearing the count, a prior
    // chunk's captures would re-emit on every subsequent fast-
    // pathed chunk until a non-fast-pathed feed replaced them.
    var o = Osc7.init();
    o.feed("\x1b]7;file://host/a\x07\x1b]7;file://host/b\x07");
    try testing.expectEqual(@as(usize, 2), o.count);
    o.onFastPath(4096);
    try testing.expectEqual(@as(usize, 0), o.count);
}
