//! snapshotter — assert the screen at named checkpoints against goldens (the
//! "expect(screen)" half). `onSnapshot` renders the grid to text and compares
//! it to `<dir>/<name>.txt`; on mismatch it writes `<dir>/<name>.actual.txt`
//! and returns `error.SnapshotMismatch`, failing the run. In `update` mode it
//! (re)writes the golden instead. A missing golden fails loudly (rather than
//! silently "passing" an unestablished check).
//!
//! Compose: `snapshotter(.{ .dir = "tests/golden" })`, or with
//! `.update = true` to regenerate goldens.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mod = @import("../module.zig");
const fio = @import("../io.zig");

pub const Error = error{ SnapshotMismatch, SnapshotGoldenMissing };

pub fn snapshotter(comptime cfg: struct {
    dir: []const u8,
    update: bool = false,
}) type {
    return struct {
        pub const Runtime = struct {
            allocator: Allocator,
            cols: u16,
            rows: u16,
        };

        pub fn attach(allocator: Allocator, info: mod.SessionInfo) !Runtime {
            return .{ .allocator = allocator, .cols = info.cols, .rows = info.rows };
        }

        pub fn onSnapshot(rt: *Runtime, name: []const u8, grid: *const mod.Grid) !void {
            // Render the current screen to text. 4 bytes/cell is the max for
            // one UTF-8 codepoint (one codepoint per cell) + a newline per row,
            // so a full screen of multi-byte glyphs never silently truncates.
            const cap = (@as(usize, rt.cols) * 4 + 1) * (@as(usize, rt.rows) + 1);
            const text_buf = try rt.allocator.alloc(u8, cap);
            defer rt.allocator.free(text_buf);
            var w = std.Io.Writer.fixed(text_buf);
            grid.renderText(&w) catch {};
            const text = text_buf[0..w.end];

            var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const golden = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}.txt", .{ cfg.dir, name });

            if (cfg.update) {
                try fio.writeFile(golden, text);
                return;
            }

            const prior = fio.readFileAlloc(rt.allocator, golden, 1 << 20) catch |e| {
                if (e != error.FileNotFound) return e; // a real IO error ≠ "no golden yet"
                try writeActual(cfg.dir, name, text);
                return Error.SnapshotGoldenMissing;
            };
            defer rt.allocator.free(prior);

            if (!std.mem.eql(u8, prior, text)) {
                try writeActual(cfg.dir, name, text);
                return Error.SnapshotMismatch;
            }
        }

        fn writeActual(dir: []const u8, name: []const u8, text: []const u8) !void {
            var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const actual = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}.actual.txt", .{ dir, name });
            try fio.writeFile(actual, text);
        }
    };
}

test {
    _ = @import("snapshotter_tests.zig");
}
