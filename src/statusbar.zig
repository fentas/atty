//! Bottom status bar — reserves N rows at the bottom of the terminal
//! and renders text to the last row. Implements the dwm-style
//! reserved region via DECSTBM (`\x1b[<top>;<bottom>r`).
//!
//! The shell's view of the terminal is shrunk: we keep our own
//! `rows` (the real terminal size) but propagate `rows - reserve` to
//! the slave PTY via `TIOCSWINSZ`. Shells then wrap and scroll
//! within rows 1..(rows-reserve), and the reserved rows at the
//! bottom stay ours.
//!
//! `reserve_rows = 2` by default = one blank row above + one row of
//! text — gives the status a bit of breathing room above the last
//! shell output line.
//!
//! Lifecycle (driven from src/proxy.zig):
//!
//!     statusbar.init(rows, cols, reserve, style)
//!     statusbar.activate(writer)   ─▶ DECSTBM + initial paint
//!     ... loop:
//!         statusbar.setText("…")
//!         statusbar.render(writer) ─▶ idempotent paint
//!         on SIGWINCH:
//!             statusbar.onResize(new_rows, new_cols)
//!             statusbar.activate(writer)
//!     statusbar.deactivate(writer) ─▶ clear + reset scroll region

const std = @import("std");
const ansi = @import("ansi.zig");
const Style = @import("style.zig").Style;

extern "c" fn clock_gettime(clk_id: c_int, tp: *std.posix.timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

pub const StatusBar = struct {
    /// Full terminal height as reported by TIOCGWINSZ on stdout.
    rows: u16,
    /// Full terminal width.
    cols: u16,
    /// How many rows are reserved at the bottom. The *last* row holds
    /// the rendered text; rows above are blank padding.
    reserve_rows: u16,
    /// Style applied to the status text.
    style: Style,

    /// Pending text — set via `setText`, painted on next `render`.
    text_buf: [256]u8 = undefined,
    text_len: usize = 0,
    /// Last painted text — `render` no-ops if `text_buf` matches.
    last_buf: [256]u8 = undefined,
    last_len: usize = 0,
    last_valid: bool = false,

    /// Transient message overrides the normal text until `transient_until_ms`
    /// passes (monotonic clock). Set via `setTransient(text, ttl_ms)`. The
    /// renderer consults `nowMs()` to decide which buffer to draw.
    transient_buf: [256]u8 = undefined,
    transient_len: usize = 0,
    transient_until_ms: i64 = 0,

    pub fn init(rows: u16, cols: u16, reserve_rows: u16, style: Style) StatusBar {
        return .{
            .rows = rows,
            .cols = cols,
            .reserve_rows = reserve_rows,
            .style = style,
        };
    }

    /// Rows the shell should think it has access to. Cap at 1 so we
    /// never feed the kernel `rows = 0`.
    pub fn effectiveRows(self: StatusBar) u16 {
        if (self.rows == 0) return 1;
        if (self.rows <= self.reserve_rows) return 1;
        return self.rows - self.reserve_rows;
    }

    pub fn setText(self: *StatusBar, text: []const u8) void {
        const n = @min(text.len, self.text_buf.len);
        @memcpy(self.text_buf[0..n], text[0..n]);
        self.text_len = n;
    }

    /// Show `text` for `ttl_ms` milliseconds, overriding whatever
    /// `setText` provides. After the TTL elapses, the bar reverts to
    /// the most recent `setText` value automatically (the renderer
    /// checks the clock on every paint).
    pub fn setTransient(self: *StatusBar, text: []const u8, ttl_ms: u32) void {
        const n = @min(text.len, self.transient_buf.len);
        @memcpy(self.transient_buf[0..n], text[0..n]);
        self.transient_len = n;
        self.transient_until_ms = nowMs() + @as(i64, @intCast(ttl_ms));
        // Force a repaint so the transient text appears immediately.
        self.last_valid = false;
    }

    /// True if a transient message is currently active.
    fn transientActive(self: *const StatusBar) bool {
        return self.transient_len > 0 and nowMs() < self.transient_until_ms;
    }

    /// Set up the bar's reserved region:
    ///
    ///   1. ED `\x1B[2J` — clear the visible screen. Without this,
    ///      DECSTBM's cursor-to-home reset leaves prior outer-shell
    ///      content on rows above where the new prompt renders,
    ///      making atty look like it "jumped to the top" of a
    ///      half-filled screen. Terminal scrollback keeps the
    ///      pre-atty content, so nothing is truly lost — the user
    ///      can scroll up to see what was on screen before.
    ///   2. Belt-and-suspenders: explicit per-row erase of the
    ///      reserved rows (redundant after ED 2 but cheap, and
    ///      defensive against terminals with non-standard ED).
    ///   3. DECSTBM `\x1B[1;<top>r` — confine shell scrolling to the
    ///      non-reserved rows.
    ///   4. CUP home so the first byte the shell writes lands at
    ///      (1,1), not in the reserved area.
    pub fn activate(self: *StatusBar, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("\x1B[2J");
        var r: u16 = self.effectiveRows() + 1;
        while (r <= self.rows) : (r += 1) {
            try w.print("\x1B[{d};1H\x1B[K", .{r});
        }
        try w.print("\x1B[1;{d}r", .{self.effectiveRows()});
        try w.writeAll("\x1B[1;1H");
        self.last_valid = false;
    }

    /// Reset DECSTBM to the full screen and clear the reserved rows.
    /// Call once on exit.
    pub fn deactivate(self: *StatusBar, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var r: u16 = self.effectiveRows() + 1;
        while (r <= self.rows) : (r += 1) {
            try w.print("\x1B[{d};1H\x1B[K", .{r});
        }
        try w.writeAll("\x1B[r"); // reset scroll region
    }

    /// Paint the status text into the last reserved row. Idempotent —
    /// if the text matches the last paint we emit zero bytes. When a
    /// transient message is active and not expired, it overrides
    /// `text_buf` for the duration of its TTL.
    pub fn render(self: *StatusBar, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const active_text: []const u8 = if (self.transientActive())
            self.transient_buf[0..self.transient_len]
        else blk: {
            // If the transient just expired, force a repaint so the
            // bar reverts to the normal text instead of leaving the
            // expired message visible.
            if (self.transient_len > 0 and !self.transientActive()) {
                self.transient_len = 0;
                self.last_valid = false;
            }
            break :blk self.text_buf[0..self.text_len];
        };

        if (self.last_valid and self.last_len == active_text.len and
            std.mem.eql(u8, self.last_buf[0..self.last_len], active_text))
            return;

        try w.writeAll(ansi.save_cursor);
        try w.print("\x1B[{d};1H\x1B[K", .{self.rows}); // CUP last row, erase
        try w.print("{f}", .{self.style});
        try w.writeAll(active_text);
        try w.writeAll(ansi.sgr_reset);
        try w.writeAll(ansi.restore_cursor);

        @memcpy(self.last_buf[0..active_text.len], active_text);
        self.last_len = active_text.len;
        self.last_valid = true;
    }

    /// Update tracked dimensions. Caller is responsible for calling
    /// `activate` afterwards (re-emit DECSTBM with new bounds) and
    /// for propagating the new `effectiveRows()` to the slave PTY.
    pub fn onResize(self: *StatusBar, rows: u16, cols: u16) void {
        self.rows = rows;
        self.cols = cols;
        self.last_valid = false;
    }
};

// ─── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "effectiveRows subtracts reserve, clamps at 1" {
    var b = StatusBar.init(24, 80, 2, .{});
    try testing.expectEqual(@as(u16, 22), b.effectiveRows());

    b.rows = 2;
    try testing.expectEqual(@as(u16, 1), b.effectiveRows());

    b.rows = 0;
    try testing.expectEqual(@as(u16, 1), b.effectiveRows());
}

