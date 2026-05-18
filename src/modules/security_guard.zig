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

pub const Pattern = patterns_mod.Pattern;
pub const Category = patterns_mod.Category;
pub const default_patterns = patterns_mod.default_patterns;
pub const TrustCache = trust_mod.TrustCache;

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

            for (cfg.patterns, 0..) |pat, idx| {
                const matched = pat.match(line) orelse continue;

                // Trust cache?
                var hash_buf: [trust_mod.hex_len]u8 = undefined;
                const hash = trust_mod.hashCategoryMatch(pat.category, matched, &hash_buf);
                if (rt.trust.contains(hash)) return .forward;

                rt.armed = true;
                rt.armed_pattern_idx = idx;
                const copy_len = @min(matched.len, rt.armed_match.len);
                @memcpy(rt.armed_match[0..copy_len], matched[0..copy_len]);
                rt.armed_match_len = copy_len;

                writeBanner(rt, pat, matched);
                return .swallow;
            }
            return .forward;
        }

        fn handleArmedResponse(rt: *Runtime, input: []const u8) m.Action {
            if (input.len == 0) return .swallow;
            rt.armed = false;
            const c = input[0];
            switch (c) {
                'y', 'Y' => return .{ .replace = "\r" },
                't', 'T' => {
                    if (rt.armed_pattern_idx >= cfg.patterns.len) return .{ .replace = "\r" };
                    const pat = cfg.patterns[rt.armed_pattern_idx];
                    var hash_buf: [trust_mod.hex_len]u8 = undefined;
                    const hash = trust_mod.hashCategoryMatch(
                        pat.category,
                        rt.armed_match[0..rt.armed_match_len],
                        &hash_buf,
                    );
                    if (rt.allocator) |a| {
                        _ = rt.trust.add(a, hash) catch {};
                        rt.trust.persist(cfg.trust_cache_path) catch {};
                    }
                    return .{ .replace = "\r" };
                },
                else => return .{ .replace = "\x15" },
            }
        }

        fn writeBanner(rt: *Runtime, pat: Pattern, matched: []const u8) void {
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
                .{ cfg.warning_style, pat.description, style_mod.reset, trunc_match, ellipsis },
            ) catch {
                var fb: [128]u8 = undefined;
                const short = std.fmt.bufPrint(
                    &fb,
                    "\r\natty security_guard: {s} — [y]/[t]/cancel\r\n",
                    .{pat.description},
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
