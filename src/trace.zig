//! Env-var-gated diagnostic logging.
//!
//! Compiled into every build but inert unless the `ATTY_TRACE`
//! environment variable is set at startup. Used to diagnose
//! interactions that don't reproduce under unit tests — slow
//! keystroke timing, terminal-specific behaviour, cursor placement
//! after multi-pass paint sequences.
//!
//! Usage from the user side:
//!
//!     ATTY_TRACE=1 atty bash 2>/tmp/atty.log
//!     # reproduce the bug
//!     # send /tmp/atty.log to a maintainer
//!
//! Optional categories — set `ATTY_TRACE=input,paint` to only get
//! those two. `ATTY_TRACE=1` (or `=all`) enables every category.
//! Empty / unset disables everything (the early `enabled` check
//! short-circuits before any formatting work).
//!
//! Output goes to fd 2 (stderr) via a single direct `write()`
//! syscall so the log stream isn't entangled with the rest of
//! atty's stdio (which is being actively rewritten in the proxy
//! loop). Each line is `[atty-trace:<cat>] <message>\n` so it
//! greps cleanly out of mixed stderr.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

pub const Category = enum {
    /// stdin read boundaries + raw bytes received.
    input,
    /// keymap matches + match misses.
    keymap,
    /// CSI-u detection, translation, drop decisions.
    csiu,
    /// dispatchInput per-module action + final decision.
    dispatch,
    /// bytes forwarded to pty.master.
    forward,
    /// alt-screen / DECSTBM state transitions seen on master output.
    altscreen,
    /// provideTermBytes invocations + bytes emitted to user stdout.
    paint,
    /// cursor_tracker updates + position queries.
    cursor,

    fn tag(self: Category) []const u8 {
        return switch (self) {
            .input => "input",
            .keymap => "keymap",
            .csiu => "csiu",
            .dispatch => "dispatch",
            .forward => "forward",
            .altscreen => "altscreen",
            .paint => "paint",
            .cursor => "cursor",
        };
    }
};

const Cache = struct {
    initialised: bool = false,
    enabled_mask: u8 = 0,
};

var cache: Cache = .{};

fn maskFor(cat: Category) u8 {
    return @as(u8, 1) << @intFromEnum(cat);
}

/// Parse the `ATTY_TRACE` env var once on first call. `1` or `all`
/// enables every category; a comma-separated list (e.g. `input,csiu`)
/// enables only those.
fn refreshMask() void {
    cache.initialised = true;
    cache.enabled_mask = 0;
    const raw_ptr = getenv("ATTY_TRACE") orelse return;
    const raw = std.mem.span(raw_ptr);
    if (raw.len == 0) return;
    if (std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "all")) {
        cache.enabled_mask = 0xFF;
        return;
    }
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len == 0) continue;
        inline for (std.meta.fields(Category)) |f| {
            if (std.mem.eql(u8, trimmed, f.name)) {
                cache.enabled_mask |= @as(u8, 1) << f.value;
            }
        }
    }
}

fn isEnabled(cat: Category) bool {
    if (!cache.initialised) refreshMask();
    return (cache.enabled_mask & maskFor(cat)) != 0;
}

/// Emit a trace line if `cat` is enabled. Inert otherwise.
pub fn log(comptime cat: Category, comptime fmt: []const u8, args: anytype) void {
    if (!isEnabled(cat)) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "[atty-trace:" ++ comptime cat.tag() ++ "] " ++ fmt ++ "\n",
        args,
    ) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
}

/// Convenience for binary payload — emits the first `max` bytes as
/// hex, truncated with `…` when longer. Single allocation-free call.
pub fn logBytes(comptime cat: Category, comptime label: []const u8, bytes: []const u8) void {
    if (!isEnabled(cat)) return;
    const max: usize = 32;
    var hex_buf: [max * 3 + 4]u8 = undefined;
    var w: std.Io.Writer = .fixed(&hex_buf);
    const n = if (bytes.len < max) bytes.len else max;
    for (bytes[0..n]) |b| {
        w.print("{x:0>2} ", .{b}) catch break;
    }
    if (bytes.len > max) w.writeAll("…") catch {};
    log(cat, label ++ " len={d} bytes={s}", .{ bytes.len, w.buffered() });
}
