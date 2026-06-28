const std = @import("std");
const testing = std.testing;
const fleet = @import("fleet.zig");
const uds = @import("uds.zig");

fn instances() [2]uds.Instance {
    return .{
        .{ .pid = 4242, .shell = "bash", .cwd = "/home/u/proj", .counters = .{ .commands = 12 } },
        .{ .pid = 99, .shell = "zsh", .cwd = "/tmp", .incognito = true, .counters = .{ .commands = 3 } },
    };
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
    try testing.expect(std.mem.indexOf(u8, down, "atty-guard not running") != null);
}

test "singular terminal" {
    var buf: [4096]u8 = undefined;
    var list = [_]uds.Instance{.{ .pid = 7, .shell = "fish" }};
    const out = fleet.renderFleet(&buf, &list, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "1 terminal\r\n") != null);
}
