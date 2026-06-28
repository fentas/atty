//! attop screenshot tests: feed each pure screen render through the VT
//! emulator (src/test/e2e/vt.zig) and assert the on-screen grid, not the
//! raw bytes — so wrapping / malformed escapes / off-screen content are
//! caught. Checks are content-present-and-unwrapped; pixel-exact goldens
//! are a follow-up.

const std = @import("std");
const testing = std.testing;
const vt = @import("vt");
const uds = @import("uds.zig");
const home = @import("home.zig");
const guard = @import("guard.zig");
const fleet = @import("fleet.zig");
const setup = @import("setup.zig");
const help = @import("help.zig");

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
        // The TL;DR copy renders intact (no mid-word wrap) at every width.
        try expectOnScreen(t, &.{"freezes anything ambiguous"});
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

test "Setup renders the checklist across widths (up, neutral, down)" {
    var buf: [65536]u8 = undefined;
    const neutral_m = uds.Metrics{ .guard = .{ .profile = "prompt", .ebpf = "off" } }; // off, no sessions
    for (widths) |cols| {
        const up = try screen(testing.allocator, setup.renderSetup(&buf, homeMetrics("strict"), true, cols, 40), 40, cols);
        defer testing.allocator.free(up);
        try expectOnScreen(up, &.{ "Setup", "atty-guard", "running", "strict", "session" });

        // Neutral rows + their fix lines must render intact — the long eBPF
        // install fix is the wrap-prone one at 70.
        const neut = try screen(testing.allocator, setup.renderSetup(&buf, neutral_m, true, cols, 40), 40, cols);
        defer testing.allocator.free(neut);
        try expectOnScreen(neut, &.{ "warn-only", "Guard panel", "make install-guard GUARD_FEATURES", "metrics_exporter" });

        const down = try screen(testing.allocator, setup.renderSetup(&buf, null, false, cols, 40), 40, cols);
        defer testing.allocator.free(down);
        try expectOnScreen(down, &.{ "not reachable", "sudo systemctl start atty-guard", "unknown (daemon down)", "not under atty" });
    }
}

test "Help renders the key + env reference across widths" {
    var buf: [65536]u8 = undefined;
    for (widths) |cols| {
        const out = try screen(testing.allocator, help.renderHelp(&buf, cols, 40), 40, cols);
        defer testing.allocator.free(out);
        // Full env strings as needles so a wrap at the narrow width (which
        // would split them across grid rows) fails the test.
        try expectOnScreen(out, &.{ "Keys", "Home", "Guard", "Fleet", "Setup", "ATTOP_THEME=dark|light|high-contrast|mono|ascii", "NO_COLOR forces mono", "atty-guard daemon" });
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
        // Pin the deliberate "reachable" wording (null = any failure, not
        // specifically "not running").
        try expectOnScreen(down, &.{"atty-guard not reachable"});

        const empty = try screen(testing.allocator, fleet.renderFleet(&buf, &.{}, cols, 40), 40, cols);
        defer testing.allocator.free(empty);
        try expectOnScreen(empty, &.{"no atty sessions reporting"});
    }
}

test "Fleet truncates a long cwd through the grid (tail kept, head dropped)" {
    var buf: [65536]u8 = undefined;
    // The cwd must exceed cwdBudget(120)=91 so truncation ACTUALLY fires
    // (a shorter path renders whole and would test nothing).
    const cwd = "/HEADXYZ" ++ ("/abcdefghij" ** 12) ++ "/tail-marker"; // ~152 chars
    var list = [_]uds.Instance{.{ .pid = 1, .shell = "bash", .cwd = cwd }};
    const t = try screen(testing.allocator, fleet.renderFleet(&buf, &list, 120, 40), 40, 120);
    defer testing.allocator.free(t);
    // The tail (incl. the ellipsis) lands on screen intact; the head drops.
    try expectOnScreen(t, &.{ "\u{2026}", "tail-marker" });
    try testing.expect(std.mem.indexOf(u8, t, "HEADXYZ") == null);
}
