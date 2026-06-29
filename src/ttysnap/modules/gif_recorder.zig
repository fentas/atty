//! gif_recorder — capture distinct screen frames (`onFrame`, deduped) and render
//! an animated SVG on `detach`: the "screen recording as a visual" half of the
//! framework. SVG rather than GIF so there's no LZW encoder and the artifact is
//! pure + dependency-free; play it in any browser or Inkscape.
//!
//! Caveat: GitHub sanitizes SVG animation, so an embedded <img> won't animate on
//! GitHub itself — for a GitHub-embeddable GIF, convert a cast_recorder .cast
//! with `agg`. gif_recorder is for local/standalone viewing + a self-contained
//! artifact with zero tooling.
//!
//! Compose: `gif_recorder(.{ .path = "run.svg", .frame_ms = 120 })`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mod = @import("../module.zig");
const fio = @import("../io.zig");

pub fn gif_recorder(comptime cfg: struct {
    path: [:0]const u8,
    /// Display time per captured frame in the rendered animation (ms).
    frame_ms: u32 = 120,
}) type {
    return struct {
        pub const Runtime = struct {
            allocator: Allocator,
            cols: u16,
            rows: u16,
            frames: std.ArrayList([]u8),
        };

        pub fn attach(allocator: Allocator, info: mod.SessionInfo) !Runtime {
            return .{ .allocator = allocator, .cols = info.cols, .rows = info.rows, .frames = .empty };
        }

        pub fn detach(rt: *Runtime) void {
            defer {
                for (rt.frames.items) |f| rt.allocator.free(f);
                rt.frames.deinit(rt.allocator);
            }
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(rt.allocator);
            render(rt, rt.allocator, &buf) catch return; // don't write a truncated SVG
            fio.writeFile(cfg.path, buf.items) catch {};
        }

        pub fn onFrame(rt: *Runtime, grid: *const mod.Grid) void {
            captureFrame(rt, grid) catch {};
        }

        fn captureFrame(rt: *Runtime, grid: *const mod.Grid) !void {
            const cap = (@as(usize, rt.cols) * 4 + 1) * (@as(usize, rt.rows) + 1);
            const scratch = try rt.allocator.alloc(u8, cap);
            defer rt.allocator.free(scratch);
            var w = std.Io.Writer.fixed(scratch);
            grid.renderText(&w) catch {};
            const out = scratch[0..w.end];
            // Dedup identical consecutive frames so the animation only advances
            // on a real screen change (onFrame fires per output chunk).
            if (rt.frames.items.len > 0 and std.mem.eql(u8, rt.frames.getLast(), out)) return;
            const dup = try rt.allocator.dupe(u8, out);
            errdefer rt.allocator.free(dup);
            try rt.frames.append(rt.allocator, dup);
        }

        /// Render the frames as a play-once animated SVG: one monospace <text>
        /// grid per frame, shown for frame_ms via a <set> at its time offset; the
        /// last frame freezes so it stays on screen. Pure — appends to `out`.
        pub fn render(rt: *const Runtime, allocator: Allocator, out: *std.ArrayList(u8)) !void {
            const cw: u32 = 8; // px per monospace cell
            const lh: u32 = 17; // px per line
            const w_px = @as(u32, rt.cols) * cw;
            const h_px = @as(u32, rt.rows) * lh;
            const dt_ms: u32 = if (cfg.frame_ms == 0) 1 else cfg.frame_ms;
            var line: [256]u8 = undefined;

            try out.appendSlice(allocator, try std.fmt.bufPrint(&line, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" font-family=\"monospace\" font-size=\"14\">\n", .{ w_px, h_px }));
            try out.appendSlice(allocator, "<rect width=\"100%\" height=\"100%\" fill=\"#1e1e1e\"/>\n");

            for (rt.frames.items, 0..) |frame, i| {
                const begin = @as(f64, @floatFromInt(@as(u64, i) * dt_ms)) / 1000.0;
                const dur = @as(f64, @floatFromInt(dt_ms)) / 1000.0;
                try out.appendSlice(allocator, "<g visibility=\"hidden\">");
                if (i == rt.frames.items.len - 1) {
                    try out.appendSlice(allocator, try std.fmt.bufPrint(&line, "<set attributeName=\"visibility\" to=\"visible\" begin=\"{d:.3}s\" fill=\"freeze\"/>", .{begin}));
                } else {
                    try out.appendSlice(allocator, try std.fmt.bufPrint(&line, "<set attributeName=\"visibility\" to=\"visible\" begin=\"{d:.3}s\" dur=\"{d:.3}s\"/>", .{ begin, dur }));
                }
                var y: u32 = lh;
                var rows = std.mem.splitScalar(u8, frame, '\n');
                while (rows.next()) |row| {
                    try out.appendSlice(allocator, try std.fmt.bufPrint(&line, "<text x=\"0\" y=\"{d}\" xml:space=\"preserve\" fill=\"#dddddd\">", .{y}));
                    try appendXmlEscaped(allocator, out, row);
                    try out.appendSlice(allocator, "</text>");
                    y += lh;
                }
                try out.appendSlice(allocator, "</g>\n");
            }
            try out.appendSlice(allocator, "</svg>\n");
        }
    };
}

/// Append `data` to `out` with the XML metacharacters escaped. The vt grid
/// never stores C0/DEL bytes in a cell, so renderText output is valid XML in
/// practice (a UTF-8 noncharacter would slip through, but that's unreachable
/// from real terminal output — same stance as cast_recorder's escaping).
fn appendXmlEscaped(allocator: Allocator, out: *std.ArrayList(u8), data: []const u8) !void {
    for (data) |b| switch (b) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        else => try out.append(allocator, b),
    };
}

test {
    _ = @import("gif_recorder_tests.zig");
}
