const std = @import("std");
const testing = std.testing;
const mod = @import("mouse.zig");
const parse = mod.parse;

test "left-click press at (5, 10)" {
    // Cb=0 (left), col=5, row=10, M=press
    const seq = "\x1b[<0;5;10M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.left, r.event.button);
    try testing.expectEqual(mod.Kind.press, r.event.kind);
    try testing.expectEqual(@as(u16, 5), r.event.col);
    try testing.expectEqual(@as(u16, 10), r.event.row);
    try testing.expectEqual(false, r.event.mods.shift);
    try testing.expectEqual(seq.len, r.consumed);
}

test "left-click release uses lowercase m" {
    const seq = "\x1b[<0;5;10m";
    const r = try parse(seq);
    try testing.expectEqual(mod.Kind.release, r.event.kind);
    try testing.expectEqual(mod.Button.left, r.event.button);
}

test "ctrl+shift+left-click at (1, 1)" {
    // Cb = 0 | shift(4) | ctrl(16) = 20
    const seq = "\x1b[<20;1;1M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.left, r.event.button);
    try testing.expectEqual(true, r.event.mods.shift);
    try testing.expectEqual(true, r.event.mods.ctrl);
    try testing.expectEqual(false, r.event.mods.alt);
}

test "right-click press" {
    // Cb=2 (right), col=80, row=24
    const seq = "\x1b[<2;80;24M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.right, r.event.button);
    try testing.expectEqual(mod.Kind.press, r.event.kind);
}

test "middle-click press" {
    const seq = "\x1b[<1;40;12M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.middle, r.event.button);
}

test "wheel up classifies as wheel_up button" {
    // Cb = 64 (wheel) + 0 (up direction)
    const seq = "\x1b[<64;10;5M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.wheel_up, r.event.button);
    try testing.expectEqual(mod.Kind.press, r.event.kind);
}

test "wheel down classifies as wheel_down" {
    // Cb = 64 (wheel) + 1 (down direction) = 65
    const seq = "\x1b[<65;10;5M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.wheel_down, r.event.button);
}

test "horizontal wheel left = wheel_left" {
    // Cb = 64 (wheel) + 2 (left direction) = 66
    const seq = "\x1b[<66;10;5M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.wheel_left, r.event.button);
}

test "horizontal wheel right = wheel_right" {
    // Cb = 64 (wheel) + 3 (right direction) = 67
    const seq = "\x1b[<67;10;5M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.wheel_right, r.event.button);
}

test "ctrl+wheel up — modifier on scroll for zoom workflow" {
    // Cb = 64 (wheel) + 0 (up) + 16 (ctrl) = 80
    const seq = "\x1b[<80;10;5M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.wheel_up, r.event.button);
    try testing.expectEqual(true, r.event.mods.ctrl);
}

test "extended buttons 9, 10, 11 all decode" {
    const seq9 = "\x1b[<129;1;1M";
    const r9 = try parse(seq9);
    try testing.expectEqual(mod.Button.extended_9, r9.event.button);
    const seq10 = "\x1b[<130;1;1M";
    const r10 = try parse(seq10);
    try testing.expectEqual(mod.Button.extended_10, r10.event.button);
    const seq11 = "\x1b[<131;1;1M";
    const r11 = try parse(seq11);
    try testing.expectEqual(mod.Button.extended_11, r11.event.button);
}

test "parse rejects non-mouse sequence with full length" {
    // 6+ bytes but wrong prefix — exercises the prefix-mismatch
    // branch at mouse.zig:80, not the length short-circuit.
    const result = parse("\x1b[?1u  ");
    try testing.expectError(error.NotMouseSequence, result);
}

test "parse rejects empty numeric field" {
    // Empty Cb between `<` and `;` — exercises readU16's
    // any=false branch (no digits at all).
    const result = parse("\x1b[<;5;10M");
    try testing.expectError(error.Malformed, result);
}

test "drag press combined with motion bit" {
    // Cb = 0 (left) + 32 (motion) = 32, trailer M (motion-press → drag)
    const seq = "\x1b[<32;15;7M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.left, r.event.button);
    try testing.expectEqual(mod.Kind.drag, r.event.kind);
}

test "extended button 8" {
    // Cb = 128 (extended) + 0 = 128
    const seq = "\x1b[<128;1;1M";
    const r = try parse(seq);
    try testing.expectEqual(mod.Button.extended_8, r.event.button);
}

test "peekIsMouse fires on the prefix" {
    try testing.expect(mod.peekIsMouse("\x1b[<0;1;1M"));
    try testing.expect(!mod.peekIsMouse("\x1b[1u")); // kitty kbd CSI-u
    try testing.expect(!mod.peekIsMouse(""));
}

test "parse rejects non-mouse sequence" {
    const result = parse("\x1b[1u");
    try testing.expectError(error.NotMouseSequence, result);
}

test "parse rejects malformed (missing semi)" {
    const result = parse("\x1b[<0510M");
    try testing.expectError(error.Malformed, result);
}

test "parse rejects bad trailer" {
    const result = parse("\x1b[<0;5;10X");
    try testing.expectError(error.BadTrailer, result);
}

test "parse rejects coord overflow" {
    // 99999 > u16 max (65535)
    const result = parse("\x1b[<0;99999;10M");
    try testing.expectError(error.Overflow, result);
}

test "consumed length matches sequence length" {
    const seq = "\x1b[<20;500;300m";
    const r = try parse(seq);
    try testing.expectEqual(seq.len, r.consumed);
}
