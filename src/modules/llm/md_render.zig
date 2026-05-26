//! Minimal markdown → ANSI SGR renderer for chat-panel turns.
//!
//! LLMs emit `\n`-separated prose with `**bold**` and `` `code` ``
//! inline. Rendering it through a flat wrap (which collapses `\n`
//! to space and ignores markers) loses both shape and emphasis,
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
//! Span survival across wrap boundaries is NOT implemented in v1.
//! A bold/code span that crosses a wrapped row break opens + closes
//! on the row where it started; continuation rows render plain.
//! In practice spans are short enough that this rarely bites; the
//! trade-off is a simpler per-row state machine.

const std = @import("std");
const pw = @import("paint_width.zig");

const SGR_BOLD_OPEN: []const u8 = "\x1B[1m";
const SGR_BOLD_CLOSE: []const u8 = "\x1B[22m";
const SGR_CODE_OPEN: []const u8 = "\x1B[22;38;5;14m";
const SGR_CODE_CLOSE: []const u8 = "\x1B[39m";
const OVERFLOW_MARKER: []const u8 = " \x1B[2m[\u{2026}]\x1B[0m";
const OVERFLOW_MARKER_COLS: usize = 5;

/// Render `content` to `w` with markdown-aware styling. Returns
/// the number of panel rows consumed (>= 1).
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
    return renderWithSkip(w, content, cols, 0, max_rows, writeSanitizedFn);
}

/// Render `content` skipping the FIRST `skip_rows` produced rows,
/// then emitting up to `max_rows` more. Per-row scrolling
/// (`chat_inline_view_offset` in row units) uses this to slice
/// the visible window through a multi-row turn.
///
/// Returns the number of rows emitted (NOT including skipped).
/// `skip_rows + max_rows == 0` returns 1 (matches `render`'s
/// "no content" floor).
pub fn renderWithSkip(
    w: *std.Io.Writer,
    content: []const u8,
    cols: usize,
    skip_rows: usize,
    max_rows: usize,
    writeSanitizedFn: *const fn (w: *std.Io.Writer, bytes: []const u8) anyerror!void,
) anyerror!usize {
    if (content.len == 0 or max_rows == 0 or cols == 0) return 1;

    var emitted: usize = 0;
    var skipped: usize = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var pending: ?[]const u8 = null;

    while (line_iter.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (line.len == 0) {
            if (try flushOrSkip(w, &pending, &emitted, &skipped, skip_rows, max_rows, cols, writeSanitizedFn, true)) return emitted;
            pending = "";
            continue;
        }

        var wrap = pw.wrapIter(line, cols);
        while (wrap.next()) |chunk| {
            if (try flushOrSkip(w, &pending, &emitted, &skipped, skip_rows, max_rows, cols, writeSanitizedFn, true)) return emitted;
            pending = chunk;
        }
    }

    if (pending) |p| if (p.len == 0) {
        pending = null;
    };
    _ = try flushOrSkip(w, &pending, &emitted, &skipped, skip_rows, max_rows, cols, writeSanitizedFn, false);
    // When the caller asked to skip past everything (skip_rows >=
    // available rows), return 0 so the inline-paint sweep can
    // advance to the next turn without leaving a blank slot.
    // The 1-row floor only applies to the no-skip path so an
    // empty-content turn still consumes a panel row instead of
    // collapsing onto the next turn's render.
    if (emitted == 0 and skip_rows == 0) return 1;
    return emitted;
}

fn flushOrSkip(
    w: *std.Io.Writer,
    pending: *?[]const u8,
    emitted: *usize,
    skipped: *usize,
    skip_rows: usize,
    max_rows: usize,
    cols: usize,
    writeSanitizedFn: *const fn (w: *std.Io.Writer, bytes: []const u8) anyerror!void,
    more_pending: bool,
) anyerror!bool {
    if (pending.* == null) return false;
    if (skipped.* < skip_rows) {
        // Drop this row — count it toward `skipped` so the row
        // budget math stays consistent, but emit no bytes.
        skipped.* += 1;
        pending.* = null;
        return false;
    }
    return flushPending(w, pending, emitted, max_rows, cols, writeSanitizedFn, more_pending);
}

/// Emit the pending chunk at the next row. When `more_pending` is
/// true AND this would be the last allowed row, trim the chunk to
/// (cols - marker_cols) and append `[…]` inline. Returns true when
/// the caller should bail (overflow fired); false otherwise.
fn flushPending(
    w: *std.Io.Writer,
    pending: *?[]const u8,
    rows: *usize,
    max_rows: usize,
    cols: usize,
    writeSanitizedFn: *const fn (w: *std.Io.Writer, bytes: []const u8) anyerror!void,
    more_pending: bool,
) anyerror!bool {
    const p = pending.* orelse return false;
    if (rows.* > 0) try w.writeAll("\r\n\x1B[2K");
    if (more_pending and rows.* + 1 == max_rows) {
        const trim_to = if (cols > OVERFLOW_MARKER_COLS) cols - OVERFLOW_MARKER_COLS else cols;
        try renderInline(w, pw.truncateToCols(p, trim_to), writeSanitizedFn);
        try w.writeAll(OVERFLOW_MARKER);
        rows.* += 1;
        pending.* = null;
        return true;
    }
    try renderInline(w, p, writeSanitizedFn);
    rows.* += 1;
    pending.* = null;
    return false;
}

/// Open/close SGR at `**`/`` ` `` boundaries; everything else
/// passes through the caller's sanitizer. Spans don't survive
/// across row boundaries (see module doc-comment).
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

test {
    _ = @import("md_render_tests.zig");
}
