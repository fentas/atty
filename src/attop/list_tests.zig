const std = @import("std");
const testing = std.testing;
const mod = @import("list.zig");
const List = mod.List;

test "List: empty list stays at 0/0" {
    var l = List{};
    l.setViewport(5);
    l.setLen(0);
    l.moveDown();
    l.toBottom();
    try testing.expectEqual(@as(usize, 0), l.selected);
    try testing.expectEqual(@as(usize, 0), l.offset);
}

test "List: move clamps to [0,len)" {
    var l = List{};
    l.setViewport(10);
    l.setLen(3);
    l.moveUp(); // already at 0
    try testing.expectEqual(@as(usize, 0), l.selected);
    l.moveDown();
    l.moveDown();
    l.moveDown(); // can't pass index 2
    try testing.expectEqual(@as(usize, 2), l.selected);
    l.toBottom();
    try testing.expectEqual(@as(usize, 2), l.selected);
    l.toTop();
    try testing.expectEqual(@as(usize, 0), l.selected);
}

test "List: scroll keeps the selection inside the viewport" {
    var l = List{};
    l.setViewport(3); // shows 3 rows
    l.setLen(10);
    // Move down past the bottom of the viewport → offset follows.
    var i: usize = 0;
    while (i < 4) : (i += 1) l.moveDown(); // selected = 4
    try testing.expectEqual(@as(usize, 4), l.selected);
    // selected must be within [offset, offset+viewport)
    try testing.expect(l.selected >= l.offset);
    try testing.expect(l.selected < l.offset + l.viewport);
    // offset shouldn't exceed len-viewport
    try testing.expect(l.offset <= l.len - l.viewport);

    // Jump to bottom: offset shows the last full screen (rows 7,8,9).
    l.toBottom();
    try testing.expectEqual(@as(usize, 9), l.selected);
    try testing.expectEqual(@as(usize, 7), l.offset);
    const v = l.visible();
    try testing.expectEqual(@as(usize, 7), v.start);
    try testing.expectEqual(@as(usize, 10), v.end);

    // Back to top.
    l.toTop();
    try testing.expectEqual(@as(usize, 0), l.offset);
}

test "List: pageUp/pageDown move by a viewport, clamped" {
    var l = List{};
    l.setViewport(4);
    l.setLen(20);
    l.pageDown(); // 0 → 4
    try testing.expectEqual(@as(usize, 4), l.selected);
    l.pageDown(); // 4 → 8
    try testing.expectEqual(@as(usize, 8), l.selected);
    l.pageUp(); // 8 → 4
    try testing.expectEqual(@as(usize, 4), l.selected);
    // pageDown near the end clamps to the last row.
    l.toBottom();
    l.pageDown();
    try testing.expectEqual(@as(usize, 19), l.selected);
    // pageUp at the top clamps to 0 (no underflow).
    l.toTop();
    l.pageUp();
    try testing.expectEqual(@as(usize, 0), l.selected);
}

test "List: shrinking len re-clamps the selection" {
    var l = List{};
    l.setViewport(5);
    l.setLen(10);
    l.toBottom(); // selected 9
    l.setLen(3); // e.g. a filter narrowed the rows
    try testing.expectEqual(@as(usize, 2), l.selected);
    try testing.expectEqual(@as(usize, 0), l.offset);
}

test "List.handleKey: vim + arrows, G/Home, consume reporting" {
    var l = List{};
    l.setViewport(5);
    l.setLen(10);

    try testing.expect(l.handleKey(.{ .char = 'j' })); // down
    try testing.expectEqual(@as(usize, 1), l.selected);
    try testing.expect(l.handleKey(.down));
    try testing.expectEqual(@as(usize, 2), l.selected);
    try testing.expect(l.handleKey(.{ .char = 'k' })); // up
    try testing.expectEqual(@as(usize, 1), l.selected);
    try testing.expect(l.handleKey(.{ .char = 'G' })); // bottom
    try testing.expectEqual(@as(usize, 9), l.selected);
    try testing.expect(l.handleKey(.home)); // Home → top
    try testing.expectEqual(@as(usize, 0), l.selected);

    // A lone `g` is deliberately NOT consumed — it must fall through so the
    // host's global `g`→Guard hotkey still works while a list panel is
    // focused (there is no `gg`; Home covers "top").
    try testing.expect(!l.handleKey(.{ .char = 'g' }));
    // Any other non-list char is likewise not consumed.
    try testing.expect(!l.handleKey(.{ .char = 'q' }));
}

test "containsIgnoreCase" {
    try testing.expect(mod.containsIgnoreCase("ls -la /usr/share", "USR"));
    try testing.expect(mod.containsIgnoreCase("BASH", "bash"));
    try testing.expect(mod.containsIgnoreCase("anything", "")); // empty needle matches
    try testing.expect(!mod.containsIgnoreCase("abc", "abcd")); // needle longer
    try testing.expect(!mod.containsIgnoreCase("hello", "xyz"));
}
