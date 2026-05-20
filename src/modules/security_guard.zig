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
            _ = io;
            var rt: Runtime = .{ .allocator = allocator };
            if (cfg.enabled) {
                rt.trust.load(allocator, cfg.trust_cache_path) catch {};
            }
            return rt;
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            _ = io;
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
            if (cfg.daemon_socket_path.len > 0 and !rt.daemon_disabled) {
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
            // (Future V2-B: also fire a SetThreatLevel(.low) RPC
            // to the daemon to clear the kernel-side BPF map
            // entry — left for the same PR that wires libbpf-rs.)
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
            const result = try rt.daemon.?.classifyOrErr(line, .{});
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
                    // matched substring + send to daemon as a
                    // persistent block decision. Only applies to
                    // URL-shaped categories (curl_pipe_sh); other
                    // hits silently fall through to cancel.
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
                        if (rt.allocator) |a| {
                            _ = rt.trust.add(a, hash) catch {};
                            rt.trust.persist(cfg.trust_cache_path) catch {};
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
                client.sessionAddTrust(hash) catch {};
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
            if (rt.session_blocked_hosts_count < rt.session_blocked_hosts.len) {
                const slot = rt.session_blocked_hosts_count;
                const copy_len = @min(host.len, rt.session_blocked_hosts[slot].len);
                @memcpy(rt.session_blocked_hosts[slot][0..copy_len], host[0..copy_len]);
                rt.session_blocked_hosts_lens[slot] = @intCast(copy_len);
                rt.session_blocked_hosts_count += 1;
            }
            if (rt.daemon) |*client| {
                client.sessionAddUrlBlock(host) catch {};
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
            // Regular host — ends at `/`, `:`, `?`, `#`, whitespace, or EOL.
            var end: usize = 0;
            while (end < after.len) : (end += 1) {
                const c = after[end];
                if (c == '/' or c == ':' or c == '?' or c == '#' or c == ' ' or c == '\t') break;
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
            return (c >= 'a' and c <= 'z')
                or (c >= 'A' and c <= 'Z')
                or (c >= '0' and c <= '9')
                or c == '.'
                or c == '-';
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
            rt.daemon.?.setThreatLevel(pid, lvl) catch {};
        }

        /// Statusbar segment — emits a brief threat-level icon
        /// while the most-recent command tree is flagged. Returns
        /// null at idle so the segment disappears (rather than
        /// staying as dead chrome).
        pub fn statusText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            _ = ctx;
            const lvl = rt.active_threat orelse return null;
            // Allocate in the per-Runtime tiny buffer. Statusbar
            // joins segments with " │ " so the icon needs no
            // surrounding chrome.
            const text: []const u8 = switch (lvl) {
                .low => "",
                .high => "\u{1F6E1} high",
                .critical => "\u{1F6E1} critical",
            };
            if (text.len == 0) return null;
            return text;
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
