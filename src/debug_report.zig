//! Serialises a debug capture — context + the recent I/O streams — into a JSON
//! report. Built into a caller-owned buffer (on the capture shortcut, off the
//! hot path); the proxy then writes it to disk. Timestamps are rebased to the
//! first event (seconds, asciinema-style) so a report is self-contained and,
//! later, replayable.

const std = @import("std");
const debug_recorder = @import("debug_recorder.zig");

pub const Meta = struct {
    atty_version: []const u8,
    cols: u16,
    rows: u16,
    term: []const u8,
    shell: []const u8,
    lang: []const u8,
    line_buffer: []const u8,
    line_cursor: usize,
    line_uncertain: bool,
    incognito: bool,
};

const Ctx = struct {
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    first_ts: ?i64 = null,
    first_event: bool = true,
    oom: bool = false,

    fn raw(c: *Ctx, s: []const u8) void {
        c.out.appendSlice(c.alloc, s) catch {
            c.oom = true;
        };
    }

    /// Append `s` as the *inside* of a JSON string (caller writes the quotes).
    fn jsonInner(c: *Ctx, s: []const u8) void {
        for (s) |ch| switch (ch) {
            '"' => c.raw("\\\""),
            '\\' => c.raw("\\\\"),
            '\n' => c.raw("\\n"),
            '\r' => c.raw("\\r"),
            '\t' => c.raw("\\t"),
            // Escape everything outside printable ASCII — control bytes AND
            // high bytes (>= 0x7f). The streams are raw bytes and can contain
            // invalid UTF-8 (partial multibyte at a chunk boundary, binary
            // output); emitting them raw would make the JSON unparseable. Each
            // byte becomes `\u00XX` (latin-1 transparent), so the report stays
            // valid JSON and a byte-exact decoder recovers the original stream.
            else => if (ch < 0x20 or ch >= 0x7f) {
                var b: [8]u8 = undefined;
                c.raw(std.fmt.bufPrint(&b, "\\u{x:0>4}", .{ch}) catch "");
            } else {
                c.out.append(c.alloc, ch) catch {
                    c.oom = true;
                };
            },
        };
    }

    fn field(c: *Ctx, key: []const u8, val: []const u8) void {
        c.raw("  \"");
        c.raw(key);
        c.raw("\": \"");
        c.jsonInner(val);
        c.raw("\",\n");
    }
};

fn emitEvent(c: *Ctx, ts: i64, stream: debug_recorder.Stream, data: []const u8) void {
    if (c.first_ts == null) c.first_ts = ts;
    const rel = @as(f64, @floatFromInt(ts - c.first_ts.?)) / 1000.0;
    if (!c.first_event) c.raw(",\n");
    c.first_event = false;
    var b: [96]u8 = undefined;
    const hdr = std.fmt.bufPrint(&b, "    [{d:.3}, \"{s}\", \"", .{ rel, stream.name() }) catch {
        c.oom = true;
        return;
    };
    c.raw(hdr);
    c.jsonInner(data);
    c.raw("\"]");
}

/// Build the report into `out`. Returns error.OutOfMemory if the buffer grow
/// failed at any point (partial content left in `out`).
pub fn write(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    meta: Meta,
    recorder: *const debug_recorder.Recorder,
) !void {
    var c = Ctx{ .out = out, .alloc = alloc };
    c.raw("{\n");
    c.field("atty_version", meta.atty_version);
    var nb: [128]u8 = undefined;
    c.raw(std.fmt.bufPrint(&nb, "  \"terminal\": {{ \"cols\": {d}, \"rows\": {d} }},\n", .{ meta.cols, meta.rows }) catch "");
    c.raw("  \"env\": {\n");
    c.raw("    \"TERM\": \"");
    c.jsonInner(meta.term);
    c.raw("\",\n    \"SHELL\": \"");
    c.jsonInner(meta.shell);
    c.raw("\",\n    \"LANG\": \"");
    c.jsonInner(meta.lang);
    c.raw("\"\n  },\n");
    c.raw("  \"line_state\": { \"buffer\": \"");
    c.jsonInner(meta.line_buffer);
    c.raw(std.fmt.bufPrint(&nb, "\", \"cursor\": {d}, \"uncertain\": {} }},\n", .{ meta.line_cursor, meta.line_uncertain }) catch "");
    c.raw(std.fmt.bufPrint(&nb, "  \"incognito\": {},\n", .{meta.incognito}) catch "");
    c.raw("  \"streams\": [\n");
    recorder.forEach(&c, emitEvent);
    c.raw("\n  ]\n}\n");
    if (c.oom) return error.OutOfMemory;
}

