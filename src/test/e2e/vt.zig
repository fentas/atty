//! Minimal VT-100/xterm-ish terminal emulator for e2e visual validation.
//!
//! We don't need a perfect emulator — we need a *stable* one. The grid
//! produced here is what we diff against goldens, so the rules must be
//! deterministic and forgiving of unknown sequences (skip instead of
//! corrupting state).
//!
//! Implemented:
//!   - Printable bytes (UTF-8 → one codepoint per cell, width assumed 1)
//!   - C0: BEL (ignored), BS, TAB, LF, VT, FF, CR
//!   - CSI: CUU CUD CUF CUB CNL CPL CHA CUP HVP VPA ED EL IL DL DCH ECH SU SD
//!          SGR (0/1/2/3/4/7/22/23/24/27 + 30-37/38;5/39 + 40-47/48;5/49 + 90-97/100-107)
//!          DECSET/DECRST (we honour DECAWM=?7; rest ignored)
//!   - ESC 7 / ESC 8                (DECSC / DECRC — used by ghost overlay)
//!   - ESC =, ESC >, ESC #, ESC ( x, ESC ) x   (silently consumed)
//!   - OSC … BEL/ST                 (skipped)
//!
//! Everything else is dropped on the floor. That's intentional: the
//! framework's job is to be a reproducible witness, not a competitor to
//! xterm.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    _pad: u3 = 0,

    pub fn isDefault(self: Attrs) bool {
        return @as(u8, @bitCast(self)) == 0;
    }
};

pub const Color = union(enum) {
    default,
    indexed: u8,

    pub fn eq(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |ai| switch (b) {
                .indexed => |bi| ai == bi,
                else => false,
            },
        };
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    pub fn isBlankDefault(self: Cell) bool {
        return self.cp == ' ' and self.fg == .default and self.bg == .default and self.attrs.isDefault();
    }

    pub fn styleEqual(a: Cell, b: Cell) bool {
        return Color.eq(a.fg, b.fg) and Color.eq(a.bg, b.bg) and
            @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }
};

const ParseState = enum {
    ground,
    escape,
    csi,
    osc,
    charset, // expecting one byte after ESC ( or ESC )
    dec_hash, // expecting one byte after ESC #
};

