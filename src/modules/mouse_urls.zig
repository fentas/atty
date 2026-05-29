//! mouse_urls — clicks on URLs in terminal output open in the
//! browser (or configured opener), gated by a per-host trust model.
//!
//! Trust posture is policy, not convenience: the default is
//! `whitelist_only` because a click in a terminal session may have
//! landed on adversarial output (curl of an untrusted page, log
//! tailing of webhook traffic, etc.) — silently opening every URL
//! turns one click into a phishing-tab opener. Users opt their
//! commonly-visited hosts in via `url_whitelist`; interactive
//! `[y]/[a]/[t]` prompting lands in PR 4h alongside the atty-guard
//! `UrlsAllow` mediation.
//!
//! Capture model mirrors mouse_links — a per-module ring of recent
//! output rows with SGR / OSC strip. Sharing the ring across both
//! modules is a future refactor (the per-byte work is light).

const std = @import("std");
const m = @import("../module.zig");
const dispatch = @import("../dispatch.zig");
const mouse = @import("../mouse.zig");
const detect = @import("mouse_urls/detect.zig");

extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub const Mode = enum {
    /// Click is a no-op; the URL is not opened. Paranoid default
    /// suitable for shared / multi-tenant hosts.
    never,
    /// Open URLs whose host matches an entry in `url_whitelist`;
    /// silent no-op for everything else (status hint surfaces the
    /// reason). Default — least-surprise behaviour while preserving
    /// user agency over what gets launched.
    whitelist_only,
};

pub const Config = struct {
    /// Master gate. See `Mode` doc-comments.
    mode: Mode = .whitelist_only,

    /// Trusted hosts. Entries support `*.example.com` suffix matching
    /// (matches `example.com` AND any subdomain). Match is case-
    /// insensitive on the host; case-sensitive elsewhere.
    url_whitelist: []const []const u8 = &.{},

    /// Browser opener. xdg-open is the canonical Linux indirection
    /// to the user's default browser. Set to "open" on macOS or to
    /// a specific browser binary for repeatable behaviour.
    opener: []const u8 = "xdg-open",

    /// Capture ring rows.
    ring_rows: usize = 256,

    /// Captured bytes per row.
    row_bytes: usize = 1024,

    /// Status-hint TTL after a click-on-non-whitelisted-URL. Lets
    /// the user notice the policy decision without polling.
    hint_ttl_ms: u64 = 4000,
};

