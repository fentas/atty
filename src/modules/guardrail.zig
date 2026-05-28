//! Guardrail module — confirmation / block prompt for dangerous commands.
//!
//! v2 adds author-aware matching: every rule carries an `AuthorMask` that
//! gates whether it fires on user-typed lines, LLM-injected lines, or
//! both. Behavior is per-rule; `block` semantics differ for `.llm` so a
//! prompt-injection-style payload can be refused outright while the same
//! pattern, when the human typed it, only requires a confirm.
//!
//! Pattern matching stays compile-time-constant: the rules array, every
//! reason string, and every pattern are visible to the optimiser through
//! `configure(comptime cfg: Config)`.

const std = @import("std");
const m = @import("../module.zig");
const style_mod = @import("../style.zig");
const match_mod = @import("guardrail/match.zig");

const rules_mod = @import("guardrail/rules.zig");

pub const Match = match_mod.Match;
pub const AuthorMask = rules_mod.AuthorMask;
pub const Behavior = rules_mod.Behavior;
pub const Rule = rules_mod.Rule;
pub const default_rules = rules_mod.default_rules;

const matches = match_mod.matches;
const globMatch = match_mod.globMatch;

pub const Config = struct {
    /// User-supplied rules prepended to `rules` at comptime so
    /// they check FIRST under first-match-wins — handy for
    /// declaring a stricter rule (e.g. `.block` a pattern the
    /// underlying list only `.confirm`s) or whitelisting a false
    /// positive (a `.warn` rule that matches before the underlying
    /// `.block` would). The "underlying list" is `cfg.rules` —
    /// which itself defaults to `default_rules`, but if you also
    /// override `rules`, extras prepend to your custom list rather
    /// than to the shipped defaults. Empty default = use `rules`
    /// alone.
    extra_rules: []const Rule = &.{},
    /// Full rule list. Defaults to the shipped `default_rules`.
    /// Set to override the defaults entirely — typically only when
    /// you want a minimal policy tailored to your environment.
    /// For the common "I just want to add a couple of rules" case,
    /// leave this alone and use `extra_rules`.
    rules: []const Rule = &default_rules,
    warning_style: style_mod.Style = .{ .dim = true, .italic = true },
};

