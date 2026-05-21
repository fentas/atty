//! Minimal markdown → ANSI SGR renderer for chat-panel turns.
//!
//! LLMs emit `\n`-separated prose with `**bold**` and `` `code` ``
//! inline. Rendering it through `renderWrappedRaw` (which flattens
//! `\n` to space and ignores markers) loses both shape and emphasis,
//! making replies hard to scan. This module preserves the source
//! structure: hard breaks at `\n`, SGR styling for bold/code spans,
//! and codepoint-aware wrap at the column budget so wide glyphs
//! (CJK, emoji) bill correctly.
//!
//! Scope is deliberately small. Italics (`*` / `_`) are skipped —
//! single `*` collides with bullet-list markers, single `_` with
//! identifiers; the false-positive rate isn't worth the value.
//! Headings, lists, and links can layer on top later without
//! rewriting the wrap/state machine.
//!
//! The renderer emits SGR opens/closes ONLY at span boundaries;
//! when a wrap row break crosses an open span, the row is closed
//! with the matching SGR-reset, then the next row re-opens the
//! span so styling continues visually. That way a paint-time
//! truncation can't leak bold styling past the cell.

const std = @import("std");
const pw = @import("paint_width.zig");

const SGR_BOLD_OPEN: []const u8 = "\x1B[1m";
const SGR_BOLD_CLOSE: []const u8 = "\x1B[22m";
const SGR_CODE_OPEN: []const u8 = "\x1B[22;38;5;14m";
const SGR_CODE_CLOSE: []const u8 = "\x1B[39m";
const OVERFLOW_MARKER: []const u8 = " \x1B[2m[\u{2026}]\x1B[0m";
const OVERFLOW_MARKER_COLS: usize = 5;

/// Render `content` to `w` with markdown-aware styling. Returns
/// number of panel rows consumed (>=1).
///
/// Splits on `\n` for hard breaks; wraps each line to `cols` at the
/// last space inside the budget (hard break on a codepoint boundary
/// if a single token exceeds `cols`). At most `max_rows` rows; the
/// last visible row gets a dim `[…]` marker when more content
/// remains.
///
/// `writeSanitizedFn` is invoked for plain-text segments — the
/// caller's sanitizer that filters control bytes / preserves UTF-8
/// continuation bytes. SGR styling is emitted directly (atty owns
/// those bytes).
pub fn render(
    w: *std.Io.Writer,
    content: []const u8,
    cols: usize,
    max_rows: usize,
    writeSanitizedFn: *const fn (w: *std.Io.Writer, bytes: []const u8) anyerror!void,
) anyerror!usize {
    if (content.len == 0 or max_rows == 0 or cols == 0) return 1;

    var rows: usize = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    // One chunk look-ahead so the LAST allowed row knows whether
    // more content is coming and can emit the `[…]` marker inline.
    var pending_chunk: ?Chunk = null;

    while (line_iter.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        // Empty source line = blank row (preserves paragraph breaks).
        if (line.len == 0) {
            if (try emitChunkOrOverflow(w, &pending_chunk, &rows, max_rows, cols, writeSanitizedFn, true)) {
                return rows;
            }
            pending_chunk = .{ .line = "", .span = .plain };
            continue;
        }

        // Wrap this line into chunks at cols boundaries.
        var wrap = lineWrapIter(line, cols);
        while (wrap.next()) |chunk_line| {
            if (try emitChunkOrOverflow(w, &pending_chunk, &rows, max_rows, cols, writeSanitizedFn, true)) {
                return rows;
            }
            pending_chunk = .{ .line = chunk_line, .span = .plain };
        }
    }

    if (try emitChunkOrOverflow(w, &pending_chunk, &rows, max_rows, cols, writeSanitizedFn, false)) {
        return rows;
    }
    return if (rows == 0) 1 else rows;
}

const Chunk = struct {
    line: []const u8,
    span: Span,
};

const Span = enum { plain };

/// Emit the pending chunk (if any) and, when `more_pending` is true
/// AND this would be the last allowed row, trim + emit the overflow
/// marker. Returns true when caller should bail (overflow fired);
/// false when caller should keep iterating.
fn emitChunkOrOverflow(
    w: *std.Io.Writer,
    pending: *?Chunk,
    rows: *usize,
    max_rows: usize,
    cols: usize,
    writeSanitizedFn: *const fn (w: *std.Io.Writer, bytes: []const u8) anyerror!void,
    more_pending: bool,
) anyerror!bool {
    const p = pending.* orelse return false;
    if (rows.* > 0) try w.writeAll("\r\n\x1B[2K");
    if (more_pending and rows.* + 1 == max_rows) {
        // Last allowed row, more content waiting → trim line to
        // (cols - marker_cols) and tack on the marker.
        const trim_to = if (cols > OVERFLOW_MARKER_COLS) cols - OVERFLOW_MARKER_COLS else cols;
        try renderInline(w, pw.truncateToCols(p.line, trim_to), writeSanitizedFn);
        try w.writeAll(OVERFLOW_MARKER);
        rows.* += 1;
        pending.* = null;
        return true;
    }
    try renderInline(w, p.line, writeSanitizedFn);
    rows.* += 1;
    pending.* = null;
    return false;
}

