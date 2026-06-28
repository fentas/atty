const std = @import("std");
const testing = std.testing;
const guard = @import("guard.zig");
const uds = @import("uds.zig");

fn metrics(profile: []const u8) uds.Metrics {
    return .{ .guard = .{ .profile = profile, .ebpf = "attached", .deny_path = 1, .deny_basename = 2 } };
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

test "unavailable state when no daemon" {
    var buf: [4096]u8 = undefined;
    const out = guard.renderGuard(&buf, null, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "atty-guard not running") != null);
}

test "rungs ladder matches the daemon order" {
    // weakest → strongest; pins the copy + order in one place.
    try testing.expectEqual(@as(usize, 6), guard.rungs.len);
    try testing.expectEqualStrings("prompt", guard.rungs[0].name);
    try testing.expectEqualStrings("smart", guard.rungs[5].name);
}
