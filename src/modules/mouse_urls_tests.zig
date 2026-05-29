//! Integration tests for `modules/mouse_urls.zig`.

const std = @import("std");
const testing = std.testing;
const mod = @import("mouse_urls.zig");
const m = @import("../module.zig");
const mouse = @import("../mouse.zig");
const dispatch = @import("../dispatch.zig");
const LineState = @import("../line_state.zig").LineState;

const configure = mod.configure;
const Config = mod.Config;
const hostMatches = mod.hostMatches;

const test_io: std.Io = std.Io.failing;

test {
    _ = @import("mouse_urls/detect.zig");
}

fn ctx(line: *LineState, scratch: *std.ArrayList(u8)) m.Context {
    return .{
        .allocator = testing.allocator,
        .io = test_io,
        .line = line,
        .scratch = scratch,
        .is_tty = true,
        .terminal_rows = 24,
        .terminal_cols = 80,
    };
}

test "hostMatches — exact host" {
    try testing.expect(hostMatches("example.com", &.{"example.com"}));
    try testing.expect(!hostMatches("example.com", &.{"foo.com"}));
}

test "hostMatches — case insensitive" {
    try testing.expect(hostMatches("Example.COM", &.{"example.com"}));
    try testing.expect(hostMatches("example.com", &.{"EXAMPLE.com"}));
}

test "hostMatches — wildcard prefix" {
    try testing.expect(hostMatches("api.example.com", &.{"*.example.com"}));
    try testing.expect(hostMatches("a.b.example.com", &.{"*.example.com"}));
    // Bare host matches `*.example.com` per the doc: the suffix
    // entry also covers the apex.
    try testing.expect(hostMatches("example.com", &.{"*.example.com"}));
    try testing.expect(!hostMatches("other.com", &.{"*.example.com"}));
    try testing.expect(!hostMatches("attacker-example.com", &.{"*.example.com"}));
}

test "hostMatches — port stripped before comparison" {
    try testing.expect(hostMatches("localhost:8080", &.{"localhost"}));
    try testing.expect(hostMatches("example.com:443", &.{"example.com"}));
}

test "hostMatches — IPv6 literal with and without port" {
    try testing.expect(hostMatches("[::1]", &.{"[::1]"}));
    try testing.expect(hostMatches("[::1]:8080", &.{"[::1]"}));
    try testing.expect(hostMatches("[2001:db8::1]:443", &.{"[2001:db8::1]"}));
    try testing.expect(!hostMatches("[::1]", &.{"[::2]"}));
}

test "hostMatches — empty whitelist always misses" {
    try testing.expect(!hostMatches("example.com", &.{}));
}

test "whitelist_only mode — whitelisted host enters launch branch" {
    // /bin/true exists on every POSIX system (glibc + musl + alpine)
    // and exits 0 immediately, so the double-fork+exec succeeds and
    // the hint is "opening: ...". If a future CI uses an exotic image
    // where `true` is missing, this test will fail on the strict
    // assertion below — that's the expected signal, not a flake.
    const Mod = configure(.{
        .mode = .whitelist_only,
        .url_whitelist = &.{"example.com"},
        .opener = "true",
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "see https://example.com/foo\n");

    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 7,
        .row = 1,
        .mods = .{},
    };
    try testing.expectEqual(dispatch.MouseAction.consume, try Mod.onMouseClick(&rt, &c, click));
    const hint = (try Mod.provideHintText(&rt, &c)).?;
    try testing.expect(std.mem.startsWith(u8, hint, "opening: "));
    try testing.expectEqualStrings("opening: https://example.com/foo", hint);
}

test "whitelist_only mode — non-whitelisted host blocks with hint" {
    const Mod = configure(.{
        .mode = .whitelist_only,
        .url_whitelist = &.{"example.com"},
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "see https://malicious.io/path\n");
    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 7,
        .row = 1,
        .mods = .{},
    };
    try testing.expectEqual(dispatch.MouseAction.consume, try Mod.onMouseClick(&rt, &c, click));
    const hint = (try Mod.provideHintText(&rt, &c)).?;
    try testing.expectEqualStrings("host not in whitelist: malicious.io", hint);
}

