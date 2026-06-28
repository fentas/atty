//! attop Fleet panel — every live atty session as a row (docs/dashboard.md
//! Fleet). Driven by the daemon's list_instances. PURE render so the layout
//! is unit-testable; cwd is tail-truncated to fit the width.

const std = @import("std");
const atty = @import("atty");
const uds = @import("uds.zig");
const theme = @import("theme.zig");
const i18n = @import("i18n.zig");
const panel = @import("panel.zig");
const list_mod = @import("list.zig");
const box = @import("box.zig");

const reset = atty.style.reset;

pub const compact_cols: u16 = 80;

pub fn renderFleet(buf: []u8, instances: ?[]const uds.Instance, cols: u16, rows: u16) []const u8 {
    _ = rows;
    var w = std.Io.Writer.fixed(buf);
    draw(&w, instances, cols) catch {};
    return buf[0..w.end];
}

/// Fleet panel — live atty sessions, now selectable + scrollable, with a
/// per-session detail view and `/`-search.
pub const Panel = struct {
    const Mode = enum { browse, search, detail };

    pub const Runtime = struct {
        list: list_mod.List = .{},
        mode: Mode = .browse,
        filter: [128]u8 = undefined,
        filter_len: usize = 0,
    };

    pub fn attach(_: std.mem.Allocator) !Runtime {
        return .{};
    }
    pub fn title() []const u8 {
        return "Fleet";
    }
    pub fn navKey() u8 {
        return 'f';
    }

    fn filterStr(rt: *Runtime) []const u8 {
        return rt.filter[0..rt.filter_len];
    }

    /// Indices into `insts` that pass the `/`-filter (shell or cwd substring,
    /// case-insensitive). Allocated in the per-frame arena.
    fn filtered(rt: *Runtime, insts: []const uds.Instance, a: std.mem.Allocator) []const usize {
        const f = filterStr(rt);
        var out: std.ArrayList(usize) = .empty;
        for (insts, 0..) |inst, i| {
            if (f.len == 0 or
                list_mod.containsIgnoreCase(inst.shell, f) or
                list_mod.containsIgnoreCase(inst.cwd, f))
            {
                out.append(a, i) catch {};
            }
        }
        return out.items;
    }

    /// Visible session rows = total height minus host chrome (tab bar +
    /// footer) and the panel's own header/count lines. Approximate; the
    /// List clamps the selection into whatever it gets.
    fn viewportRows(rows: u16) usize {
        const reserved: u16 = 9;
        return if (rows > reserved) rows - reserved else 1;
    }

    pub fn render(rt: *Runtime, ctx: *panel.Ctx, w: *std.Io.Writer) !void {
        const t = theme.active;
        const s = i18n.active;
        const cols = ctx.cols;
        const compact = cols < compact_cols;

        if (ctx.instances == null) {
            try w.print("{f}Fleet{s}\r\n\r\n", .{ t.title, reset });
            try w.print("  {f}{s}{s}\r\n  {s}\r\n", .{ t.danger, s.not_reachable, reset, s.fix_daemon_unreachable });
            return;
        }
        const insts = ctx.instances.?;
        const idx = filtered(rt, insts, ctx.arena);
        rt.list.setViewport(viewportRows(ctx.rows));
        rt.list.setLen(idx.len);

        // Detail view replaces the list for the selected session.
        if (rt.mode == .detail and idx.len > 0) {
            try renderDetail(w, insts[idx[rt.list.selected]], cols);
            return;
        }

        // Header + (search line | blank).
        try w.print("{f}Fleet{s}{s}\r\n", .{ t.title, reset, if (compact) "" else s.suffix_sessions });
        if (rt.mode == .search) {
            try w.print("  {f}/{s}{s}\u{2588}\r\n", .{ t.accent, filterStr(rt), reset });
        } else {
            try w.writeAll("\r\n");
        }

        if (insts.len == 0) {
            try w.print("  {f}{s}{s}\r\n  {s}\r\n", .{ t.muted, s.no_sessions, reset, s.fleet_enable_hint });
            return;
        }
        if (idx.len == 0) {
            try w.print("  {f}no sessions match \u{201C}{s}\u{201D}{s}\r\n", .{ t.muted, filterStr(rt), reset });
            return;
        }

        if (compact) {
            try w.print("  {f}{s:<7} {s:<8} {s:>5}{s}\r\n", .{ t.muted, "pid", "shell", "cmds", reset });
        } else {
            try w.print("  {f}{s:<7} {s:<8} {s:>5}  {s}{s}\r\n", .{ t.muted, "pid", "shell", "cmds", "cwd", reset });
        }

        const vis = rt.list.visible();
        var i = vis.start;
        while (i < vis.end) : (i += 1) {
            try renderRow(w, insts[idx[i]], cols, compact, i == rt.list.selected, t);
        }

        const term = if (idx.len == 1) s.fleet_terminals_one else s.fleet_terminals_many;
        try w.print("\r\n  {d} {s}\r\n", .{ idx.len, term });
    }

    pub fn onKey(rt: *Runtime, _: *panel.Ctx, k: panel.Key) !panel.Action {
        switch (rt.mode) {
            // Detail is modal: any key closes it (Ctrl-C still quits, handled
            // by the host before onKey).
            .detail => {
                rt.mode = .browse;
                return .handled;
            },
            .search => {
                switch (k) {
                    .escape => {
                        rt.filter_len = 0; // clear + leave search
                        rt.mode = .browse;
                    },
                    .enter => rt.mode = .browse, // keep the filter
                    .backspace => if (rt.filter_len > 0) {
                        rt.filter_len -= 1;
                    },
                    .char => |c| if (rt.filter_len < rt.filter.len) {
                        rt.filter[rt.filter_len] = c;
                        rt.filter_len += 1;
                    },
                    else => {},
                }
                return .handled;
            },
            .browse => {
                switch (k) {
                    .char => |c| if (c == '/') {
                        rt.mode = .search;
                        return .handled;
                    },
                    .enter => {
                        if (rt.list.len > 0) rt.mode = .detail;
                        return .handled;
                    },
                    else => {},
                }
                // List motion (j/k/arrows/gg/G/page). Consumed → don't let
                // global nav also act on j/k.
                if (rt.list.handleKey(k)) return .handled;
                return .pass;
            },
        }
    }

    pub fn footerHint(rt: *Runtime, _: *panel.Ctx) ?[]const u8 {
        return switch (rt.mode) {
            .detail => "any key closes detail",
            .search => "type to filter \u{b7} Enter keep \u{b7} Esc clear",
            .browse => "j/k move \u{b7} Enter detail \u{b7} / search",
        };
    }
};