pub const Grid = struct {
    rows: u16,
    cols: u16,
    cells: []Cell,
    cur_row: u16 = 0,
    cur_col: u16 = 0,
    cur_attrs: Attrs = .{},
    cur_fg: Color = .default,
    cur_bg: Color = .default,
    saved_row: u16 = 0,
    saved_col: u16 = 0,
    saved_attrs: Attrs = .{},
    saved_fg: Color = .default,
    saved_bg: Color = .default,
    autowrap: bool = true,
    wrap_pending: bool = false,
    // DECSTBM scroll region (inclusive rows); scroll_bottom set to rows-1 in
    // init/resize. lineFeed / RI / scrollUp|Down honour it.
    scroll_top: u16 = 0,
    scroll_bottom: u16 = 0,
    // Alt-screen: the saved PRIMARY buffer + cursor while in alt mode (null =
    // on the primary screen). ?1049 / ?47 / ?1047 toggle it.
    saved_screen: ?[]Cell = null,
    alt_row: u16 = 0,
    alt_col: u16 = 0,
    alt_attrs: Attrs = .{},
    alt_fg: Color = .default,
    alt_bg: Color = .default,

    state: ParseState = .ground,
    // CSI parameter buffer.
    param_buf: [128]u8 = undefined,
    param_len: usize = 0,
    // Intermediate / private marker for current CSI (e.g. '?' or '>').
    csi_private: u8 = 0,
    // UTF-8 partial codepoint accumulator.
    utf8_buf: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_expect: u3 = 0,

    allocator: Allocator,

    pub fn init(allocator: Allocator, rows: u16, cols: u16) !Grid {
        const cells = try allocator.alloc(Cell, @as(usize, rows) * cols);
        @memset(cells, .{});
        return .{
            .rows = rows,
            .cols = cols,
            .cells = cells,
            .scroll_bottom = if (rows == 0) 0 else rows - 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Grid) void {
        if (self.saved_screen) |s| self.allocator.free(s);
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    /// Resize the grid, preserving the overlapping top-left content. A shrink
    /// drops the BOTTOM rows / RIGHT columns (xterm scrolls content up instead —
    /// the witness keeps top-left, which is simpler and sufficient here). Both
    /// the live AND saved (DECSC/SCO) cursors are clamped into the new bounds so
    /// a later DECRC can't strand the cursor out of range. The child must be
    /// told the new size via TIOCSWINSZ separately — ttysnap's `Harness.resize`
    /// does both. Dimensions are clamped to >= 1.
    pub fn resize(self: *Grid, new_rows_in: u16, new_cols_in: u16) !void {
        const new_rows = @max(new_rows_in, 1);
        const new_cols = @max(new_cols_in, 1);
        if (new_rows == self.rows and new_cols == self.cols) return;
        const new_cells = try resizeBuf(self.allocator, self.cells, self.rows, self.cols, new_rows, new_cols);
        errdefer self.allocator.free(new_cells);
        // Resize the saved alt buffer too (rather than dropping it) so a later
        // ?1049l stays faithful across a resize-during-alt (ttysnap SIGWINCH).
        const new_saved: ?[]Cell = if (self.saved_screen) |s|
            try resizeBuf(self.allocator, s, self.rows, self.cols, new_rows, new_cols)
        else
            null;

        self.allocator.free(self.cells);
        self.cells = new_cells;
        if (self.saved_screen) |s| self.allocator.free(s);
        self.saved_screen = new_saved;
        self.rows = new_rows;
        self.cols = new_cols;
        if (self.cur_row >= new_rows) self.cur_row = new_rows - 1;
        if (self.cur_col >= new_cols) self.cur_col = new_cols - 1;
        if (self.saved_row >= new_rows) self.saved_row = new_rows - 1;
        if (self.saved_col >= new_cols) self.saved_col = new_cols - 1;
        if (self.alt_row >= new_rows) self.alt_row = new_rows - 1;
        if (self.alt_col >= new_cols) self.alt_col = new_cols - 1;
        // The scroll region is sized to the grid — reset it to full.
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;
        self.wrap_pending = false;
    }

    /// Allocate a `new_rows`x`new_cols` cell buffer, copying the overlapping
    /// top-left region from `old` (laid out `old_rows`x`old_cols`).
    fn resizeBuf(allocator: Allocator, old: []const Cell, old_rows: u16, old_cols: u16, new_rows: u16, new_cols: u16) ![]Cell {
        const buf = try allocator.alloc(Cell, @as(usize, new_rows) * new_cols);
        @memset(buf, .{});
        const cr = @min(old_rows, new_rows);
        const cc = @min(old_cols, new_cols);
        var r: u16 = 0;
        while (r < cr) : (r += 1) {
            @memcpy(buf[@as(usize, r) * new_cols ..][0..cc], old[@as(usize, r) * old_cols ..][0..cc]);
        }
        return buf;
    }

    inline fn idx(self: *const Grid, r: u16, c: u16) usize {
        return @as(usize, r) * self.cols + c;
    }

    fn putCell(self: *Grid, cp: u21) void {
        if (self.wrap_pending) {
            self.cur_col = 0;
            self.lineFeed();
            self.wrap_pending = false;
        }
        if (self.cur_row >= self.rows) self.cur_row = self.rows - 1;
        if (self.cur_col >= self.cols) self.cur_col = self.cols - 1;
        self.cells[self.idx(self.cur_row, self.cur_col)] = .{
            .cp = cp,
            .fg = self.cur_fg,
            .bg = self.cur_bg,
            .attrs = self.cur_attrs,
        };
        if (self.cur_col + 1 >= self.cols) {
            if (self.autowrap) {
                self.wrap_pending = true;
            } else {
                self.cur_col = self.cols - 1;
            }
        } else {
            self.cur_col += 1;
        }
    }

    fn lineFeed(self: *Grid) void {
        // At the region bottom → scroll the region; otherwise just advance
        // (a cursor below the region advances to the last row, xterm-style).
        if (self.cur_row == self.scroll_bottom) {
            self.scrollUp(1);
        } else if (self.cur_row + 1 < self.rows) {
            self.cur_row += 1;
        }
    }

    /// Scroll the [scroll_top, scroll_bottom] region up by `n`, clearing the
    /// newly exposed bottom rows (default cells, matching the old whole-grid
    /// scroll). Rows outside the region are untouched (e.g. a statusbar row).
    fn scrollUp(self: *Grid, n: u16) void {
        if (self.scroll_top > self.scroll_bottom) return;
        const cols = self.cols;
        const region = self.scroll_bottom - self.scroll_top + 1;
        const cnt = @min(n, region);
        const base = self.idx(self.scroll_top, 0);
        const moved = @as(usize, region - cnt) * cols;
        if (moved > 0) std.mem.copyForwards(Cell, self.cells[base .. base + moved], self.cells[base + @as(usize, cnt) * cols .. base + @as(usize, cnt) * cols + moved]);
        for (self.cells[base + moved .. base + @as(usize, region) * cols]) |*c| c.* = .{};
    }

    /// Scroll the region down by `n` (RI at the top), clearing the top rows.
    fn scrollDown(self: *Grid, n: u16) void {
        if (self.scroll_top > self.scroll_bottom) return;
        const cols = self.cols;
        const region = self.scroll_bottom - self.scroll_top + 1;
        const cnt = @min(n, region);
        const base = self.idx(self.scroll_top, 0);
        const moved = @as(usize, region - cnt) * cols;
        if (moved > 0) std.mem.copyBackwards(Cell, self.cells[base + @as(usize, cnt) * cols .. base + @as(usize, cnt) * cols + moved], self.cells[base .. base + moved]);
        for (self.cells[base .. base + @as(usize, cnt) * cols]) |*c| c.* = .{};
    }

    /// Enter (`on`) or leave the alt screen: save/restore the primary buffer +
    /// cursor, reset the scroll region to full (apps re-set DECSTBM as needed).
    fn setAltScreen(self: *Grid, on: bool) void {
        if (on) {
            if (self.saved_screen != null) return; // already on alt
            const save = self.allocator.dupe(Cell, self.cells) catch return;
            self.saved_screen = save;
            // ?1049 saves the cursor (DECSC) — position AND the active SGR — so
            // attrs/colors set in the alt app don't leak back to the primary.
            self.alt_row = self.cur_row;
            self.alt_col = self.cur_col;
            self.alt_attrs = self.cur_attrs;
            self.alt_fg = self.cur_fg;
            self.alt_bg = self.cur_bg;
            @memset(self.cells, .{});
            self.cur_row = 0;
            self.cur_col = 0;
        } else {
            const save = self.saved_screen orelse return; // already on primary
            if (save.len == self.cells.len) @memcpy(self.cells, save);
            self.allocator.free(save);
            self.saved_screen = null;
            self.cur_row = @min(self.alt_row, self.rows - 1);
            self.cur_col = @min(self.alt_col, self.cols - 1);
            self.cur_attrs = self.alt_attrs;
            self.cur_fg = self.alt_fg;
            self.cur_bg = self.alt_bg;
        }
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.wrap_pending = false;
    }

    fn carriageReturn(self: *Grid) void {
        self.cur_col = 0;
        self.wrap_pending = false;
    }

    fn backspace(self: *Grid) void {
        self.wrap_pending = false;
        if (self.cur_col > 0) self.cur_col -= 1;
    }

    fn tab(self: *Grid) void {
        self.wrap_pending = false;
        const next: u16 = ((self.cur_col / 8) + 1) * 8;
        self.cur_col = @min(next, self.cols - 1);
    }

    /// Feed bytes to the parser. Idempotent and safe to call in chunks.
    pub fn feed(self: *Grid, bytes: []const u8) void {
        for (bytes) |b| self.feedByte(b);
    }

    fn feedByte(self: *Grid, b: u8) void {
        switch (self.state) {
            .ground => self.feedGround(b),
            .escape => self.feedEscape(b),
            .csi => self.feedCsi(b),
            .osc => self.feedOsc(b),
            .charset => {
                self.state = .ground;
            },
            .dec_hash => {
                self.state = .ground;
            },
        }
    }

    fn feedGround(self: *Grid, b: u8) void {
        // Continuation of a multi-byte UTF-8 sequence?
        if (self.utf8_expect > 0) {
            if (b & 0xC0 == 0x80) {
                self.utf8_buf[self.utf8_len] = b;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_expect) {
                    const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch '?';
                    self.putCell(cp);
                    self.utf8_len = 0;
                    self.utf8_expect = 0;
                }
                return;
            } else {
                // malformed — drop buffer, fall through
                self.utf8_len = 0;
                self.utf8_expect = 0;
            }
        }

        switch (b) {
            0x07 => {}, // BEL
            0x08 => self.backspace(),
            0x09 => self.tab(),
            0x0A, 0x0B, 0x0C => {
                self.lineFeed();
                self.wrap_pending = false;
            },
            0x0D => self.carriageReturn(),
            0x1B => {
                self.state = .escape;
            },
            0x00...0x06, 0x0E...0x1A, 0x1C...0x1F, 0x7F => {
                // Other C0/DEL — drop silently.
            },
            else => {
                if (b < 0x80) {
                    self.putCell(b);
                } else {
                    // Start of multi-byte UTF-8.
                    const expect: u3 = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else 1;
                    if (expect == 1) {
                        // Invalid lead byte — render as '?'.
                        self.putCell('?');
                    } else {
                        self.utf8_buf[0] = b;
                        self.utf8_len = 1;
                        self.utf8_expect = expect;
                    }
                }
            },
        }
    }

    fn feedEscape(self: *Grid, b: u8) void {
        switch (b) {
            '[' => {
                self.param_len = 0;
                self.csi_private = 0;
                self.state = .csi;
            },
            ']' => self.state = .osc,
            '7' => {
                self.saved_row = self.cur_row;
                self.saved_col = self.cur_col;
                self.saved_attrs = self.cur_attrs;
                self.saved_fg = self.cur_fg;
                self.saved_bg = self.cur_bg;
                self.state = .ground;
            },
            '8' => {
                self.cur_row = self.saved_row;
                self.cur_col = self.saved_col;
                self.cur_attrs = self.saved_attrs;
                self.cur_fg = self.saved_fg;
                self.cur_bg = self.saved_bg;
                self.wrap_pending = false;
                self.state = .ground;
            },
            'D' => { // IND — line feed
                self.lineFeed();
                self.state = .ground;
            },
            'M' => { // RI — reverse line feed (scroll down at the region top)
                if (self.cur_row == self.scroll_top) {
                    self.scrollDown(1);
                } else if (self.cur_row > 0) {
                    self.cur_row -= 1;
                }
                self.state = .ground;
            },
            'E' => { // NEL — next line
                self.cur_col = 0;
                self.lineFeed();
                self.state = .ground;
            },
            '(', ')' => self.state = .charset,
            '#' => self.state = .dec_hash,
            '=', '>' => self.state = .ground, // keypad mode — ignore
            else => self.state = .ground,
        }
    }

    fn feedCsi(self: *Grid, b: u8) void {
        switch (b) {
            '0'...'9', ';', ':' => {
                if (self.param_len < self.param_buf.len) {
                    self.param_buf[self.param_len] = b;
                    self.param_len += 1;
                }
            },
            '?', '>', '!', '$', '"', '\'' => {
                if (self.param_len == 0) self.csi_private = b;
            },
            0x40...0x7E => {
                self.dispatchCsi(b);
                self.state = .ground;
            },
            else => self.state = .ground,
        }
    }

    fn feedOsc(self: *Grid, b: u8) void {
        // OSC terminates on BEL (0x07) or ST (ESC \). We're not interpreting
        // OSC at all, so the simplest correct behaviour is: bail on BEL,
        // and on ESC bounce back to .escape so the trailing '\' gets eaten.
        switch (b) {
            0x07 => self.state = .ground,
            0x1B => self.state = .escape,
            else => {},
        }
    }

    fn parseParams(self: *Grid, out: []u32) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.param_len and count < out.len) {
            var v: u32 = 0;
            var any = false;
            while (i < self.param_len and self.param_buf[i] >= '0' and self.param_buf[i] <= '9') : (i += 1) {
                v = v *% 10 +% (self.param_buf[i] - '0');
                any = true;
            }
            if (any) {
                out[count] = v;
                count += 1;
            } else if (i < self.param_len and (self.param_buf[i] == ';' or self.param_buf[i] == ':')) {
                // Empty param slot.
                out[count] = 0;
                count += 1;
            }
            if (i < self.param_len and (self.param_buf[i] == ';' or self.param_buf[i] == ':')) i += 1;
        }
        return count;
    }

    fn dispatchCsi(self: *Grid, final: u8) void {
        var params: [16]u32 = undefined;
        const n = self.parseParams(&params);

        const p0 = if (n > 0) params[0] else 0;
        const p1 = if (n > 1) params[1] else 0;

        // Private CSI ('?h' / '?l') — DEC mode set/reset.
        if (self.csi_private == '?') {
            switch (final) {
                'h', 'l' => {
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        switch (params[i]) {
                            7 => self.autowrap = (final == 'h'),
                            // Alt screen: ?1049 (save/clear/restore), ?47 / ?1047
                            // (bare switch). Treated alike — a witness only needs
                            // the primary buffer preserved under the alt app.
                            47, 1047, 1049 => self.setAltScreen(final == 'h'),
                            else => {}, // ?25 cursor visibility etc. — ignored
                        }
                    }
                },
                else => {},
            }
            return;
        }

        switch (final) {
            'A' => { // CUU
                const dy: u16 = @intCast(@max(p0, 1));
                self.cur_row = if (self.cur_row > dy) self.cur_row - dy else 0;
                self.wrap_pending = false;
            },
            'B' => { // CUD
                const dy: u16 = @intCast(@max(p0, 1));
                self.cur_row = @min(self.cur_row + dy, self.rows - 1);
                self.wrap_pending = false;
            },
            'C' => { // CUF
                const dx: u16 = @intCast(@max(p0, 1));
                self.cur_col = @min(self.cur_col + dx, self.cols - 1);
                self.wrap_pending = false;
            },
            'D' => { // CUB
                const dx: u16 = @intCast(@max(p0, 1));
                self.cur_col = if (self.cur_col > dx) self.cur_col - dx else 0;
                self.wrap_pending = false;
            },
            'E' => { // CNL
                const dy: u16 = @intCast(@max(p0, 1));
                self.cur_row = @min(self.cur_row + dy, self.rows - 1);
                self.cur_col = 0;
                self.wrap_pending = false;
            },
            'F' => { // CPL
                const dy: u16 = @intCast(@max(p0, 1));
                self.cur_row = if (self.cur_row > dy) self.cur_row - dy else 0;
                self.cur_col = 0;
                self.wrap_pending = false;
            },
            'G' => { // CHA — col (1-indexed)
                const c: u16 = @intCast(@max(p0, 1));
                self.cur_col = @min(c - 1, self.cols - 1);
                self.wrap_pending = false;
            },
            'H', 'f' => { // CUP / HVP — (row;col) 1-indexed
                const r: u16 = @intCast(@max(p0, 1));
                const c: u16 = @intCast(@max(p1, 1));
                self.cur_row = @min(r - 1, self.rows - 1);
                self.cur_col = @min(c - 1, self.cols - 1);
                self.wrap_pending = false;
            },
            'd' => { // VPA — row (1-indexed)
                const r: u16 = @intCast(@max(p0, 1));
                self.cur_row = @min(r - 1, self.rows - 1);
                self.wrap_pending = false;
            },
            'J' => { // ED
                const mode = p0;
                switch (mode) {
                    0 => self.eraseFromTo(self.idx(self.cur_row, self.cur_col), self.cells.len),
                    1 => self.eraseFromTo(0, self.idx(self.cur_row, self.cur_col) + 1),
                    2, 3 => self.eraseFromTo(0, self.cells.len),
                    else => {},
                }
            },
            'K' => { // EL
                const mode = p0;
                const row_start = self.idx(self.cur_row, 0);
                const row_end = row_start + self.cols;
                switch (mode) {
                    0 => self.eraseFromTo(self.idx(self.cur_row, self.cur_col), row_end),
                    1 => self.eraseFromTo(row_start, self.idx(self.cur_row, self.cur_col) + 1),
                    2 => self.eraseFromTo(row_start, row_end),
                    else => {},
                }
            },
            'X' => { // ECH — erase n chars at cursor
                const cnt: u16 = @intCast(@max(p0, 1));
                const start = self.idx(self.cur_row, self.cur_col);
                const row_end = self.idx(self.cur_row, 0) + self.cols;
                const end = @min(start + cnt, row_end);
                self.eraseFromTo(start, end);
            },
            'P' => { // DCH — delete n chars
                const cnt: u16 = @intCast(@max(p0, 1));
                const row_start = self.idx(self.cur_row, 0);
                const row_end = row_start + self.cols;
                const pos = self.idx(self.cur_row, self.cur_col);
                const move_n = if (row_end > pos + cnt) row_end - pos - cnt else 0;
                if (move_n > 0) std.mem.copyForwards(Cell, self.cells[pos .. pos + move_n], self.cells[pos + cnt .. pos + cnt + move_n]);
                self.eraseFromTo(row_end - cnt, row_end);
            },
            '@' => { // ICH — insert n blank chars
                const cnt: u16 = @intCast(@max(p0, 1));
                const row_start = self.idx(self.cur_row, 0);
                const row_end = row_start + self.cols;
                const pos = self.idx(self.cur_row, self.cur_col);
                const tail = if (row_end > pos + cnt) row_end - pos - cnt else 0;
                if (tail > 0) std.mem.copyBackwards(Cell, self.cells[pos + cnt .. pos + cnt + tail], self.cells[pos .. pos + tail]);
                self.eraseFromTo(pos, @min(pos + cnt, row_end));
            },
            's' => { // SCO save cursor
                self.saved_row = self.cur_row;
                self.saved_col = self.cur_col;
            },
            'u' => { // SCO restore cursor
                self.cur_row = self.saved_row;
                self.cur_col = self.saved_col;
                self.wrap_pending = false;
            },
            'm' => self.sgr(params[0..n]),
            'r' => { // DECSTBM — set scroll region (top;bottom, 1-indexed).
                // Clamp params to rows BEFORE narrowing so a value > 65535 can't
                // panic the @intCast (the parser's forgiving contract).
                const top: u16 = if (p0 > 0) @as(u16, @intCast(@min(p0, self.rows))) - 1 else 0;
                const bot: u16 = if (p1 > 0) @as(u16, @intCast(@min(p1, self.rows))) - 1 else self.rows - 1;
                if (top < bot) {
                    self.scroll_top = top;
                    self.scroll_bottom = bot;
                    self.cur_row = 0; // DECSTBM homes the cursor (no origin mode)
                    self.cur_col = 0;
                    self.wrap_pending = false;
                }
                // An invalid region (top >= bot) is ignored, keeping the prior
                // region + cursor (xterm-style) rather than resetting.
            },
            'S' => self.scrollUp(@intCast(@min(@max(p0, 1), self.rows))), // SU
            'T' => self.scrollDown(@intCast(@min(@max(p0, 1), self.rows))), // SD
            else => {},
        }
    }

    fn eraseFromTo(self: *Grid, start: usize, end: usize) void {
        const e = @min(end, self.cells.len);
        if (start >= e) return;
        for (self.cells[start..e]) |*c| c.* = .{ .fg = self.cur_fg, .bg = self.cur_bg };
    }

    fn sgr(self: *Grid, params: []const u32) void {
        if (params.len == 0) {
            self.cur_attrs = .{};
            self.cur_fg = .default;
            self.cur_bg = .default;
            return;
        }
        var i: usize = 0;
        while (i < params.len) : (i += 1) {
            const p = params[i];
            switch (p) {
                0 => {
                    self.cur_attrs = .{};
                    self.cur_fg = .default;
                    self.cur_bg = .default;
                },
                1 => self.cur_attrs.bold = true,
                2 => self.cur_attrs.dim = true,
                3 => self.cur_attrs.italic = true,
                4 => self.cur_attrs.underline = true,
                7 => self.cur_attrs.reverse = true,
                22 => {
                    self.cur_attrs.bold = false;
                    self.cur_attrs.dim = false;
                },
                23 => self.cur_attrs.italic = false,
                24 => self.cur_attrs.underline = false,
                27 => self.cur_attrs.reverse = false,
                30...37 => self.cur_fg = .{ .indexed = @intCast(p - 30) },
                38 => {
                    if (i + 2 < params.len and params[i + 1] == 5) {
                        self.cur_fg = .{ .indexed = @intCast(@min(params[i + 2], 255)) };
                        i += 2;
                    } else if (i + 4 < params.len and params[i + 1] == 2) {
                        // truecolor — quantize to nearest 0-15 for stability
                        self.cur_fg = .{ .indexed = @intCast(@min(params[i + 2] / 16, 15)) };
                        i += 4;
                    }
                },
                39 => self.cur_fg = .default,
                40...47 => self.cur_bg = .{ .indexed = @intCast(p - 40) },
                48 => {
                    if (i + 2 < params.len and params[i + 1] == 5) {
                        self.cur_bg = .{ .indexed = @intCast(@min(params[i + 2], 255)) };
                        i += 2;
                    } else if (i + 4 < params.len and params[i + 1] == 2) {
                        self.cur_bg = .{ .indexed = @intCast(@min(params[i + 2] / 16, 15)) };
                        i += 4;
                    }
                },
                49 => self.cur_bg = .default,
                90...97 => self.cur_fg = .{ .indexed = @intCast(p - 90 + 8) },
                100...107 => self.cur_bg = .{ .indexed = @intCast(p - 100 + 8) },
                else => {},
            }
        }
    }

    // ----- rendering ------------------------------------------------------

    /// Write the grid as a text rectangle, trimming trailing spaces per row.
    pub fn renderText(self: *const Grid, writer: anytype) !void {
        var r: u16 = 0;
        while (r < self.rows) : (r += 1) {
            // Find last non-blank cell.
            var last: i32 = -1;
            var c: u16 = 0;
            while (c < self.cols) : (c += 1) {
                const cell = self.cells[self.idx(r, c)];
                if (cell.cp != ' ' or !cell.fg.eq(Color.default) or !cell.bg.eq(Color.default) or !cell.attrs.isDefault()) {
                    last = c;
                }
            }
            c = 0;
            while (c <= last) : (c += 1) {
                const cell = self.cells[self.idx(r, c)];
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.cp, &buf) catch blk: {
                    buf[0] = '?';
                    break :blk 1;
                };
                try writer.writeAll(buf[0..len]);
            }
            try writer.writeByte('\n');
        }
    }

    /// Write spans of non-default style as `R<row> C<a>-<b> <attrs> fg=<x> bg=<y>`.
    /// Lines are emitted in row-major order; runs that share style on the
    /// same row are coalesced. Default cells produce no output.
    pub fn renderSgr(self: *const Grid, writer: anytype) !void {
        var r: u16 = 0;
        while (r < self.rows) : (r += 1) {
            var c: u16 = 0;
            while (c < self.cols) {
                const cell = self.cells[self.idx(r, c)];
                if (cell.fg.eq(Color.default) and cell.bg.eq(Color.default) and cell.attrs.isDefault()) {
                    c += 1;
                    continue;
                }
                const start = c;
                var end = c + 1;
                while (end < self.cols) : (end += 1) {
                    const nx = self.cells[self.idx(r, end)];
                    if (!Cell.styleEqual(cell, nx)) break;
                }
                try writer.print("R{d} C{d}-{d}", .{ r, start, end - 1 });
                if (cell.attrs.bold) try writer.writeAll(" bold");
                if (cell.attrs.dim) try writer.writeAll(" dim");
                if (cell.attrs.italic) try writer.writeAll(" italic");
                if (cell.attrs.underline) try writer.writeAll(" underline");
                if (cell.attrs.reverse) try writer.writeAll(" reverse");
                switch (cell.fg) {
                    .default => {},
                    .indexed => |i| try writer.print(" fg={d}", .{i}),
                }
                switch (cell.bg) {
                    .default => {},
                    .indexed => |i| try writer.print(" bg={d}", .{i}),
                }
                try writer.writeByte('\n');
                c = end;
            }
        }
    }
};

// ─── tests ────────────────────────────────────────────────────────────────

// ===========================================================================
// Tests — extracted to `vt_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("vt_tests.zig");
}
