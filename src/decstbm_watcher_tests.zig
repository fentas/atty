const std = @import("std");
const testing = std.testing;
const mod = @import("decstbm_watcher.zig");
const DecstbmWatcher = mod.DecstbmWatcher;

test "no CSI never flags" {
    var w = DecstbmWatcher.init();
    w.feed("hello world\n");
    try testing.expect(!w.takeClobbered());
}

test "DECSTBM reset \\x1b[r flags" {
    var w = DecstbmWatcher.init();
    w.feed("\x1B[r");
    try testing.expect(w.takeClobbered());
}

test "DECSTBM with parameters \\x1b[10;20r flags" {
    var w = DecstbmWatcher.init();
    w.feed("\x1B[10;20r");
    try testing.expect(w.takeClobbered());
}

test "non-DECSTBM CSI does not flag" {
    var w = DecstbmWatcher.init();
    w.feed("\x1B[31m"); // SGR red
    w.feed("\x1B[2J"); // ED clear-screen
    w.feed("\x1B[H"); // CUP home
    w.feed("\x1B[?25l"); // hide cursor
    try testing.expect(!w.takeClobbered());
}

test "takeClobbered clears the latch" {
    var w = DecstbmWatcher.init();
    w.feed("\x1B[r");
    try testing.expect(w.takeClobbered());
    try testing.expect(!w.takeClobbered());
}

test "split across feed boundary still flags" {
    // CSI 'r' straddles a read boundary — the state machine has
    // to survive across feed calls.
    var w = DecstbmWatcher.init();
    w.feed("\x1B[1;2");
    try testing.expect(!w.takeClobbered());
    w.feed("0");
    try testing.expect(!w.takeClobbered());
    w.feed("r");
    try testing.expect(w.takeClobbered());
}

test "ESC outside a CSI is ignored" {
    var w = DecstbmWatcher.init();
    w.feed("\x1Bc"); // RIS — full reset, not a CSI
    try testing.expect(!w.takeClobbered());
}

test "interleaved sequences only flag the r ones" {
    var w = DecstbmWatcher.init();
    w.feed("normal text \x1B[31mred\x1B[0m more \x1B[1;5rscroll \x1B[H");
    try testing.expect(w.takeClobbered());
    // Next call: no additional CSIs, should be clear.
    try testing.expect(!w.takeClobbered());
}

test "canFastPath true on ground, false inside ESC/CSI" {
    var w = DecstbmWatcher.init();
    try testing.expect(w.canFastPath());
    w.feed("\x1B");
    try testing.expect(!w.canFastPath());
    w.feed("[31m"); // back to ground after final byte
    try testing.expect(w.canFastPath());
}

test "intermediate-byte CSIs ending in r do not flag" {
    // ECMA-48 intermediate bytes (0x20..0x2F) appearing mid-CSI
    // disqualify the trailing `r` from being DECSTBM. The canonical
    // example is `CSI $ r` (DECRQSS response). Without this filter
    // every DECRQSS reply from the terminal would trigger a
    // spurious reassert.
    var w = DecstbmWatcher.init();
    w.feed("\x1B[$r");
    try testing.expect(!w.takeClobbered());

    // With parameters before the intermediate.
    w.feed("\x1B[1;5$r");
    try testing.expect(!w.takeClobbered());

    // Sanity: a clean DECSTBM after the intermediate-byte CSIs still
    // flags. Confirms `saw_intermediate` resets per CSI (the `[` arm
    // clears it on each new sequence).
    w.feed("\x1B[r");
    try testing.expect(w.takeClobbered());
}
