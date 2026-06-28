const std = @import("std");
const testing = std.testing;
const setup = @import("setup.zig");
const uds = @import("uds.zig");

test "atty installed → ✓; not on PATH → ✗ + the install fix" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 1 };

    const yes = setup.renderSetup(&buf, m, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40); // atty_on_path = true
    try testing.expect(std.mem.indexOf(u8, yes, "installed") != null);
    try testing.expect(std.mem.indexOf(u8, yes, "not installed") == null); // ✓, not the ✗ wording

    var buf2: [4096]u8 = undefined;
    const no = setup.renderSetup(&buf2, m, .{ .atty_on_path = false, .under_atty = true, .shell_integrated = true }, 120, 40); // not on PATH
    try testing.expect(std.mem.indexOf(u8, no, "not installed") != null);
    try testing.expect(std.mem.indexOf(u8, no, "bin.atty.sh") != null); // the install fix
    try testing.expect(std.mem.indexOf(u8, no, "\u{2717}") != null); // ✗
}

test "setup surfaces the enforcement depth" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached", .enforcement = "ancestry" }, .instances = 1 };
    const out = setup.renderSetup(&buf, m, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "enforce") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ancestry") != null);
}

test "setup shell row → wired ✓; not wired → ✗ + the wire fix" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 1 };

    const wired = setup.renderSetup(&buf, m, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40); // shell_integrated = true
    try testing.expect(std.mem.indexOf(u8, wired, "shell") != null);
    try testing.expect(std.mem.indexOf(u8, wired, "wired") != null);
    try testing.expect(std.mem.indexOf(u8, wired, "not wired") == null);

    // atty installed + not wired → offer the consented [w] write.
    var buf2: [4096]u8 = undefined;
    const not = setup.renderSetup(&buf2, m, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = false }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, not, "not wired") != null);
    try testing.expect(std.mem.indexOf(u8, not, "[w]") != null); // the consented-write prompt

    // atty NOT installed + not wired → the manual command, naming the shell
    // ([w] would point at an atty that isn't on PATH yet).
    var buf3: [4096]u8 = undefined;
    const zsh = setup.renderSetup(&buf3, m, .{ .atty_on_path = false, .shell_integrated = false, .shell_name = "zsh" }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, zsh, "atty init zsh") != null);
    try testing.expect(std.mem.indexOf(u8, zsh, "atty init bash") == null);
}

test "setup lists daemon compiled features; empty → minimal build" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached", .features = &.{ "ebpf", "osv-live" } }, .instances = 1 };
    const out = setup.renderSetup(&buf, m, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "features") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ebpf, osv-live") != null);

    // present-but-empty (a new daemon, default build) → "minimal build"
    var buf2: [4096]u8 = undefined;
    const m2 = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "off", .features = &.{} }, .instances = 1 };
    const out2 = setup.renderSetup(&buf2, m2, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out2, "minimal build") != null);

    // absent (older daemon, features=null) → "unknown", NOT "minimal build"
    var buf3: [4096]u8 = undefined;
    const m3 = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 1 }; // features defaults null
    const out3 = setup.renderSetup(&buf3, m3, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out3, "minimal build") == null);
    try testing.expect(std.mem.indexOf(u8, out3, "unknown") != null); // features row → unknown (ebpf attached, so it's the only unknown)
}

test "renderWire confirm shows the block + paths + prompt; done/failed messages" {
    var buf: [4096]u8 = undefined;
    const block = "# >>> atty >>>\nexport ATTY_SOURCE=\"/h/.config/atty/init.bash\"\n# <<< atty <<<\n";

    const confirm = setup.renderWire(&buf, .confirm, "/h/.config/atty/init.bash", "/h/.bashrc", block, 120, 40);
    try testing.expect(std.mem.indexOf(u8, confirm, "/h/.config/atty/init.bash") != null);
    try testing.expect(std.mem.indexOf(u8, confirm, "/h/.bashrc") != null);
    try testing.expect(std.mem.indexOf(u8, confirm, "ATTY_SOURCE") != null); // the block is shown verbatim
    try testing.expect(std.mem.indexOf(u8, confirm, "[y]") != null); // the consent key

    var buf2: [4096]u8 = undefined;
    const done = setup.renderWire(&buf2, .done, "", "", "", 120, 40);
    try testing.expect(std.mem.indexOf(u8, done, "wired") != null);

    var buf3: [4096]u8 = undefined;
    const failed = setup.renderWire(&buf3, .failed, "", "", "", 120, 40);
    try testing.expect(std.mem.indexOf(u8, failed, "could not write") != null);
}

test "daemon up, protected, ebpf, sessions, in-atty → all ok marks" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 3 };
    const out = setup.renderSetup(&buf, m, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
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
    const out = setup.renderSetup(&buf, null, .{ .atty_on_path = true, .under_atty = false, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "not reachable") != null);
    try testing.expect(std.mem.indexOf(u8, out, "sudo systemctl start atty-guard") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\u{2717}") != null); // ✗
    try testing.expect(std.mem.indexOf(u8, out, "not under atty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "run: atty") != null);
}

test "prompt profile + ebpf off + no sessions → neutral rows with fixes" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "prompt", .ebpf = "off" }, .instances = 0 };
    const out = setup.renderSetup(&buf, m, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "warn-only") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Guard panel") != null);
    try testing.expect(std.mem.indexOf(u8, out, "metrics_exporter") != null);
    try testing.expect(std.mem.indexOf(u8, out, "GUARD_FEATURES") != null);
}

test "eBPF: daemon \"off\" keeps the install fix; future status verbatim; empty → unknown" {
    // The daemon sends exactly "attached" or "off" (main.rs GuardPosture).
    var buf: [4096]u8 = undefined;
    const off = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "off" } };
    const out = setup.renderSetup(&buf, off, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "off") != null);
    try testing.expect(std.mem.indexOf(u8, out, "GUARD_FEATURES") != null); // off keeps the fix

    var buf2: [4096]u8 = undefined;
    const future = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "degraded" } };
    const out2 = setup.renderSetup(&buf2, future, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out2, "degraded") != null); // verbatim

    var buf3: [4096]u8 = undefined;
    const absent = uds.Metrics{ .guard = .{ .profile = "strict" } }; // ebpf field absent
    const out3 = setup.renderSetup(&buf3, absent, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out3, "unknown") != null);
}

test "empty profile (daemon up) → unknown, not prompt" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{} }; // daemon up, profile empty
    const out = setup.renderSetup(&buf, m, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "unknown") != null);
    try testing.expect(std.mem.indexOf(u8, out, "warn-only") == null);
}

test "singular session reporting" {
    var buf: [4096]u8 = undefined;
    const m = uds.Metrics{ .guard = .{ .profile = "strict", .ebpf = "attached" }, .instances = 1 };
    const out = setup.renderSetup(&buf, m, .{ .atty_on_path = true, .under_atty = true, .shell_integrated = true }, 120, 40);
    try testing.expect(std.mem.indexOf(u8, out, "1 session reporting") != null);
}
