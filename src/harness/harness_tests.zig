//! Integration tests for the harness engine + the comptime hook fanning.
//! These drive a REAL child (`cat`, which echoes its stdin) under a PTY, so
//! they exercise spawn → drive → render → wait end to end against a non-atty
//! target. `cat` is used over a shell because it has no prompt/PS1 variance —
//! deterministic across machines.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

/// Minimal reproducible env so execvpe finds `cat` (nothing is inherited).
const test_env = [_]harness.KV{
    .{ .key = "PATH", .value = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" },
    .{ .key = "TERM", .value = "xterm-256color" },
    .{ .key = "HOME", .value = "/tmp" },
    .{ .key = "LANG", .value = "C.UTF-8" },
};

test "harness: bare engine (no modules) drives a child and waits on the screen" {
    const H = harness.Harness(.{});
    var h = try H.spawn(testing.allocator, .{ .argv = &.{"cat"}, .cols = 40, .rows = 10, .env = &test_env });
    defer h.deinit();

    try h.send("ping-harness\r");
    try testing.expect(try h.waitFor("ping-harness", 3000)); // cat echoes it back
    try testing.expect(h.gridContains("ping-harness"));

    try h.send("\x04"); // Ctrl-D → EOF → cat exits
    _ = try h.waitExit(3000);
    try testing.expect(h.exited);
}

test "harness: waitFor times out (returns false) on absent text" {
    const H = harness.Harness(.{});
    var h = try H.spawn(testing.allocator, .{ .argv = &.{"cat"}, .cols = 40, .rows = 10, .env = &test_env });
    defer h.deinit();
    try testing.expect(!(try h.waitFor("never-appears", 200)));
}

// ---- hook-fanning probe module --------------------------------------------
// File-scope recorders (the runtime is heap-pinned; this is the same pattern
// attop's panel tests use). Reset at the top of the test that reads them.
var probe_max_chunk: usize = 0;
var probe_output_calls: usize = 0;
var probe_snaps: usize = 0;

const Probe = struct {
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: harness.SessionInfo) !Runtime {
        return .{};
    }
    pub fn beforeRead(_: *Runtime, want: usize) usize {
        return @min(want, 4); // cap every read at 4 bytes
    }
    pub fn onOutput(_: *Runtime, bytes: []const u8) void {
        probe_output_calls += 1;
        if (bytes.len > probe_max_chunk) probe_max_chunk = bytes.len;
    }
    pub fn onSnapshot(_: *Runtime, _: []const u8, _: *const harness.Grid) !void {
        probe_snaps += 1;
    }
};

test "harness: beforeRead caps reads, onOutput + onSnapshot fan to modules" {
    probe_max_chunk = 0;
    probe_output_calls = 0;
    probe_snaps = 0;

    const H = harness.Harness(.{Probe});
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
}
