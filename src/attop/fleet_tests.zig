const std = @import("std");
const testing = std.testing;
const fleet = @import("fleet.zig");
const uds = @import("uds.zig");
const panel = @import("panel.zig");

fn instances() [2]uds.Instance {
    return .{
        .{ .pid = 4242, .shell = "bash", .cwd = "/home/u/proj", .counters = .{ .commands = 12 } },
        .{ .pid = 99, .shell = "zsh", .cwd = "/tmp", .incognito = true, .counters = .{ .commands = 3 } },
    };
}

// The LIVE interactive path (Panel.render + onKey), distinct from the legacy
// renderFleet wrapper the byte-layout tests above exercise.
test "Fleet.Panel: select, detail, search, and g falls through to nav" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list = instances();
    var rt = try fleet.Panel.attach(testing.allocator);
    var ctx = panel.Ctx{ .instances = &list, .cols = 100, .rows = 24, .arena = arena.allocator() };

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try fleet.Panel.render(&rt, &ctx, &w);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "bash") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "zsh") != null);

    // j moves selection (and reports handled so global nav won't also act).
    try testing.expectEqual(panel.Action.handled, try fleet.Panel.onKey(&rt, &ctx, .{ .char = 'j' }));
    try testing.expectEqual(@as(usize, 1), rt.list.selected);

    // Enter → detail of the 2nd session (pid 99), framed in a box.
    _ = try fleet.Panel.onKey(&rt, &ctx, .enter);
    try testing.expect(rt.mode == .detail);
    w = std.Io.Writer.fixed(&buf);
    try fleet.Panel.render(&rt, &ctx, &w);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "session 99") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "\u{2502}") != null); // box side border

    // Any key closes detail.
    _ = try fleet.Panel.onKey(&rt, &ctx, .escape);
    try testing.expect(rt.mode == .browse);

    // `/` then `z` filters to the zsh row only.
    _ = try fleet.Panel.onKey(&rt, &ctx, .{ .char = '/' });
    try testing.expect(rt.mode == .search);
    _ = try fleet.Panel.onKey(&rt, &ctx, .{ .char = 'z' });
    w = std.Io.Writer.fixed(&buf);
    try fleet.Panel.render(&rt, &ctx, &w);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "zsh") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "bash") == null);

    // Esc clears the filter + leaves search; in browse, `g` must fall through
    // (.pass) so the host's global g→Guard hotkey still works (regression).
    _ = try fleet.Panel.onKey(&rt, &ctx, .escape);
    try testing.expect(rt.mode == .browse);
    try testing.expectEqual(panel.Action.pass, try fleet.Panel.onKey(&rt, &ctx, .{ .char = 'g' }));
}

test "rows render with pid, shell, cmds, cwd + the total" {
    var buf: [4096]u8 = undefined;
    var list = instances();
    const out = fleet.renderFleet(&buf, &list, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "4242") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bash") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/home/u/proj") != null);
    try testing.expect(std.mem.indexOf(u8, out, "12") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2 terminals") != null);
    // incognito session marked
    try testing.expect(std.mem.indexOf(u8, out, "\u{1F512}") != null);
}

