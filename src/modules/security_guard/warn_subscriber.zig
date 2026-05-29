//! Background subscriber for the daemon's `subscribe_warn_events`
//! stream — atty-side half of #347 PR 3.
//!
//! Spawns one thread per Runtime that connects to the daemon UDS,
//! sends the subscribe RPC, and pushes each incoming `WarnEvent`
//! into a mutex-protected ring buffer. The statusText hook +
//! the (future PR 3b) overlay UI read this buffer.
//!
//! Reconnect-on-disconnect: the daemon may bounce (systemctl
//! restart, rebuild during dev). On stream EOF / error the thread
//! sleeps `reconnect_backoff_ms` then tries again. Bounded retries
//! aren't useful — the operator's instinct is "atty should pick up
//! the daemon as soon as it's back", so forever-retry with a fixed
//! cap on the back-off cadence is the right shape.
//!
//! No JSON dependency — the daemon's response shape is fixed +
//! small, so manual prefix matching against the known wire shape
//! is simpler than pulling in a JSON parser for this one use site.
const std = @import("std");

/// One warn event held in the in-proc buffer. Heap-owned strings
/// so the events outlive the daemon line that produced them; the
/// statusText hook + overlay UI render from snapshots.
pub const Event = struct {
    pid: u32,
    ppid: u32,
    comm: []u8, // heap-allocated
    argv0: []u8, // heap-allocated
    timestamp_ms: u64,

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        allocator.free(self.comm);
        allocator.free(self.argv0);
    }
};

/// Capacity of the per-Runtime warn-event ring buffer. Beyond
/// this, oldest events drop. 256 sized to absorb a burst (CI
/// compile-flurry) without losing the most-recent context;
/// operator usually only cares about the last screenful anyway.
pub const RING_CAP: usize = 256;