pub fn configure(comptime cfg: Config) type {
    comptime {
        if (cfg.ring_rows == 0) @compileError("mouse_urls: ring_rows must be > 0");
        if (cfg.row_bytes == 0) @compileError("mouse_urls: row_bytes must be > 0");
        if (cfg.opener.len == 0) @compileError("mouse_urls: opener must not be empty");
    }
    return struct {
        pub const name = "mouse_urls";
        pub const config = cfg;

        pub const Runtime = struct {
            allocator: std.mem.Allocator,
            ring: []u8,
            line_starts: []usize,
            line_lens: []u16,
            current_row: u64 = 0,
            current_col: u16 = 0,
            ansi: AnsiState = .{},

            // Status hint surfacing the last policy decision —
            // consumed once via provideHintText then cleared.
            hint_buf: [256]u8 = undefined,
            hint_len: usize = 0,
            hint_set_at_ms: u64 = 0,

            // Optional clock for tests to inject monotonic time. nil
            // = real CLOCK_MONOTONIC.
            test_clock_ms: ?u64 = null,

            // Last URL the user attempted to open, surfaced via
            // statusText so they can see what was blocked / launched.
            // Borrowed from hint_buf; valid while hint_len > 0.
        };

        pub fn attach(allocator: std.mem.Allocator, io: std.Io) !Runtime {
            _ = io;
            const ring = try allocator.alloc(u8, cfg.ring_rows * cfg.row_bytes);
            errdefer allocator.free(ring);
            const line_starts = try allocator.alloc(usize, cfg.ring_rows);
            errdefer allocator.free(line_starts);
            const line_lens = try allocator.alloc(u16, cfg.ring_rows);
            for (line_starts, 0..) |*s, i| s.* = i * cfg.row_bytes;
            for (line_lens) |*l| l.* = 0;
            return .{
                .allocator = allocator,
                .ring = ring,
                .line_starts = line_starts,
                .line_lens = line_lens,
            };
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            _ = io;
            rt.allocator.free(rt.ring);
            rt.allocator.free(rt.line_starts);
            rt.allocator.free(rt.line_lens);
        }

        pub fn onOutput(rt: *Runtime, ctx: *m.Context, output: []const u8) !void {
            _ = ctx;
            ingest(cfg, rt, output);
        }

        pub fn onMouseClick(
            rt: *Runtime,
            ctx: *m.Context,
            evt: mouse.Event,
        ) m.Error!dispatch.MouseAction {
            if (evt.button != .left or evt.kind != .press) return .passthrough;

            const line = clickedLine(cfg, rt, ctx, evt.row) orelse return .passthrough;
            const hit = detect.find(line, evt.col, .{}) orelse return .passthrough;

            switch (cfg.mode) {
                .never => {
                    setHint(rt, "url-open disabled (mode=never): ", hit.url);
                    return .consume;
                },
                .whitelist_only => {
                    if (hostMatches(hit.host, cfg.url_whitelist)) {
                        spawnOpener(cfg.opener, hit.url) catch |err| {
                            setHintErr(rt, hit.url, err);
                            return .consume;
                        };
                        setHint(rt, "opening: ", hit.url);
                    } else {
                        setHint(rt, "host not in whitelist: ", hit.host);
                    }
                    return .consume;
                },
            }
        }

        pub fn provideHintText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            _ = ctx;
            if (rt.hint_len == 0) return null;
            if (rt.test_clock_ms == null) {
                // Real clock TTL check only when monotonic time
                // available; tests set test_clock_ms to bypass.
                const now = nowMs();
                if (now -% rt.hint_set_at_ms > cfg.hint_ttl_ms) {
                    rt.hint_len = 0;
                    return null;
                }
            } else if (rt.test_clock_ms.? -% rt.hint_set_at_ms > cfg.hint_ttl_ms) {
                rt.hint_len = 0;
                return null;
            }
            const out = rt.hint_buf[0..rt.hint_len];
            rt.hint_len = 0;
            return out;
        }
    };
}

const AnsiState = struct {
    in_csi: bool = false,
    in_osc: bool = false,
    saw_esc: bool = false,
};

fn ingest(comptime cfg: Config, rt: anytype, output: []const u8) void {
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const c = output[i];

        if (rt.ansi.in_csi) {
            if (c >= 0x40 and c <= 0x7e) rt.ansi.in_csi = false;
            continue;
        }
        if (rt.ansi.in_osc) {
            if (c == 0x07) {
                rt.ansi.in_osc = false;
            } else if (c == 0x1b) {
                rt.ansi.in_osc = false;
                rt.ansi.saw_esc = true;
            }
            continue;
        }
        if (rt.ansi.saw_esc) {
            rt.ansi.saw_esc = false;
            switch (c) {
                '[' => rt.ansi.in_csi = true,
                ']' => rt.ansi.in_osc = true,
                else => {},
            }
            continue;
        }
        if (c == 0x1b) {
            rt.ansi.saw_esc = true;
            continue;
        }

        switch (c) {
            '\n' => {
                rt.current_row +%= 1;
                rt.current_col = 0;
                const idx: usize = @intCast(rt.current_row % cfg.ring_rows);
                rt.line_lens[idx] = 0;
            },
            '\r' => rt.current_col = 0,
            0x08 => {
                if (rt.current_col > 0) rt.current_col -= 1;
            },
            else => {
                if (c < 0x20 or c == 0x7f) continue;
                const idx: usize = @intCast(rt.current_row % cfg.ring_rows);
                if (rt.current_col < cfg.row_bytes) {
                    rt.ring[rt.line_starts[idx] + rt.current_col] = c;
                    const new_col = rt.current_col + 1;
                    rt.line_lens[idx] = new_col;
                    rt.current_col = new_col;
                }
            },
        }
    }
}

fn clickedLine(comptime cfg: Config, rt: anytype, ctx: *m.Context, click_row: u16) ?[]const u8 {
    const term_rows = ctx.terminal_rows orelse return null;
    if (click_row == 0 or click_row > term_rows) return null;
    const reserved = ctx.statusbar_reserve orelse 0;
    if (term_rows <= reserved) return null;
    if (click_row > term_rows - reserved) return null;

    const target: u64 = if (rt.current_row + 1 >= @as(u64, term_rows))
        rt.current_row + @as(u64, click_row) - @as(u64, term_rows)
    else
        @as(u64, click_row) - 1;

    if (target > rt.current_row) return null;
    if (rt.current_row - target >= cfg.ring_rows) return null;

    const idx: usize = @intCast(target % cfg.ring_rows);
    const start = rt.line_starts[idx];
    const len = rt.line_lens[idx];
    return rt.ring[start .. start + len];
}

