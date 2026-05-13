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

    /// Hint row content — painted into row `rows - 1` (the blank
    /// padding row above the status text, when `reserve_rows >= 2`).
    /// Used by the LLM module to surface a one-line explanation
    /// for the command it just injected. TTL-based, auto-clears.
    /// When `reserve_rows < 2`, hint is silently dropped (nowhere
    /// to draw it).
    hint_buf: [512]u8 = undefined,
    hint_len: usize = 0,
    hint_until_ms: i64 = 0,

    /// Error notification — sibling slot to `hint_buf`, painted in
    /// `error_style` (muted red by default) with a leading "⚠ "
    /// glyph so it reads as a notification rather than info text.
    /// Shares the hint row with `hint_buf` but takes precedence:
    /// while an error is active, the hint is suppressed.
    error_buf: [512]u8 = undefined,
    error_len: usize = 0,
    error_until_ms: i64 = 0,

    /// Style for the error notification. Defaults are populated
    /// from `config.statusbar.error_style` via init().
    error_style: Style = .{ .dim = true, .fg = 1 },

    /// Tracks what was last painted on the hint row — text + the
    /// "kind" (hint vs. error vs. blank) so the renderer no-ops
    /// when nothing changed and repaints when severity flips.
    last_hint_buf: [512]u8 = undefined,
    last_hint_len: usize = 0,
    last_hint_kind: HintKind = .blank,
    last_hint_valid: bool = false,

    const HintKind = enum { blank, hint, err };

    pub fn init(rows: u16, cols: u16, reserve_rows: u16, style: Style) StatusBar {
        return .{
            .rows = rows,
            .cols = cols,
            .reserve_rows = reserve_rows,
            .style = style,
        };
    }

    /// Variant that lets the caller override `error_style`. Used by
    /// `proxy.zig` to thread the user's `config.statusbar.error_style`
    /// through.
    pub fn initWithError(rows: u16, cols: u16, reserve_rows: u16, style: Style, error_style: Style) StatusBar {
        return .{
            .rows = rows,
            .cols = cols,
            .reserve_rows = reserve_rows,
            .style = style,
            .error_style = error_style,
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

    /// Show `text` in the hint row (one above the status text) for
    /// `ttl_ms` milliseconds. Auto-clears once the TTL expires.
    /// Truncated to the buffer length; longer explanations get
    /// clipped rather than wrapping.
    pub fn setHint(self: *StatusBar, text: []const u8, ttl_ms: u32) void {
        const n = @min(text.len, self.hint_buf.len);
        @memcpy(self.hint_buf[0..n], text[0..n]);
        self.hint_len = n;
        self.hint_until_ms = nowMs() + @as(i64, @intCast(ttl_ms));
        self.last_hint_valid = false;
    }

    /// Clear the hint row immediately. Forces a repaint to erase
    /// whatever was visible.
    pub fn clearHint(self: *StatusBar) void {
        self.hint_len = 0;
        self.hint_until_ms = 0;
        self.last_hint_valid = false;
    }

    /// Show an error notification in the hint row for `ttl_ms`
    /// milliseconds. Painted in `error_style` (muted red by
    /// default) with a leading "⚠ " glyph so it reads as a
    /// notification, not an explanation. Takes precedence over
    /// `setHint` while active.
    pub fn setError(self: *StatusBar, text: []const u8, ttl_ms: u32) void {
        const n = @min(text.len, self.error_buf.len);
        @memcpy(self.error_buf[0..n], text[0..n]);
        self.error_len = n;
        self.error_until_ms = nowMs() + @as(i64, @intCast(ttl_ms));
        self.last_hint_valid = false;
    }

    pub fn clearError(self: *StatusBar) void {
        self.error_len = 0;
        self.error_until_ms = 0;
        self.last_hint_valid = false;
    }

    fn hintActive(self: *const StatusBar) bool {
        return self.hint_len > 0 and nowMs() < self.hint_until_ms;
    }

    fn errorActive(self: *const StatusBar) bool {
        return self.error_len > 0 and nowMs() < self.error_until_ms;
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

        // Errors take precedence over hints on the same row — both
        // are transient + TTL'd; reaping the expired one forces a
        // repaint so it doesn't linger.
        if (self.error_len > 0 and !self.errorActive()) {
            self.error_len = 0;
            self.last_hint_valid = false;
        }
        if (self.hint_len > 0 and !self.hintActive()) {
            self.hint_len = 0;
            self.last_hint_valid = false;
        }

        const hint_kind: HintKind = if (self.errorActive())
            .err
        else if (self.hintActive())
            .hint
        else
            .blank;
        const active_hint: []const u8 = switch (hint_kind) {
            .err => self.error_buf[0..self.error_len],
            .hint => self.hint_buf[0..self.hint_len],
            .blank => &[_]u8{},
        };

        const text_unchanged = self.last_valid and
            self.last_len == active_text.len and
            std.mem.eql(u8, self.last_buf[0..self.last_len], active_text);
        const hint_unchanged = self.last_hint_valid and
            self.last_hint_kind == hint_kind and
            self.last_hint_len == active_hint.len and
            std.mem.eql(u8, self.last_hint_buf[0..self.last_hint_len], active_hint);
        if (text_unchanged and hint_unchanged) return;

        try w.writeAll(ansi.save_cursor);

        if (!text_unchanged) {
            try w.print("\x1B[{d};1H\x1B[K", .{self.rows});
            try w.print("{f}", .{self.style});
            try w.writeAll(active_text);
            try w.writeAll(ansi.sgr_reset);

            @memcpy(self.last_buf[0..active_text.len], active_text);
            self.last_len = active_text.len;
            self.last_valid = true;
        }

        // Hint row lives one row above the status text. Skip when
        // we don't have a row to paint into (reserve_rows < 2 means
        // the row above status belongs to the shell). Errors use
        // `error_style` + a leading "⚠ " glyph to read as a
        // notification instead of an explanation.
        if (!hint_unchanged and self.reserve_rows >= 2) {
            try w.print("\x1B[{d};1H\x1B[K", .{self.rows - 1});
            switch (hint_kind) {
                .err => {
                    try w.print("{f}", .{self.error_style});
                    try w.writeAll("\u{26A0} "); // warning sign + space
                    try w.writeAll(active_hint);
                    try w.writeAll(ansi.sgr_reset);
                },
                .hint => {
                    try w.print("{f}", .{self.style});
                    try w.writeAll(active_hint);
                    try w.writeAll(ansi.sgr_reset);
                },
                .blank => {},
            }
            @memcpy(self.last_hint_buf[0..active_hint.len], active_hint);
            self.last_hint_len = active_hint.len;
            self.last_hint_kind = hint_kind;
            self.last_hint_valid = true;
        }

        try w.writeAll(ansi.restore_cursor);
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

test "setHint paints text into rows - 1 with the bar's style" {
    var b = StatusBar.init(24, 80, 2, .{ .dim = true });
    b.setText("atty");
    b.setHint("lists files in long format", 5_000);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    try testing.expect(std.mem.indexOf(u8, out, "\x1B[24;1H") != null); // status row
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[23;1H") != null); // hint row
    try testing.expect(std.mem.indexOf(u8, out, "lists files in long format") != null);
    try testing.expect(std.mem.indexOf(u8, out, "atty") != null);
}

test "hint row is skipped when reserve_rows < 2 (no row above status)" {
    var b = StatusBar.init(24, 80, 1, .{});
    b.setText("atty");
    b.setHint("explanation", 5_000);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    try testing.expect(std.mem.indexOf(u8, out, "atty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "explanation") == null);
}

test "clearHint forces a repaint that erases the hint row" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setHint("explanation", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const first_end = w.end;
    b.clearHint();
    try b.render(&w);
    const second = buf[first_end..w.end];

    try testing.expect(std.mem.indexOf(u8, second, "\x1B[23;1H") != null); // erase hint row
    try testing.expect(std.mem.indexOf(u8, second, "explanation") == null);
}

test "expired hint is dropped on the next render" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setHint("flash", 5_000);
    b.hint_until_ms = 0;

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);

    try testing.expectEqual(@as(usize, 0), b.hint_len);
}

test "setError paints with error_style + warning glyph, hint suppressed" {
    var b = StatusBar.initWithError(24, 80, 2, .{ .dim = true }, .{ .dim = true, .fg = 1 });
    b.setText("atty");
    b.setHint("an explanation", 5_000);
    b.setError("HTTP 500", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    // Warning glyph (U+26A0) UTF-8 = 0xE2 0x9A 0xA0.
    try testing.expect(std.mem.indexOf(u8, out, "\xE2\x9A\xA0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "HTTP 500") != null);
    // Error wins precedence; hint text must NOT be on screen while
    // the error is active.
    try testing.expect(std.mem.indexOf(u8, out, "an explanation") == null);
    // Style emits `\x1B[38;5;<n>m` for fg=1 (256-color form).
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[38;5;1m") != null);
}

test "error expiry falls back to hint if hint is still active" {
    var b = StatusBar.init(24, 80, 2, .{});
    b.setText("atty");
    b.setHint("the explanation", 60_000);
    b.setError("HTTP 500", 5_000);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const first_end = w.end;

    // Force the error to expire without touching the hint.
    b.error_until_ms = 0;
    try b.render(&w);
    const second = buf[first_end..w.end];

    // After error expiry, render must paint the hint that was being
    // suppressed.
    try testing.expect(std.mem.indexOf(u8, second, "the explanation") != null);
    try testing.expect(std.mem.indexOf(u8, second, "HTTP 500") == null);
    try testing.expectEqual(@as(usize, 0), b.error_len);
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
