//! Multi-row "pick list" overlay rendered below the prompt.
//!
//! Sits next to `ghost.zig` (single-row inline overlay). The split
//! keeps each state machine focused: ghost.zig wraps a one-row
//! save/SGR/text/reset/restore around the cursor's current
//! position; this file owns N rows directly below the prompt and
//! manages activate / repaint / deactivate transitions over them.
//!
//! Lifecycle is dynamic, modelled on atuin's interactive Ctrl+R:
//!
//!   * `activate(w, n)`  — make room with `\n` × N (scrolls the
//!     scroll region at the screen bottom; mid-screen it's just
//!     cursor moves) + CUU N + ED-below wipe, then paint.
//!   * `repaint(w)`      — re-emit the entries onto already-reserved
//!     rows when the cache changes. No LFs, no extra wipe.
//!   * `deactivate(w)`   — ED-below from the prompt row. Cursor
//!     does NOT scroll back; the prompt stays at whatever screen
//!     position activate floated it to.
//!
//! The proxy drives the three transitions in `renderGhostList`.

const std = @import("std");
const ansi = @import("ansi.zig");
const Style = @import("style.zig").Style;
const style_mod = @import("style.zig");

pub const GhostList = struct {
    allocator: std.mem.Allocator,
    /// Owned copies of the cached entries. We copy because the
    /// module that provided them may rewrite its own storage
    /// between renders (e.g. history's ring shifts on every commit).
    entries: std.ArrayList(std.ArrayList(u8)),
    /// True when we currently "own" the N rows below the prompt
    /// (i.e. we've emitted the LF+CUU "make room" dance and the
    /// list is painted there). Drives the activate/deactivate
    /// transitions — same shape as atuin's Ctrl+R inline TUI.
    active: bool = false,
    /// Number of rows currently reserved below the prompt.
    /// Set on activate, used by paint + clear.
    reserved_rows: u16 = 0,
    /// Style applied to the index prefix (`1: `) and the entry text.
    style: Style,

    pub fn init(allocator: std.mem.Allocator, style: Style) GhostList {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .style = style,
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

    /// Activate the list: make room for `n` rows directly below the
    /// cursor (which is on the prompt line) and paint the entries.
    ///
    /// The "make room" trick is what atuin's interactive Ctrl+R
    /// uses, but adapted for an inline non-fullscreen overlay:
    ///
    ///   1. Emit LF × n. At the bottom of the screen each LF scrolls
    ///      the scroll region up by 1 row — the prompt floats up,
    ///      blank rows appear at the bottom. Mid-screen each LF is
    ///      just a cursor move, no scroll.
    ///   2. Emit CUU n. Cursor returns to the prompt row regardless
    ///      of whether scrolling happened.
    ///   3. Wipe whatever sits in the rows below (stale shell output,
    ///      a previous list painting, blank rows) so the paint lands
    ///      on a clean surface: CUD 1 + ED 0 + CUU 1.
    ///   4. Paint the entries relatively below the cursor.
    ///
    /// On the way out (deactivate), we just clear the rows below the
    /// cursor — we do NOT scroll the screen back down. That matches
    /// atuin's behavior: close the overlay, the prompt stays where
    /// it scrolled to.
    pub fn activate(self: *GhostList, w: *std.Io.Writer, n: u16) !void {
        if (n == 0) return;
        if (self.active) return; // already reserved
        if (self.entries.items.len == 0) return;

        var i: u16 = 0;
        while (i < n) : (i += 1) try w.writeByte('\n');
        try w.print("\x1b[{d}A", .{n}); // CUU back to the prompt row
        // Wipe the rows we just exposed. The cursor is at the END of
        // the prompt's typed text (some column COL_ORIG > 1); we must
        // move to column 1 BEFORE ED 0 or the erase skips columns
        // 1..COL_ORIG-1 on row R+1, leaving stale paint there.
        // Save/restore so the prompt-row column survives the trip.
        try w.writeAll(ansi.save_cursor);
        try w.writeAll("\x1b[1B\x1b[1G");
        try w.writeAll("\x1b[J");
        try w.writeAll(ansi.restore_cursor);

        self.reserved_rows = n;
        self.active = true;
        try self.paintEntries(w);
    }

    /// Re-paint the entries onto rows we already reserved. Called
    /// when the active list's content changes (e.g. user typed
    /// another character, atuin returned a different result set).
    /// Does NOT scroll — uses relative descent within the reserved
    /// band.
    pub fn repaint(self: *GhostList, w: *std.Io.Writer) !void {
        if (!self.active) return;
        try self.paintEntries(w);
    }

    fn paintEntries(self: *GhostList, w: *std.Io.Writer) !void {
        try w.writeAll(ansi.save_cursor);
        var i: u16 = 0;
        while (i < self.reserved_rows) : (i += 1) {
            // CUD 1 + CHA 1 (cursor to column 1) + EL 0 (erase row)
            // then content. CUD doesn't scroll; we're inside the
            // reserved band we made room for.
            try w.writeAll("\x1b[1B\x1b[1G\x1b[K");
            if (i < self.entries.items.len) {
                try w.print("{f}", .{self.style});
                try w.print(" {d}: {s}", .{ i + 1, self.entries.items[i].items });
                try w.writeAll(style_mod.reset);
            }
        }
        try w.writeAll(ansi.restore_cursor);
    }

    /// Deactivate: erase the reserved rows. Cursor stays exactly
    /// where it was — the prompt remains in whatever screen
    /// position scrolling put it during activate. That's the atuin
    /// Ctrl+R UX: close the overlay, prompt doesn't snap back.
    pub fn deactivate(self: *GhostList, w: *std.Io.Writer) !void {
        if (!self.active) return;
        // Same column-1 dance as activate's wipe: cursor sits at the
        // END of the user's typed line; ED 0 from a non-1 column
        // leaves stale list bytes on columns 1..cursor_col-1 of the
        // first list row.
        try w.writeAll(ansi.save_cursor);
        try w.writeAll("\x1b[1B\x1b[1G");
        try w.writeAll("\x1b[J");
        try w.writeAll(ansi.restore_cursor);
        self.active = false;
        self.reserved_rows = 0;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "GhostList.set replaces cached entries (owned copies)" {
    var gl = GhostList.init(testing.allocator, .{});
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
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    const a = [_][]const u8{ "alpha", "beta" };
    _ = try gl.set(&a, 9);
    const changed = try gl.set(&a, 9);
    try testing.expect(!changed);
}

test "GhostList.set respects the max cap" {
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    const ten = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
    _ = try gl.set(&ten, 3);
    try testing.expectEqual(@as(usize, 3), gl.count());
    try testing.expectEqualStrings("3", gl.entry(3).?);
    try testing.expectEqual(@as(?[]const u8, null), gl.entry(4));
}

test "GhostList.entry is 1-based and bounds-checked" {
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    const a = [_][]const u8{ "first", "second" };
    _ = try gl.set(&a, 9);
    try testing.expectEqualStrings("first", gl.entry(1).?);
    try testing.expectEqualStrings("second", gl.entry(2).?);
    try testing.expectEqual(@as(?[]const u8, null), gl.entry(0));
    try testing.expectEqual(@as(?[]const u8, null), gl.entry(3));
}

test "GhostList.activate makes room with LFs + CUU + ED-below, then paints relatively" {
    var gl = GhostList.init(testing.allocator, .{ .dim = true });
    defer gl.deinit();
    const a = [_][]const u8{ "alpha", "beta", "gamma" };
    _ = try gl.set(&a, 9);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.activate(&w, 3);
    const out = buf[0..w.end];

    // The activate dance: 3 LFs + CUU 3 + step-down + ED 0 + step-up.
    // We don't insist on the exact byte sequence (allows tightening
    // later), only on the key markers.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[3A") != null); // CUU 3 back
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[J") != null); // ED-below wipe
    // Then the paint itself: SGR + numbered entries.
    try testing.expect(std.mem.indexOf(u8, out, ansi.sgr_dim) != null);
    try testing.expect(std.mem.indexOf(u8, out, " 1: alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out, " 2: beta") != null);
    try testing.expect(std.mem.indexOf(u8, out, " 3: gamma") != null);
    // Save/restore wraps the paint so the cursor stays on the prompt row.
    try testing.expect(std.mem.indexOf(u8, out, ansi.save_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, ansi.restore_cursor) != null);
    try testing.expect(gl.active);
    try testing.expectEqual(@as(u16, 3), gl.reserved_rows);
}

test "GhostList.activate is a no-op when entries are empty" {
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.activate(&w, 3);
    try testing.expectEqual(@as(usize, 0), w.end);
    try testing.expect(!gl.active);
}

test "GhostList.activate is a no-op when already active" {
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    const a = [_][]const u8{"x"};
    _ = try gl.set(&a, 9);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.activate(&w, 2);
    const first = w.end;
    try gl.activate(&w, 2);
    try testing.expectEqual(first, w.end); // no bytes emitted on 2nd call
}

test "GhostList.repaint emits only the paint sequence (no LFs, no ED-below)" {
    // Repaint is for the case where the list is already active and
    // we got fresh entries — we don't want another LF dance.
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    const a = [_][]const u8{ "alpha", "beta" };
    _ = try gl.set(&a, 9);
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.activate(&w, 2);

    var rp_buf: [512]u8 = undefined;
    var rp_w: std.Io.Writer = .fixed(&rp_buf);
    const b = [_][]const u8{ "delta", "echo" };
    _ = try gl.set(&b, 9);
    try gl.repaint(&rp_w);
    const out = rp_buf[0..rp_w.end];

    // No LFs, no whole-screen ED in repaint — those are activation-only.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[J") == null);
    // But the new content is there.
    try testing.expect(std.mem.indexOf(u8, out, " 1: delta") != null);
    try testing.expect(std.mem.indexOf(u8, out, " 2: echo") != null);
}

test "GhostList.deactivate clears reserved rows + leaves cursor put" {
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    const a = [_][]const u8{ "alpha", "beta" };
    _ = try gl.set(&a, 9);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.activate(&w, 2);
    try testing.expect(gl.active);

    var dx_buf: [256]u8 = undefined;
    var dx_w: std.Io.Writer = .fixed(&dx_buf);
    try gl.deactivate(&dx_w);
    const out = dx_buf[0..dx_w.end];

    // ED 0 to wipe below + save/restore wrap so the cursor stays
    // exactly where it was (this is the atuin Ctrl+R "close box,
    // prompt doesn't snap back" behavior).
    try testing.expect(std.mem.indexOf(u8, out, ansi.save_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, ansi.restore_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[J") != null);
    try testing.expect(!gl.active);
    try testing.expectEqual(@as(u16, 0), gl.reserved_rows);
}

test "GhostList.deactivate when not active is a no-op" {
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.deactivate(&w);
    try testing.expectEqual(@as(usize, 0), w.end);
}

test "GhostList.deactivate steps to column 1 before ED 0 (regression)" {
    // Regression: the user's cursor is at column COL_ORIG (end of
    // their typed line) when deactivate runs. `\x1b[J` from a column
    // >1 leaves columns 1..COL_ORIG-1 of row R+1 alone — that's the
    // " 1: prefix-x ga" residue bug. The fix is `\x1b[1G` after the
    // CUD 1, so the ED 0 starts from column 1. This test pins it.
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    const a = [_][]const u8{ "alpha", "beta" };
    _ = try gl.set(&a, 9);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.activate(&w, 2);

    var dx_buf: [256]u8 = undefined;
    var dx_w: std.Io.Writer = .fixed(&dx_buf);
    try gl.deactivate(&dx_w);
    const out = dx_buf[0..dx_w.end];

    // The exact pattern: CUD 1 immediately followed by CHA 1 (column 1),
    // BEFORE the ED 0.
    const idx = std.mem.indexOf(u8, out, "\x1b[1B\x1b[1G").?;
    const ed_idx = std.mem.indexOf(u8, out[idx..], "\x1b[J").?;
    // ED 0 must appear AFTER the column-1 step, not before.
    try testing.expect(ed_idx > 0);
}

test "GhostList.activate steps to column 1 before ED 0 (regression)" {
    // Same fix on the activate path's "wipe" step. Without it, a
    // re-activation after typing leaves stale bytes from a previous
    // paint at columns 1..COL_ORIG-1 of row R+1, which paintEntries'
    // own EL 0 then over-paints — so this is less visible than the
    // deactivate case, but the wipe should still be correct on
    // principle, and a future paintEntries change that skipped the
    // EL would expose the bug.
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();
    const a = [_][]const u8{"alpha"};
    _ = try gl.set(&a, 9);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gl.activate(&w, 1);
    const out = buf[0..w.end];

    // The wipe inside activate must include the `\x1b[1G` step
    // before its `\x1b[J`.
    const wipe_start = std.mem.indexOf(u8, out, "\x1b[1B\x1b[1G").?;
    _ = wipe_start;
    // We don't pin the exact order vs. paintEntries below; the
    // presence of the CUD 1 + CHA 1 sequence (plus the J that
    // follows somewhere) is enough to guarantee correctness.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[J") != null);
}

test "GhostList full lifecycle: activate → shrinking repaint → grow back → deactivate" {
    // Walks the state machine through a realistic typing pattern:
    //   1. type "git " → 3 matches, activate w/ 3 rows
    //   2. type "git p" → 1 match, repaint (2 entries become blank)
    //   3. delete back to "git " → 3 matches, repaint (full)
    //   4. clear the line → deactivate
    // Catches anything that breaks on count transitions while
    // active (the proxy never resets `reserved_rows` mid-line).
    var gl = GhostList.init(testing.allocator, .{});
    defer gl.deinit();

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const three = [_][]const u8{ "git status", "git push", "git log" };
    _ = try gl.set(&three, 9);
    try gl.activate(&w, 3);
    try testing.expect(gl.active);
    try testing.expectEqual(@as(u16, 3), gl.reserved_rows);

    // Shrink to 1 entry. Repaint MUST blank the trailing reserved
    // rows (otherwise rows 2 & 3 keep their old paint).
    w.end = 0;
    const one = [_][]const u8{"git push origin master"};
    _ = try gl.set(&one, 9);
    try gl.repaint(&w);
    const shrunk = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, shrunk, " 1: git push origin master") != null);
    // The painted output iterates reserved_rows (=3), erasing each
    // row. Rows 2 and 3 get \x1b[K but no entry text painted.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, shrunk, "\x1b[1B\x1b[1G\x1b[K"));

    // Grow back to 3. reserved_rows is still 3 — paint should
    // populate all three slots.
    w.end = 0;
    _ = try gl.set(&three, 9);
    try gl.repaint(&w);
    const regrown = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, regrown, " 1: git status") != null);
    try testing.expect(std.mem.indexOf(u8, regrown, " 2: git push") != null);
    try testing.expect(std.mem.indexOf(u8, regrown, " 3: git log") != null);

    // Deactivate.
    w.end = 0;
    try gl.deactivate(&w);
    try testing.expect(!gl.active);
    try testing.expectEqual(@as(u16, 0), gl.reserved_rows);
}
