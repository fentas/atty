//! `Style` — the universal text-styling primitive shared by atty's
//! visible elements (ghost overlay, guardrail warning, future
//! indicators…). Every module that paints something on screen should
//! accept a `Style` field rather than hardcoding SGR escapes.
//!
//! `presets` is the optional palette — copy them into your config or
//! build your own. They're just `Style` literals.

const std = @import("std");

pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    /// 256-colour foreground index (0–255). null = terminal default.
    /// 8–15 = bright variants of 0–7, 16–231 = 6×6×6 RGB cube,
    /// 232–255 = grayscale.
    fg: ?u8 = null,
    bg: ?u8 = null,

    /// `{f}` formatter: emit the SGR prefix bytes for this style.
    /// Caller is responsible for emitting `style.reset` after the
    /// styled text. A fully-default `Style{}` writes zero bytes.
    pub fn format(self: Style, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.bold) try w.writeAll("\x1B[1m");
        if (self.dim) try w.writeAll("\x1B[2m");
        if (self.italic) try w.writeAll("\x1B[3m");
        if (self.underline) try w.writeAll("\x1B[4m");
        if (self.reverse) try w.writeAll("\x1B[7m");
        if (self.fg) |f| try w.print("\x1B[38;5;{d}m", .{f});
        if (self.bg) |b| try w.print("\x1B[48;5;{d}m", .{b});
    }
};

/// SGR-reset sequence — emit after any styled text to restore defaults.
pub const reset = "\x1B[0m";

/// Named palette. Use as `atty.style.presets.muted`, copy into your
/// own theme struct, or ignore entirely and write `.{}` literals.
pub const presets = struct {
    pub const none: Style = .{};
    pub const muted: Style = .{ .dim = true };
    pub const muted_italic: Style = .{ .dim = true, .italic = true };
    pub const emphasis: Style = .{ .bold = true };
    pub const warning: Style = .{ .bold = true, .fg = 3 }; // yellow
    pub const danger: Style = .{ .bold = true, .fg = 1 }; // red
    pub const info: Style = .{ .fg = 6 }; // cyan
};

// ─── tests ────────────────────────────────────────────────────────────────

// ===========================================================================
// Tests — extracted to `style_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("style_tests.zig");
}
