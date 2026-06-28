//! attop theming — the screens paint with semantic ROLES (ok/warn/danger/
//! muted/accent/title) + a glyph set, not raw colors, so the look is
//! consistent and swappable (dark/light/high-contrast/ascii) and degrades
//! under NO_COLOR. The active theme is resolved once at startup and read
//! globally by the (otherwise pure) renders — set it before rendering.

const std = @import("std");
const atty = @import("atty");
const Style = atty.Style;

/// Glyphs with an ASCII fallback for non-nerd-font / NO_COLOR terminals.
pub const Glyphs = struct {
    protected: []const u8,
    unguarded: []const u8,
    active: []const u8,
    shield: []const u8,
    ai: []const u8,
    suggest: []const u8,
    incognito: []const u8,
    bullet: []const u8,
    ellipsis: []const u8,
};

pub const Theme = struct {
    title: Style,
    ok: Style,
    warn: Style,
    danger: Style,
    muted: Style,
    accent: Style,
    glyph: Glyphs,
};

const unicode_glyphs = Glyphs{
    .protected = "\u{25CF}", // ●
    .unguarded = "\u{25CB}", // ○
    .active = "\u{25B8}", // ▸
    .shield = "\u{1F6E1}", // 🛡
    .ai = "\u{1F916}", // 🤖
    .suggest = "\u{2728}", // ✨
    .incognito = "\u{1F512}", // 🔒
    .bullet = "\u{B7}", // ·
    .ellipsis = "\u{2026}", // …
};

const ascii_glyphs = Glyphs{
    .protected = "*",
    .unguarded = "o",
    .active = ">",
    .shield = "#",
    .ai = "AI",
    .suggest = "~",
    .incognito = "P",
    .bullet = "-",
    .ellipsis = "...",
};

pub const dark = Theme{
    .title = .{ .bold = true },
    .ok = .{ .bold = true, .fg = 2 }, // green
    .warn = .{ .bold = true, .fg = 3 }, // yellow
    .danger = .{ .bold = true, .fg = 1 }, // red
    .muted = .{ .dim = true },
    .accent = .{ .bold = true, .fg = 6 }, // cyan
    .glyph = unicode_glyphs,
};

pub const light = Theme{
    .title = .{ .bold = true },
    .ok = .{ .bold = true, .fg = 2 },
    .warn = .{ .bold = true, .fg = 3 },
    .danger = .{ .bold = true, .fg = 1 },
    .muted = .{ .fg = 8 }, // gray (dim is hard to read on a light bg)
    .accent = .{ .bold = true, .fg = 4 }, // blue (cyan washes out on light)
    .glyph = unicode_glyphs,
};

pub const high_contrast = Theme{
    .title = .{ .bold = true, .fg = 15 },
    .ok = .{ .bold = true, .fg = 10 },
    .warn = .{ .bold = true, .fg = 11 },
    .danger = .{ .bold = true, .fg = 9 },
    .muted = .{ .bold = true, .fg = 7 },
    .accent = .{ .bold = true, .fg = 15 },
    .glyph = unicode_glyphs,
};

/// NO_COLOR / no-nerd-font: no foreground colors, ASCII glyphs. Bold is
/// kept (it's monochrome-safe structure, not color).
pub const ascii = Theme{
    .title = .{ .bold = true },
    .ok = .{ .bold = true },
    .warn = .{ .bold = true },
    .danger = .{ .bold = true },
    .muted = .{ .dim = true },
    .accent = .{ .bold = true },
    .glyph = ascii_glyphs,
};

/// The active theme — set once at startup (see `resolve`), read by renders.
pub var active: Theme = dark;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

/// Resolve the theme: `$ATTOP_THEME` override wins; else `NO_COLOR` →
/// ascii; else a light terminal bg (via `COLORFGBG`) → light; else dark.
pub fn resolve() Theme {
    if (getenv("ATTOP_THEME")) |p| {
        if (byName(std.mem.span(p))) |t| return t;
    }
    if (getenv("NO_COLOR") != null) return ascii;
    if (getenv("COLORFGBG")) |p| {
        if (looksLight(std.mem.span(p))) return light;
    }
    return dark;
}

/// Theme by name, or null if unknown.
pub fn byName(name: []const u8) ?Theme {
    if (std.mem.eql(u8, name, "dark")) return dark;
    if (std.mem.eql(u8, name, "light")) return light;
    if (std.mem.eql(u8, name, "high-contrast") or std.mem.eql(u8, name, "high_contrast")) return high_contrast;
    if (std.mem.eql(u8, name, "ascii")) return ascii;
    return null;
}

/// COLORFGBG is "fg;bg" (sometimes "fg;;bg"); a light background is a
/// high/white index (7 or 15).
pub fn looksLight(colorfgbg: []const u8) bool {
    const bg = if (std.mem.lastIndexOfScalar(u8, colorfgbg, ';')) |i| colorfgbg[i + 1 ..] else return false;
    return std.mem.eql(u8, bg, "7") or std.mem.eql(u8, bg, "15");
}

test {
    _ = @import("theme_tests.zig");
}
