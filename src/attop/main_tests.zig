const std = @import("std");
const testing = std.testing;
const mod = @import("main.zig");

test "paintTabBar lists every panel + reverse-videos the focused one" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try mod.paintTabBar(&w, 0); // focus on the first panel (Home)
    const out = buf[0..w.end];

    // All five default panels appear, with their nav-key hint.
    for ([_][]const u8{ "[h]Home", "[g]Guard", "[f]Fleet", "[s]Setup", "[?]Help" }) |label| {
        try testing.expect(std.mem.indexOf(u8, out, label) != null);
    }
    // The focused panel is wrapped in reverse video (SGR 7 / 27).
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[7m [h]Home \x1b[27m") != null);
    // A non-focused panel is NOT reverse-videoed.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[7m [g]Guard") == null);
}

/// Visible columns in a tab-bar render: skip SGR escapes (`\x1b[…m`) and
/// newlines, count the rest. The ground truth tabAtCol must agree with.
fn visibleWidth(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and s[i] != 'm') i += 1;
            if (i < s.len) i += 1; // consume the 'm'
        } else if (s[i] == '\r' or s[i] == '\n') {
            i += 1;
        } else {
            n += 1;
            i += 1;
        }
    }
    return n;
}

fn tabBarCovered(focus: usize) u16 {
    var col: u16 = 1;
    while (mod.tabAtCol(focus, col) != null) col += 1;
    return col - 1; // first uncovered col − 1 = covered width
}

test "tabAtCol covers exactly the tab bar's visible width (no drift)" {
    var buf: [512]u8 = undefined;
    inline for (.{ 0, 2 }) |focus| {
        var w = std.Io.Writer.fixed(&buf);
        try mod.paintTabBar(&w, focus);
        // The clickable span must equal what paintTabBar actually drew —
        // ties tabAtCol's width model to the render, catching format drift.
        try testing.expectEqual(visibleWidth(buf[0..w.end]), tabBarCovered(focus));
    }
}

test "tabAtCol: first column is tab 0, every panel is reachable, past-end is null" {
    try testing.expectEqual(@as(?usize, 0), mod.tabAtCol(0, 1));
    try testing.expectEqual(@as(?usize, null), mod.tabAtCol(0, 9999));
    // Each of the 5 default panels is clickable at some column.
    var seen = [_]bool{false} ** 8;
    var col: u16 = 1;
    const end = tabBarCovered(0);
    while (col <= end) : (col += 1) {
        if (mod.tabAtCol(0, col)) |t| seen[t] = true;
    }
    for (0..5) |t| try testing.expect(seen[t]);
}

test "paintTabBar occupies two rows (content_row invariant)" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try mod.paintTabBar(&w, 0);
    // content_row = tab_bar_rows + 1; the bar must emit exactly 2 newlines so
    // panels' click→row math (content_row + header) lands correctly.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, buf[0..w.end], "\n"));
}

test "tabAtCol maps columns to tabs in contiguous order (per-tab boundaries)" {
    // Stronger than the total-width check: as the column advances, the tab
    // index must step 0,1,2,…,N-1 with no gap or reorder — catches a per-tab
    // width redistribution that preserves the total.
    var expected: usize = 0;
    var current: ?usize = null;
    var col: u16 = 1;
    const end = tabBarCovered(0);
    while (col <= end) : (col += 1) {
        const t = mod.tabAtCol(0, col).?;
        if (current == null or t != current.?) {
            try testing.expectEqual(expected, t);
            expected += 1;
            current = t;
        }
    }
    try testing.expectEqual(@as(usize, 5), expected); // all 5 panels, in order
}

test "handleRead: a left-click on the tab bar focuses that tab" {
    var app = mod.App{
        .rts = try mod.Host.attachAll(testing.allocator),
        .host = .{},
        .sock = "",
        .sz = .{ .rows = 24, .cols = 100 },
        .out = -1,
        .fetch_arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer mod.Host.detachAll(testing.allocator, &app.rts);
    defer app.fetch_arena.deinit();
    app.focus = 0;

    // SGR-1006 left-press (button 0, 'M') at col 15, row 1 (the tab bar).
    // focus 0 → Home [1,11), Guard [11,20): col 15 lands on Guard (tab 1).
    _ = mod.handleRead(&app, "\x1b[<0;15;1M");
    try testing.expectEqual(@as(usize, 1), app.focus);
}

test "renderInto: first frame fully paints, an identical frame diffs to nothing" {
    var app = mod.App{
        .rts = try mod.Host.attachAll(testing.allocator),
        .host = .{},
        .sock = "",
        .sz = .{ .rows = 24, .cols = 100 },
        .out = -1,
        .fetch_arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer mod.Host.detachAll(testing.allocator, &app.rts);
    defer app.fetch_arena.deinit();

    var b1: [65536]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&b1);
    app.renderInto(&w1); // first frame: full paint
    const f1 = b1[0..w1.end];
    try testing.expect(std.mem.indexOf(u8, f1, "\x1b[2J") != null); // cleared
    // A paint-only needle (the tab bar) — proves paint actually ran, so the
    // empty-diff below can't pass on a silently-failed paint + frame.diff's
    // unconditional clear alone.
    try testing.expect(std.mem.indexOf(u8, f1, "[h]Home") != null);

    var b2: [65536]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&b2);
    app.renderInto(&w2); // identical frame → the row diff emits nothing
    try testing.expectEqual(@as(usize, 0), w2.end);
}

test "banner notes the atty session and is bounded" {
    var buf: [160]u8 = undefined;

    const in_session = mod.banner(&buf, true);
    try testing.expect(std.mem.indexOf(u8, in_session, "in atty session") != null);
    try testing.expect(std.mem.indexOf(u8, in_session, "attop") != null);
    // Genuinely bounded — the formatted line fits the caller's buffer.
    try testing.expect(in_session.len <= buf.len);

    const standalone = mod.banner(&buf, false);
    try testing.expect(std.mem.indexOf(u8, standalone, "in atty session") == null);
    try testing.expect(std.mem.indexOf(u8, standalone, "attop") != null);
    try testing.expect(standalone.len <= buf.len);
}
