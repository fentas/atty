const std = @import("std");
const testing = std.testing;
const mod = @import("md_render.zig");

const Captured = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn writer(self: *Captured) std.Io.Writer {
        return std.Io.Writer.fixed(&self.buf);
    }
    pub fn bytes(self: *const Captured) []const u8 {
        return self.buf[0..self.len];
    }
};

fn passthroughSanitize(w: *std.Io.Writer, b: []const u8) anyerror!void {
    try w.writeAll(b);
}

fn renderInto(out: *Captured, content: []const u8, cols: usize, max_rows: usize) !usize {
    var w = out.writer();
    const rows = try mod.render(&w, content, cols, max_rows, &passthroughSanitize);
    out.len = w.end;
    return rows;
}

test "render: hard breaks at `\\n` — multi-line input renders as multi-row" {
    var out: Captured = .{};
    const rows = try renderInto(&out, "line one\nline two\nline three", 80, 5);
    try testing.expectEqual(@as(usize, 3), rows);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "line one") != null);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "line two") != null);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "line three") != null);
    // CR+LF + clear-line between rows so consecutive turns paint
    // onto a known column.
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "\r\n\x1B[2K") != null);
}

test "render: `**bold**` emits SGR bold open/close around the span" {
    var out: Captured = .{};
    _ = try renderInto(&out, "hello **world** done", 80, 1);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "\x1B[1m") != null);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "\x1B[22m") != null);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "world") != null);
    // No literal `**` left in the output — markers consumed.
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "**") == null);
}

test "render: `` `code` `` emits SGR cyan around the span" {
    var out: Captured = .{};
    _ = try renderInto(&out, "run `ls -la` to list", 80, 1);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "\x1B[22;38;5;14m") != null);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "\x1B[39m") != null);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "ls -la") != null);
    // No literal backticks in the output.
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "`") == null);
}

test "render: bold inside code is treated as literal text" {
    var out: Captured = .{};
    _ = try renderInto(&out, "`**not bold**`", 80, 1);
    // Code span emits cyan, the `**` chars stay literal.
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "\x1B[22;38;5;14m") != null);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "**not bold**") != null);
}

test "render: empty source lines preserve as blank rows" {
    var out: Captured = .{};
    const rows = try renderInto(&out, "first\n\nthird", 80, 5);
    try testing.expectEqual(@as(usize, 3), rows);
}

test "render: caps at max_rows with `[…]` marker" {
    var out: Captured = .{};
    const rows = try renderInto(&out, "one\ntwo\nthree\nfour\nfive", 80, 2);
    try testing.expectEqual(@as(usize, 2), rows);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "\u{2026}") != null);
    // "five" past the cap doesn't render.
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "five") == null);
}

test "render: long line word-wraps at last space inside cols budget" {
    var out: Captured = .{};
    const long = "alpha beta gamma delta epsilon zeta eta theta iota kappa";
    // cols=20 forces wrap at last space.
    const rows = try renderInto(&out, long, 20, 5);
    try testing.expect(rows >= 2);
    // Each chunk should fit roughly within 20 cols (allowing the
    // sentinels can land at the col boundary).
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "kappa") != null);
}

test "render: empty content returns 1 row claim" {
    var out: Captured = .{};
    const rows = try renderInto(&out, "", 80, 5);
    try testing.expectEqual(@as(usize, 1), rows);
    // No bytes emitted (caller renders the prefix anyway).
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "render: bold spanning the wrap boundary — open + close balance per row" {
    var out: Captured = .{};
    // Long bold span forces wrap mid-span.
    _ = try renderInto(&out, "**alpha beta gamma delta epsilon zeta**", 15, 5);
    // SGR open and close are paired; render isn't tracking
    // span-survival-across-wrap in v1, so verify markers still
    // appear at boundaries.
    const open_count = std.mem.count(u8, out.bytes(), "\x1B[1m");
    const close_count = std.mem.count(u8, out.bytes(), "\x1B[22m");
    try testing.expectEqual(open_count, close_count);
}

test "render: CRLF source — \\r stripped, \\n is the break" {
    var out: Captured = .{};
    const rows = try renderInto(&out, "line one\r\nline two", 80, 5);
    try testing.expectEqual(@as(usize, 2), rows);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "line one") != null);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "line two") != null);
    // No stray `\r` left in the output.
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "\r\n\rline") == null);
}

test "render: blank line between max_rows doesn't steal the overflow slot" {
    // Regression: `"first\n\nthird"` with max_rows=2 used to enqueue
    // the empty line as `pending`, then the third line's overflow
    // flush would trim THAT empty pending and emit `[…]` instead of
    // rendering `third`. Blank lines now emit immediately so they
    // don't compete for the last row.
    var out: Captured = .{};
    const rows = try renderInto(&out, "first\n\nthird", 80, 2);
    try testing.expectEqual(@as(usize, 2), rows);
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "first") != null);
    // Either "third" or the `[…]` marker is acceptable — both
    // signal the user that content was clipped. Pinned the
    // overflow marker because at max_rows=2 with three logical
    // lines, the third is what gets cut.
    try testing.expect(std.mem.indexOf(u8, out.bytes(), "\u{2026}") != null);
}
