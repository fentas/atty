const std = @import("std");
const testing = std.testing;
const guard = @import("guard.zig");
const uds = @import("uds.zig");
const panel = @import("panel.zig");

fn metrics(profile: []const u8) uds.Metrics {
    return .{ .guard = .{ .profile = profile, .ebpf = "attached", .deny_path = 1, .deny_basename = 2 } };
}

// The LIVE interactive path: j/k browse the rungs (the active profile stays
// marked), and `g` falls through so the host's g→Guard hotkey survives.
test "Guard.Panel: j moves selection; g is not consumed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var rt = try guard.Panel.attach(testing.allocator);
    const m = metrics("session");
    var ctx = panel.Ctx{ .metrics = m, .cols = 100, .rows = 24, .arena = arena.allocator() };

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try guard.Panel.render(&rt, &ctx, &w);
    // All rungs render through the live path.
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "prompt") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "lockdown") != null);

    const before = rt.list.selected;
    try testing.expectEqual(panel.Action.handled, try guard.Panel.onKey(&rt, &ctx, .{ .char = 'j' }));
    try testing.expectEqual(before + 1, rt.list.selected);

    // `g` is not a list key → .pass, so the host can switch to Guard.
    try testing.expectEqual(panel.Action.pass, try guard.Panel.onKey(&rt, &ctx, .{ .char = 'g' }));
}

test "all six rungs render with their TL;DRs" {
    var buf: [4096]u8 = undefined;
    const out = guard.renderGuard(&buf, metrics("session"), 120, 40);
    for ([_][]const u8{ "prompt", "audit", "session", "strict", "lockdown", "smart" }) |name| {
        try testing.expect(std.mem.indexOf(u8, out, name) != null);
    }
    try testing.expect(std.mem.indexOf(u8, out, "kills a threat right after it starts") != null);
    try testing.expect(std.mem.indexOf(u8, out, "deny-rules: 1 path + 2 basename") != null);
}

test "the active rung is marked, others are not" {
    var buf: [4096]u8 = undefined;
    const out = guard.renderGuard(&buf, metrics("strict"), 120, 40);
    // The active marker (▸) precedes exactly the active rung name.
    const marker = "\u{25B8} strict";
    try testing.expect(std.mem.indexOf(u8, out, marker) != null);
    // A non-active rung doesn't get the marker.
    try testing.expect(std.mem.indexOf(u8, out, "\u{25B8} prompt") == null);
}

test "unknown profile shows a cue, not a silent ladder" {
    var buf: [4096]u8 = undefined;
    const out = guard.renderGuard(&buf, metrics("bogus"), 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "not a listed rung") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bogus") != null);
    // no rung gets the active marker for an unrecognized profile
    try testing.expect(std.mem.indexOf(u8, out, "\u{25B8}") == null);
}

test "unavailable state when no daemon" {
    var buf: [4096]u8 = undefined;
    const out = guard.renderGuard(&buf, null, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "atty-guard not running") != null);
}

test "rungs ladder matches the daemon order" {
    // weakest → strongest; pin ALL six by index — this is a hand-copy of
    // the daemon's SecurityProfile, so a reorder/rename must trip a test.
    const expect = [_][]const u8{ "prompt", "audit", "session", "strict", "lockdown", "smart" };
    try testing.expectEqual(expect.len, guard.rungs.len);
    for (expect, guard.rungs) |name, r| try testing.expectEqualStrings(name, r.name);
}

test "compact title drops the suffix below the break" {
    var buf: [4096]u8 = undefined;
    const full = guard.renderGuard(&buf, metrics("session"), 120, 40);
    try testing.expect(std.mem.indexOf(u8, full, "security profile") != null);
    var buf2: [4096]u8 = undefined;
    const narrow = guard.renderGuard(&buf2, metrics("session"), 70, 40);
    try testing.expect(std.mem.indexOf(u8, narrow, "security profile") == null);
}