test "render emits SGR + CUP + text" {
    var b = StatusBar.init(24, 80, 2, .{ .dim = true });
    b.setText("hello");

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = w.buffered();

    try testing.expect(std.mem.indexOf(u8, out, ansi.save_cursor) != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[24;1H") != null); // CUP last row
    try testing.expect(std.mem.indexOf(u8, out, ansi.sgr_dim) != null);
    try testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, out, ansi.restore_cursor) != null);
}

test "render is idempotent when text unchanged" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("x");

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const first = w.end;
    try b.render(&w);
    try testing.expectEqual(first, w.end); // no additional bytes
}

test "activate forces next render to repaint" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("x");

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const before = w.end;
    try b.activate(&w);
    try b.render(&w);
    try testing.expect(w.end > before);
}

test "setTransient overrides text_buf for the TTL window" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setTransient("deleted: foo", 5_000);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "deleted: foo") != null);
    try testing.expect(std.mem.indexOf(u8, out, "atty") == null);
}

test "expired transient is dropped on the next render" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setTransient("flash", 5_000);
    // Force expiry by rewinding the deadline. Avoids real-time sleep
    // in the test.
    b.transient_until_ms = 0;

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "flash") == null);
    try testing.expect(std.mem.indexOf(u8, out, "atty") != null);
    try testing.expectEqual(@as(usize, 0), b.transient_len); // cleared by render
}
