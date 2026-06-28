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
//!
//! HOT-PATH NOTE: `onInput` blocks on the UDS round-trip to
//! atty-guard for up to `Client.read_timeout_ms` (50 ms default)
//! per Enter when the sidecar is reachable. This contradicts
//! CLAUDE.md's general "no blocking I/O on the hot path" rule and
//! is deliberate: the classify-before-execute contract requires a
//! synchronous verdict before the keystroke can be forwarded —
//! routing through an async worker (atuin's pattern) would let the
//! dangerous Enter race ahead of the verdict. The 50 ms cap is the
//! ceiling, not the average; daemon-on-localhost typical round
//! trips are sub-millisecond. The fd-close-on-timeout fix landed
//! in PR #302 prevents a single slow verdict from poisoning the
//! next classify.

const std = @import("std");
const m = @import("../module.zig");
const lib = @import("_lib.zig");
const style_mod = @import("../style.zig");
const patterns_mod = @import("security_guard/patterns.zig");
const trust_mod = @import("security_guard/trust_cache.zig");
const uds_client_mod = @import("security_guard/uds_client.zig");
const warn_subscriber_mod = @import("security_guard/warn_subscriber.zig");

pub const Pattern = patterns_mod.Pattern;
pub const Category = patterns_mod.Category;
pub const default_patterns = patterns_mod.default_patterns;
pub const TrustCache = trust_mod.TrustCache;
pub const UdsClient = uds_client_mod.Client;
pub const WarnSubscriber = warn_subscriber_mod.Subscriber;

/// Interval, in Enters, between daemon re-probes once `daemon_disabled`
/// has latched: after N Enters the daemon is retried (the Nth Enter
/// itself runs the query). Bounds the recovery delay — a restarting
/// daemon is picked back up within ~N commands — against re-paying the
/// connect-failure latency on every Enter while it's genuinely down.
/// `pub` so the sibling test can pin the re-probe cadence.
pub const daemon_reprobe_interval: u32 = 20;

/// What Alt+P does. The profile is daemon-GLOBAL; the modes differ in how
/// (and whether) a switch is authorized:
///   .off    — inert; Alt+P keeps its readline meaning (M-p).
///   .daemon — switch directly over the UDS. Needs root, or the daemon's
///             `[profile] allow_user_switch` for a non-root caller.
///   .sudo   — stage `sudo atty-guard profile set <next>` into the prompt
///             for you to run; your shell's sudo does the auth (per-action,
///             no daemon flag, atty never handles the password). Default.
pub const ProfileSwitchMode = enum { off, daemon, sudo };

pub const Config = struct {
    /// Master switch. Off by default — opt-in only. When disabled
    /// the module is statically eliminated from the input path
    /// (the `onInput` hook short-circuits to `.forward` at the top).
    enabled: bool = false,
    /// Patterns to apply on each Enter. Defaults to the shipped
    /// `default_patterns`. Empty slice disables in-proc matching
    /// while keeping the module attached, so a daemon-only setup
    /// (every classify goes through the UDS, no in-proc Tier-1)
    /// is still reachable from the same config.
    patterns: []const Pattern = &default_patterns,
    /// Banner style — dim italic by default, same vocabulary as
    /// the guardrail module.
    warning_style: style_mod.Style = .{ .dim = true, .italic = true },
    /// Refused style — bold red 8-color (fg=1) by default. Used by
    /// the daemon's `Block` verdict path, which prints a one-shot
    /// "refused" notice and clears readline instead of prompting.
    refused_style: style_mod.Style = .{ .bold = true, .fg = 1 },
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
    /// Show the live security profile as a status-bar segment (e.g.
    /// `🛡 session`), polled from the daemon and cached. On by default —
    /// it's read-only and answers "am I protected, at what level?".
    show_profile: bool = true,
    /// What Alt+P does (see `ProfileSwitchMode`). Defaults to `.sudo`:
    /// Alt+P stages `sudo atty-guard profile set <next>` into your prompt —
    /// no daemon flag, per-action sudo auth, atty never touches the
    /// password. `.daemon` switches directly (needs root / the daemon's
    /// `allow_user_switch`); `.off` keeps M-p.
    profile_switch_mode: ProfileSwitchMode = .sudo,
    /// How often (ms) to refresh the cached profile segment — the poll
    /// runs on `onTick`, NOT per status render, so the UDS isn't hammered.
    profile_poll_ms: u32 = 3_000,
};

/// The profile rungs, in cycle order (matches the daemon's SecurityProfile
/// + the docs/dashboard.md Guard slider).
pub const PROFILES = [_][]const u8{ "prompt", "audit", "session", "strict", "lockdown", "smart" };

