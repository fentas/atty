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
//!
//! Module ordering: when `.ask_each` mode is on, the armed banner's
//! key consumption (returning `.swallow` from `onInput`) must beat
//! other input-consuming modules in dispatch order. Place
//! `mouse_urls` BEFORE `guardrail` (which also swallows on its own
//! armed banner) in the user's `modules` tuple — otherwise an open
//! guardrail prompt could eat the `y/a/t` keystroke meant for the
//! URL banner. The same rule applies to any future input-consuming
//! module.

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
    /// Open URLs whose host matches an entry in `url_whitelist` OR
    /// the in-memory session-trust set. Silent no-op + status hint
    /// for anything else. The least-surprise mode for users who want
    /// agency over what gets launched.
    whitelist_only,
    /// On click of an untrusted URL, arm a banner with `[y]/[a]/[t]/
    /// cancel`: open once / session-trust / print the sudo guidance
    /// for permanent trust / cancel. Trusted hosts (`url_whitelist`
    /// or in-memory session-trust) still fast-path through without a
    /// banner.
    ask_each,
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
    /// the user notice the policy decision without polling. While
    /// the `ask_each` banner is armed the TTL is suspended (the
    /// banner persists until a keystroke).
    hint_ttl_ms: u64 = 4000,

    /// Maximum hosts kept in the in-memory session-trust set. Old
    /// entries are evicted oldest-first. 64 is plenty for a typical
    /// session; raise if you click "a" on many distinct hosts.
    session_trust_capacity: usize = 64,
};

