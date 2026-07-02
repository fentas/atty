//! `atty debug replay <report>` — re-read a captured debug report and replay a
//! stream (default `term`) back to the terminal, so a captured render / ghost /
//! LLM bug can be re-seen deterministically. Replaying `term` re-emits exactly
//! what atty wrote to the terminal (its overlay/statusbar/ghost injections
//! included); replaying `shell` shows what the shell produced without atty, so
//! the two together reveal atty's transformation.
//!
//! Report stream data is `\u00XX`-encoded (latin-1 transparent, see
//! debug_report). std.json decodes each escape to code point U+00XX; since the
//! encoder only ever emits code points <= 0xFF, iterating code points and taking
//! the low byte recovers the original stream byte-exactly.

const std = @import("std");

pub const Stream = enum {
    in,
    shell,
    term,

    pub fn fromName(s: []const u8) ?Stream {
        return std.meta.stringToEnum(Stream, s);
    }
    pub fn name(self: Stream) []const u8 {
        return @tagName(self);
    }
};

pub const Event = struct { t: f64, stream: Stream, data: []const u8 };

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    atty_version: []const u8,
    cols: u16,
    rows: u16,
    events: []Event,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }
};

pub const Error = error{ BadReport, OutOfMemory };

/// Recover raw bytes from a `\u00XX`-transparent string as decoded by std.json.
/// atty's encoder only emits code points <= 0xFF (each == one original byte); a
/// code point > 0xFF can only come from a hand-edited / foreign report, so we
/// preserve its UTF-8 bytes rather than truncating. (std.json always yields
/// valid UTF-8, so the init fallback is a defensive no-op.)
fn decodeData(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const view = std.unicode.Utf8View.init(s) catch return arena.dupe(u8, s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0xFF) {
            try out.append(arena, @intCast(cp));
        } else {
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &b) catch continue;
            try out.appendSlice(arena, b[0..n]);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Parse a report's JSON. The returned Report owns an arena holding all its
/// slices — call `deinit`.
pub fn parse(gpa: std.mem.Allocator, json_bytes: []const u8) Error!Report {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{}) catch return error.BadReport;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadReport;
    const root = parsed.value.object;

    const version: []const u8 = if (root.get("atty_version")) |v|
        (if (v == .string) try a.dupe(u8, v.string) else "")
    else
        "";

    var cols: u16 = 0;
    var rows: u16 = 0;
    if (root.get("terminal")) |t| if (t == .object) {
        if (t.object.get("cols")) |c| if (c == .integer and c.integer > 0) {
            cols = std.math.cast(u16, c.integer) orelse 0;
        };
        if (t.object.get("rows")) |r| if (r == .integer and r.integer > 0) {
            rows = std.math.cast(u16, r.integer) orelse 0;
        };
    };

    var events: std.ArrayList(Event) = .empty;
    if (root.get("streams")) |st| if (st == .array) {
        for (st.array.items) |ev| {
            if (ev != .array or ev.array.items.len < 3) continue;
            const sv = ev.array.items[1];
            const dv = ev.array.items[2];
            if (sv != .string or dv != .string) continue;
            const stream = Stream.fromName(sv.string) orelse continue;
            const t: f64 = switch (ev.array.items[0]) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => 0,
            };
            try events.append(a, .{ .t = t, .stream = stream, .data = try decodeData(a, dv.string) });
        }
    };

    return .{
        .arena = arena,
        .atty_version = version,
        .cols = cols,
        .rows = rows,
        .events = try events.toOwnedSlice(a),
    };
}

/// Concatenate one stream's bytes in order (owned by `alloc`).
pub fn streamBytes(report: *const Report, stream: Stream, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (report.events) |ev| {
        if (ev.stream == stream) try out.appendSlice(alloc, ev.data);
    }
    return out.toOwnedSlice(alloc);
}

fn sleepMs(ms: i64) void {
    if (ms <= 0) return;
    var ts = std.c.timespec{ .sec = @intCast(@divFloor(ms, 1000)), .nsec = @intCast(@mod(ms, 1000) * std.time.ns_per_ms) };
    var rem: std.c.timespec = undefined;
    while (true) {
        const rc = std.c.nanosleep(&ts, &rem);
        if (rc == 0) break;
        if (std.posix.errno(rc) != .INTR) break; // re-arm with the remaining time on a signal
        ts = rem;
    }
}

// libc file read (runtime; consistent with debug_report's libc write).
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
const O_RDONLY: c_int = @bitCast(std.posix.O{ .ACCMODE = .RDONLY });

fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = open(path_z.ptr, O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const rc = std.c.read(fd, &chunk, chunk.len);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) break;
        try buf.appendSlice(gpa, chunk[0..@intCast(rc)]);
    }
    return buf.toOwnedSlice(gpa);
}

