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
