const std = @import("std");
const testing = std.testing;
const home = @import("home.zig");
const uds = @import("uds.zig");

fn sample(profile: []const u8) uds.Metrics {
    return .{
        .aggregate = .{ .commands = 312, .guard_block = 3 },
        .guard = .{ .profile = profile, .ebpf = "attached" },
        .instances = 5,
    };
}

test "isProtected: prompt is unguarded, others protected" {
    try testing.expect(!home.isProtected(sample("prompt")));
    try testing.expect(!home.isProtected(sample(""))); // unknown → unguarded
    try testing.expect(home.isProtected(sample("session")));
    try testing.expect(home.isProtected(sample("strict")));
}

test "render shows protected status + the counts row" {
    var buf: [4096]u8 = undefined;
    const out = home.renderHome(&buf, sample("session"), 120, 30);
    try testing.expect(std.mem.indexOf(u8, out, "Protected") != null);
    try testing.expect(std.mem.indexOf(u8, out, "session") != null);
    try testing.expect(std.mem.indexOf(u8, out, "312 commands") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3 threats blocked") != null);
    try testing.expect(std.mem.indexOf(u8, out, "5 terminals active") != null);
}

test "metrics off (no sessions) → honest hint, not zero counters" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "session" }, .instances = 0 };
    const out = home.renderHome(&buf, m, 120, 30);
    try testing.expect(std.mem.indexOf(u8, out, "metrics off") != null);
    // No misleading zero counters / "0 terminals active".
    try testing.expect(std.mem.indexOf(u8, out, "commands") == null);
    try testing.expect(std.mem.indexOf(u8, out, "terminals active") == null);
}

test "render shows unguarded for prompt" {
    var buf: [4096]u8 = undefined;
    const out = home.renderHome(&buf, sample("prompt"), 120, 30);
    try testing.expect(std.mem.indexOf(u8, out, "Unguarded") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Protected") == null);
}

test "null metrics → daemon-unavailable state" {
    var buf: [4096]u8 = undefined;
    const out = home.renderHome(&buf, null, 120, 30);
    try testing.expect(std.mem.indexOf(u8, out, "atty-guard not running") != null);
}

test "responsive: dashboard suffix only at full width" {
    var buf: [4096]u8 = undefined;
    const full = home.renderHome(&buf, sample("session"), 120, 30);
    try testing.expect(std.mem.indexOf(u8, full, "dashboard") != null);

    var buf2: [4096]u8 = undefined;
    const narrow = home.renderHome(&buf2, sample("session"), 70, 30);
    try testing.expect(std.mem.indexOf(u8, narrow, "dashboard") == null);
}

test "singular terminal" {
    var buf: [4096]u8 = undefined;
    var m = sample("audit");
    m.instances = 1;
    const out = home.renderHome(&buf, m, 120, 30);
    try testing.expect(std.mem.indexOf(u8, out, "1 terminal active") != null);
}
