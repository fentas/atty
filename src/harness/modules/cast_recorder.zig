//! cast_recorder — record the session as an asciinema v2 cast, the "screen
//! recording" half of the framework. `onOutput`/`onInput` accumulate
//! timestamped events; `detach` renders them to the configured path. The
//! `render` core is pure (events → JSON bytes) so it's unit-testable without
//! the filesystem.
//!
//! Compose: `cast_recorder(.{ .path = "run.cast" })`. Play with `asciinema
//! play run.cast` or convert to a GIF with `agg`.
//!
//! Caveat: data is escaped conservatively (valid UTF-8 passes through; control
//! bytes become `\uXXXX`). A `fragment_injector` can split a multi-byte
//! codepoint across events, which lenient players concatenate fine but a strict
//! JSON validator may reject. Recordings aren't asserted, so this is benign;
//! lossless-across-fragmentation export is a follow-on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mod = @import("../module.zig");
const fio = @import("../io.zig");

pub fn cast_recorder(comptime cfg: struct { path: [:0]const u8 }) type {
    return struct {
        const Event = struct { ms: i64, kind: u8, data: []u8 };

        pub const Runtime = struct {
            allocator: Allocator,
            cols: u16,
            rows: u16,
            start_ms: i64,
            events: std.ArrayList(Event),
        };

        pub fn attach(allocator: Allocator, info: mod.SessionInfo) !Runtime {
            return .{
                .allocator = allocator,
                .cols = info.cols,
                .rows = info.rows,
                .start_ms = mod.nowMs(),
                .events = .empty,
            };
        }

        pub fn detach(rt: *Runtime) void {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(rt.allocator);
            render(rt, rt.allocator, &buf) catch {};
            fio.writeFile(cfg.path, buf.items) catch {};
            for (rt.events.items) |e| rt.allocator.free(e.data);
            rt.events.deinit(rt.allocator);
        }

        pub fn onOutput(rt: *Runtime, bytes: []const u8) void {
            record(rt, 'o', bytes) catch {};
        }
        pub fn onInput(rt: *Runtime, bytes: []const u8) void {
            record(rt, 'i', bytes) catch {};
        }

        fn record(rt: *Runtime, kind: u8, bytes: []const u8) !void {
            const dup = try rt.allocator.dupe(u8, bytes);
            errdefer rt.allocator.free(dup);
            try rt.events.append(rt.allocator, .{
                .ms = mod.nowMs() - rt.start_ms,
                .kind = kind,
                .data = dup,
            });
        }

        /// Serialize the recorded events as an asciinema v2 cast (header line +
        /// one `[t, "o"|"i", "data"]` line per event). Pure — appends to `out`.
        pub fn render(rt: *const Runtime, allocator: Allocator, out: *std.ArrayList(u8)) !void {
            var line: [128]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(
                &line,
                "{{\"version\":2,\"width\":{d},\"height\":{d}}}\n",
                .{ rt.cols, rt.rows },
            ));
            for (rt.events.items) |e| {
                const secs = @as(f64, @floatFromInt(e.ms)) / 1000.0;
                try out.appendSlice(allocator, try std.fmt.bufPrint(&line, "[{d:.6}, \"{c}\", \"", .{ secs, e.kind }));
                try appendJsonEscaped(allocator, out, e.data);
                try out.appendSlice(allocator, "\"]\n");
            }
        }
    };
}

/// Append `data` to `out` as the inside of a JSON string. Escapes the JSON
/// metacharacters + C0 controls; bytes >= 0x20 pass through (correct for valid
/// UTF-8). See the file caveat re: fragmented multi-byte codepoints.
fn appendJsonEscaped(allocator: Allocator, out: *std.ArrayList(u8), data: []const u8) !void {
    for (data) |b| switch (b) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0x08 => try out.appendSlice(allocator, "\\b"),
        0x0c => try out.appendSlice(allocator, "\\f"),
        else => if (b < 0x20) {
            var u: [6]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&u, "\\u{x:0>4}", .{b}));
        } else {
            try out.append(allocator, b);
        },
    };
}
