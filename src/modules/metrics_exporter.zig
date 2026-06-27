//! metrics_exporter — opt-in dashboard telemetry (attop, see
//! docs/dashboard.md). Holds per-session counters and flushes them to the
//! atty-guard daemon's `report_metrics` UDS on a batched `onTick`, so the
//! `attop` dashboard can show "what is atty doing for me" + a fleet view.
//!
//! NOT in the default `modules` tuple — enable it explicitly in
//! `src/config.zig`:
//!
//!     atty.modules.metrics_exporter.configure(.{}),
//!
//! Hot-path discipline: counters are bumped on `onLineCommit` (cheap,
//! integer add — never `onInput`), and the only I/O (the UDS report) runs
//! on `onTick`, batched to `report_interval_ms`, over a fully non-blocking
//! socket (connect polled at most `timeout_ms`, then a non-blocking write)
//! so a stuck daemon can't wedge the tick thread. Reporting is best-effort:
//! a connect/write failure is swallowed (the daemon is optional).
//!
//! Privacy: counts only, never command content. Incognito is governed by
//! `incognito_policy` — by default a session reports its existence + the
//! guard_* security counters while incognito, but suppresses the
//! productivity counters + its cwd (see `IncognitoPolicy`).

const std = @import("std");
const m = @import("../module.zig");
const lib = @import("_lib.zig");

const Allocator = std.mem.Allocator;

/// What the exporter sends while the session is in incognito mode.
pub const IncognitoPolicy = enum {
    /// Report nothing — the daemon's TTL prunes the session, so it drops
    /// out of the dashboard entirely while incognito.
    nothing,
    /// Report existence + the guard_* security counters only; suppress the
    /// productivity counters and blank the cwd. The default — a threat
    /// matters even in incognito, but the productivity view doesn't leak.
    security_only,
    /// Report normally, as if not incognito.
    normal,
};

pub const Config = struct {
    enabled: bool = true,
    /// atty-guard UDS path. The daemon reads `report_metrics` here.
    daemon_socket_path: []const u8 = "/run/atty-guard/atty-guard.sock",
    /// Minimum gap between reports; the flush is batched on `onTick`.
    report_interval_ms: u64 = 5_000,
    /// Poll budget (ms) for the non-blocking connect when the daemon's
    /// listen backlog is momentarily full — keep it small; the report runs
    /// on the latency-sensitive tick thread.
    timeout_ms: u32 = 30,
    incognito_policy: IncognitoPolicy = .security_only,
};

/// Monotonic per-session counters. Field names + JSON shape match the
/// daemon's `MetricsCounters` (atty-guard/src/protocol.rs).
///
/// STUB STATUS (P1b): only `commands` is wired today (incremented on
/// `onLineCommit`). The other seven are reserved — they always report 0
/// until the producing events are exposed: ghost_* via atuin/history,
/// keystrokes_saved via ghost acceptance, llm_calls via the llm module,
/// and guard_* (ideally daemon-sourced — the daemon issues the verdicts).
/// Wiring them is a follow-up; the wire shape is stable so adding a
/// producer needs no protocol change.
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

/// True when the session should report NOTHING this flush (incognito +
/// `nothing` policy).
pub fn incognitoSkip(incognito: bool, policy: IncognitoPolicy) bool {
    return incognito and policy == .nothing;
}

/// True when the session should report existence + security counters only
/// (incognito + `security_only`): suppress productivity counters + cwd.
pub fn incognitoRedact(incognito: bool, policy: IncognitoPolicy) bool {
    return incognito and policy == .security_only;
}

/// Whether a committed command should be counted at all. Incognito
/// sessions under a non-`normal` policy aren't counted (the session
/// reports existence + security only — productivity stays private).
pub fn shouldCount(incognito: bool, policy: IncognitoPolicy) bool {
    return !(incognito and policy != .normal);
}

/// Drop the productivity counters, keep the guard_* security counters.
pub fn redactedCounters(c: Counters) Counters {
    return .{
        .guard_warn = c.guard_warn,
        .guard_block = c.guard_block,
        .guard_refused = c.guard_refused,
    };
}