test "never mode — every click is no-op-with-hint" {
    const Mod = configure(.{
        .mode = .never,
        .url_whitelist = &.{"example.com"},
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "https://example.com\n");
    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 5,
        .row = 1,
        .mods = .{},
    };
    try testing.expectEqual(dispatch.MouseAction.consume, try Mod.onMouseClick(&rt, &c, click));
    const hint = (try Mod.provideHintText(&rt, &c)).?;
    try testing.expectEqualStrings(
        "url-open disabled (mode=never): https://example.com",
        hint,
    );
}

test "click on row with no URL is passthrough" {
    const Mod = configure(.{ .url_whitelist = &.{"example.com"} });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "no URLs in this line\n");
    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 5,
        .row = 1,
        .mods = .{},
    };
    try testing.expectEqual(
        dispatch.MouseAction.passthrough,
        try Mod.onMouseClick(&rt, &c, click),
    );
}

test "non-left button is passthrough" {
    const Mod = configure(.{ .url_whitelist = &.{"example.com"} });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);
    try Mod.onOutput(&rt, &c, "https://example.com\n");

    const click: mouse.Event = .{ .button = .right, .kind = .press, .col = 5, .row = 1, .mods = .{} };
    try testing.expectEqual(
        dispatch.MouseAction.passthrough,
        try Mod.onMouseClick(&rt, &c, click),
    );
}

