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
        // `subprocess_text` is up to ~192 bytes from the proxy
        // (`subp_buf`); adding the per-segment SGR (`subprocess_style`
        // + reset + bar_style reapply) plus the arrow glyph leaves
        // ~64 bytes of headroom in a 256-byte buffer — borderline.
        // 384 bytes guarantees a complete sequence even when both
        // styles are maximally verbose (truecolor fg/bg + every
        // attribute bit set). If formatting STILL fails (impossible
        // in practice with the bounded inputs above, but defended
        // against by Copilot's "either fully well-formed or
        // omitted" suggestion), we drop the segment entirely rather
        // than risk emitting a partial style escape that bleeds
        // into the next segment.
        var seg_buf: [384]u8 = undefined;
        var sw: std.Io.Writer = .fixed(&seg_buf);
        if (sw.print("{f}\u{2192} {s}{s}{f}", .{
            args.subprocess_style,
            args.subprocess_text,
            style_mod.reset,
            args.bar_style,
        })) {
            try writeSegment(args.w, &any, sw.buffered());
        } else |_| {
            // Partial output — omit. Better a missing segment than
            // a half-emitted SGR leaking style into subsequent text.
        }
    }
    try writeSegment(args.w, &any, args.base_text);
    try writeSegment(args.w, &any, args.module_text);
}

// ===========================================================================
// Tests — extracted to `status_text_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("status_text_tests.zig");
}
