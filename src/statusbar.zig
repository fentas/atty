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
    /// Init-time `reserve_rows` snapshot. Modules (inline chat) may
    /// expand the live reservation via `setReserveRows` for their
    /// own panel rows, then restore by calling `setReserveRows(base_reserve_rows)`.
    /// Initialised in every constructor; mutating it after init
    /// loses the "back to default" reference, so don't.
    base_reserve_rows: u16,
    /// Style applied to the status text.
    style: Style,

    /// Pending text — set via `setText`, painted on next `render`.
    ///
    /// 1 KB to fit a single-line bar text payload INCLUDING any
    /// inline SGR escapes module-side. The LLM module's styled
    /// AI-mode hint embeds per-shortcut colour transitions that
    /// add ~100 bytes of escape overhead on top of the visible
    /// ~100-column text; 256 bytes was too tight and clipped the
    /// visible suffix mid-escape.
    text_buf: [1024]u8 = undefined,
    text_len: usize = 0,
    /// Last painted text — `render` no-ops if `text_buf` matches.
    last_buf: [1024]u8 = undefined,
    last_len: usize = 0,
    last_valid: bool = false,

    /// Transient message overrides the normal text until `transient_until_ms`
    /// passes (monotonic clock). Set via `setTransient(text, ttl_ms)`. The
    /// renderer consults `nowMs()` to decide which buffer to draw.
    transient_buf: [256]u8 = undefined,
    transient_len: usize = 0,
    transient_until_ms: i64 = 0,

    /// Hint row content — painted at `effectiveRows() + 1` (the
    /// TOP of the reserved region), leaving the rows between it
    /// and the status text as blank padding. In the common case
    /// `rows > reserve_rows` this equals `rows - reserve_rows + 1`
    /// (so with the default `reserve_rows = 3`, the hint paints
    /// on `rows - 2`). The `effectiveRows()` form keeps the row
    /// math sound even when `reserve_rows >= rows` (tiny terminal
    /// or misconfig) — see `render` for the underflow guard.
    /// Used by the LLM module to surface a one-line explanation
    /// for the command it just injected. TTL-based, auto-clears.
    /// When `reserve_rows < 2` (or there's no room above status),
    /// the hint is silently dropped.
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

    /// Style for the error notification. Falls back to the struct
    /// default (dim red) unless the caller threads `config.statusbar.error_style`
    /// through via `initWithError` / `initFull`. The plain `init`
    /// constructor leaves it at the struct default.
    error_style: Style = .{ .dim = true, .fg = 1 },
    /// Style for the regular (info) hint — LLM explanations etc.
    /// Falls back to the struct default (dim italic) unless the
    /// caller threads `config.statusbar.hint_style` through via
    /// `initFull`. Distinguishes the hint row from the status
    /// text below it.
    hint_style: Style = .{ .dim = true, .italic = true },

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
            .base_reserve_rows = reserve_rows,
            .style = style,
        };
    }

    /// Dynamically grow / shrink the reservation — used by modules
    /// that want to paint a panel above the status text (inline
    /// chat mode). The caller is responsible for triggering an
    /// `activate` so the new reservation takes effect (new DECSTBM
    /// + cleared rows). `base_reserve_rows` records the original
    /// value at init time so callers can restore to "default
    /// statusbar only" without remembering what config said.
    pub fn setReserveRows(self: *StatusBar, n: u16) void {
        self.reserve_rows = n;
        self.last_valid = false;
        self.last_hint_valid = false;
    }

    /// Read-only access to the init-time reserve_rows. Modules
    /// use this to compute "default + N for my panel" without
    /// needing to know the static config value themselves.
    pub fn baseReserveRows(self: *const StatusBar) u16 {
        return self.base_reserve_rows;
    }

    /// Variant that lets the caller override `error_style` while
    /// leaving `hint_style` at the struct default. Kept for
    /// callers that don't care about the hint slot (and for
    /// tests that want to isolate error rendering); `proxy.zig`
    /// itself uses `initFull` to thread both styles through.
    pub fn initWithError(rows: u16, cols: u16, reserve_rows: u16, style: Style, error_style: Style) StatusBar {
        return .{
            .rows = rows,
            .cols = cols,
            .reserve_rows = reserve_rows,
            .base_reserve_rows = reserve_rows,
            .style = style,
            .error_style = error_style,
        };
    }

    /// Full constructor — caller threads in every style override
    /// (status, error, hint). Used by `proxy.zig` when wiring the
    /// user's config through.
    pub fn initFull(rows: u16, cols: u16, reserve_rows: u16, style: Style, error_style: Style, hint_style: Style) StatusBar {
        return .{
            .rows = rows,
            .cols = cols,
            .reserve_rows = reserve_rows,
            .base_reserve_rows = reserve_rows,
            .style = style,
            .error_style = error_style,
            .hint_style = hint_style,
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

    /// Show `text` in the hint row for `ttl_ms` milliseconds.
    /// Auto-clears once the TTL expires.
    ///
    /// Hint row math: `effectiveRows() + 1`. In the common case
    /// `rows > reserve_rows` this is identical to
    /// `rows - reserve_rows + 1` (so with the default
    /// `reserve_rows = 3`, the hint paints two rows above the
    /// status row). When `reserve_rows >= rows` the `effectiveRows`
    /// clamp keeps the math correct without underflowing u16 —
    /// notifications still surface on tiny terminals.
    ///
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

    /// Lighter re-apply used after an alt-screen TUI exited. Unlike
    /// `activate()` this does NOT emit `ED 2` or move the cursor to
    /// home — that would clobber bytes the shell may have already
    /// drawn after `?1049l` in the same read chunk (e.g. a prompt
    /// redraw, an OSC 133 marker, output from a subsequent command).
    ///
    /// Sequence:
    ///   1. DECSC `\x1B[s` — save cursor.
    ///   2. DECSTBM `\x1B[1;<top>r` — defensively re-establish the
    ///      scroll region (the alt-screen app may have emitted
    ///      `\x1B[r` on its own buffer; on terminals where DECSTBM
    ///      is per-buffer this is a no-op, on terminals where it's
    ///      global it restores our reservation).
    ///   3. Per-row erase of the reserved rows so any leaked drawing
    ///      from the alt-screen app is gone.
    ///   4. DECRC `\x1B[u` — restore cursor.
    pub fn reactivate(self: *StatusBar, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("\x1B[s");
        try w.print("\x1B[1;{d}r", .{self.effectiveRows()});
        var r: u16 = self.effectiveRows() + 1;
        while (r <= self.rows) : (r += 1) {
            try w.print("\x1B[{d};1H\x1B[K", .{r});
        }
        try w.writeAll("\x1B[u");
        self.last_valid = false;
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

        // Hint / error notification paints at the TOP of the reserved
        // region, leaving the rows in between as blank padding before
        // the status text. With reserve_rows=3 (default): hint at
        // rows-2, blank at rows-1, status at rows — gives a clear
        // visual gap so the hint reads as a separate element. With
        // reserve_rows=2 (legacy): hint and status are adjacent.
        // With reserve_rows<2 there's no room → skip the paint but
        // still update the "last hint" tracking state so subsequent
        // `render` calls become true no-ops (otherwise
        // `hint_unchanged` stays false forever and every tick emits
        // a save/restore-cursor pair pointlessly).
        if (!hint_unchanged) {
            // Anchor the hint row to `base_reserve_rows` (the
            // init-time reservation), NOT the live `reserve_rows`
            // — modules that grow the reservation for an inline
            // panel (chat) take the *top* rows of the expansion and
            // leave the hint pinned just above the status row at
            // its original position. When `rows <= base_reserve_rows`
            // (pathological tiny terminal) fall back to the
            // `effectiveRows`-based formula so the hint stays
            // visible instead of underflowing.
            const hint_row: u16 = if (self.rows > self.base_reserve_rows)
                self.rows - self.base_reserve_rows + 1
            else
                self.effectiveRows() + 1;
            if (self.base_reserve_rows >= 2 and hint_row < self.rows) {
                try w.print("\x1B[{d};1H\x1B[K", .{hint_row});
                switch (hint_kind) {
                    .err => {
                        try w.print("{f}", .{self.error_style});
                        try w.writeAll("\u{26A0} "); // warning sign + space
                        try w.writeAll(active_hint);
                        try w.writeAll(ansi.sgr_reset);
                    },
                    .hint => {
                        try w.print("{f}", .{self.hint_style});
                        try w.writeAll(active_hint);
                        try w.writeAll(ansi.sgr_reset);
                    },
                    .blank => {},
                }
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

test "setHint paints into the hint row with hint_style (dim by default)" {
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

test "hint paints at TOP of the reserved region (gap above status when reserve_rows >= 3)" {
    // Default reserve_rows=3 layout:
    //   rows-2 = hint, rows-1 = blank padding, rows = status.
    var b = StatusBar.initFull(
        24,
        80,
        3,
        .{ .dim = true }, // bar style
        .{ .dim = true, .fg = 1 }, // error style
        .{ .italic = true }, // hint style (distinct from bar)
    );
    b.setText("atty");
    b.setHint("explanation", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    // Status at row 24.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[24;1H") != null);
    // Hint at row 22 (rows - reserve_rows + 1 = 24 - 3 + 1).
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[22;1H") != null);
    // Hint must NOT paint into row 23 (the blank padding row).
    // We only verify the explicit CUP escape isn't present —
    // it's fine for the cursor to traverse rows in between
    // implicitly.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[23;1H") == null);
    // Hint uses hint_style (italic), not bar style (dim).
    try testing.expect(std.mem.indexOf(u8, out, ansi.sgr_italic) != null);
    try testing.expect(std.mem.indexOf(u8, out, "explanation") != null);
}

test "render is idempotent even when reserve_rows < 2 (hint silently dropped)" {
    // When there's no room for the hint row, painting must still
    // be skipped — but the "last hint" tracking state has to
    // advance so subsequent `render` calls become true no-ops.
    // Otherwise every tick re-emits the save/restore-cursor pair
    // for nothing visible.
    var b = StatusBar.init(24, 80, 1, .{}); // reserve_rows=1
    b.setText("atty");
    b.setHint("explanation", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const first_end = w.end;

    // Second call with same state → zero new bytes written.
    // (idempotence even though the hint row is silently dropped.)
    try b.render(&w);
    try testing.expectEqual(first_end, w.end);
}

test "render guards against u16 underflow when rows < reserve_rows" {
    // Pathological config: rows smaller than reserve_rows. The
    // computation has to use `effectiveRows()` (which clamps) so
    // the row math never underflows in u16 — without that guard,
    // `rows - reserve_rows + 1` wraps to ~65000 and the emitted
    // CUP escape lands on a nonsense row.
    var b = StatusBar.init(2, 80, 5, .{}); // rows=2 < reserve_rows=5
    b.setText("status");
    b.setHint("explanation", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    // None of the wraparound row values should appear.
    try testing.expect(std.mem.indexOf(u8, out, "65532") == null);
    try testing.expect(std.mem.indexOf(u8, out, "65533") == null);
    try testing.expect(std.mem.indexOf(u8, out, "65534") == null);
    try testing.expect(std.mem.indexOf(u8, out, "65535") == null);
}

test "render still paints hint when reserve_rows > rows (effectiveRows clamps)" {
    // rows=3, reserve_rows=5 → effectiveRows=1, hint_row=2,
    // status at rows=3. There IS room for the hint above the
    // status row even though `rows < reserve_rows`; the previous
    // `self.rows >= self.reserve_rows` guard would have dropped
    // it. Pin that the new effectiveRows-based math actually
    // paints something.
    var b = StatusBar.init(3, 80, 5, .{});
    b.setText("status");
    b.setHint("hint here", 5_000);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w);
    const out = buf[0..w.end];

    // Status painted on row 3, hint painted on row 2.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[3;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[2;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out, "hint here") != null);
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
