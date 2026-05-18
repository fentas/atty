//! Ghost-text overlay state machine.
//!
//! Ghost text is the dim "phantom" completion shown after the cursor
//! (fish/zsh-autosuggestions style). Rendering one is easy; *not*
//! corrupting the terminal as the user keeps typing is the hard part.
//!
//! Our rules:
//!
//!   1. Render at most one overlay at a time.
//!   2. Before forwarding any keystroke to the shell, clear the
//!      overlay. (The shell will move the cursor and redraw its line,
//!      so anything we left there would become garbage.)
//!   3. Before passing shell output through to the user, clear the
//!      overlay. The shell's redraw will then run on a clean line.
//!   4. Only render the overlay when the line buffer matches what we
//!      remember (no escape/uncertainty in flight) and the suggestion
//!      starts with the current input prefix — otherwise we'd be
//!      offering nonsense.
//!
//! These rules give a "render is cheap, clear is conservative" pattern:
//! we may sometimes clear when there's nothing to clear, but we'll
//! never leave dim bytes orphaned on the user's screen.

const std = @import("std");
const ansi = @import("ansi.zig");

/// Re-export of the canonical `Style` from `atty.style` for callers
/// that import via `atty.ghost.Style`. Prefer `atty.Style` in new code.
pub const Style = @import("style.zig").Style;

pub const Ghost = struct {
    allocator: std.mem.Allocator,
    /// Currently-rendered suggestion text (the part AFTER the user's
    /// cursor). Empty when no overlay is on screen.
    rendered: std.ArrayList(u8) = .empty,
    visible: bool = false,
    style: Style,

    pub fn init(allocator: std.mem.Allocator, style: Style) Ghost {
        return .{ .allocator = allocator, .style = style };
    }

    pub fn deinit(self: *Ghost) void {
        self.rendered.deinit(self.allocator);
    }

    /// Compute the trailing portion of `suggestion` that should be
    /// displayed after the cursor, given that the user has already
    /// typed `current`. Returns null if the suggestion does not extend
    /// the current input.
    pub fn trailing(current: []const u8, suggestion: []const u8) ?[]const u8 {
        if (suggestion.len <= current.len) return null;
        if (!std.mem.startsWith(u8, suggestion, current)) return null;
        return suggestion[current.len..];
    }

    /// Render an overlay. Caller has already verified `trailing` is
    /// non-empty. Idempotent: if the same text is already rendered we
    /// emit nothing — that matters because the proxy re-renders on
    /// every tick, and naive re-paints would flicker.
    pub fn show(self: *Ghost, w: *std.Io.Writer, text: []const u8) !void {
        if (self.visible and std.mem.eql(u8, self.rendered.items, text)) return;
        if (self.visible) try self.clear(w);
        try ansi.writeGhost(w, text, self.style);
        self.rendered.clearRetainingCapacity();
        try self.rendered.appendSlice(self.allocator, text);
        self.visible = true;
    }

    /// Remove any rendered overlay. Cheap to call when nothing is
    /// rendered — just emits the conservative "save/erase-eol/restore"
    /// sequence when visible.
    pub fn clear(self: *Ghost, w: *std.Io.Writer) !void {
        if (!self.visible) return;
        try ansi.writeClearGhost(w);
        self.rendered.clearRetainingCapacity();
        self.visible = false;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "trailing returns suffix" {
    try std.testing.expectEqualSlices(u8, " -la", Ghost.trailing("ls", "ls -la").?);
}

test "trailing rejects mismatch" {
    try std.testing.expect(Ghost.trailing("ls", "cd ..") == null);
}

test "trailing rejects shorter suggestion" {
    try std.testing.expect(Ghost.trailing("lsla", "ls") == null);
}

/// How many bytes from the START of `trailing` constitute the
/// next "section" for `ghost_accept_word` (Ctrl+Right). A section
/// ends at the FIRST `/` AFTER an opening segment, or at the
/// first space-run, whichever comes first. The boundary character
/// (a single `/` or the whole space-run) is INCLUDED so the next
/// press lands cleanly on the start of the following section.
///
/// Returns 0 when there's nothing accept-worthy (empty input, or
/// pure leading whitespace consumed but the caller wants a
/// no-op).
///
/// Examples:
///   `/home/fentas/x`  → 6 (`/home/`)
///   `git checkout x`  → 4 (`git `)
///   `foo/`            → 4 (`foo/`)
///   `foo`             → 3 (`foo`)
///   `` (empty)        → 0
///   `/foo`            → 4 (`/foo`)
pub fn nextSectionEnd(trailing: []const u8) usize {
    if (trailing.len == 0) return 0;
    var end: usize = 0;
    while (end < trailing.len and trailing[end] == ' ') end += 1;
    // Opening `/` belongs to this segment (`/home/` rather than
    // `/` + `home/`).
    if (end < trailing.len and trailing[end] == '/') end += 1;
    // Segment body — non-space, non-slash.
    while (end < trailing.len and trailing[end] != ' ' and trailing[end] != '/') end += 1;
    // Trailing boundary.
    if (end < trailing.len and trailing[end] == '/') {
        end += 1;
    } else {
        while (end < trailing.len and trailing[end] == ' ') end += 1;
    }
    return end;
}

test "nextSectionEnd: rooted path peels segment + slash" {
    try std.testing.expectEqual(@as(usize, 6), nextSectionEnd("/home/fentas/x"));
}

test "nextSectionEnd: non-slash ghost stops at space-run (legacy behaviour)" {
    try std.testing.expectEqual(@as(usize, 4), nextSectionEnd("git checkout master"));
}

test "nextSectionEnd: trailing slash included" {
    try std.testing.expectEqual(@as(usize, 4), nextSectionEnd("foo/"));
}

test "nextSectionEnd: no slash, no trailing space → whole word" {
    try std.testing.expectEqual(@as(usize, 3), nextSectionEnd("foo"));
}

test "nextSectionEnd: empty input → 0" {
    try std.testing.expectEqual(@as(usize, 0), nextSectionEnd(""));
}

test "nextSectionEnd: leading slash alone" {
    try std.testing.expectEqual(@as(usize, 4), nextSectionEnd("/foo"));
}

test "nextSectionEnd: double slash" {
    // `//foo` — opening `/`, body is empty (next char is also `/`),
    // boundary slash consumed. Net 2; next press peels `foo`.
    try std.testing.expectEqual(@as(usize, 2), nextSectionEnd("//foo"));
}

test "nextSectionEnd: walks a full path through successive calls" {
    var s: []const u8 = "/home/fentas/github/atty";
    const e1 = nextSectionEnd(s);
    try std.testing.expectEqualStrings("/home/", s[0..e1]);
    s = s[e1..];
    const e2 = nextSectionEnd(s);
    try std.testing.expectEqualStrings("fentas/", s[0..e2]);
    s = s[e2..];
    const e3 = nextSectionEnd(s);
    try std.testing.expectEqualStrings("github/", s[0..e3]);
    s = s[e3..];
    const e4 = nextSectionEnd(s);
    try std.testing.expectEqualStrings("atty", s[0..e4]);
}

test "show then clear toggles visibility" {
    var g = Ghost.init(std.testing.allocator, .{});
    defer g.deinit();

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try std.testing.expect(!g.visible);
    try g.show(&w, " -la");
    try std.testing.expect(g.visible);
    try std.testing.expectEqualSlices(u8, " -la", g.rendered.items);

    try g.clear(&w);
    try std.testing.expect(!g.visible);
}