/// Compile-time-baked module type.
pub fn configure(comptime cfg: Config) type {
    // Common case (no extras) reuses cfg.rules directly to avoid
    // a duplicate constant in the binary. The ++ branch only fires
    // when there's actually something to prepend; extras prepend
    // so they check first under first-match-wins.
    const effective_rules: []const Rule = if (cfg.extra_rules.len == 0)
        cfg.rules
    else
        cfg.extra_rules ++ cfg.rules;
    return struct {
        pub const name = "guardrail";
        pub const config = cfg;
        pub const rules = effective_rules;

        pub const Runtime = struct {
            armed: bool = false,
            armed_rule_idx: usize = 0,
            confirmed_once: [effective_rules.len]bool = .{false} ** effective_rules.len,
            sink_ctx: ?*anyopaque = null,
            sink_fn: ?*const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void = null,
        };

        pub fn attach(allocator: std.mem.Allocator, io: std.Io) !Runtime {
            _ = allocator;
            _ = io;
            return .{};
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            _ = rt;
            _ = io;
        }

        /// First matching rule wins, in declaration order. Author
        /// defaults to `.user` — for an author-aware probe use
        /// `checkAs`.
        pub fn check(line: []const u8) ?Rule {
            return checkAs(line, .user);
        }

        /// Author-aware variant of `check`.
        pub fn checkAs(line: []const u8, author: m.Author) ?Rule {
            if (findRule(line, author)) |hit| return hit.rule;
            return null;
        }

        const Hit = struct { rule: Rule, idx: usize };

        fn findRule(line: []const u8, author: m.Author) ?Hit {
            inline for (effective_rules, 0..) |rule, i| {
                if (rule.authors.applies(author) and matches(rule.match, line)) {
                    return .{ .rule = rule, .idx = i };
                }
            }
            return null;
        }

        /// True iff `input` is a non-empty sequence consisting
        /// ENTIRELY of CR (0x0D) and/or LF (0x0A) bytes. Used to
        /// distinguish a legitimate "press Enter again to confirm"
        /// keystroke from a paste that happens to end in Enter:
        /// the latter contains added bytes that change what the
        /// shell will execute, so the rule check must re-run.
        pub fn isEnterOnly(input: []const u8) bool {
            if (input.len == 0) return false;
            for (input) |b| {
                switch (b) {
                    0x0D, 0x0A => {},
                    else => return false,
                }
            }
            return true;
        }

        /// Test seam — redirect the warning banner.
        pub fn setSink(
            rt: *Runtime,
            ctx: *anyopaque,
            writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
        ) void {
            rt.sink_ctx = ctx;
            rt.sink_fn = writeFn;
        }

        pub fn onInput(
            rt: *Runtime,
            ctx: *m.Context,
            input: []const u8,
        ) m.Error!m.Action {
            const has_enter = blk: {
                for (input) |b| if (b == 0x0D or b == 0x0A) break :blk true;
                break :blk false;
            };

            if (!has_enter) {
                // No Enter anywhere — plain typing. Any prior arm
                // is invalidated by the buffer change, but the
                // user hasn't tried to submit yet so we just
                // disarm + forward. The next Enter will re-run
                // findRule on the new buffer.
                rt.armed = false;
                return .forward;
            }

            // applyInput ran first, so the committed line lives in
            // lastCommitted(); fall back to current() when the proxy
            // hasn't wired OSC 133 (recalled-line gap). Author must
            // come from the same source: committed_author for the
            // post-submit snapshot, pending_author for the live
            // buffer fallback — otherwise a stale committed_author
            // can mislabel a fallback line.
            const committed = ctx.line.lastCommitted();
            const line = committed orelse ctx.line.current();
            const author = if (committed != null)
                ctx.line.committedAuthor()
            else
                ctx.line.pending_author;

            if (rt.armed) {
                rt.armed = false;
                // Only a pure CR/LF chunk is a legitimate second-press
                // confirmation. A mixed chunk (paste containing `\r`
                // appended to non-Enter bytes) means the buffer has
                // CHANGED since the rule was armed — the user's first
                // Enter confirmed `sudo apt update`, but the paste
                // could have appended `; rm -rf /` before the `\r`,
                // and the shell would execute the combined string.
                // Fall through to a fresh findRule on the new line
                // so the appended-and-dangerous shape is caught.
                if (isEnterOnly(input)) {
                    if (rt.armed_rule_idx < effective_rules.len) {
                        const armed_rule = effective_rules[rt.armed_rule_idx];
                        if (armed_rule.behavior == .confirm_once) {
                            rt.confirmed_once[rt.armed_rule_idx] = true;
                        }
                    }
                    return .forward;
                }
            }

            const hit = findRule(line, author) orelse return .forward;

            if (hit.rule.behavior == .confirm_once and rt.confirmed_once[hit.idx]) {
                return .forward;
            }

            switch (hit.rule.behavior) {
                .confirm, .confirm_once => {
                    rt.armed = true;
                    rt.armed_rule_idx = hit.idx;
                    writeBanner(rt, hit.rule, line, author, "press Enter again to confirm, any other key to cancel.");
                    return .swallow;
                },
                .block => {
                    writeBanner(rt, hit.rule, line, author, "blocked.");
                    // Ctrl+U → readline unix-line-discard.
                    return .{ .replace = "\x15" };
                },
                .warn => {
                    writeBanner(rt, hit.rule, line, author, "warning — running anyway.");
                    return .forward;
                },
            }
        }

        fn writeBanner(
            rt: *Runtime,
            rule: Rule,
            line: []const u8,
            author: m.Author,
            trailer: []const u8,
        ) void {
            const author_tag: []const u8 = switch (author) {
                .user => "user",
                .llm => "llm",
            };
            // The line is rendered as part of the banner. We bound
            // it so a 4 KiB pasted command can't blow past the
            // banner buffer and silently swallow the warning —
            // .block in particular would otherwise replace Enter
            // with Ctrl+U and leave the user with no explanation.
            const max_line_in_banner: usize = 512;
            const trunc_line = if (line.len > max_line_in_banner)
                line[0..max_line_in_banner]
            else
                line;
            const ellipsis: []const u8 = if (line.len > max_line_in_banner) " …" else "";
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "\r\n{f}atty guardrail: {s} [{s}]{s}\r\n        line: {s}{s}\r\n        {s}\r\n",
                .{ cfg.warning_style, rule.reason, author_tag, style_mod.reset, trunc_line, ellipsis, trailer },
            ) catch {
                // Worst-case fallback: a single short line so the
                // user at least sees that *something* tripped.
                var fallback: [128]u8 = undefined;
                const short = std.fmt.bufPrint(
                    &fallback,
                    "\r\natty guardrail: {s} [{s}] — {s}\r\n",
                    .{ rule.name, author_tag, trailer },
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
// Tests — extracted to `guardrail_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("guardrail_tests.zig");
}
