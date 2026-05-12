//! Snapshot read/write/compare for the e2e framework.
//!
//! A "snapshot" is a directory holding:
//!   grid.txt   — rendered text grid (trailing blanks trimmed per row)
//!   grid.sgr   — non-default style spans, one per line
//!
//! Each scenario's `golden/` dir contains:
//!   env.toml             — terminal size + forced env + argv + atty version
//!   cast.json            — full asciinema-v2 recording of the session
//!   <snapshot-name>/grid.txt
//!   <snapshot-name>/grid.sgr
//!
//! On a failed comparison we leave `actual.txt` / `actual.sgr` next to the
//! golden so the user can `diff -u golden/foo/grid.txt actual/foo/grid.txt`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vt = @import("vt.zig");

/// One captured frame for a `snapshot <name>` directive.
pub const Frame = struct {
    grid_text: []u8,
    grid_sgr: []u8,
    allocator: Allocator,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.grid_text);
        self.allocator.free(self.grid_sgr);
        self.* = undefined;
    }
};

pub fn captureFrame(allocator: Allocator, grid: *const vt.Grid) !Frame {
    var text_list: std.ArrayList(u8) = .empty;
    defer text_list.deinit(allocator);
    var text_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &text_list);
    try grid.renderText(&text_aw.writer);
    const text_bytes = try text_aw.toOwnedSlice();
    errdefer allocator.free(text_bytes);

    var sgr_list: std.ArrayList(u8) = .empty;
    defer sgr_list.deinit(allocator);
    var sgr_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &sgr_list);
    try grid.renderSgr(&sgr_aw.writer);
    const sgr_bytes = try sgr_aw.toOwnedSlice();

    return .{
        .grid_text = text_bytes,
        .grid_sgr = sgr_bytes,
        .allocator = allocator,
    };
}

/// Recorded environment for a scenario run.
pub const EnvSnapshot = struct {
    atty_version: []const u8,
    cols: u16,
    rows: u16,
    argv: []const []const u8,
    forced_env: []const KV,
    extra_env: []const KV,

    pub const KV = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// Write env.toml (our subset is valid TOML too).
pub fn writeEnv(writer: anytype, env: EnvSnapshot) !void {
    try writer.print("# atty e2e — recorded environment\n", .{});
    try writer.print("atty_version = \"{s}\"\n", .{env.atty_version});
    try writer.print("cols = {d}\n", .{env.cols});
    try writer.print("rows = {d}\n", .{env.rows});
    try writer.print("\n[argv]\n", .{});
    for (env.argv, 0..) |a, i| try writer.print("{d} = \"{f}\"\n", .{ i, fmtTomlStr(a) });
    try writer.print("\n[forced_env]\n", .{});
    for (env.forced_env) |kv| try writer.print("{s} = \"{f}\"\n", .{ kv.key, fmtTomlStr(kv.value) });
    if (env.extra_env.len > 0) {
        try writer.print("\n[extra_env]\n", .{});
        for (env.extra_env) |kv| try writer.print("{s} = \"{f}\"\n", .{ kv.key, fmtTomlStr(kv.value) });
    }
}

const TomlStrFmt = struct {
    s: []const u8,
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.s) |c| switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) try writer.print("\\u{x:0>4}", .{c}) else try writer.writeByte(c),
        };
    }
};

pub fn fmtTomlStr(s: []const u8) TomlStrFmt {
    return .{ .s = s };
}

