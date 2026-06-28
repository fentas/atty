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
//!   * `activate(w, n, cols)` — make room with `\n` × N (scrolls the
//!     scroll region at the screen bottom; mid-screen it's just
//!     cursor moves) + CUU N + ED-below wipe, then paint. `cols` is the
//!     terminal width each row is clipped to so it can't wrap.
//!   * `repaint(w, cols)` — re-emit the entries onto already-reserved
//!     rows when the cache changes. No LFs, no extra wipe.
//!   * `deactivate(w)`   — ED-below from the prompt row. Cursor
//!     does NOT scroll back; the prompt stays at whatever screen
//!     position activate floated it to.
//!
//! The proxy drives the three transitions in `renderGhostList`.

const std = @import("std");
const ansi = @import("ansi.zig");
const ghost = @import("ghost.zig");
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
    /// Terminal width, refreshed on each activate/repaint. Rows are
    /// truncated to it so a wide entry never wraps onto a second
    /// physical row — the per-entry descent in `paintEntries` assumes
    /// one physical row per entry, and a wrap would desync the descent
    /// and leave the wrapped tail uncleared.
    cols: u16 = 0,
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
    pub fn activate(self: *GhostList, w: *std.Io.Writer, n: u16, cols: u16) !void {
        if (n == 0) return;
        if (self.active) return; // already reserved
        if (self.entries.items.len == 0) return;
        self.cols = cols;

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
    pub fn repaint(self: *GhostList, w: *std.Io.Writer, cols: u16) !void {
        if (!self.active) return;
        self.cols = cols;
        try self.paintEntries(w);
    }

    fn paintEntries(self: *GhostList, w: *std.Io.Writer) !void {
        try w.writeAll(ansi.save_cursor);
        // Leave the last column free so a row filling the width doesn't
        // trip the terminal's auto-margin wrap. `cols == 0` means UNKNOWN
        // width (non-tty / not yet probed) → don't truncate; any real
        // width clips to `cols - 1` (a 1-col terminal clips to nothing,
        // which still beats wrapping).
        const budget: usize = if (self.cols == 0) std.math.maxInt(usize) else self.cols - 1;
        var i: u16 = 0;
        while (i < self.reserved_rows) : (i += 1) {
            // CUD 1 + CHA 1 (cursor to column 1) + EL 0 (erase row)
            // then content. CUD doesn't scroll; we're inside the
            // reserved band we made room for.
            try w.writeAll("\x1b[1B\x1b[1G\x1b[K");
            if (i < self.entries.items.len) {
                try w.print("{f}", .{self.style});
                // Prefix (` N: `) then entry, the whole row clipped to
                // the width budget so it occupies exactly one row.
                var pfxbuf: [16]u8 = undefined;
                const pfx = ghost.fitWidth(
                    std.fmt.bufPrint(&pfxbuf, " {d}: ", .{i + 1}) catch " ",
                    budget,
                );
                try w.writeAll(pfx);
                try w.writeAll(ghost.fitWidth(self.entries.items[i].items, budget - pfx.len));
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
// Tests — extracted to `ghost_list_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("ghost_list_tests.zig");
}
