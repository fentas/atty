//! A selectable, scrollable list — the workhorse interactive widget for
//! attop panels (Fleet sessions, Guard rungs, …). It owns only the
//! selection + scroll STATE over `len` rows; the panel owns the row data
//! and renders each visible row itself (consulting `selected`/`visible`),
//! so one widget serves every list shape without a render contract.
//!
//! Keys (vim + arrows): j/k + Down/Up, PageUp/PageDown, Home/End, gg/G.
//! All motion clamps so the selection stays on a real row AND inside the
//! viewport — no off-screen cursor, no scroll past the end.

const std = @import("std");
const key = @import("key.zig");

const Key = key.Key;

pub const List = struct {
    /// Index of the selected row, always in `[0, len)` (or 0 when empty).
    selected: usize = 0,
    /// Index of the first visible row (top of the viewport).
    offset: usize = 0,
    /// Total rows. Set each frame from the (possibly filtered) data.
    len: usize = 0,
    /// Visible rows. Set each frame from the panel's content height.
    viewport: usize = 1,
    /// vim `gg` latch: first `g` arms, second `g` jumps to the top.
    pending_g: bool = false,

    /// Update the row count (e.g. after a filter changed it) + re-clamp.
    pub fn setLen(self: *List, n: usize) void {
        self.len = n;
        self.clamp();
    }

    /// Update the visible height (content rows the panel can paint) + clamp.
    pub fn setViewport(self: *List, rows: usize) void {
        self.viewport = if (rows == 0) 1 else rows;
        self.clamp();
    }

    /// The visible window `[start, end)` — the rows the panel should paint.
    pub fn visible(self: *const List) struct { start: usize, end: usize } {
        const end = @min(self.offset + self.viewport, self.len);
        return .{ .start = self.offset, .end = end };
    }

    fn clamp(self: *List) void {
        if (self.len == 0) {
            self.selected = 0;
            self.offset = 0;
            return;
        }
        if (self.selected >= self.len) self.selected = self.len - 1;
        // Keep the selection inside the viewport.
        if (self.selected < self.offset) self.offset = self.selected;
        if (self.selected >= self.offset + self.viewport) {
            self.offset = self.selected - self.viewport + 1;
        }
        // Don't scroll past the last full screen.
        const max_off = if (self.len > self.viewport) self.len - self.viewport else 0;
        if (self.offset > max_off) self.offset = max_off;
    }

    pub fn moveUp(self: *List) void {
        if (self.selected > 0) self.selected -= 1;
        self.clamp();
    }
    pub fn moveDown(self: *List) void {
        if (self.selected + 1 < self.len) self.selected += 1;
        self.clamp();
    }
    pub fn pageUp(self: *List) void {
        self.selected -= @min(self.viewport, self.selected);
        self.clamp();
    }
    pub fn pageDown(self: *List) void {
        if (self.len > 0) self.selected = @min(self.len - 1, self.selected + self.viewport);
        self.clamp();
    }
    pub fn toTop(self: *List) void {
        self.selected = 0;
        self.clamp();
    }
    pub fn toBottom(self: *List) void {
        if (self.len > 0) self.selected = self.len - 1;
        self.clamp();
    }

    /// Apply a key to the list. Returns true when it was a list-motion key
    /// (so the panel can report `.handled` and the host's global nav doesn't
    /// also act on it). `gg` is handled via the `pending_g` latch; any other
    /// key clears the latch.
    pub fn handleKey(self: *List, k: Key) bool {
        switch (k) {
            .up => {
                self.pending_g = false;
                self.moveUp();
                return true;
            },
            .down => {
                self.pending_g = false;
                self.moveDown();
                return true;
            },
            .page_up => {
                self.pending_g = false;
                self.pageUp();
                return true;
            },
            .page_down => {
                self.pending_g = false;
                self.pageDown();
                return true;
            },
            .home => {
                self.pending_g = false;
                self.toTop();
                return true;
            },
            .end => {
                self.pending_g = false;
                self.toBottom();
                return true;
            },
            .char => |c| switch (c) {
                'k' => {
                    self.pending_g = false;
                    self.moveUp();
                    return true;
                },
                'j' => {
                    self.pending_g = false;
                    self.moveDown();
                    return true;
                },
                'G' => {
                    self.pending_g = false;
                    self.toBottom();
                    return true;
                },
                'g' => {
                    if (self.pending_g) {
                        self.toTop();
                        self.pending_g = false;
                    } else {
                        self.pending_g = true;
                    }
                    return true; // the lone first `g` is consumed (armed)
                },
                else => {
                    self.pending_g = false;
                    return false;
                },
            },
            else => {
                self.pending_g = false;
                return false;
            },
        }
    }
};

/// Case-insensitive substring test — the filter primitive panels use for
/// `/`-search over their rows (ASCII fold; the dashboard's content is ASCII).
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

test {
    _ = @import("list_tests.zig");
}
