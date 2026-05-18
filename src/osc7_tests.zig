//! Tests for `osc7.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("osc7.zig");

// Re-binds of pub decls so test bodies stay short.
const max_captures = mod.max_captures;
const max_path_bytes = mod.max_path_bytes;
const Osc7 = mod.Osc7;

// ===========================================================================
// Tests
// ===========================================================================

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
