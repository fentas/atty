//! In-memory 3-stream recorder behind the debug/feedback capture. Keeps the
//! recent window of I/O — `in` (keystrokes atty received), `shell` (raw output
//! the shell produced), `term` (atty's final bytes to the terminal) — each
//! record timestamped. Nothing is written to disk until the user's capture
//! shortcut serialises it (via `forEach` + `debug_report.save`), so there is no
//! passive on-disk log to leak.
//!
//! Storage is a double buffer, not a byte ring: records are appended to the
//! active half until it fills, then the halves swap (the just-filled half
//! becomes the retained "previous window", the stale one is reset). Push is
//! therefore O(1) and allocation-free on the hot path, and the retained window
//! is between one and two halves of history — exact size doesn't matter for a
//! debug snapshot, only that it's bounded and recent.

const std = @import("std");

/// Monotonic milliseconds — same clock idiom the proxy/statusbar use.
fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

pub const Stream = enum(u8) {
    in,
    shell,
    term,

    pub fn name(self: Stream) []const u8 {
        return switch (self) {
            .in => "in",
            .shell => "shell",
            .term => "term",
        };
    }
};

// [data_len:u32-le][ts_ms:i64-le][stream:u8] then `data_len` bytes.
const header_len = 4 + 8 + 1;

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    halves: [2][]u8,
    active: usize = 0, // index of the half currently being written
    pos: usize = 0, // write cursor within the active half
    prev_len: usize = 0, // bytes retained in the inactive (previous) half
    dropped: u64 = 0, // records dropped because a single record exceeded a half
    paused: bool = false, // set while incognito — pushNow drops silently

    /// `half_bytes` is the size of ONE half; total footprint is 2×. A record
    /// larger than a half can never be stored intact, so it's dropped.
    pub fn init(allocator: std.mem.Allocator, half_bytes: usize) !Recorder {
        const cap = @max(half_bytes, header_len + 64);
        const a = try allocator.alloc(u8, cap);
        errdefer allocator.free(a);
        const b = try allocator.alloc(u8, cap);
        return .{ .allocator = allocator, .halves = .{ a, b } };
    }

    pub fn deinit(self: *Recorder) void {
        self.allocator.free(self.halves[0]);
        self.allocator.free(self.halves[1]);
    }

    /// Append a record. Never allocates; never fails. Silently drops a record
    /// too large to fit a half (bumping `dropped`).
    pub fn push(self: *Recorder, stream: Stream, ts_ms: i64, bytes: []const u8) void {
        const need = header_len + bytes.len;
        const cap = self.halves[self.active].len;
        if (need > cap) {
            self.dropped += 1;
            return;
        }
        if (self.pos + need > cap) {
            // Active half is full — retire it, write into the other one.
            self.prev_len = self.pos;
            self.active = 1 - self.active;
            self.pos = 0;
        }
        const buf = self.halves[self.active];
        var p = self.pos;
        std.mem.writeInt(u32, buf[p..][0..4], @intCast(bytes.len), .little);
        p += 4;
        std.mem.writeInt(i64, buf[p..][0..8], ts_ms, .little);
        p += 8;
        buf[p] = @intFromEnum(stream);
        p += 1;
        @memcpy(buf[p .. p + bytes.len], bytes);
        self.pos = p + bytes.len;
    }

    /// Monotonic-clock convenience for the hot-path tees. `clock_gettime`
    /// MONOTONIC is a vDSO read, not a real syscall. Silently drops while
    /// `paused` (incognito) so private sessions are never recorded.
    pub fn pushNow(self: *Recorder, stream: Stream, bytes: []const u8) void {
        if (self.paused) return;
        self.push(stream, nowMs(), bytes);
    }

    /// Walk records oldest→newest (previous half, then active half), invoking
    /// `cb(context, ts_ms, stream, data)` for each.
    pub fn forEach(
        self: *const Recorder,
        context: anytype,
        comptime cb: fn (@TypeOf(context), i64, Stream, []const u8) void,
    ) void {
        const prev = self.halves[1 - self.active][0..self.prev_len];
        walk(prev, context, cb);
        walk(self.halves[self.active][0..self.pos], context, cb);
    }

    fn walk(
        region: []const u8,
        context: anytype,
        comptime cb: fn (@TypeOf(context), i64, Stream, []const u8) void,
    ) void {
        var p: usize = 0;
        while (p + header_len <= region.len) {
            const dlen = std.mem.readInt(u32, region[p..][0..4], .little);
            const ts = std.mem.readInt(i64, region[p + 4 ..][0..8], .little);
            const stream: Stream = @enumFromInt(region[p + 12]);
            const start = p + header_len;
            const end = start + dlen;
            if (end > region.len) break; // truncated tail — stop
            cb(context, ts, stream, region[start..end]);
            p = end;
        }
    }
};

test {
    _ = @import("debug_recorder_tests.zig");
}