/// Minimal JSON string escaping into `dst`: `"` and `\` escaped, control
/// chars (< 0x20) dropped. Paths/shell names don't legitimately contain
/// controls; dropping keeps the output valid JSON without a full escape
/// table. Returns the written prefix (truncated if `dst` is too small).
pub fn jsonEscapeInto(dst: []u8, src: []const u8) []const u8 {
    var i: usize = 0;
    for (src) |ch| {
        switch (ch) {
            '"', '\\' => {
                if (i + 2 > dst.len) break;
                dst[i] = '\\';
                dst[i + 1] = ch;
                i += 2;
            },
            else => {
                if (ch < 0x20) continue;
                if (i + 1 > dst.len) break;
                dst[i] = ch;
                i += 1;
            },
        }
    }
    return dst[0..i];
}

/// Build the `report_metrics` JSON line (newline-framed) into `out`. The
/// string fields must already be JSON-escaped. `ts_ms` is sent as 0 — the
/// daemon stamps its own receipt time for staleness (immune to client
/// clock skew), so a client timestamp would be informational and unused.
pub fn buildReportJson(
    out: []u8,
    pid: u32,
    cwd_esc: []const u8,
    shell_esc: []const u8,
    incognito: bool,
    c: Counters,
) ![]const u8 {
    return std.fmt.bufPrint(
        out,
        "{{\"id\":1,\"method\":\"report_metrics\",\"pid\":{d}," ++
            "\"cwd\":\"{s}\",\"shell\":\"{s}\",\"incognito\":{}," ++
            "\"counters\":{{\"commands\":{d},\"ghost_accepted\":{d}," ++
            "\"ghost_shown\":{d},\"keystrokes_saved\":{d},\"llm_calls\":{d}," ++
            "\"guard_warn\":{d},\"guard_block\":{d},\"guard_refused\":{d}}}," ++
            "\"ts_ms\":0}}\n",
        .{
            pid,         cwd_esc,          shell_esc,     incognito,
            c.commands,  c.ghost_accepted, c.ghost_shown, c.keystrokes_saved,
            c.llm_calls, c.guard_warn,     c.guard_block, c.guard_refused,
        },
    );
}