/// Render a single line's worth of inline markdown — open/close SGR
/// at `**`/`` ` `` boundaries; everything else passes through the
/// caller's sanitizer.
fn renderInline(
    w: *std.Io.Writer,
    line: []const u8,
    writeSanitizedFn: *const fn (w: *std.Io.Writer, bytes: []const u8) anyerror!void,
) !void {
    var i: usize = 0;
    var in_bold = false;
    var in_code = false;
    var seg_start: usize = 0;
    while (i < line.len) {
        const b = line[i];
        // Backtick: toggle code span. Doesn't nest with bold inside
        // — code spans are literal, ignore other markers.
        if (b == '`') {
            if (i > seg_start) try writeSanitizedFn(w, line[seg_start..i]);
            if (in_code) {
                try w.writeAll(SGR_CODE_CLOSE);
                in_code = false;
            } else {
                if (in_bold) {
                    try w.writeAll(SGR_BOLD_CLOSE);
                    in_bold = false;
                }
                try w.writeAll(SGR_CODE_OPEN);
                in_code = true;
            }
            i += 1;
            seg_start = i;
            continue;
        }
        // Bold: `**`. Skipped while inside a code span.
        if (!in_code and b == '*' and i + 1 < line.len and line[i + 1] == '*') {
            if (i > seg_start) try writeSanitizedFn(w, line[seg_start..i]);
            if (in_bold) {
                try w.writeAll(SGR_BOLD_CLOSE);
                in_bold = false;
            } else {
                try w.writeAll(SGR_BOLD_OPEN);
                in_bold = true;
            }
            i += 2;
            seg_start = i;
            continue;
        }
        i += 1;
    }
    if (seg_start < line.len) try writeSanitizedFn(w, line[seg_start..]);
    if (in_bold) try w.writeAll(SGR_BOLD_CLOSE);
    if (in_code) try w.writeAll(SGR_CODE_CLOSE);
}

/// Wrap iterator that walks a single source line and yields chunks
/// of byte slices, each ≤ `cols` display columns. Treats markdown
/// markers as plain text for the width calculation (`**` bills 2
/// cols, `` ` `` bills 1) — overcounts by a tiny amount but never
/// undercounts, so trailing chrome stays clear of the right margin.
const LineWrapIter = struct {
    bytes: []const u8,
    i: usize = 0,
    cols: usize,

    pub fn next(it: *LineWrapIter) ?[]const u8 {
        if (it.i >= it.bytes.len) return null;
        // Drop runs of plain spaces left over from a wrap point.
        while (it.i < it.bytes.len and it.bytes[it.i] == ' ') it.i += 1;
        if (it.i >= it.bytes.len) return null;

        const start = it.i;
        var ci = pw.utf8Iter(it.bytes[start..]);
        var used: usize = 0;
        var fit_end: usize = 0;
        var last_space_start: ?usize = null;
        var last_space_after: usize = 0;
        var before_step: usize = 0;
        while (ci.next()) |c| {
            const new_used = used + c.width;
            if (new_used > it.cols) break;
            if (c.cp == ' ') {
                last_space_start = before_step;
                last_space_after = ci.i;
            }
            used = new_used;
            fit_end = ci.i;
            before_step = ci.i;
        }
        if (start + fit_end >= it.bytes.len) {
            it.i = it.bytes.len;
            return it.bytes[start..it.bytes.len];
        }
        if (last_space_start) |sp| {
            if (sp > 0) {
                it.i = start + last_space_after;
                return it.bytes[start .. start + sp];
            }
        }
        if (fit_end == 0) {
            var single = pw.utf8Iter(it.bytes[start..]);
            if (single.next()) |c2| fit_end = c2.byte_len;
        }
        it.i = start + fit_end;
        return it.bytes[start .. start + fit_end];
    }
};

fn lineWrapIter(bytes: []const u8, cols: usize) LineWrapIter {
    return .{ .bytes = bytes, .cols = if (cols == 0) 1 else cols };
}

test {
    _ = @import("md_render_tests.zig");
}