/// Asciinema v2 cast recorder. Events appended in real time; finalise on
/// scenario end. We hold the full session in memory because typical
/// scenarios are tiny (<100 KiB).
pub const Cast = struct {
    allocator: Allocator,
    width: u16,
    height: u16,
    started_ms: i64 = 0,
    started: bool = false,
    events: std.ArrayList(Event),

    pub const Event = struct {
        t_us: i64,
        kind: u8, // 'o' or 'i'
        bytes: []u8,
    };

    pub fn init(allocator: Allocator, width: u16, height: u16) Cast {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .events = .empty,
        };
    }

    pub fn deinit(self: *Cast) void {
        for (self.events.items) |e| self.allocator.free(e.bytes);
        self.events.deinit(self.allocator);
    }

    pub fn record(self: *Cast, kind: u8, bytes: []const u8) !void {
        const now_ms = monoMillis();
        if (!self.started) {
            self.started = true;
            self.started_ms = now_ms;
        }
        const t_us = (now_ms - self.started_ms) * 1000;
        const owned = try self.allocator.dupe(u8, bytes);
        try self.events.append(self.allocator, .{ .t_us = t_us, .kind = kind, .bytes = owned });
    }

    pub fn write(self: *const Cast, writer: anytype) !void {
        try writer.print(
            "{{\"version\":2,\"width\":{d},\"height\":{d},\"timestamp\":0,\"env\":{{\"TERM\":\"xterm-256color\",\"SHELL\":\"/bin/sh\"}}}}\n",
            .{ self.width, self.height },
        );
        for (self.events.items) |e| {
            const t_sec_f: f64 = @as(f64, @floatFromInt(e.t_us)) / 1_000_000.0;
            try writer.print("[{d:.6}, \"{c}\", \"", .{ t_sec_f, e.kind });
            for (e.bytes) |b| switch (b) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"),
                0x0C => try writer.writeAll("\\f"),
                else => if (b < 0x20 or b == 0x7F)
                    try writer.print("\\u{x:0>4}", .{b})
                else
                    try writer.writeByte(b),
            };
            try writer.writeAll("\"]\n");
        }
    }
};

const posix = std.posix;
extern "c" fn clock_gettime(clk_id: c_int, tp: *posix.timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;

pub fn monoMillis() i64 {
    var ts: posix.timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

/// Return value from comparing a frame against its golden.
pub const CompareResult = union(enum) {
    match,
    missing_golden,
    mismatch: struct {
        // One of grid.txt or grid.sgr (or both) differ.
        text_diff: bool,
        sgr_diff: bool,
    },
};

pub fn compareFrame(
    io: std.Io,
    allocator: Allocator,
    golden_dir_path: []const u8,
    frame: *const Frame,
) !CompareResult {
    var cwd = std.Io.Dir.cwd();
    var golden_dir = cwd.openDir(io, golden_dir_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return .missing_golden,
        else => return e,
    };
    defer golden_dir.close(io);

    const want_text = golden_dir.readFileAlloc(io, "grid.txt", allocator, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return .missing_golden,
        else => return e,
    };
    defer allocator.free(want_text);

    const want_sgr = golden_dir.readFileAlloc(io, "grid.sgr", allocator, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => @as([]u8, &.{}),
        else => return e,
    };
    defer if (want_sgr.len > 0) allocator.free(want_sgr);

    const text_diff = !std.mem.eql(u8, want_text, frame.grid_text);
    const sgr_diff = !std.mem.eql(u8, want_sgr, frame.grid_sgr);
    if (!text_diff and !sgr_diff) return .match;
    return .{ .mismatch = .{ .text_diff = text_diff, .sgr_diff = sgr_diff } };
}

pub fn writeGoldenFrame(io: std.Io, golden_dir_path: []const u8, frame: *const Frame) !void {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, golden_dir_path);
    var dir = try cwd.openDir(io, golden_dir_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "grid.txt", .data = frame.grid_text });
    try dir.writeFile(io, .{ .sub_path = "grid.sgr", .data = frame.grid_sgr });
}

pub fn writeActualFrame(io: std.Io, actual_dir_path: []const u8, frame: *const Frame) !void {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, actual_dir_path);
    var dir = try cwd.openDir(io, actual_dir_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "grid.txt", .data = frame.grid_text });
    try dir.writeFile(io, .{ .sub_path = "grid.sgr", .data = frame.grid_sgr });
}

// ─── tests ────────────────────────────────────────────────────────────────

test "captureFrame round-trips a tiny grid" {
    var g = try vt.Grid.init(std.testing.allocator, 1, 8);
    defer g.deinit();
    g.feed("hi");
    var frame = try captureFrame(std.testing.allocator, &g);
    defer frame.deinit();
    try std.testing.expectEqualStrings("hi\n", frame.grid_text);
}

test "writeEnv emits valid-looking TOML" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeEnv(&w, .{
        .atty_version = "0.1.0",
        .cols = 80,
        .rows = 24,
        .argv = &.{ "atty", "bash" },
        .forced_env = &.{
            .{ .key = "TERM", .value = "xterm-256color" },
        },
        .extra_env = &.{},
    });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "cols = 80") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TERM = \"xterm-256color\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0 = \"atty\"") != null);
}