/// One session row; the selected row is wrapped in reverse video.
fn renderRow(w: *std.Io.Writer, inst: uds.Instance, cols: u16, compact: bool, selected: bool, t: theme.Theme) !void {
    const shell = if (inst.shell.len > 0) inst.shell else "\u{2014}";
    if (selected) try w.writeAll("\x1b[7m");
    try w.print("  {d:<7} {s:<8} {d:>5}", .{ inst.pid, shell, inst.counters.commands });
    if (!compact) {
        const cwd = cwdShow(inst.cwd, cwdBudget(cols), t.glyph.ellipsis);
        try w.writeAll("  ");
        if (cwd.ellipsis) try w.writeAll(t.glyph.ellipsis);
        try w.print("{s}", .{cwd.text});
    }
    if (inst.incognito) try w.print(" {s}", .{t.glyph.incognito});
    if (selected) try w.writeAll("\x1b[27m");
    try w.writeAll("\r\n");
}

/// Per-session detail, framed in a box.
fn renderDetail(w: *std.Io.Writer, inst: uds.Instance, cols: u16) !void {
    const t = theme.active;
    try w.print("{f}Fleet{s} \u{203A} session\r\n\r\n", .{ t.title, reset });

    var lb: [5][256]u8 = undefined;
    var lines: [5][]const u8 = undefined;
    const shell = if (inst.shell.len > 0) inst.shell else "\u{2014}";
    // Pre-truncate the cwd so the format can never overflow its buffer (a
    // failed bufPrint would silently blank the row). The box width-clamps for
    // display on top of this.
    const cwd_cap = lb[2].len - 16;
    const cwd_shown = if (inst.cwd.len > cwd_cap) inst.cwd[0..cwd_cap] else inst.cwd;
    lines[0] = std.fmt.bufPrint(&lb[0], "pid        {d}", .{inst.pid}) catch "";
    lines[1] = std.fmt.bufPrint(&lb[1], "shell      {s}", .{shell}) catch "";
    lines[2] = std.fmt.bufPrint(&lb[2], "cwd        {s}", .{cwd_shown}) catch "";
    lines[3] = std.fmt.bufPrint(&lb[3], "commands   {d}", .{inst.counters.commands}) catch "";
    lines[4] = std.fmt.bufPrint(&lb[4], "incognito  {s}", .{if (inst.incognito) "yes" else "no"}) catch "";

    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "session {d}", .{inst.pid}) catch "session";
    try box.drawBox(w, title, lines[0..5], cols);
}

