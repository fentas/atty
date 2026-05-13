//! Multi-row "pick list" overlay rendered below the prompt.
//!
//! Sits next to `ghost.zig` (single-row inline overlay). The split
//! keeps each state machine focused: ghost.zig wraps a one-row
//! save/SGR/text/reset/restore around the cursor's current
//! position; this file paints N rows below the cursor and tracks
//! how many rows it last painted so `clear` can erase exactly
//! that many.
//!
//! Rendering rules (mirror ghost.zig's "render is cheap, clear is
//! conservative" pattern):
//!
//!   1. Render at most one list overlay at a time.
//!   2. Before forwarding any keystroke or before passing shell
//!      output through, clear the overlay. The shell will redraw
//!      its line and any rows below; leaving dim bytes orphaned is
//!      worse than a one-frame flicker.
//!   3. Only render when the line buffer is *certain* and a module
//!      produced a non-empty list. Otherwise clear.
//!   4. inline_rows mode uses save-cursor + LF/CR descents +
//!      restore-cursor so the shell's cursor position is untouched.
//!      It can visibly scroll the screen near the bottom row —
//!      reserved_region mode is the sturdier alternative when that
//!      bites.

const std = @import("std");
const ansi = @import("ansi.zig");
const Style = @import("style.zig").Style;
const style_mod = @import("style.zig");

pub const RenderMode = enum {
    /// Save cursor, descend N rows with LF/CR, restore cursor. Cheap;
    /// the shell can scroll the screen if the prompt is near the
    /// bottom row. The proxy renders after shell output so a
    /// scroll-induced repaint corrects itself within a frame.
    inline_rows,
    /// Reserve a DECSTBM band above the statusbar while the list is
    /// visible; release the band when the list goes empty or Enter
    /// is pressed. Sturdier — never scrolls — but more cursor
    /// bookkeeping. Falls back to inline_rows for now until the
    /// statusbar coordination lands.
    reserved_region,
};