pub const HostSlot = struct {
    bytes: [256]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const HostSlot) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn configure(comptime cfg: Config) type {
    comptime {
        if (cfg.ring_rows == 0) @compileError("mouse_urls: ring_rows must be > 0");
        if (cfg.row_bytes == 0) @compileError("mouse_urls: row_bytes must be > 0");
        if (cfg.opener.len == 0) @compileError("mouse_urls: opener must not be empty");
        if (cfg.session_trust_capacity == 0) @compileError("mouse_urls: session_trust_capacity must be > 0");
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

            // ask_each banner state. While `armed` is true, the
            // statusText shows `Open <url>? [y]/[a]/[t]/cancel` and
            // hint_ttl is suspended. Cleared on any keystroke
            // response (y/a/t/Esc/Ctrl-C/c).
            armed: bool = false,
            armed_url_buf: [2048]u8 = undefined,
            armed_url_len: usize = 0,
            armed_host_buf: [256]u8 = undefined,
            armed_host_len: usize = 0,

            // Session-trust ring of hosts (no port). [a]llow appends
            // here; subsequent clicks on the same host fast-path
            // through the whitelist check. FIFO eviction at capacity.
            session_hosts: []HostSlot = &.{},
            session_head: usize = 0, // next-write index
            session_filled: usize = 0, // entries seen (≤ capacity)

            // Optional clock for tests to inject monotonic time. nil
            // = real CLOCK_MONOTONIC.
            test_clock_ms: ?u64 = null,
        };

        pub fn attach(allocator: std.mem.Allocator, io: std.Io) !Runtime {
            _ = io;
            const ring = try allocator.alloc(u8, cfg.ring_rows * cfg.row_bytes);
            errdefer allocator.free(ring);
            const line_starts = try allocator.alloc(usize, cfg.ring_rows);
            errdefer allocator.free(line_starts);
            const line_lens = try allocator.alloc(u16, cfg.ring_rows);
            errdefer allocator.free(line_lens);
            const session_hosts = try allocator.alloc(HostSlot, cfg.session_trust_capacity);
            for (line_starts, 0..) |*s, i| s.* = i * cfg.row_bytes;
            for (line_lens) |*l| l.* = 0;
            for (session_hosts) |*h| h.* = .{};
            return .{
                .allocator = allocator,
                .ring = ring,
                .line_starts = line_starts,
                .line_lens = line_lens,
                .session_hosts = session_hosts,
            };
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            _ = io;
            rt.allocator.free(rt.ring);
            rt.allocator.free(rt.line_starts);
            rt.allocator.free(rt.line_lens);
            rt.allocator.free(rt.session_hosts);
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
            if (rt.armed) return .consume; // ignore further clicks while a banner is open

            const line = clickedLine(cfg, rt, ctx, evt.row) orelse return .passthrough;
            const hit = detect.find(line, evt.col, .{}) orelse return .passthrough;

            switch (cfg.mode) {
                .never => {
                    setHint(rt, "url-open disabled (mode=never): ", hit.url);
                    return .consume;
                },
                .whitelist_only => {
                    if (hostTrusted(rt, hit.host)) {
                        return launch(rt, hit.url);
                    }
                    setHint(rt, "host not in whitelist: ", hit.host);
                    return .consume;
                },
                .ask_each => {
                    if (hostTrusted(rt, hit.host)) {
                        return launch(rt, hit.url);
                    }
                    arm(rt, hit.url, hit.host);
                    return .consume;
                },
            }
        }

        pub fn onInput(rt: *Runtime, ctx: *m.Context, input: []const u8) m.Error!m.Action {
            _ = ctx;
            if (!rt.armed) return .forward;
            if (input.len == 0) return .forward;

            const c = input[0];
            // Esc / Ctrl-C / Ctrl-U / 'c' cancel.
            if (c == 0x1b or c == 0x03 or c == 0x15 or c == 'c' or c == 'C') {
                disarm(rt);
                setHint(rt, "url-open cancelled: ", rt.armed_url_buf[0..0]);
                return .swallow;
            }

            switch (c) {
                'y', 'Y' => {
                    const url = rt.armed_url_buf[0..rt.armed_url_len];
                    const act = launch(rt, url) catch dispatch.MouseAction.passthrough;
                    _ = act;
                    disarm(rt);
                    return .swallow;
                },
                'a', 'A' => {
                    sessionTrustAdd(rt, rt.armed_host_buf[0..rt.armed_host_len]);
                    const url = rt.armed_url_buf[0..rt.armed_url_len];
                    _ = launch(rt, url) catch dispatch.MouseAction.passthrough;
                    disarm(rt);
                    return .swallow;
                },
                't', 'T' => {
                    // [t] adds to session-trust + surfaces the
                    // permanent-trust guidance, but does NOT open
                    // — opening would clobber the guidance hint
                    // before the user has a chance to read it.
                    // Clicking the same URL again then takes the
                    // session-trust fast-path and opens immediately.
                    const host = rt.armed_host_buf[0..rt.armed_host_len];
                    setPersistHint(rt, host);
                    disarm(rt);
                    return .swallow;
                },
                else => return .swallow, // any other key while armed: ignore (don't pass to shell)
            }
        }

        pub fn statusText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            _ = ctx;
            if (!rt.armed) return null;
            // Use hint_buf as scratch — when armed there's no
            // competing TTL hint to clobber (armed disables it).
            var w: usize = 0;
            const cap = rt.hint_buf.len;
            const prefix: []const u8 = "open ";
            w += copyClamped(rt.hint_buf[w..cap], prefix);
            w += copyClamped(rt.hint_buf[w..cap], rt.armed_host_buf[0..rt.armed_host_len]);
            const suffix: []const u8 = "? [y]es / [a]llow / [t]rust / cancel";
            w += copyClamped(rt.hint_buf[w..cap], suffix);
            return rt.hint_buf[0..w];
        }

        fn arm(rt: *Runtime, url: []const u8, host: []const u8) void {
            rt.armed = true;
            const ucopy = @min(url.len, rt.armed_url_buf.len);
            @memcpy(rt.armed_url_buf[0..ucopy], url[0..ucopy]);
            rt.armed_url_len = ucopy;
            const hcopy = @min(host.len, rt.armed_host_buf.len);
            @memcpy(rt.armed_host_buf[0..hcopy], host[0..hcopy]);
            rt.armed_host_len = hcopy;
            // Clear any pending TTL hint — banner is the active UI.
            rt.hint_len = 0;
        }

        fn disarm(rt: *Runtime) void {
            rt.armed = false;
            rt.armed_url_len = 0;
            rt.armed_host_len = 0;
        }

        fn launch(rt: *Runtime, url: []const u8) m.Error!dispatch.MouseAction {
            spawnOpener(cfg.opener, url) catch |err| {
                setHintErr(rt, url, err);
                return .consume;
            };
            setHint(rt, "opening: ", url);
            return .consume;
        }

        fn hostTrusted(rt: *Runtime, host: []const u8) bool {
            if (hostMatches(host, cfg.url_whitelist)) return true;
            const host_no_port = stripPort(host);
            const n = @min(rt.session_filled, rt.session_hosts.len);
            for (rt.session_hosts[0..n]) |*slot| {
                if (std.ascii.eqlIgnoreCase(slot.slice(), host_no_port)) return true;
            }
            return false;
        }

        fn sessionTrustAdd(rt: *Runtime, host: []const u8) void {
            const host_no_port = stripPort(host);
            if (host_no_port.len == 0) return;
            // Dedupe.
            const n = @min(rt.session_filled, rt.session_hosts.len);
            for (rt.session_hosts[0..n]) |*slot| {
                if (std.ascii.eqlIgnoreCase(slot.slice(), host_no_port)) return;
            }
            const idx = rt.session_head;
            const slot = &rt.session_hosts[idx];
            const copy = @min(host_no_port.len, slot.bytes.len);
            @memcpy(slot.bytes[0..copy], host_no_port[0..copy]);
            slot.len = @intCast(copy);
            rt.session_head = (rt.session_head + 1) % rt.session_hosts.len;
            if (rt.session_filled < rt.session_hosts.len) rt.session_filled += 1;
        }

        fn setPersistHint(rt: *Runtime, host: []const u8) void {
            // Daemon-side `urls allow` requires EUID 0 (see
            // atty-guard/src/server.rs::handle_urls_allow), so atty
            // can't write it directly. Surface the sudo command;
            // session-trust adds the host in-memory for THIS session
            // so the user gets the immediate effect without leaving
            // the prompt.
            sessionTrustAdd(rt, host);
            const host_clean = stripPort(host);
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "session-trusted; persist: sudo atty-guard urls allow {s}", .{host_clean}) catch
                return setHint(rt, "session-trusted: ", host_clean);
            setHint(rt, "", msg);
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

