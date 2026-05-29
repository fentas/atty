//! mouse_links — convert clicks on path tokens in terminal output
//! to `$EDITOR` launches.
//!
//! Click flow (issue #304, PR 4f):
//!
//!     onOutput          — SGR-strip + append to row ring
//!     onMouseClick      — left-press → coords → captured row →
//!                         path token (path_detect.find) → queue
//!                         `\x15<editor> +LINE 'path'\n`
//!     pollShellInput    — surface the queued bytes to pty.master,
//!                         shell runs them like the user typed.
//!
//! Output capture model: monotonic row counter; every `\n` starts a
//! new row at `lines[row % N]`. CR/BS reset col within the row.
//! Cursor addressing (CSI H/A/B/C/D) is NOT tracked — this is a
//! streaming-line model fit for compiler / grep / ls / git output.
//! TUIs like vim/htop run in the alt-screen path where atty's mouse
//! intercept is bypassed (the shell owns input), so this model
//! never sees their cursor-addressed paints.
//!
//! Quoting is POSIX shell single-quote with `'\''` escape — see
//! `mouse_links/inject.zig`. Path strings can legitimately contain
//! `*`, `?`, `;`, `$`, backtick, etc.; the formatter quotes them
//! literally so the shell parser doesn't expand them.

const std = @import("std");
const m = @import("../module.zig");
const dispatch = @import("../dispatch.zig");
const mouse = @import("../mouse.zig");
const path_detect = @import("mouse_links/path_detect.zig");
const inject = @import("mouse_links/inject.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

pub const Config = struct {
    /// Override $EDITOR. When null the env var is read at click time;
    /// if neither is set, the click is a silent no-op.
    editor: ?[]const u8 = null,

    /// Capture ring capacity in rows. 256 covers a typical
    /// scrollback depth of one full screen plus margin.
    ring_rows: usize = 256,

    /// Max captured bytes per row. The terminal still sees the full
    /// row through the proxy passthrough; this only bounds what
    /// mouse_links retains for click-lookup.
    row_bytes: usize = 1024,

    /// Accept relative-path tokens (e.g. `src/foo.zig`). When false
    /// only absolute / `~/` / `./` paths are clickable.
    accept_relative: bool = true,
};

pub fn configure(comptime cfg: Config) type {
    return struct {
        pub const name = "mouse_links";
        pub const config = cfg;

        pub const Runtime = struct {
            allocator: std.mem.Allocator,
            ring: []u8,
            line_starts: []usize,
            line_lens: []u16,
            current_row: u64 = 0,
            current_col: u16 = 0,
            ansi: AnsiState = .{},
            inject_buf: [4096]u8 = undefined,
            inject_len: usize = 0,
        };

        pub fn attach(allocator: std.mem.Allocator, io: std.Io) !Runtime {
            _ = io;
            const ring = try allocator.alloc(u8, cfg.ring_rows * cfg.row_bytes);
            errdefer allocator.free(ring);
            const line_starts = try allocator.alloc(usize, cfg.ring_rows);
            errdefer allocator.free(line_starts);
            const line_lens = try allocator.alloc(u16, cfg.ring_rows);
            for (line_starts, 0..) |*s, i| s.* = i * cfg.row_bytes;
            for (line_lens) |*l| l.* = 0;
            return .{
                .allocator = allocator,
                .ring = ring,
                .line_starts = line_starts,
                .line_lens = line_lens,
            };
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            _ = io;
            rt.allocator.free(rt.ring);
            rt.allocator.free(rt.line_starts);
            rt.allocator.free(rt.line_lens);
        }

        pub fn onOutput(rt: *Runtime, ctx: *m.Context, output: []const u8) !void {
            _ = ctx;
            ingest(cfg, rt, output);
        }

        pub fn onMouseClick(
            rt: *Runtime,
            ctx: *m.Context,
            evt: mouse.Event,
        ) m.Error!dispatch.MouseAction {
            if (evt.button != .left or evt.kind != .press) return .passthrough;
            if (rt.inject_len > 0) return .passthrough;

            const line = clickedLine(cfg, rt, ctx, evt.row) orelse return .passthrough;
            const hit = path_detect.find(
                line,
                evt.col,
                .{ .accept_relative = cfg.accept_relative },
            ) orelse return .passthrough;

            const editor = resolveEditor(cfg) orelse return .passthrough;

            const formatted = inject.format(
                &rt.inject_buf,
                editor,
                .{ .path = hit.path, .line = hit.line },
            ) catch return .passthrough;
            rt.inject_len = formatted.len;
            return .consume;
        }

        pub fn pollShellInput(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            _ = ctx;
            if (rt.inject_len == 0) return null;
            const out = rt.inject_buf[0..rt.inject_len];
            rt.inject_len = 0;
            return out;
        }
    };
}

const AnsiState = struct {
    in_csi: bool = false,
    in_osc: bool = false,
    saw_esc: bool = false,
};

fn ingest(comptime cfg: Config, rt: anytype, output: []const u8) void {
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const c = output[i];

        if (rt.ansi.in_csi) {
            if (c >= 0x40 and c <= 0x7e) rt.ansi.in_csi = false;
            continue;
        }
        if (rt.ansi.in_osc) {
            // OSC terminates on BEL or ESC (sloppy ST handling — the
            // ESC of an ST also ends the OSC; the following `\` is
            // an unmapped ESC X that the saw_esc branch ignores).
            if (c == 0x07) {
                rt.ansi.in_osc = false;
            } else if (c == 0x1b) {
                rt.ansi.in_osc = false;
                rt.ansi.saw_esc = true;
            }
            continue;
        }
        if (rt.ansi.saw_esc) {
            rt.ansi.saw_esc = false;
            switch (c) {
                '[' => rt.ansi.in_csi = true,
                ']' => rt.ansi.in_osc = true,
                else => {}, // ESC X — discard the X
            }
            continue;
        }
        if (c == 0x1b) {
            rt.ansi.saw_esc = true;
            continue;
        }

        switch (c) {
            '\n' => {
                rt.current_row +%= 1;
                rt.current_col = 0;
                const idx: usize = @intCast(rt.current_row % cfg.ring_rows);
                rt.line_lens[idx] = 0;
            },
            '\r' => rt.current_col = 0,
            0x08 => { // backspace
                if (rt.current_col > 0) rt.current_col -= 1;
            },
            else => {
                if (c < 0x20 or c == 0x7f) continue;
                const idx: usize = @intCast(rt.current_row % cfg.ring_rows);
                if (rt.current_col < cfg.row_bytes) {
                    rt.ring[rt.line_starts[idx] + rt.current_col] = c;
                    const new_col = rt.current_col + 1;
                    if (new_col > rt.line_lens[idx]) rt.line_lens[idx] = new_col;
                    rt.current_col = new_col;
                }
            },
        }
    }
}