pub const GhostList = struct {
    allocator: std.mem.Allocator,
    /// Owned copies of the cached entries. We copy because the
    /// module that provided them may rewrite its own storage
    /// between renders (e.g. history's ring shifts on every commit).
    entries: std.ArrayList(std.ArrayList(u8)),
    /// True when the overlay is currently painted on screen.
    visible: bool = false,
    /// Row count of the last paint — `clear` erases exactly this
    /// many rows. Decoupled from `entries.items.len` because the
    /// configured `list_count` can change mid-session.
    painted_rows: u16 = 0,
    /// Style applied to the index prefix (`1: `) and the entry text.
    style: Style,
    /// Render mode — see `RenderMode`.
    mode: RenderMode,

    pub fn init(allocator: std.mem.Allocator, style: Style, mode: RenderMode) GhostList {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .style = style,
            .mode = mode,
        };
    }

    pub fn deinit(self: *GhostList) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn count(self: GhostList) usize {
        return self.entries.items.len;
    }

    /// 1-based lookup. Returns null when N is out of range. Used by
    /// the proxy's `ghost_pick` action handler.
    pub fn entry(self: GhostList, n: u8) ?[]const u8 {
        if (n < 1) return null;
        const idx: usize = @as(usize, n) - 1;
        if (idx >= self.entries.items.len) return null;
        return self.entries.items[idx].items;
    }

    /// Replace cached entries with copies of `new_entries`, truncated
    /// to `max`. Returns true when the cache differs from before
    /// (callers use this to skip the paint when the list hasn't
    /// changed).
    pub fn set(self: *GhostList, new_entries: []const []const u8, max: usize) !bool {
        const want_n = @min(new_entries.len, max);
        // Fast path: same length + same bytes → no-op.
        if (self.entries.items.len == want_n) {
            var same = true;
            for (self.entries.items, new_entries[0..want_n]) |existing, new| {
                if (!std.mem.eql(u8, existing.items, new)) {
                    same = false;
                    break;
                }
            }
            if (same) return false;
        }
        // Reallocate the cache.
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
        var i: usize = 0;
        while (i < want_n) : (i += 1) {
            var owned: std.ArrayList(u8) = .empty;
            try owned.appendSlice(self.allocator, new_entries[i]);
            try self.entries.append(self.allocator, owned);
        }
        return true;
    }

    pub fn clearCached(self: *GhostList) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
    }

    /// Paint the cached entries below the cursor. Idempotent — the
    /// caller can call this every render cycle. When `entries` is
    /// empty the overlay is cleared instead. When the cached
    /// entries match what's already on screen, NO bytes are emitted
    /// (critical: the proxy ticks at 100ms and each paint descends
    /// N rows below the cursor; if we re-emit every tick near the
    /// bottom of the screen we accumulate scroll-induced drift).
    pub fn show(self: *GhostList, w: *std.Io.Writer) !void {
        if (self.entries.items.len == 0) {
            if (self.visible) try self.clear(w);
            return;
        }
        // Already on screen with the same row count → no-op. The
        // `set` caller is expected to have skipped reaching us when
        // the entries didn't change, but defend in case it didn't.
        if (self.visible and self.painted_rows == self.entries.items.len)
            return;
        if (self.visible and self.painted_rows != self.entries.items.len) {
            try self.clear(w);
        }

        switch (self.mode) {
            // reserved_region falls back to inline_rows until the
            // statusbar coordination lands — same paint path.
            .inline_rows, .reserved_region => try self.paintInlineRows(w),
        }

        self.visible = true;
        self.painted_rows = @intCast(self.entries.items.len);
    }

    fn paintInlineRows(self: *GhostList, w: *std.Io.Writer) !void {
        try w.writeAll(ansi.save_cursor);
        for (self.entries.items, 0..) |e, i| {
            // Move to start of next line. CR+LF in raw mode is just
            // "down one + column 0"; near the bottom of the screen
            // the terminal will scroll. Documented limitation of
            // inline_rows mode.
            try w.writeAll("\r\n");
            try w.writeAll(ansi.erase_to_eol);
            try w.print("{f}", .{self.style});
            try w.print(" {d}: {s}", .{ i + 1, e.items });
            try w.writeAll(style_mod.reset);
        }
        try w.writeAll(ansi.restore_cursor);
    }

    /// Erase the rows we last painted. Cheap when not visible.
    pub fn clear(self: *GhostList, w: *std.Io.Writer) !void {
        if (!self.visible) return;
        try w.writeAll(ansi.save_cursor);
        var i: u16 = 0;
        while (i < self.painted_rows) : (i += 1) {
            try w.writeAll("\r\n");
            try w.writeAll(ansi.erase_to_eol);
        }
        try w.writeAll(ansi.restore_cursor);
        self.visible = false;
        self.painted_rows = 0;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "GhostList.set replaces cached entries (owned copies)" {
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();

    var entries = [_][]const u8{ "git status", "git push", "git log" };
    const changed = try gl.set(&entries, 9);
    try testing.expect(changed);
    try testing.expectEqual(@as(usize, 3), gl.count());

    // Mutate the source slice — our cache shouldn't change.
    entries[0] = "MUTATED";
    try testing.expectEqualStrings("git status", gl.entry(1).?);
}

test "GhostList.set is a no-op when the cache already matches" {
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();
    const a = [_][]const u8{ "alpha", "beta" };
    _ = try gl.set(&a, 9);
    const changed = try gl.set(&a, 9);
    try testing.expect(!changed);
}

test "GhostList.set respects the max cap" {
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();
    const ten = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
    _ = try gl.set(&ten, 3);
    try testing.expectEqual(@as(usize, 3), gl.count());
    try testing.expectEqualStrings("3", gl.entry(3).?);
    try testing.expectEqual(@as(?[]const u8, null), gl.entry(4));
}

test "GhostList.entry is 1-based and bounds-checked" {
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();
    const a = [_][]const u8{ "first", "second" };
    _ = try gl.set(&a, 9);
    try testing.expectEqualStrings("first", gl.entry(1).?);
    try testing.expectEqualStrings("second", gl.entry(2).?);
    try testing.expectEqual(@as(?[]const u8, null), gl.entry(0));
    try testing.expectEqual(@as(?[]const u8, null), gl.entry(3));
}

test "GhostList.show writes save/restore cursor + N rows of erase + text" {
    var gl = GhostList.init(testing.allocator, .{ .dim = true }, .inline_rows);
    defer gl.deinit();
    const a = [_][]const u8{ "alpha", "beta" };
    _ = try gl.set(&a, 9);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.show(&w);
    const out = buf[0..w.end];

    try testing.expect(std.mem.indexOf(u8, out, ansi.save_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, ansi.restore_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, ansi.sgr_dim) != null);
    try testing.expect(std.mem.indexOf(u8, out, " 1: alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out, " 2: beta") != null);
    try testing.expect(gl.visible);
    try testing.expectEqual(@as(u16, 2), gl.painted_rows);
}

test "GhostList.clear erases the rows it last painted" {
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();
    const a = [_][]const u8{ "alpha", "beta", "gamma" };
    _ = try gl.set(&a, 9);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.show(&w);
    try testing.expect(gl.visible);

    var clr_buf: [256]u8 = undefined;
    var clr_w: std.Io.Writer = .fixed(&clr_buf);
    try gl.clear(&clr_w);
    const out = clr_buf[0..clr_w.end];

    try testing.expect(std.mem.indexOf(u8, out, ansi.save_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, ansi.restore_cursor) != null);
    // 3 erase_to_eol sequences (one per painted row).
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOf(u8, out[i..], ansi.erase_to_eol)) |idx| : (i += idx + ansi.erase_to_eol.len) count += 1;
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expect(!gl.visible);
}

test "GhostList.show after empty set clears the overlay" {
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();
    const a = [_][]const u8{"x"};
    _ = try gl.set(&a, 9);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.show(&w);
    try testing.expect(gl.visible);

    const empty = [_][]const u8{};
    _ = try gl.set(&empty, 9);
    var w2: std.Io.Writer = .fixed(&buf);
    try gl.show(&w2);
    try testing.expect(!gl.visible);
}
