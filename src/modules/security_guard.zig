//! security_guard — pre-Enter pattern matcher for high-risk shell
//! commands.
//!
//! V1 scope: in-proc static patterns + a per-user trust cache. No
//! SLM, no eBPF, no network — see `docs/security-guard-design.md`
//! for the V2 atty-guard sidecar roadmap.
//!
//! Behaviour: when a typed line matches one of the configured
//! patterns AND its category+match hash is NOT in the trust
//! cache, the Enter keystroke is swallowed and a banner prompts
//! the user to respond:
//!   - `y` / `Y` → allow this invocation (does NOT persist).
//!   - `t` / `T` → allow + persist (adds hash to trust file).
//!   - any other key → cancel (Ctrl+U clears readline buffer).
//!
//! Disabled by default. Opt-in via `config.security_guard.enabled
//! = true` in `src/config.zig`.

const std = @import("std");
const m = @import("../module.zig");
const style_mod = @import("../style.zig");
const patterns_mod = @import("security_guard/patterns.zig");
const trust_mod = @import("security_guard/trust_cache.zig");
const uds_client_mod = @import("security_guard/uds_client.zig");

pub const Pattern = patterns_mod.Pattern;
pub const Category = patterns_mod.Category;
pub const default_patterns = patterns_mod.default_patterns;
pub const TrustCache = trust_mod.TrustCache;
pub const UdsClient = uds_client_mod.Client;

pub const Config = struct {
    /// Master switch. Off by default — opt-in only. When disabled
    /// the module is statically eliminated from the input path
    /// (the `onInput` hook short-circuits to `.forward` at the top).
    enabled: bool = false,
    /// Patterns to apply on each Enter. Defaults to the shipped
    /// `default_patterns`. Empty slice disables matching while
    /// keeping the module attached (handy for the trust-cache
    /// path alone, though probably you'd just set `enabled=false`).
    patterns: []const Pattern = &default_patterns,
    /// Trust cache file. Tilde-expanded at attach time. Created
    /// on first `[t]rust` action. Format: one 64-char SHA-256 hex
    /// per line; everything else skipped.
    trust_cache_path: []const u8 = "~/.cache/atty/security_trust.txt",
    /// Banner style — dim italic by default, same vocabulary as
    /// the guardrail module.
    warning_style: style_mod.Style = .{ .dim = true, .italic = true },
    /// When true, the module STOPS matching once incognito mode is
    /// active. Default is false — incognito means "don't record",
    /// not "don't protect"; turning protection off in incognito
    /// would invert the relationship users expect with sensitive
    /// sessions.
    skip_in_incognito: bool = false,
    /// Optional path to the `atty-guard` sidecar's Unix domain
    /// socket. When set AND the daemon is reachable, every Enter
    /// queries the daemon BEFORE running the in-proc Tier-1
    /// patterns. If the daemon flags the line, atty arms the same
    /// confirmation banner with the daemon's reason / matched
    /// substring. If the daemon is unreachable / times out, the
    /// in-proc patterns run as a fallback so security degrades
    /// gracefully to V1 behaviour. Empty = sidecar disabled.
    daemon_socket_path: []const u8 = "",
    /// Per-classify timeout when talking to the daemon. The default
    /// 50 ms is well above Tier-1 regex latency (sub-millisecond)
    /// and below the Tier-2 SLM target (≤15 ms), leaving headroom
    /// for a saturated CPU. Tune up if the daemon is doing heavier
    /// work or running under a slower scheduler class.
    daemon_timeout_ms: u32 = 50,
};