fn draw(w: *std.Io.Writer, instances: ?[]const uds.Instance, cols: u16) !void {
    const t = theme.active;
    const s = i18n.active;
    const compact = cols < compact_cols;
    if (compact) {
        try w.print("{f}Fleet{s}\r\n\r\n", .{ t.title, reset });
    } else {
        try w.print("{f}Fleet{s}{s}\r\n\r\n", .{ t.title, reset, s.suffix_sessions });
    }

    if (instances == null) {
        // null = the round-trip failed for ANY reason (down, unreachable,
        // timeout, malformed) — say "not reachable", not "not running".
        try w.print("  {f}{s}{s}\r\n", .{ t.danger, s.not_reachable, reset });
        try w.print("  {s}\r\n", .{s.fix_daemon_unreachable});
        return;
    }
    const list = instances.?;
    if (list.len == 0) {
        try w.print("  {f}{s}{s}\r\n", .{ t.muted, s.no_sessions, reset });
        try w.print("  {s}\r\n", .{s.fleet_enable_hint});
        return;
    }

    if (compact) {
        try w.print("  {f}{s:<7} {s:<8} {s:>5}{s}\r\n", .{ t.muted, "pid", "shell", "cmds", reset });
    } else {
        try w.print("  {f}{s:<7} {s:<8} {s:>5}  {s}{s}\r\n", .{ t.muted, "pid", "shell", "cmds", "cwd", reset });
    }

    for (list) |inst| {
        const shell = if (inst.shell.len > 0) inst.shell else "\u{2014}";
        if (compact) {
            try w.print("  {d:<7} {s:<8} {d:>5}", .{ inst.pid, shell, inst.counters.commands });
        } else {
            const cwd = cwdShow(inst.cwd, cwdBudget(cols), t.glyph.ellipsis);
            try w.print("  {d:<7} {s:<8} {d:>5}  ", .{ inst.pid, shell, inst.counters.commands });
            if (cwd.ellipsis) try w.writeAll(t.glyph.ellipsis);
            try w.print("{s}", .{cwd.text});
        }
        if (inst.incognito) try w.print(" {s}", .{t.glyph.incognito});
        try w.writeAll("\r\n");
    }

    const term = if (list.len == 1) s.fleet_terminals_one else s.fleet_terminals_many;
    try w.print("\r\n  {d} {s}\r\n", .{ list.len, term });
}

/// Columns available for the cwd after the pid/shell/cmds prefix, leaving
/// room for the trailing incognito marker so an incognito row's cwd can't
/// push the line past the width. Reserves the worst case (unicode " 🔒" ≈ 3
/// cols); the ascii " P" (2) just over-reserves harmlessly.
fn cwdBudget(cols: u16) usize {
    const reserved: usize = 26 + 3; // prefix (2+7+1+8+1+5+2) + marker
    return if (cols > reserved + 8) cols - reserved else 8;
}

const Cwd = struct { ellipsis: bool, text: []const u8 };

/// Show the TAIL of a path (the deepest dirs are the useful part), with a
/// leading ellipsis when truncated. Reserves the ellipsis's DISPLAY width
/// (1 for "…", 3 for the ascii "...") so the marked line still fits `max`.
fn cwdShow(cwd: []const u8, max: usize, ellipsis: []const u8) Cwd {
    if (cwd.len <= max) return .{ .ellipsis = false, .text = cwd };
    const ew = cellWidth(ellipsis);
    const keep = if (max > ew) max - ew else 1;
    var start = cwd.len - keep;
    // Don't start mid-codepoint: skip UTF-8 continuation bytes (10xxxxxx)
    // so a tail-truncated path can't emit a garbled glyph.
    while (start < cwd.len and (cwd[start] & 0xC0) == 0x80) start += 1;
    return .{ .ellipsis = true, .text = cwd[start..] };
}

/// Display columns of a (no-wide-char) glyph string = its codepoint count
/// (one column each); a UTF-8 continuation byte adds no column.
fn cellWidth(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) n += 1;
    }
    return n;
}

test {
    _ = @import("fleet_tests.zig");
}