pub fn hostMatches(host: []const u8, whitelist: []const []const u8) bool {
    for (whitelist) |pattern| {
        if (matchOne(host, pattern)) return true;
    }
    return false;
}

fn matchOne(host: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;

    // Strip optional `:port` from the host for matching — entries
    // are written by humans without a port, and the trust decision
    // shouldn't depend on the port number.
    const host_no_port = if (std.mem.lastIndexOfScalar(u8, host, ':')) |idx|
        host[0..idx]
    else
        host;

    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[2..];
        if (std.ascii.eqlIgnoreCase(host_no_port, suffix)) return true;
        if (host_no_port.len > suffix.len + 1) {
            const tail_start = host_no_port.len - suffix.len;
            if (host_no_port[tail_start - 1] == '.' and
                std.ascii.eqlIgnoreCase(host_no_port[tail_start..], suffix))
                return true;
        }
        return false;
    }

    return std.ascii.eqlIgnoreCase(host_no_port, pattern);
}

fn setHint(rt: anytype, prefix: []const u8, body: []const u8) void {
    var w: usize = 0;
    const cap = rt.hint_buf.len;
    const pcopy = @min(prefix.len, cap - w);
    @memcpy(rt.hint_buf[w .. w + pcopy], prefix[0..pcopy]);
    w += pcopy;
    const bcopy = @min(body.len, cap - w);
    @memcpy(rt.hint_buf[w .. w + bcopy], body[0..bcopy]);
    w += bcopy;
    rt.hint_len = w;
    rt.hint_set_at_ms = if (rt.test_clock_ms) |c| c else nowMs();
}

fn setHintErr(rt: anytype, url: []const u8, err: anyerror) void {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "opener failed ({s}): ", .{@errorName(err)}) catch
        return setHint(rt, "opener failed: ", url);
    setHint(rt, msg, url);
}

extern "c" fn clock_gettime(clk_id: c_int, tp: *std.posix.timespec) c_int;

fn nowMs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub const SpawnError = error{
    /// fork(2) failed — likely RLIMIT_NPROC or system overload.
    ForkFailed,
    /// The URL is too long for our internal argv buffer (32 KiB).
    UrlTooLong,
};

fn spawnOpener(opener: []const u8, url: []const u8) SpawnError!void {
    if (opener.len == 0 or opener.len >= 256) return error.UrlTooLong;
    if (url.len == 0 or url.len >= 32 * 1024) return error.UrlTooLong;

    // Double-fork: child A becomes init's child after exit; child B
    // execs the opener and becomes init's grandchild. Parent only
    // has to wait for child A (which exits immediately), so no
    // zombies accumulate.
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const pid2 = fork();
        if (pid2 < 0) std.c._exit(127);
        if (pid2 > 0) std.c._exit(0); // child A exits
        // ---- child B ----
        _ = setsid();
        detachStdio();

        var opener_buf: [256]u8 = undefined;
        var url_buf: [32 * 1024]u8 = undefined;
        @memcpy(opener_buf[0..opener.len], opener);
        opener_buf[opener.len] = 0;
        @memcpy(url_buf[0..url.len], url);
        url_buf[url.len] = 0;

        const argv = [_:null]?[*:0]const u8{
            @ptrCast(&opener_buf[0]),
            @ptrCast(&url_buf[0]),
        };
        _ = execvp(@ptrCast(&opener_buf[0]), &argv);
        std.c._exit(127);
    }
    // Parent: reap child A (immediate exit).
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
}

extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;

fn detachStdio() void {
    const fd = std.c.open("/dev/null", @bitCast(std.c.O{ .ACCMODE = .RDWR }), @as(std.c.mode_t, 0));
    if (fd < 0) return;
    _ = std.c.dup2(fd, 0);
    _ = std.c.dup2(fd, 1);
    _ = std.c.dup2(fd, 2);
    if (fd > 2) _ = std.c.close(fd);
}

test {
    _ = @import("mouse_urls_tests.zig");
}
