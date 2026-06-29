//! ttysnap — the configured TTY-test binary: the "single binary precompiled
//! with config.zig" form of the framework (docs/ttysnap.md).
//!
//! This example drives `bash` through the ttysnap and asserts on the RENDERED
//! screen — proving the framework end to end against a non-atty target. Swap
//! the scenario below for your own, or the `modules` tuple in `config.zig` for
//! different observers / fault injectors; the composition is baked at build
//! time. Exits 0 on success, non-zero on the first failed assertion.

const std = @import("std");
const ttysnap = @import("ttysnap.zig");
const config = @import("config.zig");

/// A minimal, reproducible environment for the child — nothing is inherited
/// (see pty.zig), so PATH must let execvpe find `bash` and bash find its
/// commands. No PS1 override: bash --norc's default prompt already ends in `$`.
const child_env = [_]ttysnap.KV{
    .{ .key = "PATH", .value = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" },
    .{ .key = "TERM", .value = "xterm-256color" },
    .{ .key = "HOME", .value = "/tmp" },
    .{ .key = "LANG", .value = "C.UTF-8" },
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const H = ttysnap.Harness(config.modules);
    var h = try H.spawn(alloc, .{
        .argv = &.{ "bash", "--norc", "--noprofile", "-i" },
        .cols = 80,
        .rows = 24,
        .env = &child_env,
    });
    defer h.deinit();

    try check("shell prompt appears", try h.waitFor("$", 3000));

    try h.send("printf 'hello-from-ttysnap\\n'\r");
    try check("command output rendered", try h.waitFor("hello-from-ttysnap", 3000));

    // No-op unless a snapshotter is composed into config.modules.
    try h.snapshot("hello");

    try h.send("exit\r");
    const status = (try h.waitExit(3000)) orelse {
        std.debug.print("ttysnap example: FAIL — child did not exit in time\n", .{});
        return error.AssertionFailed;
    };
    std.debug.print("ttysnap example: OK (child wait status {d})\n", .{status});
}

fn check(label: []const u8, ok: bool) !void {
    if (!ok) {
        std.debug.print("ttysnap example: FAIL — {s}\n", .{label});
        return error.AssertionFailed;
    }
}

test {
    // Import the source files; each with tests carries a sibling
    // `test { _ = @import("..._tests.zig"); }` stub that cascades (house style).
    _ = @import("ttysnap.zig");
    _ = @import("pty.zig");
    _ = @import("io.zig");
    _ = @import("module.zig");
    _ = @import("modules/fragment_injector.zig");
    _ = @import("modules/cast_recorder.zig");
    _ = @import("modules/snapshotter.zig");
    _ = @import("modules/latency_injector.zig");
    _ = @import("modules/resize_injector.zig");
    _ = @import("modules/gif_recorder.zig");
}