// TODO(termview): `AnsiState` / `ingest` / `clickedLine` are
// byte-identical to `mouse_links.zig`. When a third consumer
// appears, extract into `src/modules/_termview.zig` (or core
// `src/termview.zig` if other layers want it).
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

    const host_no_port = stripPort(host);

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

/// Strip `:port` from a host while preserving IPv6 bracketed
/// literals. `[::1]:8080` → `[::1]`; `example.com:443` →
/// `example.com`; `[::1]` (no port) → `[::1]`.
fn stripPort(host: []const u8) []const u8 {
    if (host.len == 0) return host;
    if (host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return host;
        if (close + 1 < host.len and host[close + 1] == ':') return host[0 .. close + 1];
        return host;
    }
    const idx = std.mem.lastIndexOfScalar(u8, host, ':') orelse return host;
    // Plain hostnames never legitimately contain `:`; the only
    // bare-`:` case is host:port. (Userinfo was already stripped by
    // `extractHost`.)
    return host[0..idx];
}

fn copyClamped(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
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

fn nowMs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    // `.MONOTONIC` resolves the OS-correct clockid_t (was a hardcoded
    // Linux `1`, which is 0/wrong on Darwin).
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub const SpawnError = error{
    /// fork(2) failed — likely RLIMIT_NPROC or system overload.
    ForkFailed,
    /// The URL exceeds the 32 KiB argv slot. Real URLs cap around
    /// 8 KiB; this is a defensive guard, not an expected outcome.
    UrlTooLong,
    /// The opener binary name exceeds the 255-byte slot. The comptime
    /// assert in `configure` catches empty; this branch covers
    /// pathological non-empty cases (config injected by a generator).
    OpenerTooLong,
};

fn spawnOpener(opener: []const u8, url: []const u8) SpawnError!void {
    if (opener.len == 0 or opener.len >= 256) return error.OpenerTooLong;
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
