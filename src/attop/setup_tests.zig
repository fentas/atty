const std = @import("std");
const testing = std.testing;
const setup = @import("setup.zig");
const uds = @import("uds.zig");

test "atty installed → ✓; not on PATH → ✗ + the install fix" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 1 };

    const yes = setup.renderSetup(&buf, m, true, true, 120, 40); // atty_on_path = true
    try testing.expect(std.mem.indexOf(u8, yes, "installed") != null);
    try testing.expect(std.mem.indexOf(u8, yes, "not installed") == null); // ✓, not the ✗ wording

    var buf2: [4096]u8 = undefined;
    const no = setup.renderSetup(&buf2, m, false, true, 120, 40); // not on PATH
    try testing.expect(std.mem.indexOf(u8, no, "not installed") != null);
    try testing.expect(std.mem.indexOf(u8, no, "bin.atty.sh") != null); // the install fix
    try testing.expect(std.mem.indexOf(u8, no, "\u{2717}") != null); // ✗
}

test "setup surfaces the enforcement depth" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached", .enforcement = "ancestry" }, .instances = 1 };
    const out = setup.renderSetup(&buf, m, true, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "enforce") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ancestry") != null);
}

test "daemon up, protected, ebpf, sessions, in-atty → all ok marks" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 3 };
    const out = setup.renderSetup(&buf, m, true, true, 120, 40);
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
    const out = setup.renderSetup(&buf, null, true, false, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "not reachable") != null);
    try testing.expect(std.mem.indexOf(u8, out, "sudo systemctl start atty-guard") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\u{2717}") != null); // ✗
    try testing.expect(std.mem.indexOf(u8, out, "not under atty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "run: atty") != null);
}

test "prompt profile + ebpf off + no sessions → neutral rows with fixes" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "prompt", .ebpf = "off" }, .instances = 0 };
    const out = setup.renderSetup(&buf, m, true, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "warn-only") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Guard panel") != null);
    try testing.expect(std.mem.indexOf(u8, out, "metrics_exporter") != null);
    try testing.expect(std.mem.indexOf(u8, out, "GUARD_FEATURES") != null);
}

test "eBPF: daemon \"off\" keeps the install fix; future status verbatim; empty → unknown" {
    // The daemon sends exactly "attached" or "off" (main.rs GuardPosture).
    var buf: [4096]u8 = undefined;
    const off = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "off" } };
    const out = setup.renderSetup(&buf, off, true, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "off") != null);
    try testing.expect(std.mem.indexOf(u8, out, "GUARD_FEATURES") != null); // off keeps the fix

    var buf2: [4096]u8 = undefined;
    const future = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "degraded" } };
    const out2 = setup.renderSetup(&buf2, future, true, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out2, "degraded") != null); // verbatim

    var buf3: [4096]u8 = undefined;
    const absent = uds.Metrics{ .guard = .{ .profile = "strict" } }; // ebpf field absent
    const out3 = setup.renderSetup(&buf3, absent, true, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out3, "unknown") != null);
}

test "empty profile (daemon up) → unknown, not prompt" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{} }; // daemon up, profile empty
    const out = setup.renderSetup(&buf, m, true, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "unknown") != null);
    try testing.expect(std.mem.indexOf(u8, out, "warn-only") == null);
}

test "singular session reporting" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 1 };
    const out = setup.renderSetup(&buf, m, true, true, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "1 session reporting") != null);
}
