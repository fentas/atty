//! attop's read-only client for the atty-guard metrics API — one
//! `get_metrics` round-trip per dashboard poll. Fully bounded (a
//! non-blocking connect polled for at most `timeout_ms`, then a polled
//! read) so a down/wedged daemon never hangs the UI; on any failure the
//! caller renders the "daemon not running" state.

const std = @import("std");
const posix = std.posix;

/// Mirrors atty-guard's MetricsCounters (protocol.rs). All defaulted so a
/// forward/older daemon that omits a field still parses.
pub const Counters = struct {
    commands: u64 = 0,
    ghost_accepted: u64 = 0,
    ghost_shown: u64 = 0,
    keystrokes_saved: u64 = 0,
    llm_calls: u64 = 0,
    guard_warn: u64 = 0,
    guard_block: u64 = 0,
    guard_refused: u64 = 0,
};

/// Mirrors atty-guard's GuardPosture (protocol.rs). Strings borrow the
/// parse arena (valid until the Parsed is deinited).
pub const Guard = struct {
    profile: []const u8 = "",
    ebpf: []const u8 = "",
    enforcement: []const u8 = "",
    atoms_version: []const u8 = "",
    deny_path: u32 = 0,
    deny_basename: u32 = 0,
    /// Cargo features compiled into the daemon (ebpf/tier2-onnx/osv-live/
    /// atoms-fetch). Defaulted so an older daemon without the field parses.
    features: []const []const u8 = &.{},
};

/// The get_metrics reply body (the "type" tag is ignored on parse).
pub const Metrics = struct {
    aggregate: Counters = .{},
    guard: Guard = .{},
    instances: u64 = 0,
};

/// One live atty instance (mirrors atty-guard's InstanceInfo). Strings
/// borrow the parse arena.
pub const Instance = struct {
    uid: u32 = 0,
    pid: u32 = 0,
    cwd: []const u8 = "",
    shell: []const u8 = "",
    incognito: bool = false,
    last_seen_ms: u64 = 0,
    counters: Counters = .{},
};

/// The list_instances reply body.
pub const InstancesReply = struct {
    instances: []Instance = &.{},
};

pub const default_socket = "/run/atty-guard/atty-guard.sock";

/// $ATTY_GUARD_SOCK override, else the system daemon path.
pub fn socketPath() []const u8 {
    if (std.c.getenv("ATTY_GUARD_SOCK")) |p| return std.mem.span(p);
    return default_socket;
}

/// Parse a reply line into T (caller deinits the Parsed). Pure — split out
/// so each wire shape is unit-testable without a daemon.
pub fn parseInto(comptime T: type, allocator: std.mem.Allocator, line: []const u8) ?std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, line, .{ .ignore_unknown_fields = true }) catch null;
}

/// Metrics-specific parse (the get_metrics path + its tests).
pub fn parse(allocator: std.mem.Allocator, line: []const u8) ?std.json.Parsed(Metrics) {
    return parseInto(Metrics, allocator, line);
}

/// One request→reply round-trip parsed into T. Fully bounded: a
/// non-blocking connect + a polled read against ONE deadline, so a
/// down/wedged daemon can't hang the UI. Returns the parsed reply (caller
/// deinits) or null on any failure.
fn roundtrip(
    comptime T: type,
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    timeout_ms: u32,
    req: []const u8,
) ?std.json.Parsed(T) {
    const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    if (fd < 0) return null;
    defer _ = std.c.close(fd);

    const deadline = nowMs() + @as(i64, timeout_ms);

    var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    if (socket_path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;
    const addr_len: posix.socklen_t = @intCast(@sizeOf(@TypeOf(addr)));

    const crc = std.c.connect(fd, @ptrCast(&addr), addr_len);
    if (crc != 0) {
        const e = posix.errno(crc);
        if (e != .AGAIN and e != .INPROGRESS) return null;
        if (!pollOnce(fd, posix.POLL.OUT, deadline)) return null;
    }

    var off: usize = 0;
    while (off < req.len) {
        const n = std.c.write(fd, req.ptr + off, req.len - off);
        if (n < 0) {
            const e = posix.errno(n);
            // Non-blocking socket: a full send buffer is EAGAIN (poll for
            // writability); EINTR is a signal (attop's SIGWINCH/SIGTERM
            // handlers) — both retry, not fail. Bounded by the deadline.
            if (e == .AGAIN) {
                if (!pollOnce(fd, posix.POLL.OUT, deadline)) return null;
                continue;
            }
            if (e == .INTR) continue;
            return null;
        }
        if (n == 0) return null;
        off += @intCast(n);
    }

    // Read one newline-framed reply, bounded by the buffer + deadline.
    // 64 KiB holds a list_instances reply of a few hundred sessions (each
    // ~200B); a single user realistically has a handful, so truncation
    // (no newline in the buffer → null → the "unavailable" state) is only
    // reachable by a pathological fleet.
    var buf: [65536]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        if (!pollOnce(fd, posix.POLL.IN, deadline)) return null;
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n < 0) {
            // EAGAIN (spurious/raced poll wake) or EINTR (a signal, e.g.
            // SIGWINCH) — re-poll rather than treat it as a dead connection.
            const e = posix.errno(n);
            if (e == .AGAIN or e == .INTR) continue;
            return null;
        }
        if (n == 0) return null; // EOF
        len += @intCast(n);
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
            return parseInto(T, allocator, buf[0..nl]);
        }
    }
    return null;
}

pub fn fetch(allocator: std.mem.Allocator, socket_path: []const u8, timeout_ms: u32) ?std.json.Parsed(Metrics) {
    return roundtrip(Metrics, allocator, socket_path, timeout_ms, "{\"id\":1,\"method\":\"get_metrics\"}\n");
}

pub fn listInstances(allocator: std.mem.Allocator, socket_path: []const u8, timeout_ms: u32) ?std.json.Parsed(InstancesReply) {
    return roundtrip(InstancesReply, allocator, socket_path, timeout_ms, "{\"id\":1,\"method\":\"list_instances\"}\n");
}

fn pollOnce(fd: i32, events: i16, deadline: i64) bool {
    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    while (true) {
        const t = remainingMs(deadline);
        if (t == 0) return false; // total budget spent
        const r = std.c.poll(&pfd, 1, t);
        // Retry on EINTR (attop's SIGWINCH handler) — but with the
        // REMAINING budget, so an EINTR storm can't exceed the deadline.
        if (r < 0 and posix.errno(r) == .INTR) continue;
        if (r <= 0) return false;
        return (pfd[0].revents & events) != 0;
    }
}

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

fn remainingMs(deadline: i64) i32 {
    const r = deadline - nowMs();
    return if (r <= 0) 0 else @intCast(@min(r, std.math.maxInt(i32)));
}

test {
    _ = @import("uds_tests.zig");
}
