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
    /// 1-based absolute row where the list's first entry paints.
    /// Set by the proxy after TIOCGWINSZ + statusbar coordination —
    /// `0` means "geometry not configured yet, skip painting." Using
    /// absolute rows (not "cursor + N below") is what avoids the
    /// scroll-desync bug of the old `\r\n` descent: with CUP, no
    /// paint can scroll the screen, so DECSC/DECRC stay coherent.
    top_row: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, style: Style, mode: RenderMode) GhostList {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .style = style,
            .mode = mode,
        };
    }

    /// Sets the absolute paint row. Called by the proxy at startup
    /// and on SIGWINCH. Pass `top` = (rows - statusbar.reserve_rows
    /// - list_count + 1) — the first row of the reserved bottom
    /// band, just above the statusbar (or at screen bottom if no
    /// statusbar). `top = 0` deactivates painting.
    pub fn setTopRow(self: *GhostList, top: u16) void {
        self.top_row = top;
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

    /// Paint the cached entries at the configured absolute rows
    /// (CUP to `top_row + i` for each entry). Save/restore cursor
    /// wraps the whole thing so the shell's cursor position is
    /// untouched. No `\r\n` descents — never scrolls.
    ///
    /// No-op when `top_row == 0` (geometry not configured) or when
    /// the cached state already matches what's on screen.
    pub fn show(self: *GhostList, w: *std.Io.Writer) !void {
        if (self.top_row == 0) return;
        if (self.entries.items.len == 0) {
            if (self.visible) try self.clear(w);
            return;
        }

        // If the previous paint had MORE rows, clear the trailing
        // ones at their absolute positions before we paint over the
        // first N rows.
        if (self.visible and self.painted_rows > self.entries.items.len) {
            try w.writeAll(ansi.save_cursor);
            var i: u16 = @intCast(self.entries.items.len);
            while (i < self.painted_rows) : (i += 1) {
                try w.print("\x1b[{d};1H\x1b[K", .{self.top_row + i});
            }
            try w.writeAll(ansi.restore_cursor);
        }

        // Paint each entry at its absolute row. `\x1b[<row>;1H`
        // (CUP) doesn't scroll; `\x1b[K` erases pre-existing
        // content so a shorter entry can overwrite a longer one.
        try w.writeAll(ansi.save_cursor);
        for (self.entries.items, 0..) |e, i| {
            try w.print("\x1b[{d};1H\x1b[K", .{self.top_row + @as(u16, @intCast(i))});
            try w.print("{f}", .{self.style});
            try w.print(" {d}: {s}", .{ i + 1, e.items });
            try w.writeAll(style_mod.reset);
        }
        try w.writeAll(ansi.restore_cursor);

        self.visible = true;
        self.painted_rows = @intCast(self.entries.items.len);
    }

    /// Erase the rows we last painted (at their absolute row
    /// positions, so the clear targets the real list location even
    /// if the cursor has since moved). Cheap when not visible.
    pub fn clear(self: *GhostList, w: *std.Io.Writer) !void {
        if (!self.visible) return;
        if (self.top_row == 0) {
            // No geometry to target — just flip the flag.
            self.visible = false;
            self.painted_rows = 0;
            return;
        }
        try w.writeAll(ansi.save_cursor);
        var i: u16 = 0;
        while (i < self.painted_rows) : (i += 1) {
            try w.print("\x1b[{d};1H\x1b[K", .{self.top_row + i});
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

test "GhostList.show paints with absolute CUP at top_row + i" {
    var gl = GhostList.init(testing.allocator, .{ .dim = true }, .inline_rows);
    defer gl.deinit();
    gl.setTopRow(20);
    const a = [_][]const u8{ "alpha", "beta" };
    _ = try gl.set(&a, 9);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.show(&w);
    const out = buf[0..w.end];

    try testing.expect(std.mem.indexOf(u8, out, ansi.save_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, ansi.restore_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, ansi.sgr_dim) != null);
    // CUP to row 20 for entry #1, row 21 for entry #2.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[20;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[21;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out, " 1: alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out, " 2: beta") != null);
    // No `\r\n` descent bytes — that's the whole point of the
    // absolute-CUP rewrite.
    try testing.expect(std.mem.indexOf(u8, out, "\r\n") == null);
    try testing.expect(gl.visible);
    try testing.expectEqual(@as(u16, 2), gl.painted_rows);
}

test "GhostList.show is a no-op when top_row hasn't been configured" {
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();
    const a = [_][]const u8{"alpha"};
    _ = try gl.set(&a, 9);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.show(&w);
    try testing.expectEqual(@as(usize, 0), w.end);
    try testing.expect(!gl.visible);
}

test "GhostList.clear erases the absolute rows it last painted" {
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();
    gl.setTopRow(20);
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
    // CUP to each of the 3 painted absolute rows + erase_to_eol.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[20;1H\x1b[K") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[21;1H\x1b[K") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[22;1H\x1b[K") != null);
    try testing.expect(!gl.visible);
}

test "GhostList.show after empty set clears the overlay" {
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();
    gl.setTopRow(20);
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

test "GhostList.show shrinking from 3 → 2 rows clears the trailing row" {
    // When the list goes from 3 entries to 2, row 22 must be
    // explicitly erased — otherwise the third entry stays painted
    // beneath the new (shorter) list. Tests the trailing-clear
    // branch.
    var gl = GhostList.init(testing.allocator, .{}, .inline_rows);
    defer gl.deinit();
    gl.setTopRow(20);
    const three = [_][]const u8{ "a", "b", "c" };
    _ = try gl.set(&three, 9);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.show(&w);
    try testing.expectEqual(@as(u16, 3), gl.painted_rows);

    const two = [_][]const u8{ "a", "b" };
    _ = try gl.set(&two, 9);
    var buf2: [512]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try gl.show(&w2);
    const out = buf2[0..w2.end];
    // Row 22 (top_row + 2) must be erased.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[22;1H\x1b[K") != null);
    try testing.expectEqual(@as(u16, 2), gl.painted_rows);
}