pub fn configure(comptime cfg: Config) type {
    return struct {
        pub const name = "security_guard";
        pub const config = cfg;
        pub const patterns = cfg.patterns;

        pub const Runtime = struct {
            armed: bool = false,
            armed_pattern_idx: usize = 0,
            /// Snapshot of the matched substring so the trust hash
            /// stays stable across the arm→response keystroke gap.
            /// Bounded — long URLs that don't fit just lose
            /// trailing characters from the trust key, which is
            /// fine for the cache (hash collision risk is the
            /// user mis-trusting; the worst case is they have to
            /// re-trust once).
            armed_match: [256]u8 = undefined,
            armed_match_len: usize = 0,
            trust: TrustCache = .{},
            /// `attach` records the allocator so per-Runtime
            /// helpers don't need to plumb it through every call
            /// path. atty modules already share `ctx.allocator`,
            /// but a module-owned ArrayList outlives a single
            /// `onInput` dispatch and needs an allocator that
            /// matches the eventual `detach`.
            allocator: ?std.mem.Allocator = null,
            /// Optional sidecar client. Null until the first
            /// Enter; opened lazily so a missing daemon doesn't
            /// pay the connect cost on every session start. Re-
            /// opened by the client itself on any I/O error.
            daemon: ?UdsClient = null,
            /// Sticky flag — once the daemon proves unreachable
            /// we stop trying on subsequent Enters this session.
            /// Without this, every Enter would re-pay the connect
            /// failure path (a ~ms `connect()` syscall) and the
            /// user feels a paper-cut latency that an absent
            /// sidecar shouldn't introduce.
            daemon_disabled: bool = false,
            /// Set when the LAST armed banner came from the daemon
            /// instead of an in-proc pattern. The category may not
            /// have a `patterns_mod.Category` equivalent (the
            /// sidecar's `pid_high_threat` is daemon-only), so
            /// `handleArmedResponse` checks this flag before
            /// computing a trust hash — daemon-only verdicts
            /// can't be persistently trusted via the V1 cache.
            armed_daemon_category: ?uds_client_mod.Category = null,
            /// Test seam — when set, the banner writes here
            /// instead of stderr.
            sink_ctx: ?*anyopaque = null,
            sink_fn: ?*const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void = null,
        };

        pub fn attach(allocator: std.mem.Allocator, io: std.Io) !Runtime {
            _ = io;
            var rt: Runtime = .{ .allocator = allocator };
            if (cfg.enabled) {
                rt.trust.load(allocator, cfg.trust_cache_path) catch {};
            }
            return rt;
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            _ = io;
            if (rt.allocator) |a| rt.trust.deinit(a);
            if (rt.daemon) |*d| d.deinit();
        }

        /// Test seam — redirect the banner write.
        pub fn setSink(
            rt: *Runtime,
            ctx: *anyopaque,
            writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
        ) void {
            rt.sink_ctx = ctx;
            rt.sink_fn = writeFn;
        }

        pub fn onInput(rt: *Runtime, ctx: *m.Context, input: []const u8) m.Error!m.Action {
            if (!cfg.enabled) return .forward;
            if (cfg.skip_in_incognito and ctx.incognito) return .forward;

            // Armed state: the previous Enter tripped a pattern;
            // the current keystroke is the user's response.
            if (rt.armed) return handleArmedResponse(rt, input);

            const is_enter = blk: {
                for (input) |b| if (b == 0x0D or b == 0x0A) break :blk true;
                break :blk false;
            };
            if (!is_enter) return .forward;

            const committed = ctx.line.lastCommitted();
            const line = committed orelse ctx.line.current();

            // Sidecar first when configured. The daemon's verdict is
            // authoritative when present — it sees BOTH Tier-1 (a
            // superset of our in-proc patterns) AND Tier-2 (encoder
            // SLM, V2-C). Falls through to in-proc on any sidecar
            // error so security degrades gracefully.
            if (cfg.daemon_socket_path.len > 0 and !rt.daemon_disabled) {
                if (queryDaemon(rt, line)) |daemon_verdict| {
                    if (daemon_verdict.armed) return .swallow;
                    // Daemon said safe — skip in-proc pattern walk
                    // entirely. The daemon's Tier-1 is a strict
                    // superset of ours, so re-running locally is
                    // wasted work.
                    return .forward;
                } else |_| {
                    // Sidecar unreachable / timed out / parse error.
                    // Latch the disable so subsequent Enters don't
                    // re-pay the connect failure.
                    rt.daemon_disabled = true;
                }
            }

            for (cfg.patterns, 0..) |pat, idx| {
                const matched = pat.match(line) orelse continue;

                // Trust cache?
                var hash_buf: [trust_mod.hex_len]u8 = undefined;
                const hash = trust_mod.hashCategoryMatch(pat.category, matched, &hash_buf);
                if (rt.trust.contains(hash)) return .forward;

                rt.armed = true;
                rt.armed_pattern_idx = idx;
                rt.armed_daemon_category = null;
                const copy_len = @min(matched.len, rt.armed_match.len);
                @memcpy(rt.armed_match[0..copy_len], matched[0..copy_len]);
                rt.armed_match_len = copy_len;

                writeBanner(rt, pat.description, matched);
                return .swallow;
            }
            return .forward;
        }

        const DaemonVerdict = struct {
            armed: bool,
        };

        /// Ask the sidecar to classify `line`. On Warn/Block, arms
        /// the banner and returns `armed=true`; on Safe, returns
        /// `armed=false`. Returns an error on any I/O / parse
        /// failure so the caller can fall through to in-proc
        /// patterns.
        fn queryDaemon(rt: *Runtime, line: []const u8) !DaemonVerdict {
            if (rt.daemon == null) {
                var client = UdsClient.init(cfg.daemon_socket_path);
                client.read_timeout_ms = cfg.daemon_timeout_ms;
                rt.daemon = client;
            }
            const result = try rt.daemon.?.classifyOrErr(line, .{});
            if (result.verdict == .safe) return .{ .armed = false };

            // Either warn or block — arm the banner. Trust cache
            // logic uses the SIDECAR's category mapping so an
            // in-proc category fires the same hash; daemon-only
            // categories skip the trust cache (the user can still
            // press `y` for one-shot allow, but `t` won't persist
            // a category atty doesn't model in-proc).
            const local_cat = result.category.toLocal();
            if (local_cat) |lc| {
                var hash_buf: [trust_mod.hex_len]u8 = undefined;
                const hash = trust_mod.hashCategoryMatch(lc, result.matched, &hash_buf);
                if (rt.trust.contains(hash)) return .{ .armed = false };
            }

            rt.armed = true;
            rt.armed_daemon_category = result.category;
            // Use a fake pattern index so handleArmedResponse can
            // look up the local category via armed_daemon_category
            // instead.
            rt.armed_pattern_idx = std.math.maxInt(usize);
            const copy_len = @min(result.matched.len, rt.armed_match.len);
            @memcpy(rt.armed_match[0..copy_len], result.matched[0..copy_len]);
            rt.armed_match_len = copy_len;

            writeBanner(rt, result.reason, result.matched);
            return .{ .armed = true };
        }

        fn handleArmedResponse(rt: *Runtime, input: []const u8) m.Action {
            if (input.len == 0) return .swallow;
            rt.armed = false;
            const armed_daemon_cat = rt.armed_daemon_category;
            rt.armed_daemon_category = null;
            const c = input[0];
            switch (c) {
                'y', 'Y' => return .{ .replace = "\r" },
                't', 'T' => {
                    // Compute the local category — either from the
                    // armed in-proc pattern index, or from the
                    // daemon's mapped category. Daemon-only
                    // categories (pid_high_threat) can't be cached.
                    const local_cat: ?patterns_mod.Category = blk: {
                        if (armed_daemon_cat) |dc| break :blk dc.toLocal();
                        if (rt.armed_pattern_idx < cfg.patterns.len) {
                            break :blk cfg.patterns[rt.armed_pattern_idx].category;
                        }
                        break :blk null;
                    };
                    if (local_cat) |lc| {
                        var hash_buf: [trust_mod.hex_len]u8 = undefined;
                        const hash = trust_mod.hashCategoryMatch(
                            lc,
                            rt.armed_match[0..rt.armed_match_len],
                            &hash_buf,
                        );
                        if (rt.allocator) |a| {
                            _ = rt.trust.add(a, hash) catch {};
                            rt.trust.persist(cfg.trust_cache_path) catch {};
                        }
                    }
                    return .{ .replace = "\r" };
                },
                else => return .{ .replace = "\x15" },
            }
        }

        fn writeBanner(rt: *Runtime, description: []const u8, matched: []const u8) void {
            const max_match_in_banner: usize = 256;
            const trunc_match = if (matched.len > max_match_in_banner)
                matched[0..max_match_in_banner]
            else
                matched;
            const ellipsis: []const u8 = if (matched.len > max_match_in_banner) " …" else "";
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "\r\n{f}atty security_guard: {s}{s}\r\n        match: {s}{s}\r\n        [y]es once · [t]rust permanently · any other key cancels.\r\n",
                .{ cfg.warning_style, description, style_mod.reset, trunc_match, ellipsis },
            ) catch {
                var fb: [128]u8 = undefined;
                const short = std.fmt.bufPrint(
                    &fb,
                    "\r\natty security_guard: {s} — [y]/[t]/cancel\r\n",
                    .{description},
                ) catch return;
                if (rt.sink_fn) |f| {
                    f(rt.sink_ctx.?, short) catch {};
                    return;
                }
                _ = std.c.write(std.posix.STDERR_FILENO, short.ptr, short.len);
                return;
            };
            if (rt.sink_fn) |f| {
                f(rt.sink_ctx.?, msg) catch {};
                return;
            }
            _ = std.c.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
        }
    };
}

// ===========================================================================
// Tests — extracted to `security_guard_tests.zig`.
// ===========================================================================

test {
    _ = @import("security_guard_tests.zig");
}
