//! A bordered box for panel detail views. Drawn sequentially (top border →
//! content rows → bottom border), so it fits the host's top-to-bottom render
//! model — no absolute positioning. Box-drawing characters are standard
//! Unicode (not nerd-font), so they're safe under every theme.
//!
//! Content is assumed single-width ASCII (the dashboard's detail rows are
//! `key   value` pairs); a line wider than the inner width is byte-truncated.

const std = @import("std");
const atty = @import("atty");
const theme = @import("theme.zig");

const reset = atty.style.reset;

const tl = "\u{250C}"; // ┌
const tr = "\u{2510}"; // ┐
const bl = "\u{2514}"; // └
const br = "\u{2518}"; // ┘
const hbar = "\u{2500}"; // ─
const vbar = "\u{2502}"; // │

/// Draw a box framing `lines` under `title`, sized to the widest of
/// {title, lines} but capped to fit `max_cols`. Indented two columns to match
/// the panels' content gutter.
pub fn drawBox(w: *std.Io.Writer, title: []const u8, lines: []const []const u8, max_cols: usize) !void {
    const t = theme.active;

    // Inner width = the content columns between the side borders' padding.
    var inner: usize = title.len;
    for (lines) |l| inner = @max(inner, l.len);
    // Cap so the whole box (2 gutter + 2 border + 2 padding + inner) fits.
    const cap = if (max_cols > 8) max_cols - 8 else 1;
    if (inner > cap) inner = cap;
    if (inner < 1) inner = 1;

    // Top border: ┌─ title ─…─┐  (the run between ┌┐ spans inner+2 columns:
    // "─ " + title + trailing "─" fill, with the title clamped to fit).
    // Clamp the title to inner-1 so the top run ("─ " + title + " ") can never
    // exceed the box's interior width (inner+2) — otherwise the fill loop is
    // skipped and the top border ends up one ─ wider than the rest.
    const tmax = inner - 1; // inner is >= 1 (clamped above)
    const title_shown = if (title.len > tmax) title[0..tmax] else title;
    try w.print("  {f}{s}{s} {s} ", .{ t.muted, tl, hbar, title_shown });
    // Columns used after ┌: "─"(1)+" "(1)+title+" "(1) = title_shown.len + 3.
    // Fill ─ up to inner+2, then ┐.
    var used: usize = title_shown.len + 3;
    while (used < inner + 2) : (used += 1) try w.writeAll(hbar);
    try w.print("{s}{s}\r\n", .{ tr, reset });

    // Content rows: │ <line padded to inner> │
    for (lines) |line| {
        const shown = if (line.len > inner) line[0..inner] else line;
        try w.print("  {f}{s}{s} {s}", .{ t.muted, vbar, reset, shown });
        var pad: usize = inner - shown.len;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print(" {f}{s}{s}\r\n", .{ t.muted, vbar, reset });
    }

    // Bottom border: └─…─┘ spanning inner+2.
    try w.print("  {f}{s}", .{ t.muted, bl });
    var i: usize = 0;
    while (i < inner + 2) : (i += 1) try w.writeAll(hbar);
    try w.print("{s}{s}\r\n", .{ br, reset });
}

test {
    _ = @import("box_tests.zig");
}
