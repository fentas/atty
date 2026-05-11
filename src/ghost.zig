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

pub const Ghost = struct {
    /// Currently-rendered suggestion text (the part AFTER the user's
    /// cursor). Empty when no overlay is on screen.
    rendered: std.ArrayList(u8),
    visible: bool = false,

    pub fn init(allocator: std.mem.Allocator) Ghost {
        return .{ .rendered = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *Ghost) void {
        self.rendered.deinit();
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
    pub fn show(self: *Ghost, writer: anytype, text: []const u8) !void {
        if (self.visible and std.mem.eql(u8, self.rendered.items, text)) return;
        if (self.visible) try self.clear(writer);
        try ansi.writeGhost(writer, text);
        self.rendered.clearRetainingCapacity();
        try self.rendered.appendSlice(text);
        self.visible = true;
    }

    /// Remove any rendered overlay. Cheap to call when nothing is
    /// rendered — just emits the conservative "save/erase-eol/restore"
    /// sequence when visible.
    pub fn clear(self: *Ghost, writer: anytype) !void {
        if (!self.visible) return;
        try ansi.writeClearGhost(writer);
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

test "show then clear toggles visibility" {
    var g = Ghost.init(std.testing.allocator);
    defer g.deinit();
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try std.testing.expect(!g.visible);
    try g.show(buf.writer(), " -la");
    try std.testing.expect(g.visible);
    try std.testing.expectEqualSlices(u8, " -la", g.rendered.items);

    try g.clear(buf.writer());
    try std.testing.expect(!g.visible);
}
