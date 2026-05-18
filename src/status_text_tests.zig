//! Tests for `status_text.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("status_text.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const Style = @import("style.zig").Style;
const style_mod = @import("style.zig");

// Re-binds of pub decls so test bodies stay short.
const assemble = mod.assemble;
const AssembleArgs = mod.AssembleArgs;
const separator = mod.separator;
const writeSegment = mod.writeSegment;

// ===========================================================================
// Tests
// ===========================================================================

test "writeSegment skips empty input and inserts no separator" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var any: bool = false;
    try writeSegment(&w, &any, "");
    try testing.expectEqual(@as(usize, 0), w.end);
    try testing.expect(!any);
}

test "writeSegment first non-empty input writes no leading separator" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var any: bool = false;
    try writeSegment(&w, &any, "atuin");
    try testing.expectEqualStrings("atuin", buf[0..w.end]);
    try testing.expect(any);
}

test "writeSegment between two non-empty inputs inserts separator" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var any: bool = false;
    try writeSegment(&w, &any, "a");
    try writeSegment(&w, &any, "b");
    try testing.expectEqualStrings("a \u{2502} b", buf[0..w.end]);
}

test "writeSegment empty between two non-empty does not double the separator" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var any: bool = false;
    try writeSegment(&w, &any, "a");
    try writeSegment(&w, &any, "");
    try writeSegment(&w, &any, "b");
    try testing.expectEqualStrings("a \u{2502} b", buf[0..w.end]);
}

test "assemble with nothing emits zero bytes" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try assemble(.{
        .w = &w,
        .incognito = false,
        .incognito_style = .{},
        .bar_style = .{},
        .base_text = "",
        .module_text = "",
    });
    try testing.expectEqual(@as(usize, 0), w.end);
}

test "assemble base + module joins with separator" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try assemble(.{
        .w = &w,
        .incognito = false,
        .incognito_style = .{},
        .bar_style = .{},
        .base_text = "atty",
        .module_text = "atuin",
    });
    try testing.expectEqualStrings("atty \u{2502} atuin", buf[0..w.end]);
}

test "assemble incognito is emitted first and styled" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try assemble(.{
        .w = &w,
        .incognito = true,
        .incognito_style = .{ .dim = true, .fg = 1 },
        .bar_style = .{ .dim = true },
        .base_text = "atty",
        .module_text = "",
    });
    const out = buf[0..w.end];
    // Incognito segment carries its own SGR (dim + fg=1).
    try testing.expect(std.mem.indexOf(u8, out, "\u{1F512} incognito") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[38;5;1m") != null);
    // It precedes the base text and there is exactly one separator.
    const inc_at = std.mem.indexOf(u8, out, "incognito").?;
    const base_at = std.mem.indexOf(u8, out, "atty").?;
    try testing.expect(inc_at < base_at);
    var sep_count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOf(u8, out[i..], separator)) |idx| : (i += idx + separator.len) sep_count += 1;
    try testing.expectEqual(@as(usize, 1), sep_count);
}

test "assemble incognito alone produces no trailing separator" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try assemble(.{
        .w = &w,
        .incognito = true,
        .incognito_style = .{ .dim = true, .fg = 1 },
        .bar_style = .{ .dim = true },
        .base_text = "",
        .module_text = "",
    });
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "incognito") != null);
    try testing.expect(std.mem.indexOf(u8, out, separator) == null);
}

test "assemble: subprocess segment alone renders with arrow glyph" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try assemble(.{
        .w = &w,
        .incognito = false,
        .incognito_style = .{},
        .bar_style = .{},
        .subprocess_text = "ssh:foo@bar",
        .subprocess_style = .{ .dim = true, .fg = 6 },
        .base_text = "",
        .module_text = "",
    });
    const out = buf[0..w.end];
    // Right-arrow glyph + the text.
    try testing.expect(std.mem.indexOf(u8, out, "\u{2192} ssh:foo@bar") != null);
    // No separator (only one segment).
    try testing.expect(std.mem.indexOf(u8, out, separator) == null);
}

test "assemble: empty subprocess_text omits the segment entirely" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try assemble(.{
        .w = &w,
        .incognito = false,
        .incognito_style = .{},
        .bar_style = .{},
        .subprocess_text = "", // empty — should be skipped
        .subprocess_style = .{ .dim = true, .fg = 6 },
        .base_text = "atty",
        .module_text = "",
    });
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\u{2192}") == null);
    try testing.expectEqualStrings("atty", out);
}

test "assemble: subprocess segment ordering — between incognito and base, with separators" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try assemble(.{
        .w = &w,
        .incognito = true,
        .incognito_style = .{ .dim = true, .fg = 1 },
        .bar_style = .{ .dim = true },
        .subprocess_text = "ssh:foo@bar",
        .subprocess_style = .{ .dim = true, .fg = 6 },
        .base_text = "atty",
        .module_text = "atuin",
    });
    const out = buf[0..w.end];
    // All four segments present.
    try testing.expect(std.mem.indexOf(u8, out, "incognito") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\u{2192} ssh:foo@bar") != null);
    try testing.expect(std.mem.indexOf(u8, out, "atty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "atuin") != null);
    // Ordering: incognito → subprocess → base → module.
    const inc_at = std.mem.indexOf(u8, out, "incognito").?;
    const sub_at = std.mem.indexOf(u8, out, "\u{2192}").?;
    const base_at = std.mem.indexOf(u8, out, "atty").?;
    const mod_at = std.mem.indexOf(u8, out, "atuin").?;
    try testing.expect(inc_at < sub_at);
    try testing.expect(sub_at < base_at);
    try testing.expect(base_at < mod_at);
    // Exactly three separators between four segments.
    var sep_count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOf(u8, out[i..], separator)) |idx| : (i += idx + separator.len) sep_count += 1;
    try testing.expectEqual(@as(usize, 3), sep_count);
}

test "assemble: subprocess segment style is applied with a reset after" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try assemble(.{
        .w = &w,
        .incognito = false,
        .incognito_style = .{},
        .bar_style = .{ .dim = true },
        .subprocess_text = "ssh:host",
        .subprocess_style = .{ .dim = true, .fg = 6 },
        .base_text = "atty",
        .module_text = "",
    });
    const out = buf[0..w.end];
    // The subprocess SGR uses fg=6.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[38;5;6m") != null);
    // The reset comes BEFORE the next segment's separator so
    // the separator picks up the bar's style, not the subprocess
    // segment's. (Reset is `\x1B[0m`.)
    const sub_at = std.mem.indexOf(u8, out, "\u{2192}").?;
    const reset_after = std.mem.indexOf(u8, out[sub_at..], "\x1B[0m");
    try testing.expect(reset_after != null);
}
