//! attop screenshot tests — the docs/dashboard.md "screenshots end-to-end
//! tested" guarantee. Each pure screen render is fed through the SAME VT
//! emulator the proxy's e2e harness uses (src/test/e2e/vt.zig), and we
//! assert against the resulting on-screen grid — the actual terminal text,
//! not the raw escape bytes. The checks are content-present-and-unwrapped
//! (each needle appears INTACT in the grid, so it fit the width without a
//! mid-word wrap) across widths; full pixel-exact grid goldens are a
//! follow-up. Still catches malformed escapes, wrapping, and off-screen
//! content that a raw-byte assertion would miss.

const std = @import("std");
const testing = std.testing;
const vt = @import("vt");
const uds = @import("uds.zig");
const home = @import("home.zig");
const guard = @import("guard.zig");
const fleet = @import("fleet.zig");

/// Render `frame` into a rows×cols VT grid and return the visible text
/// (trailing blanks trimmed per row). Caller frees.
fn screen(allocator: std.mem.Allocator, frame: []const u8, rows: u16, cols: u16) ![]u8 {
    var grid = try vt.Grid.init(allocator, rows, cols);
    defer grid.deinit();
    grid.feed(frame);
    var out_buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    try grid.renderText(&w);
    return allocator.dupe(u8, out_buf[0..w.end]);
}

/// Assert every `needle` appears intact in the emulated grid (intact ⇒ it
/// wasn't split by a wrap, so it fit the width).
fn expectOnScreen(text: []const u8, needles: []const []const u8) !void {
    for (needles) |n| {
        if (std.mem.indexOf(u8, text, n) == null) {
            std.debug.print("\n--- on-screen grid ---\n{s}\n--- missing: {s} ---\n", .{ text, n });
            return error.NotOnScreen;
        }
    }
}

const widths = [_]u16{ 120, 80, 70 };

fn homeMetrics(profile: []const u8) uds.Metrics {
    return .{
        .aggregate = .{ .commands = 312, .guard_block = 3 },
        .guard = .{ .profile = profile, .ebpf = "attached" },
        .instances = 5,
    };
}

test "Home renders protected/unguarded/unavailable across widths" {
    var buf: [65536]u8 = undefined;
    for (widths) |cols| {
        // protected
        {
            const t = try screen(testing.allocator, home.renderHome(&buf, homeMetrics("session"), cols, 40), 40, cols);
            defer testing.allocator.free(t);
            try expectOnScreen(t, &.{ "atty", "Protected", "session", "312 commands", "5 terminals active" });
        }
        // unguarded
        {
            const t = try screen(testing.allocator, home.renderHome(&buf, homeMetrics("prompt"), cols, 40), 40, cols);
            defer testing.allocator.free(t);
            try expectOnScreen(t, &.{ "Unguarded", "prompt" });
        }
        // unavailable
        {
            const t = try screen(testing.allocator, home.renderHome(&buf, null, cols, 40), 40, cols);
            defer testing.allocator.free(t);
            try expectOnScreen(t, &.{"atty-guard not running"});
        }
    }
}

test "Guard renders the ladder + active rung across widths" {
    var buf: [65536]u8 = undefined;
    for (widths) |cols| {
        const t = try screen(testing.allocator, guard.renderGuard(&buf, homeMetrics("strict"), cols, 40), 40, cols);
        defer testing.allocator.free(t);
        try expectOnScreen(t, &.{ "prompt", "audit", "session", "strict", "lockdown", "smart", "kernel" });
        // The ACTIVE rung carries the ▸ marker (the fixture is "strict");
        // a non-active rung must not.
        try expectOnScreen(t, &.{"\u{25B8} strict"});
        try testing.expect(std.mem.indexOf(u8, t, "\u{25B8} prompt") == null);
        // A long TL;DR must render intact (not wrapped mid-line) at full
        // width — the wrap the VT grid would expose.
        if (cols >= 120) try expectOnScreen(t, &.{"freezes anything ambiguous"});
    }
}

test "Guard renders the negative states across widths" {
    var buf: [65536]u8 = undefined;
    for (widths) |cols| {
        const down = try screen(testing.allocator, guard.renderGuard(&buf, null, cols, 40), 40, cols);
        defer testing.allocator.free(down);
        try expectOnScreen(down, &.{"atty-guard not running"});

        const unknown = try screen(testing.allocator, guard.renderGuard(&buf, homeMetrics("bogus"), cols, 40), 40, cols);
        defer testing.allocator.free(unknown);
        try expectOnScreen(unknown, &.{"not a listed rung"});
    }
}

test "Fleet renders rows + total across widths" {
    var buf: [65536]u8 = undefined;
    var list = [_]uds.Instance{
        .{ .pid = 4242, .shell = "bash", .cwd = "/home/u/proj", .counters = .{ .commands = 12 } },
        .{ .pid = 99, .shell = "zsh", .cwd = "/tmp", .incognito = true },
    };
    for (widths) |cols| {
        const t = try screen(testing.allocator, fleet.renderFleet(&buf, &list, cols, 40), 40, cols);
        defer testing.allocator.free(t);
        // Both rows (incl. the incognito 🔒 on the 2nd) + the total.
        try expectOnScreen(t, &.{ "Fleet", "4242", "bash", "99", "zsh", "\u{1F512}", "2 terminals" });
    }
}

test "Fleet renders the negative states across widths" {
    var buf: [65536]u8 = undefined;
    for (widths) |cols| {
        const down = try screen(testing.allocator, fleet.renderFleet(&buf, null, cols, 40), 40, cols);
        defer testing.allocator.free(down);
        try expectOnScreen(down, &.{"atty-guard not"});

        const empty = try screen(testing.allocator, fleet.renderFleet(&buf, &.{}, cols, 40), 40, cols);
        defer testing.allocator.free(empty);
        try expectOnScreen(empty, &.{"no atty sessions reporting"});
    }
}

test "Fleet truncates a long cwd intact (tail visible, head dropped)" {
    var buf: [65536]u8 = undefined;
    var list = [_]uds.Instance{.{ .pid = 1, .shell = "bash", .cwd = "/very/deeply/nested/that/will/overflow/the/column/budget/tail-marker" }};
    // At full width the cwd still overflows the column → tail-truncated; the
    // tail must land on screen intact (not split by a wrap).
    const t = try screen(testing.allocator, fleet.renderFleet(&buf, &list, 120, 40), 40, 120);
    defer testing.allocator.free(t);
    try expectOnScreen(t, &.{"tail-marker"});
}