fn writeStdout(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.c.write(std.posix.STDOUT_FILENO, bytes[off..].ptr, bytes.len - off);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return;
        }
        if (rc == 0) return;
        off += @intCast(rc);
    }
}

fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDERR_FILENO, bytes.ptr, bytes.len);
}

const usage =
    \\usage: atty debug replay <report.json> [--stream in|shell|term] [--fast] [--info]
    \\
    \\  Replays a captured debug report. Default replays the `term` stream with the
    \\  recorded timing so you re-see exactly what atty emitted to the terminal.
    \\    --stream <name>   which stream to replay (default: term)
    \\    --fast            skip inter-event delays (dump instantly)
    \\    --info            print a summary instead of replaying
    \\
;

pub const Options = struct {
    stream: Stream = .term,
    fast: bool = false,
    info: bool = false,
};

/// CLI entry for `atty debug <argv…>`. `argv` is the tokens after `debug`.
/// Returns a process exit code.
pub fn run(gpa: std.mem.Allocator, argv: []const []const u8) u8 {
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "help") or std.mem.eql(u8, argv[0], "-h")) {
        writeStdout(usage);
        return if (argv.len == 0) 2 else 0;
    }
    if (!std.mem.eql(u8, argv[0], "replay")) {
        writeStderr("error: unknown debug verb (expected `replay`)\n\n");
        writeStderr(usage);
        return 2;
    }

    var opts = Options{};
    var path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--fast")) {
            opts.fast = true;
        } else if (std.mem.eql(u8, a, "--info")) {
            opts.info = true;
        } else if (std.mem.eql(u8, a, "--stream")) {
            i += 1;
            if (i >= argv.len) {
                writeStderr("error: --stream needs a value\n");
                return 2;
            }
            opts.stream = Stream.fromName(argv[i]) orelse {
                writeStderr("error: --stream must be in|shell|term\n");
                return 2;
            };
        } else if (std.mem.startsWith(u8, a, "--stream=")) {
            opts.stream = Stream.fromName(a["--stream=".len..]) orelse {
                writeStderr("error: --stream must be in|shell|term\n");
                return 2;
            };
        } else if (a.len > 0 and a[0] == '-') {
            writeStderr("error: unknown flag\n\n");
            writeStderr(usage);
            return 2;
        } else if (path == null) {
            path = a;
        } else {
            writeStderr("error: unexpected extra argument\n\n");
            writeStderr(usage);
            return 2;
        }
    }

    const report_path = path orelse {
        writeStderr("error: replay needs a <report.json> path\n\n");
        writeStderr(usage);
        return 2;
    };

    const json = readFile(gpa, report_path) catch {
        writeStderr("error: cannot read report: ");
        writeStderr(report_path);
        writeStderr("\n");
        return 1;
    };
    defer gpa.free(json);

    var report = parse(gpa, json) catch {
        writeStderr("error: not a valid atty debug report (bad JSON / schema)\n");
        return 1;
    };
    defer report.deinit();

    if (opts.info) {
        printInfo(gpa, &report);
        return 0;
    }

    replayStream(&report, opts);
    return 0;
}

fn replayStream(report: *const Report, opts: Options) void {
    var last_t: ?f64 = null;
    for (report.events) |ev| {
        if (ev.stream != opts.stream) continue;
        if (!opts.fast) {
            if (last_t) |lt| {
                const gap_ms: i64 = @intFromFloat(@min((ev.t - lt) * 1000.0, 2000.0)); // cap gaps at 2s
                sleepMs(gap_ms);
            }
            last_t = ev.t;
        }
        writeStdout(ev.data);
    }
}

fn printInfo(gpa: std.mem.Allocator, report: *const Report) void {
    var counts = [_]usize{ 0, 0, 0 };
    var bytes = [_]usize{ 0, 0, 0 };
    var duration: f64 = 0;
    for (report.events) |ev| {
        const idx = @intFromEnum(ev.stream);
        counts[idx] += 1;
        bytes[idx] += ev.data.len;
        if (ev.t > duration) duration = ev.t;
    }
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf,
        \\atty debug report
        \\  version   : {s}
        \\  terminal  : {d}x{d}
        \\  duration  : {d:.3}s
        \\  in        : {d} events, {d} bytes
        \\  shell     : {d} events, {d} bytes
        \\  term      : {d} events, {d} bytes
        \\
    , .{
        report.atty_version, report.cols, report.rows, duration,
        counts[0],           bytes[0],    counts[1],   bytes[1],
        counts[2],           bytes[2],
    }) catch return;
    _ = gpa;
    writeStdout(msg);
}

test {
    _ = @import("debug_replay_tests.zig");
}