// ── Disk persistence (libc; runtime, off the hot path) ────────────────────
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;

const O_WRONLY: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY });
const O_CREAT: c_int = @bitCast(std.posix.O{ .CREAT = true });
const O_TRUNC: c_int = @bitCast(std.posix.O{ .TRUNC = true });

/// Resolve the report directory: `dir_cfg` if set, else `$XDG_DATA_HOME/atty/
/// reports`, else `$HOME/.local/share/atty/reports`. Caller owns the result.
fn resolveDir(alloc: std.mem.Allocator, dir_cfg: []const u8) ![]u8 {
    if (dir_cfg.len > 0) return alloc.dupe(u8, dir_cfg);
    if (getenv("XDG_DATA_HOME")) |x| {
        const s = std.mem.sliceTo(x, 0);
        if (s.len > 0) return std.fmt.allocPrint(alloc, "{s}/atty/reports", .{s});
    }
    const home = getenv("HOME") orelse return error.NoHome;
    const hs = std.mem.sliceTo(home, 0);
    if (hs.len == 0) return error.NoHome;
    return std.fmt.allocPrint(alloc, "{s}/.local/share/atty/reports", .{hs});
}

/// `mkdir -p` each path prefix (ignoring "already exists"). Works for both
/// absolute and relative `dir`: starting at 1 only skips the empty prefix
/// `dir[0..0]` (and a leading `/`, which can't be mkdir'd anyway); the first
/// real component is still created at the first `/` — e.g. "a/b" → mkdir "a"
/// then "a/b".
fn mkdirp(alloc: std.mem.Allocator, dir: []const u8) !void {
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i < dir.len and dir[i] != '/') continue;
        const z = try alloc.dupeZ(u8, dir[0..i]);
        defer alloc.free(z);
        _ = std.c.mkdir(z.ptr, 0o700); // EEXIST is fine
    }
}

/// Build + write a report to disk; returns the created path (caller frees).
pub fn save(
    alloc: std.mem.Allocator,
    dir_cfg: []const u8,
    meta: Meta,
    recorder: *const debug_recorder.Recorder,
) ![]u8 {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(alloc);
    try write(&json, alloc, meta, recorder);

    const dir = try resolveDir(alloc, dir_cfg);
    defer alloc.free(dir);
    try mkdirp(alloc, dir);

    // sec + nsec so two captures in the same second don't overwrite.
    var now: std.posix.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &now) != 0) now = .{ .sec = 0, .nsec = 0 };
    const path = try std.fmt.allocPrint(alloc, "{s}/report-{d}-{d}.json", .{ dir, now.sec, now.nsec });
    errdefer alloc.free(path);
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    const fd = open(path_z.ptr, O_WRONLY | O_CREAT | O_TRUNC, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var off: usize = 0;
    while (off < json.items.len) {
        const rc = std.c.write(fd, json.items[off..].ptr, json.items.len - off);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue; // retry a signal-interrupted write
            return error.WriteFailed;
        }
        if (rc == 0) return error.WriteFailed; // a 0-byte write is a truncated report, not success
        off += @intCast(rc);
    }
    return path;
}

test {
    _ = @import("debug_report_tests.zig");
}
