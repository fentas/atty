const std = @import("std");
const testing = std.testing;
const setup = @import("setup.zig");
const uds = @import("uds.zig");

test "daemon up, protected, ebpf, sessions, in-atty → all ok marks" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 3 };
    const out = setup.renderSetup(&buf, m, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "running") != null);
    try testing.expect(std.mem.indexOf(u8, out, "strict") != null);
    try testing.expect(std.mem.indexOf(u8, out, "attached") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3 sessions reporting") != null);
    try testing.expect(std.mem.indexOf(u8, out, "in an atty session") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\u{2713}") != null); // ✓
    try testing.expect(std.mem.indexOf(u8, out, "\u{2717}") == null); // no ✗
}

test "daemon down → bad mark + fix; session still checkable" {
    var buf: [4096]u8 = undefined;
    const out = setup.renderSetup(&buf, null, false, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "not reachable") != null);
    try testing.expect(std.mem.indexOf(u8, out, "sudo systemctl start atty-guard") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\u{2717}") != null); // ✗
    try testing.expect(std.mem.indexOf(u8, out, "not under atty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "run: atty") != null);
}

test "prompt profile + no ebpf + no sessions → neutral rows with fixes" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "prompt" }, .instances = 0 };
    const out = setup.renderSetup(&buf, m, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "warn-only") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Guard panel") != null);
    try testing.expect(std.mem.indexOf(u8, out, "metrics_exporter") != null);
    try testing.expect(std.mem.indexOf(u8, out, "GUARD_FEATURES") != null);
}

test "eBPF: a non-attached status shows verbatim; empty → off + fix" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "failed" } };
    const out = setup.renderSetup(&buf, m, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "failed") != null); // raw, not "off"

    var buf2: [4096]u8 = undefined;
    const m2 = uds.Metrics{ .guard = .{ .profile = "strict" } }; // ebpf empty
    const out2 = setup.renderSetup(&buf2, m2, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out2, "off") != null);
    try testing.expect(std.mem.indexOf(u8, out2, "GUARD_FEATURES") != null);
}

test "empty profile (daemon up) → unknown, not prompt" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{} }; // daemon up, profile empty
    const out = setup.renderSetup(&buf, m, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "unknown") != null);
    try testing.expect(std.mem.indexOf(u8, out, "warn-only") == null);
}

test "singular session reporting" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 1 };
    const out = setup.renderSetup(&buf, m, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "1 session reporting") != null);
}