pub const Subscriber = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    parent_pid_tree: u32,
    io: ?std.Io = null,
    mutex: std.Io.Mutex = .init,
    events: std.ArrayListUnmanaged(Event) = .empty,
    /// Set to true on detach to signal the thread to exit on its
    /// next reconnect cycle. The thread checks between socket I/O
    /// calls; doesn't interrupt a blocked read (those have their
    /// own SO_RCVTIMEO).
    shutdown: std.atomic.Value(bool) = .init(false),
    /// Best-effort total dropped from the ring (oldest-out when
    /// at cap, plus `WarnDropped` notices from the daemon side).
    /// Surfaced in statusText / overlay so the operator knows the
    /// view is windowed.
    dropped_total: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,
    /// 5-second initial back-off, doubles up to 60s. Resets to
    /// initial on a successful subscribe.
    reconnect_backoff_ms: u32 = 5_000,

    pub fn init(
        allocator: std.mem.Allocator,
        socket_path: []const u8,
        parent_pid_tree: u32,
    ) Subscriber {
        return .{
            .allocator = allocator,
            .socket_path = socket_path,
            .parent_pid_tree = parent_pid_tree,
        };
    }

    /// Spawns the subscriber thread. Returns immediately; the
    /// thread connects + subscribes in the background. Idempotent
    /// — second start() call is a no-op.
    ///
    /// `io` is the std.Io bus the thread uses for mutex
    /// operations (Zig 0.16 mutex takes an io). Test paths can
    /// skip start() and use injectForTesting + count/snapshot
    /// directly — those don't touch io.
    pub fn start(self: *Subscriber, io: std.Io) std.Thread.SpawnError!void {
        if (self.thread != null) return;
        self.io = io;
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Signals the thread to exit on its next loop iteration +
    /// frees the event buffer. Joins the thread before returning
    /// so the daemon connection is cleanly closed. Safe to call
    /// when start() was never invoked (frees the test-only
    /// in-proc buffer).
    pub fn stop(self: *Subscriber) void {
        self.shutdown.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        // No mutex needed at deinit: thread is joined (or never
        // started); nothing else can touch events.
        for (self.events.items) |*e| e.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    pub fn count(self: *Subscriber) usize {
        if (self.io) |io| {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.events.items.len;
        }
        // No io → no thread → no concurrent mutation. Read direct.
        return self.events.items.len;
    }

    pub fn droppedTotal(self: *Subscriber) u32 {
        return self.dropped_total.load(.acquire);
    }

    /// Caller-owned snapshot of the current buffer; freed via
    /// `freeSnapshot`. Lets the overlay UI iterate without
    /// holding the mutex through render.
    pub fn snapshot(
        self: *Subscriber,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]Event {
        if (self.io) |io| {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return try snapshotLocked(self, allocator);
        }
        return try snapshotLocked(self, allocator);
    }

    fn snapshotLocked(
        self: *Subscriber,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]Event {
        var out = try allocator.alloc(Event, self.events.items.len);
        for (self.events.items, 0..) |src, i| {
            out[i] = .{
                .pid = src.pid,
                .ppid = src.ppid,
                .comm = try allocator.dupe(u8, src.comm),
                .argv0 = try allocator.dupe(u8, src.argv0),
                .timestamp_ms = src.timestamp_ms,
            };
        }
        return out;
    }

    pub fn freeSnapshot(allocator: std.mem.Allocator, snap: []Event) void {
        for (snap) |*e| e.deinit(allocator);
        allocator.free(snap);
    }

    /// Test-only event injection — production path is the
    /// background thread reading from the socket. No mutex (test
    /// fixtures don't run the thread).
    pub fn injectForTesting(self: *Subscriber, evt: Event) std.mem.Allocator.Error!void {
        try self.pushLocked(evt);
    }

    /// Caller must hold `mutex`. Drops oldest on cap overflow +
    /// bumps `dropped_total`.
    fn pushLocked(self: *Subscriber, evt: Event) std.mem.Allocator.Error!void {
        if (self.events.items.len >= RING_CAP) {
            // Drop oldest. orderedRemove is O(n) which is fine at
            // this cap — the alternative (true ring buffer with
            // head/tail pointers) is more code for negligible
            // perf at 256 entries.
            var dropped = self.events.orderedRemove(0);
            dropped.deinit(self.allocator);
            _ = self.dropped_total.fetchAdd(1, .acq_rel);
        }
        try self.events.append(self.allocator, evt);
    }
};

fn runLoop(sub: *Subscriber) void {
    while (!sub.shutdown.load(.acquire)) {
        connectAndPump(sub) catch |err| {
            std.log.warn("atty security_guard: warn subscriber disconnect: {s}", .{@errorName(err)});
        };
        if (sub.shutdown.load(.acquire)) return;
        // Back off + retry. The daemon side might be restarting,
        // unloading eBPF, or rebuilt mid-dev. Don't spin.
        sleepMs(sub.reconnect_backoff_ms);
    }
}

fn connectAndPump(sub: *Subscriber) !void {
    const fd = try connect(sub.socket_path);
    defer _ = std.c.close(fd);
    try sendSubscribe(fd, sub.parent_pid_tree);
    // Pump events until the daemon closes the connection or we
    // hit an unrecoverable read error.
    try pumpEvents(fd, sub);
}

fn connect(socket_path: []const u8) !i32 {
    if (socket_path.len >= 108) return error.PathTooLong;
    const fd_raw = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (fd_raw < 0) return error.SocketFailed;
    const fd: i32 = @intCast(fd_raw);
    errdefer _ = std.c.close(fd);
    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);
    const len: std.posix.socklen_t = @intCast(
        @sizeOf(std.posix.sa_family_t) + socket_path.len + 1,
    );
    if (std.c.connect(fd, @ptrCast(&addr), len) < 0) return error.ConnectFailed;
    return fd;
}