/// Next rung after `cur` (wrapping); the first rung when `cur` is unknown
/// (daemon unreachable) so a switch still does something sane.
pub fn nextProfile(cur: ?[]const u8) []const u8 {
    const c = cur orelse return PROFILES[0];
    for (PROFILES, 0..) |p, i| {
        if (std.mem.eql(u8, p, c)) return PROFILES[(i + 1) % PROFILES.len];
    }
    return PROFILES[0];
}

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
            /// Session-only trust set, populated by the
            /// banner's `[a]llow always` keystroke. Identical shape
            /// to `trust` (hex SHA-256 hashes of "category:matched")
            /// but never persisted to disk — cleared on atty exit.
            /// `queryDaemon` + the in-proc pattern walk consult this
            /// set in addition to `trust`, so an `[a]` tap silently
            /// short-circuits the banner for the rest of the session.
            session_trust: TrustCache = .{},
            /// Session-only blocked hosts, populated by the
            /// banner's `[B]lock host forever` keystroke. Each
            /// entry is a literal host (e.g. `evil.io`); a future
            /// command whose committed line contains any blocked
            /// host (at a HOST BOUNDARY — see `hasHostMatch`) gets
            /// a REFUSED line + readline cleared, no banner.
            /// Storage is `[16][64]u8` slots inline so detach
            /// doesn't need an allocator to drop them. The 17th
            /// `[B]` tap in one session is silently dropped — at
            /// that point the operator should `sudo atty-guard
            /// session write` to persist + restart atty.
            session_blocked_hosts: [16][64]u8 = undefined,
            session_blocked_hosts_lens: [16]u8 = std.mem.zeroes([16]u8),
            session_blocked_hosts_count: u8 = 0,
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
            /// Set when the daemon proves unreachable, so the next few
            /// Enters skip the connect-failure path — a ~ms `connect()`
            /// the user would otherwise feel as a paper-cut latency that
            /// an absent sidecar shouldn't introduce. NOT permanently
            /// sticky: a daemon that's merely restarting (e.g.
            /// `systemctl restart` mid-session) would otherwise
            /// downgrade the whole session to in-proc Tier-1 — a strict
            /// subset of the daemon's coverage (no Tier-2 SLM, no OSV,
            /// no auto-Block) — with no recovery. `onInput` re-probes
            /// every `daemon_reprobe_interval` Enters (see
            /// `daemon_disabled_skips`).
            daemon_disabled: bool = false,
            /// Enters seen since `daemon_disabled` latched. Incremented
            /// on each Enter while disabled; when it reaches
            /// `daemon_reprobe_interval` it resets to 0 and that Enter
            /// re-probes the daemon (so the counting Enter is also the
            /// retry, not a skipped one).
            daemon_disabled_skips: u32 = 0,
            /// True once we've fetched the daemon's persistent
            /// trust list and seeded `rt.trust` from it. Flipped
            /// inside `queryDaemon` on first successful classify
            /// (lazy seed — avoids paying the connect cost at
            /// attach time for sessions that never type a flagged
            /// command). Stays false until a trustList fetch actually
            /// SUCCEEDS, so a transient failure (or a daemon that came
            /// back after a `daemon_disabled` re-probe) re-seeds on a
            /// later Enter rather than being silently skipped forever.
            daemon_trust_seeded: bool = false,
            /// Cached live security profile for the status segment + the
            /// cycle action's "current" read. Refreshed on a poll
            /// (`profile_poll_ms`) from `onTick`, so the status render +
            /// the hot path never block on the UDS. Empty = unknown /
            /// daemon unreachable.
            profile_name: [16]u8 = undefined,
            profile_name_len: usize = 0,
            profile_last_poll_ms: i64 = 0,
            /// Consecutive poll failures — backs off the poll interval so a
            /// down/wedged daemon isn't re-probed every tick (the connect
            /// can block on a wedged-but-listening daemon).
            profile_poll_fails: u32 = 0,
            /// One-shot staging buffer for `.sudo` profile-switch mode:
            /// `onAction` writes `sudo atty-guard profile set <next>` here
            /// (onAction has no return channel to the proxy), and
            /// `pollShellInput` drains it to the shell readline. 64 B fits
            /// the longest rung command.
            staged_input: [64]u8 = undefined,
            staged_input_len: usize = 0,
            /// Set when the LAST armed banner came from the daemon
            /// instead of an in-proc pattern. The category may not
            /// have a `patterns_mod.Category` equivalent (the
            /// sidecar's `pid_high_threat` is daemon-only), so
            /// `handleArmedResponse` checks this flag before
            /// computing a trust hash — daemon-only verdicts
            /// can't be persistently trusted via the V1 cache.
            armed_daemon_category: ?uds_client_mod.Category = null,
            /// Threat level the armed pattern would impose on the
            /// shell's PID tree if the user accepts (`y`/`t`).
            /// Set at arm time; consumed (or cleared) at the
            /// response keystroke.
            pending_threat: ?uds_client_mod.Client.ThreatLevel = null,
            /// Sticky "this shell session has a high-risk command
            /// in flight" indicator — surfaced via `statusText`
            /// AND sent to atty-guard via `set_threat_level` so the
            /// V2-B kernel LSM hook can gate descendant execves.
            /// Cleared when the user types a CLEAN line + Enter
            /// (no pattern hit), so the indicator stays visible
            /// for as long as the suspect command's process tree
            /// might still be running.
            active_threat: ?uds_client_mod.Client.ThreatLevel = null,
            /// Test seam — when set, the banner writes here
            /// instead of stderr.
            sink_ctx: ?*anyopaque = null,
            sink_fn: ?*const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void = null,
            /// #347 PR 3 — kernel-side warn-event subscriber.
            /// Background thread connects to the daemon's
            /// `subscribe_warn_events` stream + buffers events
            /// for the status segment + (future) overlay UI.
            /// Heap-allocated so the address survives Runtime
            /// moves (the thread captures a pointer at spawn).
            warn_sub: ?*WarnSubscriber = null,
            /// Persistent storage for the statusText return slice.
            /// dispatch.gatherStatus borrows the slice (doesn't
            /// free), so a stack buffer would dangle by the time
            /// the writer reads it. 128 bytes covers the longest
            /// shape: emoji + count + "warns | critical".
            status_buf: [128]u8 = undefined,
        };

        /// Convert an in-proc pattern's category to a threat level
        /// for the V2-B PID-tree marking. `bash_c_base64` is the
        /// most-obviously-malicious shape (encoded payloads exist
        /// almost exclusively to evade detection) — Critical
        /// makes the kernel LSM hook EPERM children outright.
        /// Other categories are still high-risk but legitimate
        /// users hit them (`curl|sh` installers, `npm install`
        /// supply-chain hits), so Warn-level (High) which the
        /// hook surfaces but doesn't auto-block.
        fn categoryToThreat(c: patterns_mod.Category) uds_client_mod.Client.ThreatLevel {
            return switch (c) {
                .curl_pipe_sh, .npm_unsafe_install => .high,
                .bash_c_base64 => .critical,
            };
        }

        /// Daemon verdict → threat level. `Block` is the daemon's
        /// strongest signal; everything else (Warn) is High.
        fn daemonVerdictToThreat(v: uds_client_mod.Verdict) ?uds_client_mod.Client.ThreatLevel {
            return switch (v) {
                .safe => null,
                .warn => .high,
                .block => .critical,
            };
        }

        pub fn attach(allocator: std.mem.Allocator, io: std.Io) !Runtime {
            var rt: Runtime = .{ .allocator = allocator };
            // Trust state seeded lazily from the daemon's
            // commands.trusted.txt — see `queryDaemon` for the
            // `daemon_trust_seeded` flag. No local file is read or
            // written; the daemon is the single source of truth for
            // persisted trust hashes (post-#147 + post-#150).
            // #347 PR 3: spawn the warn-event subscriber thread
            // when the daemon socket is configured. The subscriber
            // is best-effort — if the daemon isn't reachable on
            // first connect, the thread keeps trying in the
            // background; statusText shows nothing until events
            // arrive. No banner / no log noise on the no-daemon
            // path (subscriber's own back-off + log discipline).
            if (cfg.daemon_socket_path.len > 0) {
                const ptr = allocator.create(WarnSubscriber) catch return rt;
                ptr.* = WarnSubscriber.init(
                    allocator,
                    cfg.daemon_socket_path,
                    @intCast(std.c.getpid()),
                );
                ptr.start(io) catch |err| {
                    // Spawn failure (resource exhaustion) — log
                    // and continue without subscriber rather than
                    // failing module attach entirely.
                    std.log.warn(
                        "atty security_guard: warn subscriber spawn failed: {s}",
                        .{@errorName(err)},
                    );
                    allocator.destroy(ptr);
                    return rt;
                };
                rt.warn_sub = ptr;
            }
            return rt;
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            _ = io;
            if (rt.warn_sub) |sub| {
                sub.stop();
                if (rt.allocator) |a| a.destroy(sub);
                rt.warn_sub = null;
            }
            if (rt.allocator) |a| {
                rt.trust.deinit(a);
                rt.session_trust.deinit(a);
            }
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

        /// Action dispatch — currently only handles the warn-event
        /// dump (Alt+Shift+W). Returns true iff the action was
        /// consumed; false lets the proxy try other modules / fall
        /// through to its own switch case.
        pub fn onAction(rt: *Runtime, ctx: *m.Context, action: anytype) m.Error!bool {
            switch (action) {
                .security_guard_show_warnings => {
                    renderWarnDump(rt) catch return false;
                    return true;
                },
                .security_guard_cycle_profile => switch (cfg.profile_switch_mode) {
                    // Inert — return false (don't consume) so Alt+P keeps its
                    // readline meaning (M-p) rather than shadowing it.
                    .off => return false,
                    // Switch directly over the UDS (daemon authorizes).
                    .daemon => {
                        cycleProfile(rt);
                        return true;
                    },
                    // Stage `sudo atty-guard profile set <next>` for the user
                    // to run — per-action sudo auth, atty never escalates.
                    .sudo => {
                        stageProfileSudo(rt, ctx);
                        return true;
                    },
                },
                else => return false,
            }
        }

        /// Lazily set up the daemon client for profile RPCs (mirrors
        /// `queryDaemon`'s lazy open; connect itself is lazy in the client).
        fn profileClient(rt: *Runtime) ?*UdsClient {
            if (cfg.daemon_socket_path.len == 0) return null;
            if (rt.daemon == null) {
                var client = UdsClient.init(cfg.daemon_socket_path);
                client.read_timeout_ms = cfg.daemon_timeout_ms;
                rt.daemon = client;
            }
            return &rt.daemon.?;
        }

        fn setCachedProfile(rt: *Runtime, prof: []const u8) void {
            const n = @min(prof.len, rt.profile_name.len);
            @memcpy(rt.profile_name[0..n], prof[0..n]);
            rt.profile_name_len = n;
        }

        /// CURRENT rung: live read (UDS), else the last-known cache; null if
        /// neither. NEVER advance from a failed read — `nextProfile(null)` is
        /// `prompt`, so a transient timeout would silently DOWNGRADE the
        /// posture to the weakest rung. Callers abort on null.
        fn currentProfile(rt: *Runtime, client: *UdsClient, buf: []u8) ?[]const u8 {
            return client.getProfile(buf) orelse
                (if (rt.profile_name_len > 0) rt.profile_name[0..rt.profile_name_len] else null);
        }

        /// Cycle the live security profile directly via the daemon
        /// (`profile_switch_mode = .daemon`); the daemon enforces who may
        /// switch (the profile is daemon-global). Renders the outcome to
        /// scrollback + refreshes the cached status segment.
        fn cycleProfile(rt: *Runtime) void {
            const client = profileClient(rt) orelse {
                writeSink(rt, "\r\natty security_guard: no daemon configured for profile switch.\r\n");
                return;
            };
            var cur_buf: [16]u8 = undefined;
            const cur = currentProfile(rt, client, &cur_buf) orelse {
                writeSink(rt, "\r\natty security_guard: can't read the current " ++
                    "profile (daemon unreachable) — switch aborted.\r\n");
                return;
            };
            const next = nextProfile(cur);
            var out_buf: [192]u8 = undefined;
            var line: [256]u8 = undefined;
            switch (client.setProfile(next, &out_buf)) {
                .ok => |p| {
                    setCachedProfile(rt, p);
                    // Fall back to a fixed notice if formatting overflows so
                    // a switch is never silently unacknowledged.
                    const s = std.fmt.bufPrint(&line, "\r\natty security_guard: profile \u{2192} {s}\r\n", .{p}) catch
                        "\r\natty security_guard: profile switched.\r\n";
                    writeSink(rt, s);
                },
                .refused => |msg| {
                    const s = std.fmt.bufPrint(&line, "\r\natty security_guard: {s}\r\n", .{msg}) catch
                        "\r\natty security_guard: profile switch refused.\r\n";
                    writeSink(rt, s);
                },
                .unavailable => writeSink(rt, "\r\natty security_guard: daemon unreachable — profile unchanged.\r\n"),
            }
        }

        /// `.sudo` mode: stage `sudo atty-guard profile set <next>` into the
        /// prompt (drained by `pollShellInput`) so the user's own shell runs
        /// sudo — per-action auth, atty never handles the password. Guards on
        /// an empty line so it can't clobber a partial command.
        fn stageProfileSudo(rt: *Runtime, ctx: *m.Context) void {
            if (ctx.line.current().len > 0) {
                writeSink(rt, "\r\natty security_guard: clear the line first, then Alt+P to stage the profile switch.\r\n");
                return;
            }
            const client = profileClient(rt) orelse {
                writeSink(rt, "\r\natty security_guard: no daemon configured for profile switch.\r\n");
                return;
            };
            var cur_buf: [16]u8 = undefined;
            const cur = currentProfile(rt, client, &cur_buf) orelse {
                writeSink(rt, "\r\natty security_guard: can't read the current profile (daemon unreachable) — not staged.\r\n");
                return;
            };
            const next = nextProfile(cur);
            const cmd = std.fmt.bufPrint(&rt.staged_input, "sudo atty-guard profile set {s}", .{next}) catch {
                writeSink(rt, "\r\natty security_guard: couldn't stage the profile command.\r\n");
                return;
            };
            rt.staged_input_len = cmd.len;
        }

        /// Drain the `.sudo`-mode staged command to the shell readline (the
        /// proxy writes it to pty.master as if typed, so the user reviews +
        /// runs it). One-shot; no trailing newline — never auto-runs.
        pub fn pollShellInput(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            _ = ctx;
            if (rt.staged_input_len == 0) return null;
            const n = rt.staged_input_len;
            rt.staged_input_len = 0;
            return rt.staged_input[0..n];
        }

        /// Poll the live profile on a cadence (off the status-render path)
        /// so the status segment + the cycle action's "current" read are
        /// cheap. Batched to `profile_poll_ms`.
        pub fn onTick(rt: *Runtime, ctx: *m.Context, elapsed_ms: u64) m.Error!void {
            _ = ctx;
            _ = elapsed_ms;
            if (!cfg.show_profile) return;
            const now = lib.nowMs();
            // Exponential backoff after failures (capped at 16× ≈ 48s) so a
            // down/wedged daemon isn't probed every interval.
            const shift: u5 = @intCast(@min(rt.profile_poll_fails, 4));
            const interval = @as(i64, @intCast(cfg.profile_poll_ms)) * (@as(i64, 1) << shift);
            if (now - rt.profile_last_poll_ms < interval) return;
            rt.profile_last_poll_ms = now;
            const client = profileClient(rt) orelse return;
            var buf: [16]u8 = undefined;
            if (client.getProfile(&buf)) |p| {
                setCachedProfile(rt, p);
                rt.profile_poll_fails = 0;
            } else {
                // Daemon unreachable → hide the segment rather than show stale.
                rt.profile_name_len = 0;
                rt.profile_poll_fails +|= 1;
            }
        }

        fn renderWarnDump(rt: *Runtime) m.Error!void {
            const sub = rt.warn_sub orelse {
                // No subscriber (security_guard disabled or daemon
                // socket unset) — emit a one-line notice so the
                // keystroke isn't silently lost.
                writeSink(rt, "\r\natty security_guard: no warn-event subscriber attached.\r\n");
                return;
            };
            const allocator = rt.allocator orelse {
                writeSink(rt, "\r\natty security_guard: warn dump skipped — no allocator.\r\n");
                return;
            };
            const snap = sub.snapshot(allocator) catch return error.OutOfMemory;
            defer warn_subscriber_mod.Subscriber.freeSnapshot(allocator, snap);

            if (snap.len == 0) {
                writeSink(rt, "\r\natty security_guard: no warn events buffered.\r\n");
                return;
            }

            // Header. Inline the drop count rather than referring
            // operators to a daemon CLI — `atty-guard session list`
            // doesn't surface warn-event drops; the count only
            // exists in this subscriber's atomic.
            var hdr_buf: [256]u8 = undefined;
            const dropped = sub.droppedTotal();
            const hdr = if (dropped > 0) std.fmt.bufPrint(
                &hdr_buf,
                "\r\natty security_guard: {d} warn event{s} ({d} dropped this session)\r\n",
                .{ snap.len, if (snap.len == 1) "" else "s", dropped },
            ) catch return else std.fmt.bufPrint(
                &hdr_buf,
                "\r\natty security_guard: {d} warn event{s}\r\n",
                .{ snap.len, if (snap.len == 1) "" else "s" },
            ) catch return;
            writeSink(rt, hdr);

            // One line per event. Format keeps fixed-width fields
            // so multiple events line up in scrollback.
            var line_buf: [512]u8 = undefined;
            for (snap) |evt| {
                const sec = evt.timestamp_ms / 1000;
                const ms = evt.timestamp_ms % 1000;
                const comm = if (evt.comm.len <= 16) evt.comm else evt.comm[0..16];
                const trunc_comm: []const u8 = if (evt.comm.len > 16) "…" else "";
                const argv0 = if (evt.argv0.len <= 96) evt.argv0 else evt.argv0[0..96];
                const trunc_argv: []const u8 = if (evt.argv0.len > 96) "…" else "";
                const line = std.fmt.bufPrint(
                    &line_buf,
                    "  {d}.{d:03}  pid={d}  ppid={d}  comm={s}{s}  argv0={s}{s}\r\n",
                    .{ sec, ms, evt.pid, evt.ppid, comm, trunc_comm, argv0, trunc_argv },
                ) catch continue;
                writeSink(rt, line);
            }

            sub.clear();
        }

        fn writeSink(rt: *Runtime, bytes: []const u8) void {
            if (rt.sink_fn) |f| {
                f(rt.sink_ctx.?, bytes) catch {};
                return;
            }
            _ = std.c.write(std.posix.STDOUT_FILENO, bytes.ptr, bytes.len);
        }

        pub fn onInput(rt: *Runtime, ctx: *m.Context, input: []const u8) m.Error!m.Action {
            if (!cfg.enabled) return .forward;
            if (cfg.skip_in_incognito and ctx.incognito) return .forward;

            // Armed state: the previous Enter tripped a pattern;
            // the current keystroke is the user's response.
            if (rt.armed) return handleArmedResponse(rt, ctx, input);

            const is_enter = blk: {
                for (input) |b| if (b == 0x0D or b == 0x0A) break :blk true;
                break :blk false;
            };
            if (!is_enter) return .forward;

            const committed = ctx.line.lastCommitted();
            const line = committed orelse ctx.line.current();

            // Short-circuit on `[B]lock host forever` entries from
            // earlier in the session. The user has
            // already declared "I never want this host again",
            // so we don't even need to consult the daemon /
            // in-proc patterns. REFUSED line + readline clear.
            if (lineIsSessionBlocked(rt, line)) {
                writeRefused(rt, "session-blocked host", line);
                return .{ .replace = "\x15" };
            }

            // Sidecar first when configured. The daemon's verdict is
            // authoritative when present — it sees BOTH Tier-1 (a
            // superset of our in-proc patterns) AND Tier-2 (encoder
            // SLM, V2-C). Falls through to in-proc on any sidecar
            // error so security degrades gracefully.
            if (cfg.daemon_socket_path.len > 0) {
                // Re-probe a previously-disabled daemon every
                // `daemon_reprobe_interval` Enters so a restarting
                // sidecar is picked back up instead of downgrading the
                // session to in-proc Tier-1 for good.
                if (rt.daemon_disabled) {
                    rt.daemon_disabled_skips += 1;
                    if (rt.daemon_disabled_skips >= daemon_reprobe_interval) {
                        rt.daemon_disabled = false;
                        rt.daemon_disabled_skips = 0;
                    }
                }
                if (!rt.daemon_disabled) {
                    if (queryDaemon(rt, line, ctx)) |daemon_verdict| {
                        if (daemon_verdict.refused) return .{ .replace = "\x15" };
                        if (daemon_verdict.armed) return .swallow;
                        // Daemon said safe — skip in-proc pattern walk
                        // entirely. The daemon's Tier-1 is a strict
                        // superset of ours, so re-running locally is
                        // wasted work.
                        return .forward;
                    } else |_| {
                        // Sidecar unreachable / timed out / parse error.
                        // Latch the disable so the next few Enters don't
                        // re-pay the connect failure; we re-probe later.
                        // Surface the downgrade once per episode (this
                        // branch only runs on the false→true transition,
                        // since we just queried with disabled == false).
                        std.log.warn(
                            "atty security_guard: daemon unreachable — degraded to in-proc Tier-1 (re-probing every {d} commands)",
                            .{daemon_reprobe_interval},
                        );
                        rt.daemon_disabled = true;
                        rt.daemon_disabled_skips = 0;
                    }
                }
            }

            for (cfg.patterns, 0..) |pat, idx| {
                const matched = pat.match(line) orelse continue;

                // Trust cache?
                var hash_buf: [trust_mod.hex_len]u8 = undefined;
                const hash = trust_mod.hashCategoryMatch(pat.category, matched, &hash_buf);
                if (rt.trust.contains(hash)) return .forward;

                if (rt.session_trust.contains(hash)) return .forward;

                rt.armed = true;
                rt.armed_pattern_idx = idx;
                rt.armed_daemon_category = null;
                rt.pending_threat = categoryToThreat(pat.category);
                const copy_len = @min(matched.len, rt.armed_match.len);
                @memcpy(rt.armed_match[0..copy_len], matched[0..copy_len]);
                rt.armed_match_len = copy_len;

                writeBanner(rt, pat.description, matched);
                return .swallow;
            }

            // Clean line passed all patterns + the daemon — clear
            // any sticky high-threat indicator from a prior command.
            // The user has typed something normal; we can stop
            // gating the descendant tree on the previous mark.
            //
            // Fire `setThreatLevel(pid, .low)` to the daemon so the
            // kernel-side BPF map entry (V2-B) also clears. Without
            // this, the daemon's classify path keeps upgrading
            // later safe commands to `pid_high_threat` for the rest
            // of the shell's lifetime — and for Critical, the
            // daemon keeps returning `Block`, so the user sees
            // repeated `REFUSED` lines after one critical command.
            //
            // Only fire when we ACTUALLY had a non-null mark
            // (otherwise we're churning Low → Low RPCs on every
            // clean line, which the daemon would just evict
            // again). Best-effort: daemon errors are logged to
            // stderr (same posture as markShellThreat above).
            if (rt.active_threat != null) {
                if (ctx.shell_pid) |pid| {
                    if (rt.daemon != null and !rt.daemon_disabled) {
                        rt.daemon.?.setThreatLevel(pid, .low) catch |err| switch (err) {
                            error.DaemonError => {
                                const msg = "atty: daemon rejected setThreatLevel(low) — kernel enforcement may stay armed\n";
                                _ = std.c.write(2, msg, msg.len);
                            },
                            else => {},
                        };
                    }
                }
            }
            rt.active_threat = null;
            return .forward;
        }

        const DaemonVerdict = struct {
            armed: bool,
            refused: bool,
        };

        /// Ask the sidecar to classify `line`. Returns:
        ///   `armed=true`  — Warn: banner is up, next keystroke is
        ///                   the user's [y]/[t]/cancel response.
        ///   `refused=true`— Block: no prompt; the caller MUST
        ///                   clear readline. A short red "refused"
        ///                   message is already written and the
        ///                   shell PID is marked Critical.
        ///   neither true  — Safe: caller continues normally.
        /// Returns an error on any I/O / parse failure so the
        /// caller can fall through to in-proc patterns.
        ///
        /// Trust-cache hits short-circuit BOTH paths — a user who
        /// previously trusted this exact category+match keeps the
        /// "yes I really mean it" choice even when the operator
        /// has opted into auto-Block. Operators who want auto-Block
        /// to override prior trust should clear the trust cache.
        fn queryDaemon(rt: *Runtime, line: []const u8, ctx: *m.Context) !DaemonVerdict {
            if (rt.daemon == null) {
                var client = UdsClient.init(cfg.daemon_socket_path);
                client.read_timeout_ms = cfg.daemon_timeout_ms;
                rt.daemon = client;
            }
            // Forward the live context so the daemon's PID-keyed
            // threat-map upgrade path can promote Safe → Warn/Block
            // when the source PID's tree is already marked
            // high-risk by an earlier confirmed command. Without
            // `ctx.shell_pid` here, the V2-J threat-accumulator +
            // V2-J-2 auto-Block path on the daemon stays
            // effectively dead — atty marks the PID via
            // `setThreatLevel` but never sends it back on the next
            // classify. `ctx.incognito` is forwarded for
            // future daemon-side policy (no consumer today).
            // Shell name would need plumbing through Runtime first.
            const result = try rt.daemon.?.classifyOrErr(line, .{
                .pid = ctx.shell_pid,
                .incognito = ctx.incognito,
            });
            // Lazy seed of in-proc trust set from the daemon's
            // commands.trusted.txt. Runs once per atty session after
            // the FIRST successful daemon classify — by then the
            // daemon is proven reachable + the connect cost is
            // already amortized. Errors are swallowed: the daemon is
            // the only persistent trust store, so a failed seed just
            // means cross-shell trust hashes are unavailable this
            // session. Banner [t] still adds to rt.trust locally +
            // mirrors via TrustAdd, so trust state set in THIS
            // session works regardless of the daemon mirror outcome.
            if (!rt.daemon_trust_seeded) {
                if (rt.allocator) |a| {
                    // Only mark seeded when the fetch actually succeeds,
                    // so a transient failure re-seeds on a later Enter
                    // instead of leaving cross-shell trust unavailable
                    // for the whole session.
                    if (rt.daemon.?.trustList(a, &rt.trust)) |_| {
                        rt.daemon_trust_seeded = true;
                    } else |_| {}
                }
            }
            if (result.verdict == .safe) return .{ .armed = false, .refused = false };

            // Trust cache logic uses the SIDECAR's category mapping
            // so an in-proc category fires the same hash; daemon-only
            // categories skip the trust cache (the user can still
            // press `y` for one-shot allow, but `t` won't persist
            // a category atty doesn't model in-proc).
            const local_cat = result.category.toLocal();
            if (local_cat) |lc| {
                var hash_buf: [trust_mod.hex_len]u8 = undefined;
                const hash = trust_mod.hashCategoryMatch(lc, result.matched, &hash_buf);
                if (rt.trust.contains(hash)) return .{ .armed = false, .refused = false };
                if (rt.session_trust.contains(hash)) return .{ .armed = false, .refused = false };
            }

            if (result.verdict == .block) {
                writeRefused(rt, result.reason, result.matched);
                markShellThreat(rt, ctx, daemonVerdictToThreat(result.verdict));
                return .{ .armed = false, .refused = true };
            }

            rt.armed = true;
            rt.armed_daemon_category = result.category;
            rt.pending_threat = daemonVerdictToThreat(result.verdict);
            // Use a fake pattern index so handleArmedResponse can
            // look up the local category via armed_daemon_category
            // instead.
            rt.armed_pattern_idx = std.math.maxInt(usize);
            const copy_len = @min(result.matched.len, rt.armed_match.len);
            @memcpy(rt.armed_match[0..copy_len], result.matched[0..copy_len]);
            rt.armed_match_len = copy_len;

            writeBanner(rt, result.reason, result.matched);
            return .{ .armed = true, .refused = false };
        }

        fn handleArmedResponse(rt: *Runtime, ctx: *m.Context, input: []const u8) m.Action {
            if (input.len == 0) return .swallow;
            rt.armed = false;
            const armed_daemon_cat = rt.armed_daemon_category;
            rt.armed_daemon_category = null;
            const pending = rt.pending_threat;
            rt.pending_threat = null;
            const c = input[0];
            switch (c) {
                'y', 'Y' => {
                    markShellThreat(rt, ctx, pending);
                    return .{ .replace = "\r" };
                },
                'a', 'A' => {
                    // [a]llow always (this session). Compute the
                    // same hash as [t] but store in session_trust
                    // instead of the persistent cache. No daemon
                    // round-trip required — the next classify
                    // (in-proc or daemon-side) consults
                    // session_trust BEFORE arming the banner, so
                    // the user won't see this match again until
                    // atty exits.
                    addSessionTrust(rt, armed_daemon_cat);
                    markShellThreat(rt, ctx, pending);
                    return .{ .replace = "\r" };
                },
                'b', 'B' => {
                    // [B]lock host forever — extract host from the
                    // matched substring + add to the session-only
                    // blocked-hosts list. The daemon mirror is also
                    // session-only (no sudo, in-memory). To make
                    // the block actually permanent, the operator
                    // runs `sudo atty-guard session write` later.
                    // Hits without a URL-shaped match (atom-only
                    // categories, daemon-only categories) silently
                    // fall through to cancel.
                    return blockHostThenCancel(rt, armed_daemon_cat);
                },
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
                        // In-memory cache for the runtime check (no
                        // local file write — daemon is the only
                        // persistent store). The daemon mirror via
                        // trustAdd is the canonical persistence path;
                        // we add to the in-memory cache too so the
                        // SAME atty session's next Enter skips the
                        // banner without waiting for a daemon
                        // round-trip.
                        if (rt.allocator) |a| {
                            _ = rt.trust.add(a, hash) catch {};
                        }
                        if (rt.daemon) |*client| {
                            client.trustAdd(hash) catch |err| switch (err) {
                                error.DaemonError => {
                                    // Daemon-side rejection (auth /
                                    // perm / disk-full) means the
                                    // hash never landed in
                                    // commands.trusted.txt — a
                                    // fresh atty session won't see
                                    // this trust. Local rt.trust
                                    // still works for THIS session.
                                    const msg = "atty: daemon rejected trustAdd — `[t]rust permanently` won't persist across sessions\n";
                                    _ = std.c.write(2, msg, msg.len);
                                },
                                else => {},
                            };
                        }
                    }
                    markShellThreat(rt, ctx, pending);
                    return .{ .replace = "\r" };
                },
                else => {
                    // Cancel — Ctrl+U clears readline buffer.
                    // Don't mark the shell's PID; nothing risky is
                    // about to execute.
                    return .{ .replace = "\x15" };
                },
            }
        }

        /// `[a]llow always` handler. Computes the same
        /// (category, matched) hash as `[t]rust permanently` and
        /// adds it to the session-only trust set. Best-effort
        /// daemon mirror via SessionAddTrust so `atty-guard session
        /// list` surfaces the operator's choices.
        fn addSessionTrust(
            rt: *Runtime,
            armed_daemon_cat: ?uds_client_mod.Category,
        ) void {
            const local_cat: ?patterns_mod.Category = blk: {
                if (armed_daemon_cat) |dc| break :blk dc.toLocal();
                if (rt.armed_pattern_idx < cfg.patterns.len) {
                    break :blk cfg.patterns[rt.armed_pattern_idx].category;
                }
                break :blk null;
            };
            const lc = local_cat orelse return;
            var hash_buf: [trust_mod.hex_len]u8 = undefined;
            const hash = trust_mod.hashCategoryMatch(
                lc,
                rt.armed_match[0..rt.armed_match_len],
                &hash_buf,
            );
            if (rt.allocator) |a| {
                _ = rt.session_trust.add(a, hash) catch {};
            }
            if (rt.daemon) |*client| {
                client.sessionAddTrust(hash) catch |err| switch (err) {
                    error.DaemonError => {
                        const msg = "atty: daemon rejected sessionAddTrust — entry won't appear in `atty-guard session list`\n";
                        _ = std.c.write(2, msg, msg.len);
                    },
                    else => {},
                };
            }
        }

        /// `[B]lock host forever` handler. Extracts the
        /// host substring from the armed match (best-effort: looks
        /// for `://` then takes the next host-shaped token) and
        /// adds it to the session-only blocked-hosts list. Daemon
        /// mirror via SessionAddUrlBlock. Falls through to cancel
        /// when no host can be extracted (atom-only matches like
        /// `chmod +s` have no host concept).
        fn blockHostThenCancel(
            rt: *Runtime,
            armed_daemon_cat: ?uds_client_mod.Category,
        ) m.Action {
            _ = armed_daemon_cat; // daemon category isn't needed; host is the key.
            const matched = rt.armed_match[0..rt.armed_match_len];
            const host = extractHost(matched) orelse {
                // No URL in the matched substring — [B] degrades to
                // [cancel]. Readline cleared, no persistent change.
                return .{ .replace = "\x15" };
            };
            // Two failure modes that BOTH must skip the daemon
            // mirror to keep atty's view and the daemon's view in
            // sync (per round-1 review): host won't fit in the
            // 64-byte slot, OR the session list is full. In either
            // case, log to the sink, cancel the current command,
            // and don't pretend we recorded anything.
            const slot_cap = rt.session_blocked_hosts[0].len;
            if (host.len > slot_cap) {
                writeRefused(rt, "host too long for session-block slot — `[B]` ignored, use `sudo atty-guard urls block` for the persistent path", host);
                return .{ .replace = "\x15" };
            }
            if (rt.session_blocked_hosts_count >= rt.session_blocked_hosts.len) {
                writeRefused(rt, "session-block list full (16 entries) — run `sudo atty-guard session write` to persist + restart atty", host);
                return .{ .replace = "\x15" };
            }
            const slot = rt.session_blocked_hosts_count;
            @memcpy(rt.session_blocked_hosts[slot][0..host.len], host);
            rt.session_blocked_hosts_lens[slot] = @intCast(host.len);
            rt.session_blocked_hosts_count += 1;
            if (rt.daemon) |*client| {
                client.sessionAddUrlBlock(host) catch |err| switch (err) {
                    error.DaemonError => {
                        const msg = "atty: daemon rejected sessionAddUrlBlock — entry won't appear in `atty-guard session list`\n";
                        _ = std.c.write(2, msg, msg.len);
                    },
                    else => {},
                };
            }
            // Cancel the current command too — `[B]lock` implies
            // "don't run this one either."
            return .{ .replace = "\x15" };
        }

        /// URL-host extractor. Returns the slice of `s` representing
        /// the host of the first `scheme://[userinfo@]host[:port]/`
        /// occurrence, or null if no URL shape is found. Handles:
        ///   - `userinfo@` skip (`https://user:pass@host.io/x` → `host.io`)
        ///   - `[v6-literal]` opaque host (`[2001:db8::1]:8443/x` → `[2001:db8::1]`)
        ///   - port + path stripping (`example.com:8443/foo` → `example.com`)
        fn extractHost(s: []const u8) ?[]const u8 {
            const scheme_at = std.mem.indexOf(u8, s, "://") orelse return null;
            var after = s[scheme_at + 3 ..];
            // Strip `userinfo@`. The authority is `userinfo@host:port`
            // per RFC 3986; we want the host. Skip the FIRST `@`
            // that appears BEFORE the next `/`, `?`, or `#`, so a
            // path-segment `@` doesn't confuse us.
            var i: usize = 0;
            var at_idx: ?usize = null;
            while (i < after.len) : (i += 1) {
                const c = after[i];
                if (c == '/' or c == '?' or c == '#') break;
                if (c == '@') {
                    at_idx = i;
                    break;
                }
            }
            if (at_idx) |idx| {
                after = after[idx + 1 ..];
            }
            if (after.len == 0) return null;
            // IPv6 literal — `[...]`. The brackets are part of the
            // host (matches what the browser address bar shows). Find
            // the closing `]`; everything from the leading `[` up to
            // and including it is the host. After that we still
            // tolerate a `:<port>` we'll strip.
            if (after[0] == '[') {
                const close = std.mem.indexOfScalar(u8, after, ']') orelse return null;
                return after[0 .. close + 1];
            }
            // Regular host — ends at `/`, `:`, `?`, `#`, whitespace,
            // or any of the punctuation chars commonly used to
            // bracket / quote a URL in shell input (`)`, `"`, `'`,
            // `|`, `;`, `>`, `<`, `,`). Without these, `curl
            // "https://evil.io"` would extract `evil.io"` and never
            // match in future commands.
            var end: usize = 0;
            while (end < after.len) : (end += 1) {
                const c = after[end];
                switch (c) {
                    '/', ':', '?', '#', ' ', '\t', '\r', '\n', ')', '(', '"', '\'', '|', ';', '>', '<', ',', '`' => break,
                    else => {},
                }
            }
            if (end == 0) return null;
            return after[0..end];
        }

        /// Short-circuit predicate for the in-proc + daemon classify
        /// paths. Returns true when the committed line contains any
        /// host the operator added via `[B]lock host forever` AT A
        /// HOST BOUNDARY. Substring-only matching would false-block
        /// `notevil.io` for a blocked `evil.io`, AND under-block
        /// `prefix-evil.io.attacker.com` shapes where an attacker
        /// owns a sibling host. We require the host substring to be
        /// preceded AND followed by a non-host-char (anything that
        /// can't extend a domain label — alnum, `.`, `-`).
        fn lineIsSessionBlocked(rt: *Runtime, line: []const u8) bool {
            var i: usize = 0;
            while (i < rt.session_blocked_hosts_count) : (i += 1) {
                const len = rt.session_blocked_hosts_lens[i];
                if (len == 0) continue;
                const host = rt.session_blocked_hosts[i][0..len];
                if (hasHostMatch(line, host)) return true;
            }
            return false;
        }

        /// True when `needle` appears in `haystack` at a host
        /// boundary — preceded AND followed by a non-host-char (or
        /// at the string edge). A host-char is alnum / `.` / `-`.
        fn hasHostMatch(haystack: []const u8, needle: []const u8) bool {
            if (needle.len == 0 or haystack.len < needle.len) return false;
            var search_from: usize = 0;
            while (search_from + needle.len <= haystack.len) {
                const found = std.mem.indexOfPos(u8, haystack, search_from, needle) orelse return false;
                const before_ok = found == 0 or !isHostChar(haystack[found - 1]);
                const after = found + needle.len;
                const after_ok = after == haystack.len or !isHostChar(haystack[after]);
                if (before_ok and after_ok) return true;
                search_from = found + 1;
            }
            return false;
        }

        fn isHostChar(c: u8) bool {
            return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '.' or c == '-';
        }

        /// Push `level` to atty-guard for the shell's PID tree
        /// AND latch `rt.active_threat` so `statusText` reflects
        /// it until the user types a clean command. Silently no-op
        /// when the daemon isn't configured / reachable, or when
        /// we don't know the shell's PID (non-TTY tests).
        fn markShellThreat(
            rt: *Runtime,
            ctx: *m.Context,
            level: ?uds_client_mod.Client.ThreatLevel,
        ) void {
            const lvl = level orelse return;
            rt.active_threat = lvl;
            const pid = ctx.shell_pid orelse return;
            if (rt.daemon == null or rt.daemon_disabled) return;
            // Best-effort. If the daemon is wedged we already
            // know (daemon_disabled would be true) — if it's
            // alive and this RPC fails the verdict already
            // landed in the user's banner, so the consequence
            // of a missed kernel-side mark is "no kernel
            // enforcement this time", which is the V2-A
            // fallback semantics anyway.
            //
            // DaemonError specifically means the daemon SAID NO
            // (auth gate rejected, sandbox blocked /proc, rate
            // limit, etc.) — pre-fix the four mutation RPCs
            // swallowed the daemon's error envelope, so a
            // broken auth path looked like success while the
            // kernel map silently never updated. Log to stderr
            // so the failure surfaces during dev/debug runs and
            // in systemd journal capture; no in-band UI for
            // now since security_guard has no error-latch
            // channel and aborting the proxy on every daemon
            // hiccup would be worse than the silent failure.
            rt.daemon.?.setThreatLevel(pid, lvl) catch |err| switch (err) {
                error.DaemonError => {
                    const msg = "atty: daemon rejected setThreatLevel — kernel enforcement may be inactive\n";
                    _ = std.c.write(2, msg, msg.len);
                },
                else => {},
            };
        }

        /// Statusbar segment — emits a brief threat-level icon
        /// while the most-recent command tree is flagged. Returns
        /// null at idle so the segment disappears (rather than
        /// staying as dead chrome).
        pub fn statusText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            // Segment layout: `🛡 <profile> | <N> warns | <threat>`. The
            // live profile (polled on onTick) is the baseline posture and
            // leads; the event signals follow —
            // 1. `warn_sub.count()` — kernel-side warn events the daemon's
            //    ringbuf consumer pushed our way (post #347 PR 2b).
            // 2. `active_threat` — sticky in-flight warning from a
            //    recently-typed flagged command.
            // Any subset present renders; all absent → null (no dead chrome).
            _ = ctx;
            const warn_count: usize = if (rt.warn_sub) |sub| sub.count() else 0;
            const lvl = rt.active_threat;
            const lvl_label: []const u8 = if (lvl) |l| switch (l) {
                .low => "",
                .high => "high",
                .critical => "critical",
            } else "";
            // The live profile (polled on onTick) is the baseline posture;
            // warns/threat are appended events. Shield = guard.
            const profile: []const u8 = if (cfg.show_profile and rt.profile_name_len > 0)
                rt.profile_name[0..rt.profile_name_len]
            else
                "";

            if (profile.len == 0 and warn_count == 0 and lvl_label.len == 0) return null;

            // Assemble into the per-Runtime buffer — the slice must outlive
            // the gatherStatus writer (which borrows, not copies).
            var w: std.Io.Writer = .fixed(&rt.status_buf);
            w.writeAll("\u{1F6E1} ") catch return null;
            var sep = false;
            if (profile.len > 0) {
                w.writeAll(profile) catch return null;
                sep = true;
            }
            if (warn_count > 0) {
                w.print("{s}{d} warn{s}", .{
                    if (sep) " | " else "",
                    warn_count,
                    if (warn_count == 1) "" else "s",
                }) catch return null;
                sep = true;
            }
            if (lvl_label.len > 0) {
                w.print("{s}{s}", .{ if (sep) " | " else "", lvl_label }) catch return null;
            }
            return rt.status_buf[0..w.end];
        }

        /// Daemon-`Block` refusal notice. Single red line + clears
        /// readline; no prompt, no follow-up keystroke. The shell's
        /// PID tree is already marked Critical by the caller.
        fn writeRefused(rt: *Runtime, description: []const u8, matched: []const u8) void {
            const max_match: usize = 256;
            const trunc_match = if (matched.len > max_match) matched[0..max_match] else matched;
            const ellipsis: []const u8 = if (matched.len > max_match) " …" else "";
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "\r\n{f}atty security_guard: REFUSED — {s}{s}\r\n        match: {s}{s}\r\n",
                .{ cfg.refused_style, description, style_mod.reset, trunc_match, ellipsis },
            ) catch {
                var fb: [128]u8 = undefined;
                const short = std.fmt.bufPrint(
                    &fb,
                    "\r\natty security_guard: REFUSED — {s}\r\n",
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
                "\r\n{f}atty security_guard: {s}{s}\r\n        match: {s}{s}\r\n        [y]es once · [a]llow always · [t]rust permanently · [B]lock host forever · any other key cancels.\r\n",
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
