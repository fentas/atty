//! attop screenshot tests — the docs/dashboard.md "screenshots end-to-end
//! tested" guarantee. Each pure screen render is fed through the SAME VT
//! emulator the proxy's e2e harness uses (src/test/e2e/vt.zig), and we
//! assert against the resulting on-screen grid — i.e. exactly what a
//! terminal would display, not just the raw escape bytes. This catches
//! malformed escapes, mid-word wrapping, and content dropped off-screen
//! that a raw-byte assertion would miss, across widths.

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
        try expectOnScreen(t, &.{ "Fleet", "4242", "bash", "2 terminals" });
    }
}
