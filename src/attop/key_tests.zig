const std = @import("std");
const testing = std.testing;
const mod = @import("key.zig");
const Key = mod.Key;
const decode = mod.decode;

fn one(bytes: []const u8) Key {
    return decode(bytes).?.key;
}

test "decode: printables + enter/tab/backspace" {
    try testing.expectEqual(Key{ .char = 'q' }, one("q"));
    try testing.expectEqual(Key.enter, one("\r"));
    try testing.expectEqual(Key.enter, one("\n"));
    try testing.expectEqual(Key.tab, one("\t"));
    try testing.expectEqual(Key.backspace, one("\x7f"));
    try testing.expectEqual(Key.backspace, one("\x08"));
}

test "decode: Ctrl-letters" {
    try testing.expectEqual(Key{ .ctrl = 'c' }, one("\x03"));
    try testing.expectEqual(Key{ .ctrl = 'd' }, one("\x04"));
    try testing.expectEqual(Key{ .ctrl = 'u' }, one("\x15"));
}

test "decode: lone ESC is Escape" {
    try testing.expectEqual(Key.escape, one("\x1b"));
    // ESC + an unrelated byte → Escape consumes just the ESC; the next
    // byte decodes on its own.
    const d = decode("\x1bx").?;
    try testing.expectEqual(Key.escape, d.key);
    try testing.expectEqual(@as(usize, 1), d.len);
    try testing.expectEqual(Key{ .char = 'x' }, one("\x1bx"[d.len..]));
}

test "decode: CSI arrows + Home/End" {
    try testing.expectEqual(Key.up, one("\x1b[A"));
    try testing.expectEqual(Key.down, one("\x1b[B"));
    try testing.expectEqual(Key.right, one("\x1b[C"));
    try testing.expectEqual(Key.left, one("\x1b[D"));
    try testing.expectEqual(Key.home, one("\x1b[H"));
    try testing.expectEqual(Key.end, one("\x1b[F"));
}

test "decode: Shift+Tab (CSI Z) + SS3 arrows" {
    try testing.expectEqual(Key.back_tab, one("\x1b[Z"));
    try testing.expectEqual(Key.up, one("\x1bOA"));
    try testing.expectEqual(Key.left, one("\x1bOD"));
}

test "decode: tilde keys (Home/End/PgUp/PgDn) with modifiers" {
    try testing.expectEqual(Key.home, one("\x1b[1~"));
    try testing.expectEqual(Key.end, one("\x1b[4~"));
    try testing.expectEqual(Key.page_up, one("\x1b[5~"));
    try testing.expectEqual(Key.page_down, one("\x1b[6~"));
    // Modified form (e.g. Ctrl+End = ESC [ 4 ; 5 ~) still classifies by
    // the leading param — close enough for nav.
    try testing.expectEqual(Key.end, one("\x1b[4;5~"));
}

test "decode: unknown CSI is consumed, not leaked" {
    const d = decode("\x1b[200~rest").?; // bracketed-paste start — not bound
    try testing.expectEqual(Key.unknown, d.key);
    try testing.expectEqual(@as(usize, 6), d.len); // consumed through the ~
}

test "decode: drains a multi-key read left-to-right" {
    const bytes = "j\x1b[Bk";
    var i: usize = 0;
    var keys: [8]Key = undefined;
    var n: usize = 0;
    while (mod.decode(bytes[i..])) |d| {
        keys[n] = d.key;
        n += 1;
        i += d.len;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(Key{ .char = 'j' }, keys[0]);
    try testing.expectEqual(Key.down, keys[1]);
    try testing.expectEqual(Key{ .char = 'k' }, keys[2]);
}

test "decode: empty slice yields null" {
    try testing.expect(mod.decode("") == null);
}