test "long cwd is tail-truncated with a leading ellipsis" {
    var buf: [4096]u8 = undefined;
    var list = [_]uds.Instance{.{ .pid = 1, .shell = "bash", .cwd = "/very/deeply/nested/path/that/exceeds/the/column/budget/for/sure/x" }};
    const out = fleet.renderFleet(&buf, &list, 80, 40);
    try testing.expect(std.mem.indexOf(u8, out, "\u{2026}") != null); // ellipsis
    // the tail (deepest) survives; the head is dropped
    try testing.expect(std.mem.indexOf(u8, out, "/sure/x") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/very/deeply") == null);
}

test "compact (<80) drops the cwd column" {
    var buf: [4096]u8 = undefined;
    var list = instances();
    const full = fleet.renderFleet(&buf, &list, 120, 40);
    try testing.expect(std.mem.indexOf(u8, full, "cwd") != null); // header label
    try testing.expect(std.mem.indexOf(u8, full, "/home/u/proj") != null);

    var buf2: [4096]u8 = undefined;
    const narrow = fleet.renderFleet(&buf2, &list, 70, 40);
    try testing.expect(std.mem.indexOf(u8, narrow, "cwd") == null); // no cwd column
    try testing.expect(std.mem.indexOf(u8, narrow, "/home/u/proj") == null);
    try testing.expect(std.mem.indexOf(u8, narrow, "4242") != null); // rows still render
}

test "tail-truncation lands on a UTF-8 boundary" {
    // A multibyte path; the shown tail must not start mid-codepoint.
    var buf: [4096]u8 = undefined;
    var list = [_]uds.Instance{.{ .pid = 1, .shell = "bash", .cwd = "/x/café/" ++ ("ä" ** 40) }};
    const out = fleet.renderFleet(&buf, &list, 80, 40);
    // The whole frame stays valid UTF-8 (no split codepoint after the ellipsis).
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "empty fleet + unavailable states" {
    var buf: [4096]u8 = undefined;
    const empty = fleet.renderFleet(&buf, &.{}, 120, 40);
    try testing.expect(std.mem.indexOf(u8, empty, "no atty sessions reporting") != null);

    var buf2: [4096]u8 = undefined;
    const down = fleet.renderFleet(&buf2, null, 120, 40);
    // Stable substring — tolerates wording tweaks of the unavailable line.
    try testing.expect(std.mem.indexOf(u8, down, "atty-guard not") != null);
}

test "singular terminal" {
    var buf: [4096]u8 = undefined;
    var list = [_]uds.Instance{.{ .pid = 7, .shell = "fish" }};
    const out = fleet.renderFleet(&buf, &list, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "1 terminal\r\n") != null);
}

test "Fleet.Panel: onClick selects the row under the cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list = instances(); // 2 sessions
    var rt = try fleet.Panel.attach(testing.allocator);
    var ctx = panel.Ctx{ .instances = &list, .cols = 100, .rows = 24, .content_row = 3, .arena = arena.allocator() };

    // Render once so the list's len/offset are populated.
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try fleet.Panel.render(&rt, &ctx, &w);

    // content_row(3) + 3 header rows → first session at row 6; row 7 = 2nd.
    try testing.expectEqual(panel.Action.handled, try fleet.Panel.onClick(&rt, &ctx, 5, 7));
    try testing.expectEqual(@as(usize, 1), rt.list.selected);
    // A click in the header (above the list) is ignored.
    try testing.expectEqual(panel.Action.pass, try fleet.Panel.onClick(&rt, &ctx, 5, 4));
    // A click past the last row is ignored.
    try testing.expectEqual(panel.Action.pass, try fleet.Panel.onClick(&rt, &ctx, 5, 50));
}

test "responsive: a uid column appears at >=120 cols, hidden below" {
    var list = [_]uds.Instance{.{ .pid = 7, .uid = 1000, .shell = "bash", .cwd = "/x" }};
    var buf: [4096]u8 = undefined;
    const wide = fleet.renderFleet(&buf, &list, 120, 40);
    try testing.expect(std.mem.indexOf(u8, wide, "uid") != null); // header
    try testing.expect(std.mem.indexOf(u8, wide, "1000") != null); // value
    var buf2: [4096]u8 = undefined;
    const mid = fleet.renderFleet(&buf2, &list, 100, 40);
    try testing.expect(std.mem.indexOf(u8, mid, "uid") == null);
    try testing.expect(std.mem.indexOf(u8, mid, "1000") == null);
}

test "responsive: the live Panel.render shows uid at wide width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list = [_]uds.Instance{.{ .pid = 7, .uid = 1000, .shell = "bash", .cwd = "/x" }};
    var rt = try fleet.Panel.attach(testing.allocator);
    var ctx = panel.Ctx{ .instances = &list, .cols = 120, .rows = 24, .arena = arena.allocator() };
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try fleet.Panel.render(&rt, &ctx, &w);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "1000") != null);
}