fn clickedLine(comptime cfg: Config, rt: anytype, ctx: *m.Context, click_row: u16) ?[]const u8 {
    const term_rows = ctx.terminal_rows orelse return null;
    if (click_row == 0 or click_row > term_rows) return null;
    const reserved = ctx.statusbar_reserve orelse 0;
    if (term_rows <= reserved) return null;
    if (click_row > term_rows - reserved) return null;

    const target: u64 = if (rt.current_row + 1 >= @as(u64, term_rows))
        rt.current_row + @as(u64, click_row) - @as(u64, term_rows)
    else
        @as(u64, click_row) - 1;

    if (target > rt.current_row) return null;
    if (rt.current_row - target >= cfg.ring_rows) return null;

    const idx: usize = @intCast(target % cfg.ring_rows);
    const start = rt.line_starts[idx];
    const len = rt.line_lens[idx];
    return rt.ring[start .. start + len];
}

fn resolveEditor(comptime cfg: Config) ?[]const u8 {
    if (cfg.editor) |e| if (e.len > 0) return e;
    if (getenv("EDITOR")) |raw| {
        const s = std.mem.sliceTo(raw, 0);
        if (s.len > 0) return s;
    }
    if (getenv("VISUAL")) |raw| {
        const s = std.mem.sliceTo(raw, 0);
        if (s.len > 0) return s;
    }
    return null;
}

test {
    _ = @import("mouse_links_tests.zig");
}
