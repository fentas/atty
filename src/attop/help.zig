//! attop Help screen — an in-app keybinding + environment reference, so the
//! dashboard is usable without leaving it for the README. PURE render;
//! theme + i18n driven. Key names, env vars, and the short screen titles
//! stay literal (they're literal everywhere); the section labels are i18n'd.

const std = @import("std");
const atty = @import("atty");
const theme = @import("theme.zig");
const i18n = @import("i18n.zig");

const reset = atty.style.reset;

pub const compact_cols: u16 = 80;

const KeyRow = struct { key: []const u8, screen: []const u8 };
const rows = [_]KeyRow{
    .{ .key = "h", .screen = "Home" },
    .{ .key = "g", .screen = "Guard" },
    .{ .key = "f", .screen = "Fleet" },
    .{ .key = "s", .screen = "Setup" },
    .{ .key = "?", .screen = "Help" },
    .{ .key = "q", .screen = "Quit" },
};

pub fn renderHelp(buf: []u8, cols: u16, rows_: u16) []const u8 {
    _ = rows_;
    var w = std.Io.Writer.fixed(buf);
    render(&w, cols) catch {};
    return buf[0..w.end];
}

fn render(w: *std.Io.Writer, cols: u16) !void {
    const t = theme.active;
    const s = i18n.active;
    try w.writeAll("\x1b[2J\x1b[H");
    if (cols < compact_cols) {
        try w.print("{f}attop{s}\r\n\r\n", .{ t.title, reset });
    } else {
        try w.print("{f}attop{s}{s}\r\n\r\n", .{ t.title, reset, s.suffix_help });
    }

    try w.print("  {f}{s}{s}\r\n", .{ t.muted, s.help_keys, reset });
    for (rows) |r| {
        try w.print("    {f}{s}{s}   {s}\r\n", .{ t.accent, r.key, reset, r.screen });
    }

    try w.print(
        "\r\n  {f}{s}{s}    ATTOP_THEME=dark|light|high-contrast|mono|ascii  \u{B7}  NO_COLOR\r\n",
        .{ t.muted, s.help_display, reset },
    );
    try w.print("  {f}{s}{s}   ATTOP_LANG (en, de)\r\n", .{ t.muted, s.help_language, reset });

    try w.print("\r\n  {f}{s}{s}\r\n", .{ t.muted, s.help_needs_daemon, reset });
}

test {
    _ = @import("help_tests.zig");
}