fn sendSubscribe(fd: i32, parent_pid_tree: u32) !void {
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &buf,
        "{{\"id\":1,\"method\":\"subscribe_warn_events\",\"parent_pid_tree\":{d}}}\n",
        .{parent_pid_tree},
    );
    var written: usize = 0;
    while (written < msg.len) {
        const n = std.c.write(fd, msg.ptr + written, msg.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
    // Drain the `Subscribed` ack — required to flush before the
    // server starts pushing events. Reading a JSON line that
    // includes "subscribed" is enough; we don't need full parsing.
    var ack_buf: [4096]u8 = undefined;
    const ack_line = try readLine(fd, &ack_buf);
    if (std.mem.indexOf(u8, ack_line, "\"subscribed\"") == null) {
        return error.UnexpectedAck;
    }
}

fn pumpEvents(fd: i32, sub: *Subscriber) !void {
    var line_buf: [16384]u8 = undefined;
    while (!sub.shutdown.load(.acquire)) {
        const line = readLine(fd, &line_buf) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        // Reset reconnect back-off on first event received — the
        // stream is healthy.
        if (sub.reconnect_backoff_ms > 5_000) sub.reconnect_backoff_ms = 5_000;
        try handleLine(sub, line);
    }
}

fn handleLine(sub: *Subscriber, line: []const u8) !void {
    // Discriminator first — cheap substring match against `"type":"..."`.
    if (std.mem.indexOf(u8, line, "\"type\":\"warn_event\"") != null) {
        const evt = try parseWarnEvent(sub.allocator, line);
        const io = sub.io orelse return error.IoMissing;
        sub.mutex.lockUncancelable(io);
        defer sub.mutex.unlock(io);
        try sub.pushLocked(evt);
    } else if (std.mem.indexOf(u8, line, "\"type\":\"warn_dropped\"") != null) {
        if (parseWarnDropped(line)) |count| {
            _ = sub.dropped_total.fetchAdd(count, .acq_rel);
        }
    }
    // Other shapes (error, subscribed re-ack) ignored.
}

fn parseWarnEvent(allocator: std.mem.Allocator, line: []const u8) !Event {
    return .{
        .pid = try parseU64Field(line, "\"pid\":"),
        .ppid = try parseU64Field(line, "\"ppid\":"),
        .comm = try parseStringField(allocator, line, "\"comm\":\""),
        .argv0 = try parseStringField(allocator, line, "\"argv0\":\""),
        .timestamp_ms = parseU64FieldWide(line, "\"timestamp_ms\":") catch return error.FieldMissing,
    };
}

/// Sibling parser kept around for `timestamp_ms` which can exceed
/// u32 in practice (millis-since-daemon-start grows fast enough
/// to matter after a few weeks of uptime). The other numeric
/// fields are pids — u32-bounded — so `parseU64Field` stays.
fn parseU64FieldWide(line: []const u8, prefix: []const u8) !u64 {
    const start = (std.mem.indexOf(u8, line, prefix) orelse return error.FieldMissing) + prefix.len;
    var end = start;
    while (end < line.len) : (end += 1) {
        const c = line[end];
        if (c < '0' or c > '9') break;
    }
    if (end == start) return error.FieldEmpty;
    return try std.fmt.parseInt(u64, line[start..end], 10);
}

/// Test-only re-export so warn_subscriber_tests can exercise the
/// parser without re-implementing wire-shape knowledge.
pub fn parseWarnEventForTesting(allocator: std.mem.Allocator, line: []const u8) !Event {
    return parseWarnEvent(allocator, line);
}

fn parseWarnDropped(line: []const u8) ?u32 {
    const v = parseU64Field(line, "\"count\":") catch return null;
    return v;
}

fn parseU64Field(line: []const u8, prefix: []const u8) !u32 {
    const start = (std.mem.indexOf(u8, line, prefix) orelse return error.FieldMissing) + prefix.len;
    var end = start;
    while (end < line.len) : (end += 1) {
        const c = line[end];
        if (c < '0' or c > '9') break;
    }
    if (end == start) return error.FieldEmpty;
    const v = try std.fmt.parseInt(u64, line[start..end], 10);
    if (v > std.math.maxInt(u32)) return error.FieldOverflow;
    return @intCast(v);
}

fn parseStringField(
    allocator: std.mem.Allocator,
    line: []const u8,
    prefix: []const u8,
) ![]u8 {
    const start = (std.mem.indexOf(u8, line, prefix) orelse return error.FieldMissing) + prefix.len;
    // Find closing quote. Daemon-side `comm` / `argv0` are
    // serde-serialized; bare `"` in payload would be escaped as
    // `\"` so a literal `"` ends the value.
    var end = start;
    while (end < line.len and line[end] != '"') : (end += 1) {
        if (line[end] == '\\' and end + 1 < line.len) end += 1;
    }
    return try allocator.dupe(u8, line[start..end]);
}

fn readLine(fd: i32, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(fd, buf.ptr + len, 1);
        if (n == 0) return error.EndOfStream;
        if (n < 0) return error.ReadFailed;
        if (buf[len] == '\n') return buf[0..len];
        len += 1;
    }
    return error.LineTooLong;
}

fn sleepMs(ms: u32) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast(@as(i64, ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

test {
    _ = @import("warn_subscriber_tests.zig");
}