/// Fire-and-forget the report line over the daemon UDS, FULLY BOUNDED so it
/// can run on the proxy's tick thread without wedging the terminal: a
/// NON-BLOCKING connect (polled for at most `timeout_ms` if the listen
/// backlog is full) followed by a non-blocking write. Best-effort — any
/// failure (daemon down/wedged, path too long, partial write) returns an
/// error the caller swallows; the daemon is optional.
fn sendUds(socket_path: []const u8, line: []const u8, timeout_ms: u32) !void {
    const fd = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
    if (fd < 0) return error.Unavailable;
    defer _ = std.c.close(fd);

    var addr: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = std.posix.AF.UNIX;
    if (socket_path.len >= addr.path.len) return error.Unavailable;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    const addr_len: std.posix.socklen_t = @intCast(@sizeOf(@TypeOf(addr)));
    const crc = std.c.connect(fd, @ptrCast(&addr), addr_len);
    if (crc != 0) {
        // A non-blocking UDS connect normally succeeds immediately;
        // EAGAIN/EINPROGRESS means the listen backlog is momentarily full
        // — poll briefly for writability rather than block the tick.
        // Anything else means no reachable daemon.
        const e = std.posix.errno(crc);
        if (e != .AGAIN and e != .INPROGRESS) return error.Unavailable;
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        if (std.c.poll(&pfd, 1, @intCast(timeout_ms)) <= 0) return error.Timeout;
        if (pfd[0].revents & std.posix.POLL.OUT == 0) return error.Unavailable;
    }

    // Non-blocking write — the line is small (< 1 KiB) and the send buffer
    // is empty on a fresh connection, so one write suffices; a partial /
    // EAGAIN is a dropped report (best-effort).
    var off: usize = 0;
    while (off < line.len) {
        const n = std.c.write(fd, line.ptr + off, line.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsize: usize) isize;

/// Basename of `$SHELL` (e.g. `/usr/bin/bash` → `bash`), or "" if unset.
fn shellName() []const u8 {
    const sh = std.mem.span(getenv("SHELL") orelse return "");
    if (std.mem.lastIndexOfScalar(u8, sh, '/')) |i| return sh[i + 1 ..];
    return sh;
}

pub fn configure(comptime cfg: Config) type {
    return struct {
        pub const name = "metrics_exporter";
        pub const config = cfg;

        pub const Runtime = struct {
            allocator: Allocator,
            /// The proxy's own pid — used only as the session-id fallback
            /// when `ctx.shell_pid` isn't known yet (see `report`).
            pid: u32,
            shell: []const u8,
            counters: Counters = .{},
            last_report_ms: i64 = 0,
        };

        pub fn attach(allocator: Allocator, io: std.Io) !Runtime {
            _ = io;
            return .{
                .allocator = allocator,
                .pid = @intCast(std.c.getpid()),
                .shell = shellName(),
            };
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            _ = rt;
            _ = io;
        }

        /// Count a committed command (cheap integer add). Incognito
        /// sessions under a non-`normal` policy aren't counted at all.
        pub fn onLineCommit(rt: *Runtime, ctx: *m.Context, line: []const u8) m.Error!void {
            _ = line;
            if (!cfg.enabled) return;
            if (!shouldCount(ctx.incognito, cfg.incognito_policy)) return;
            rt.counters.commands +%= 1;
        }

        /// Batched flush — report at most every `report_interval_ms`.
        pub fn onTick(rt: *Runtime, ctx: *m.Context, elapsed_ms: u64) m.Error!void {
            _ = elapsed_ms;
            if (!cfg.enabled) return;
            const now = lib.nowMs();
            if (now - rt.last_report_ms < @as(i64, @intCast(cfg.report_interval_ms))) return;
            rt.last_report_ms = now;
            report(rt, ctx);
        }

        fn report(rt: *Runtime, ctx: *m.Context) void {
            if (incognitoSkip(ctx.incognito, cfg.incognito_policy)) return;
            const redact = incognitoRedact(ctx.incognito, cfg.incognito_policy);
            const counters = if (redact) redactedCounters(rt.counters) else rt.counters;

            // cwd: best-effort readlink /proc/<shell_pid>/cwd; blanked when
            // redacting. Buffers are stack-local to this flush.
            var cwd_buf: [256]u8 = undefined;
            const cwd: []const u8 = if (redact) "" else cwdOf(ctx, &cwd_buf);

            var cwd_esc_buf: [512]u8 = undefined;
            var shell_esc_buf: [64]u8 = undefined;
            const cwd_esc = jsonEscapeInto(&cwd_esc_buf, cwd);
            const shell_esc = jsonEscapeInto(&shell_esc_buf, rt.shell);

            // Identify the session by shell_pid — that's the key the rest
            // of the system joins on (security_guard threat marking, the
            // eBPF tree-mark). Fall back to the proxy's own pid only when
            // the shell pid isn't known yet.
            const pid = ctx.shell_pid orelse rt.pid;

            var json_buf: [1024]u8 = undefined;
            const line = buildReportJson(&json_buf, pid, cwd_esc, shell_esc, ctx.incognito, counters) catch return;

            // Best-effort. TODO(P1b.1): file fallback to
            // $XDG_RUNTIME_DIR/atty/<pid>.json when the daemon is absent
            // (proxy-only installs) — the UDS path is primary for now.
            sendUds(cfg.daemon_socket_path, line, cfg.timeout_ms) catch {};
        }

        fn cwdOf(ctx: *m.Context, buf: []u8) []const u8 {
            const pid = ctx.shell_pid orelse return "";
            var path_buf: [64]u8 = undefined;
            const proc = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{pid}) catch return "";
            const n = readlink(proc.ptr, buf.ptr, buf.len);
            if (n <= 0) return "";
            return buf[0..@intCast(n)];
        }
    };
}

test {
    _ = @import("metrics_exporter_tests.zig");
}