test "wildcard whitelist entry covers subdomain on click" {
    const Mod = configure(.{
        .mode = .whitelist_only,
        .url_whitelist = &.{"*.github.com"},
        .opener = "true",
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "https://api.github.com/repos\n");
    const click: mouse.Event = .{ .button = .left, .kind = .press, .col = 5, .row = 1, .mods = .{} };
    try testing.expectEqual(
        dispatch.MouseAction.consume,
        try Mod.onMouseClick(&rt, &c, click),
    );
    const hint = (try Mod.provideHintText(&rt, &c)).?;
    try testing.expect(std.mem.indexOf(u8, hint, "api.github.com") != null);
}

test "ask_each — untrusted click arms banner with statusText prompt" {
    const Mod = configure(.{
        .mode = .ask_each,
        .url_whitelist = &.{},
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "see https://blog.example.com/post\n");
    const click: mouse.Event = .{ .button = .left, .kind = .press, .col = 7, .row = 1, .mods = .{} };
    try testing.expectEqual(dispatch.MouseAction.consume, try Mod.onMouseClick(&rt, &c, click));

    try testing.expect(rt.armed);
    const banner = (try Mod.statusText(&rt, &c)).?;
    try testing.expectEqualStrings(
        "open blog.example.com? [y]es / [a]llow / [t]rust / cancel",
        banner,
    );
}

test "ask_each — 'y' opens once, doesn't add to session-trust" {
    const Mod = configure(.{
        .mode = .ask_each,
        .opener = "true",
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "https://once.example/path\n");
    const click: mouse.Event = .{ .button = .left, .kind = .press, .col = 5, .row = 1, .mods = .{} };
    _ = try Mod.onMouseClick(&rt, &c, click);
    try testing.expect(rt.armed);

    const action = try Mod.onInput(&rt, &c, "y");
    try testing.expectEqual(m.Action.swallow, action);
    try testing.expect(!rt.armed);
    try testing.expectEqual(@as(usize, 0), rt.session_filled);
    const hint = (try Mod.provideHintText(&rt, &c)).?;
    try testing.expectEqualStrings("opening: https://once.example/path", hint);
}

test "ask_each — 'a' adds host to session-trust + opens" {
    const Mod = configure(.{
        .mode = .ask_each,
        .opener = "true",
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "https://allow.example/x\n");
    const click: mouse.Event = .{ .button = .left, .kind = .press, .col = 5, .row = 1, .mods = .{} };
    _ = try Mod.onMouseClick(&rt, &c, click);

    _ = try Mod.onInput(&rt, &c, "a");
    try testing.expect(!rt.armed);
    try testing.expectEqual(@as(usize, 1), rt.session_filled);
    try testing.expectEqualStrings("allow.example", rt.session_hosts[0].slice());

    // Subsequent click on the same host fast-paths through the
    // banner — directly opens.
    try Mod.onOutput(&rt, &c, "https://allow.example/y\n");
    const click2: mouse.Event = .{ .button = .left, .kind = .press, .col = 5, .row = 2, .mods = .{} };
    _ = try Mod.onMouseClick(&rt, &c, click2);
    try testing.expect(!rt.armed);
}

test "ask_each — 't' surfaces sudo guidance + session-trusts" {
    const Mod = configure(.{
        .mode = .ask_each,
        .opener = "true",
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "https://trust.example/x\n");
    const click: mouse.Event = .{ .button = .left, .kind = .press, .col = 5, .row = 1, .mods = .{} };
    _ = try Mod.onMouseClick(&rt, &c, click);

    _ = try Mod.onInput(&rt, &c, "t");
    try testing.expect(!rt.armed);
    try testing.expectEqual(@as(usize, 1), rt.session_filled);
    const hint = (try Mod.provideHintText(&rt, &c)).?;
    try testing.expect(std.mem.indexOf(u8, hint, "sudo atty-guard urls allow trust.example") != null);
}

test "ask_each — Esc / Ctrl-C / 'c' cancel the banner without opening" {
    for ([_]u8{ 0x1b, 0x03, 'c', 'C' }) |key| {
        const Mod = configure(.{
            .mode = .ask_each,
            .opener = "true",
            .hint_ttl_ms = 60_000,
        });
        var rt = try Mod.attach(testing.allocator, test_io);
        defer Mod.detach(&rt, test_io);
        rt.test_clock_ms = 1000;

        var line = LineState{};
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(testing.allocator);
        var c = ctx(&line, &scratch);

        try Mod.onOutput(&rt, &c, "https://cancel.example/x\n");
        const click: mouse.Event = .{ .button = .left, .kind = .press, .col = 5, .row = 1, .mods = .{} };
        _ = try Mod.onMouseClick(&rt, &c, click);
        try testing.expect(rt.armed);

        const buf = [_]u8{key};
        const action = try Mod.onInput(&rt, &c, &buf);
        try testing.expectEqual(m.Action.swallow, action);
        try testing.expect(!rt.armed);
        try testing.expectEqual(@as(usize, 0), rt.session_filled);
    }
}

test "ask_each — unrelated keystroke while armed is swallowed (not forwarded)" {
    const Mod = configure(.{ .mode = .ask_each, .opener = "true", .hint_ttl_ms = 60_000 });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);
    try Mod.onOutput(&rt, &c, "https://example.com\n");
    _ = try Mod.onMouseClick(&rt, &c, .{ .button = .left, .kind = .press, .col = 5, .row = 1, .mods = .{} });

    const action = try Mod.onInput(&rt, &c, "x");
    try testing.expectEqual(m.Action.swallow, action);
    try testing.expect(rt.armed); // still armed after unrelated key
}

test "ask_each — pre-existing whitelist entry fast-paths past the banner" {
    const Mod = configure(.{
        .mode = .ask_each,
        .url_whitelist = &.{"trusted.example"},
        .opener = "true",
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "https://trusted.example/x\n");
    _ = try Mod.onMouseClick(&rt, &c, .{ .button = .left, .kind = .press, .col = 5, .row = 1, .mods = .{} });
    try testing.expect(!rt.armed);
    const hint = (try Mod.provideHintText(&rt, &c)).?;
    try testing.expectEqualStrings("opening: https://trusted.example/x", hint);
}

test "session_trust FIFO eviction at capacity — strict ordering" {
    const Mod = configure(.{
        .mode = .ask_each,
        .opener = "true",
        .session_trust_capacity = 3,
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    const hosts = [_][]const u8{ "ha.example", "hb.example", "hc.example", "hd.example", "he.example" };
    inline for ([_][]const u8{ "a", "b", "c", "d", "e" }, 1..) |suffix, row| {
        const out = "https://h" ++ suffix ++ ".example\n";
        try Mod.onOutput(&rt, &c, out);
        const click: mouse.Event = .{ .button = .left, .kind = .press, .col = 5, .row = @intCast(row), .mods = .{} };
        _ = try Mod.onMouseClick(&rt, &c, click);
        _ = try Mod.onInput(&rt, &c, "a");
    }

    try testing.expectEqual(@as(usize, 3), rt.session_filled);

    // After 5 adds with capacity 3, ha + hb were evicted; hc, hd, he survive.
    try testing.expect(!ringHas(&rt, hosts[0])); // ha evicted
    try testing.expect(!ringHas(&rt, hosts[1])); // hb evicted
    try testing.expect(ringHas(&rt, hosts[2])); // hc
    try testing.expect(ringHas(&rt, hosts[3])); // hd
    try testing.expect(ringHas(&rt, hosts[4])); // he

    // hc must still hostTrust — proves the surviving entries work.
    try Mod.onOutput(&rt, &c, "https://hc.example/p\n");
    const click_hc: mouse.Event = .{ .button = .left, .kind = .press, .col = 5, .row = 6, .mods = .{} };
    _ = try Mod.onMouseClick(&rt, &c, click_hc);
    try testing.expect(!rt.armed); // fast-path through session-trust
}

fn ringHas(rt: anytype, host: []const u8) bool {
    for (rt.session_hosts) |*slot| {
        if (std.mem.eql(u8, slot.slice(), host)) return true;
    }
    return false;
}

test "ask_each — 'y' on first host, 'a' on second: only the 'a' host is trusted" {
    // Inverse-coverage for the 'y' test: prove 'y' does NOT fall through
    // to the 'a' arm by interleaving them in the same Runtime.
    const Mod = configure(.{
        .mode = .ask_each,
        .opener = "true",
        .hint_ttl_ms = 60_000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "https://once.example/p\n");
    _ = try Mod.onMouseClick(&rt, &c, .{ .button = .left, .kind = .press, .col = 5, .row = 1, .mods = .{} });
    _ = try Mod.onInput(&rt, &c, "y");
    try testing.expectEqual(@as(usize, 0), rt.session_filled);

    try Mod.onOutput(&rt, &c, "https://twice.example/p\n");
    _ = try Mod.onMouseClick(&rt, &c, .{ .button = .left, .kind = .press, .col = 5, .row = 2, .mods = .{} });
    _ = try Mod.onInput(&rt, &c, "a");

    try testing.expectEqual(@as(usize, 1), rt.session_filled);
    try testing.expectEqualStrings("twice.example", rt.session_hosts[0].slice());
    // The 'y' host must NOT have been trusted.
    try testing.expect(!ringHas(&rt, "once.example"));
}

test "hint TTL expiry suppresses stale hint" {
    const Mod = configure(.{
        .mode = .never,
        .hint_ttl_ms = 1000,
    });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);
    rt.test_clock_ms = 1000;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var c = ctx(&line, &scratch);

    try Mod.onOutput(&rt, &c, "https://example.com\n");
    const click: mouse.Event = .{ .button = .left, .kind = .press, .col = 5, .row = 1, .mods = .{} };
    _ = try Mod.onMouseClick(&rt, &c, click);

    // Advance past the TTL; hint should be cleared.
    rt.test_clock_ms = 3000;
    try testing.expect((try Mod.provideHintText(&rt, &c)) == null);
}
