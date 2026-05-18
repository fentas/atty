//! Tests for `style.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("style.zig");

// Re-binds of pub decls so test bodies stay short.
const presets = mod.presets;
const reset = mod.reset;
const Style = mod.Style;

test "Style format emits SGR for enabled fields only" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const s = Style{ .dim = true, .italic = true };
    try w.print("{f}", .{s});
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[2m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[1m") == null);
}

test "Style format with fg/bg colours" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const s = Style{ .bold = true, .fg = 244, .bg = 0 };
    try w.print("{f}", .{s});
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[38;5;244m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1B[48;5;0m") != null);
}

test "Default Style writes nothing" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{Style{}});
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}
