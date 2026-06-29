//! Integration tests for the ttysnap engine + the comptime hook fanning.
//! These drive a REAL child (`cat`, which echoes its stdin) under a PTY, so
//! they exercise spawn → drive → render → wait end to end against a non-atty
//! target. `cat` is used over a shell because it has no prompt/PS1 variance —
//! deterministic across machines.

const std = @import("std");
const testing = std.testing;
const ttysnap = @import("ttysnap.zig");

/// Minimal reproducible env so execvpe finds `cat` (nothing is inherited).
const test_env = [_]ttysnap.KV{
    .{ .key = "PATH", .value = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" },
    .{ .key = "TERM", .value = "xterm-256color" },
    .{ .key = "HOME", .value = "/tmp" },
    .{ .key = "LANG", .value = "C.UTF-8" },
};

test "ttysnap: bare engine (no modules) drives a child and waits on the screen" {
    const H = ttysnap.Harness(.{});
    var h = try H.spawn(testing.allocator, .{ .argv = &.{"cat"}, .cols = 40, .rows = 10, .env = &test_env });
    defer h.deinit();

    try h.send("ping-ttysnap\r");
    try testing.expect(try h.waitFor("ping-ttysnap", 3000)); // cat echoes it back
    try testing.expect(h.gridContains("ping-ttysnap"));

    try h.send("\x04"); // Ctrl-D → EOF → cat exits
    _ = try h.waitExit(3000);
    try testing.expect(h.exited);
}

test "ttysnap: waitFor times out (returns false) on absent text" {
    const H = ttysnap.Harness(.{});
    var h = try H.spawn(testing.allocator, .{ .argv = &.{"cat"}, .cols = 40, .rows = 10, .env = &test_env });
    defer h.deinit();
    try testing.expect(!(try h.waitFor("never-appears", 200)));
}

test "ttysnap: resize grows the grid + preserves rendered content" {
    const H = ttysnap.Harness(.{});
    var h = try H.spawn(testing.allocator, .{ .argv = &.{"cat"}, .cols = 20, .rows = 5, .env = &test_env });
    defer h.deinit();

    try h.send("hello-resize\r");
    try testing.expect(try h.waitFor("hello-resize", 3000));

    try h.resize(40, 12);
    try testing.expectEqual(@as(u16, 40), h.cols);
    try testing.expectEqual(@as(u16, 12), h.rows);
    try testing.expectEqual(@as(u16, 12), h.grid.rows);
    try testing.expectEqual(@as(u16, 40), h.grid.cols);
    try testing.expect(h.gridContains("hello-resize")); // content survived the resize
}

// ---- hook-fanning probe module --------------------------------------------
// File-scope recorders (the runtime is heap-pinned; this is the same pattern
// attop's panel tests use). Reset at the top of the test that reads them.
var probe_max_chunk: usize = 0;
var probe_output_calls: usize = 0;
var probe_snaps: usize = 0;
var probe_exits: usize = 0;

const Probe = struct {
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: ttysnap.SessionInfo) !Runtime {
        return .{};
    }
    pub fn beforeRead(_: *Runtime, want: usize) usize {
        return @min(want, 4); // cap every read at 4 bytes
    }
    pub fn onOutput(_: *Runtime, bytes: []const u8) void {
        probe_output_calls += 1;
        if (bytes.len > probe_max_chunk) probe_max_chunk = bytes.len;
    }
    pub fn onSnapshot(_: *Runtime, _: []const u8, _: *const ttysnap.Grid) !void {
        probe_snaps += 1;
    }
    pub fn onExit(_: *Runtime, _: u32) void {
        probe_exits += 1;
    }
};

test "ttysnap: beforeRead caps reads, onOutput/onSnapshot/onExit fan to modules" {
    probe_max_chunk = 0;
    probe_output_calls = 0;
    probe_snaps = 0;
    probe_exits = 0;

    const H = ttysnap.Harness(.{Probe});
    var h = try H.spawn(testing.allocator, .{ .argv = &.{"cat"}, .cols = 40, .rows = 10, .env = &test_env });
    defer h.deinit();

    try h.send("abcdefghijklmnop\r");
    try testing.expect(try h.waitFor("abcdef", 3000));

    try testing.expect(probe_output_calls > 0); // onOutput fired
    try testing.expect(probe_max_chunk > 0);
    try testing.expect(probe_max_chunk <= 4); // beforeRead(4) capped EVERY read

    try h.snapshot("checkpoint");
    try testing.expectEqual(@as(usize, 1), probe_snaps); // onSnapshot fanned

    try h.send("\x04");
    _ = try h.waitExit(3000);
    try testing.expectEqual(@as(usize, 1), probe_exits); // onExit fired exactly once
}

test "ttysnap: terminate (deinit on a live child) reaps it + fires onExit once" {
    probe_exits = 0;
    const H = ttysnap.Harness(.{Probe});
    var h = try H.spawn(testing.allocator, .{ .argv = &.{ "sleep", "30" }, .cols = 40, .rows = 10, .env = &test_env });
    try testing.expect(!h.exited);
    h.deinit(); // no waitExit → drives the terminate() teardown path
    try testing.expectEqual(@as(usize, 1), probe_exits); // reaped + onExit once, not double
}
