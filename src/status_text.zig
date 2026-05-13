//! Pure assembly of the bottom status bar's text payload.
//!
//! The proxy gathers contributions from three sources — the incognito
//! indicator, the configured base text, and the modules' `statusText`
//! hooks — and joins them with " │ " (U+2502) separators. The join
//! has one subtle rule: empty segments must NOT produce a leading or
//! double separator. That rule is the reason this lives in its own
//! file with its own tests.
//!
//! The function takes a fixed scratch buffer (the caller's stack space)
//! and writes into it via std.Io.Writer. No allocation, no I/O.

const std = @import("std");
const Style = @import("style.zig").Style;
const style_mod = @import("style.zig");

pub const separator = " \u{2502} ";

/// Append `text` to `w`, prepending a separator if `any` is already
/// true. Updates `any` to true if `text` is non-empty. Empty segments
/// are no-ops — they don't insert a separator, which is what keeps
/// a missing base_text or a silent module from leaving "│" littered
/// across an otherwise sparse bar.
pub fn writeSegment(w: *std.Io.Writer, any: *bool, text: []const u8) std.Io.Writer.Error!void {
    if (text.len == 0) return;
    if (any.*) try w.writeAll(separator);
    try w.writeAll(text);
    any.* = true;
}

/// Convenience: one-shot assembly with the known segments. The
/// incognito + subprocess segments are formatted with their own SGRs
/// (caller passes the styles).
pub const AssembleArgs = struct {
    /// Output writer.
    w: *std.Io.Writer,
    /// Whether the incognito indicator should be emitted as the first
    /// segment (with its own SGR + reset + bar-style reapply).
    incognito: bool,
    /// Style applied to the 🔒 segment.
    incognito_style: Style,
    /// Style of the surrounding bar — re-applied after the incognito /
    /// subprocess segments' resets so the next text picks up the bar
    /// style again.
    bar_style: Style,
    /// Subprocess target — when non-empty, renders as
    /// "→ <subprocess_text>" between the incognito segment and the
    /// base text. Empty (default) omits the segment.
    subprocess_text: []const u8 = "",
    /// Style applied to the subprocess segment.
    subprocess_style: Style = .{},
    /// Configured base text (may be empty).
    base_text: []const u8,
    /// Pre-gathered module contributions (may be empty).
    module_text: []const u8,
};

pub fn assemble(args: AssembleArgs) std.Io.Writer.Error!void {
    var any: bool = false;
    if (args.incognito) {
        // Each segment is its own writeAll call — separator logic in
        // writeSegment doesn't know about SGR bytes, but it doesn't
        // need to: the SGR runs only around the indicator's own glyph,
        // and writeSegment counts the whole thing as a single segment.
        var seg_buf: [96]u8 = undefined;
        var sw: std.Io.Writer = .fixed(&seg_buf);
        try sw.print("{f}\u{1F512} incognito{s}{f}", .{
            args.incognito_style,
            style_mod.reset,
            args.bar_style,
        });
        try writeSegment(args.w, &any, sw.buffered());
    }
    if (args.subprocess_text.len > 0) {
        var seg_buf: [256]u8 = undefined;
        var sw: std.Io.Writer = .fixed(&seg_buf);
        sw.print("{f}\u{2192} {s}{s}{f}", .{
            args.subprocess_style,
            args.subprocess_text,
            style_mod.reset,
            args.bar_style,
        }) catch {};
        try writeSegment(args.w, &any, sw.buffered());
    }
    try writeSegment(args.w, &any, args.base_text);
    try writeSegment(args.w, &any, args.module_text);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

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
