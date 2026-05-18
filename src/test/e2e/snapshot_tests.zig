//! Tests for `test/e2e/snapshot.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("snapshot.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const Allocator = std.mem.Allocator;
const vt = @import("vt.zig");
const posix = std.posix;

// Re-binds of pub decls so test bodies stay short.
const captureFrame = mod.captureFrame;
const Cast = mod.Cast;
const compareFrame = mod.compareFrame;
const CompareResult = mod.CompareResult;
const EnvSnapshot = mod.EnvSnapshot;
const fmtTomlStr = mod.fmtTomlStr;
const Frame = mod.Frame;
const monoMillis = mod.monoMillis;
const writeActualFrame = mod.writeActualFrame;
const writeEnv = mod.writeEnv;
const writeGoldenFrame = mod.writeGoldenFrame;

test "captureFrame round-trips a tiny grid" {
    var g = try vt.Grid.init(std.testing.allocator, 1, 8);
    defer g.deinit();
    g.feed("hi");
    var frame = try captureFrame(std.testing.allocator, &g);
    defer frame.deinit();
    try std.testing.expectEqualStrings("hi\n", frame.grid_text);
}

test "writeEnv emits valid-looking TOML" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeEnv(&w, .{
        .atty_version = "0.1.0",
        .cols = 80,
        .rows = 24,
        .argv = &.{ "atty", "bash" },
        .forced_env = &.{
            .{ .key = "TERM", .value = "xterm-256color" },
        },
        .extra_env = &.{},
    });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "cols = 80") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TERM = \"xterm-256color\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0 = \"atty\"") != null);
}
