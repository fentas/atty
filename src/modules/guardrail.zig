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
            const is_enter = blk: {
                for (input) |b| if (b == 0x0D or b == 0x0A) break :blk true;
                break :blk false;
            };

            if (!is_enter) {
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
                if (rt.armed_rule_idx < effective_rules.len) {
                    const armed_rule = effective_rules[rt.armed_rule_idx];
                    if (armed_rule.behavior == .confirm_once) {
                        rt.confirmed_once[rt.armed_rule_idx] = true;
                    }
                }
                return .forward;
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
// Tests
// ===========================================================================

const testing = std.testing;
const LineState = @import("../line_state.zig").LineState;

// Pull in sibling guardrail/*.zig tests so `unit_tests.zig`'s
// `_ = @import("modules/guardrail.zig")` line discovers them.
test {
    _ = match_mod;
    _ = rules_mod;
}

const TestSink = struct {
    buf: std.ArrayList(u8),

    fn write(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        try self.buf.appendSlice(testing.allocator, bytes);
    }
};

const test_io: std.Io = std.Io.failing;

test "checkAs: default rules — user gets confirm on rm-rf, llm gets block" {
    const G = configure(.{});
    const user_hit = G.checkAs("rm -rf /home/me", .user).?;
    try testing.expectEqual(Behavior.confirm, user_hit.behavior);
    const llm_hit = G.checkAs("rm -rf /home/me", .llm).?;
    try testing.expectEqual(Behavior.block, llm_hit.behavior);
}

test "checkAs: rm -rf / is .block for both authors" {
    const G = configure(.{});
    try testing.expectEqual(Behavior.block, G.checkAs("rm -rf /", .user).?.behavior);
    try testing.expectEqual(Behavior.block, G.checkAs("rm -rf /", .llm).?.behavior);
}

test "checkAs: sudo prefix is .confirm for both" {
    const G = configure(.{});
    try testing.expectEqual(Behavior.confirm, G.checkAs("sudo apt update", .user).?.behavior);
    try testing.expectEqual(Behavior.confirm, G.checkAs("sudo apt update", .llm).?.behavior);
}

test "checkAs: safe line returns null for both authors" {
    const G = configure(.{});
    try testing.expect(G.checkAs("ls -la", .user) == null);
    try testing.expect(G.checkAs("ls -la", .llm) == null);
}

test "AuthorMask.applies" {
    const both = AuthorMask{};
    try testing.expect(both.applies(.user));
    try testing.expect(both.applies(.llm));
    const user_only = AuthorMask{ .user = true, .llm = false };
    try testing.expect(user_only.applies(.user));
    try testing.expect(!user_only.applies(.llm));
}

test "Match union: prefix vs substring" {
    const G = configure(.{
        .rules = &[_]Rule{
            .{ .name = "dd-prefix", .match = .{ .prefix = "dd " }, .reason = "raw" },
        },
    });
    try testing.expect(G.check("dd if=/dev/zero of=/tmp/x") != null);
    try testing.expect(G.check("echo dd ") == null);
    try testing.expect(G.check("sudo dd if=...") == null);
}

test "Match union: glob match wires through configure" {
    const G = configure(.{
        .rules = &[_]Rule{
            .{ .name = "g", .match = .{ .glob = "rm *" }, .reason = "x" },
        },
    });
    try testing.expect(G.check("rm foo") != null);
    try testing.expect(G.check("ls foo") == null);
}

test "Enter on dangerous line swallows and arms (proxy-flow: applyInput first)" {
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("rm -rf /home/user\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };
    try testing.expectEqualSlices(u8, "", line.current());
    try testing.expectEqualStrings("rm -rf /home/user", line.lastCommitted().?);

    const action = try G.onInput(&rt, &ctx, "\r");
    try testing.expectEqual(m.Action.swallow, action);
    try testing.expect(rt.armed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "guardrail") != null);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "[user]") != null);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "rm -rf /home/user") != null);
}

test "LLM-author rm -rf is .block (replaces with Ctrl+U, banner tagged [llm])" {
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    line.setCommitAuthor(.llm);
    _ = line.applyInput("rm -rf /home/me\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };
    try testing.expectEqual(m.Author.llm, line.committedAuthor());

    const action = try G.onInput(&rt, &ctx, "\r");
    switch (action) {
        .replace => |bytes| try testing.expectEqualSlices(u8, "\x15", bytes),
        else => return error.TestFailed,
    }
    try testing.expect(!rt.armed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "[llm]") != null);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "blocked.") != null);
}

test "User-author rm -rf is .confirm (swallow + arm)" {
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("rm -rf /home/me\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try testing.expectEqual(m.Action.swallow, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(rt.armed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "[user]") != null);
}

test "non-Enter keystroke disarms" {
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    // `rm -rf /home/foo` hits the broader user-confirm rule, not the
    // root .block — so it arms.
    var line = LineState{};
    _ = line.applyInput("rm -rf /home/foo\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    _ = try G.onInput(&rt, &ctx, "\r");
    try testing.expect(rt.armed);
    _ = try G.onInput(&rt, &ctx, "x");
    try testing.expect(!rt.armed);
}

test "Enter on safe line passes through" {
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var line = LineState{};
    _ = line.applyInput("ls -la\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try testing.expectEqual(m.Action.forward, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(!rt.armed);
}

test ".warn behavior: banner + forward (no swallow)" {
    const rules = [_]Rule{.{
        .name = "warn-only",
        .match = .{ .substring = "WARN" },
        .reason = "audit",
        .behavior = .warn,
    }};
    const G = configure(.{ .rules = &rules });
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("echo WARN now\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try testing.expectEqual(m.Action.forward, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(!rt.armed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "warning") != null);
}

test ".block replaces with Ctrl+U and never arms" {
    const rules = [_]Rule{.{
        .name = "block-test",
        .match = .{ .substring = "BAD" },
        .reason = "blocked",
        .behavior = .block,
    }};
    const G = configure(.{ .rules = &rules });
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("echo BAD\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    const action = try G.onInput(&rt, &ctx, "\r");
    switch (action) {
        .replace => |bytes| try testing.expectEqualSlices(u8, "\x15", bytes),
        else => return error.TestFailed,
    }
    try testing.expect(!rt.armed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "blocked.") != null);
}

test ".confirm_once: first match arms; after confirm, subsequent forwards silently" {
    const rules = [_]Rule{.{
        .name = "ask-once",
        .match = .{ .substring = "git push --force" },
        .reason = "force-pushing",
        .behavior = .confirm_once,
    }};
    const G = configure(.{ .rules = &rules });
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    _ = line.applyInput("git push --force\r");
    try testing.expectEqual(m.Action.swallow, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(rt.armed);

    _ = line.applyInput("\r");
    try testing.expectEqual(m.Action.forward, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(!rt.armed);
    try testing.expect(rt.confirmed_once[0]);

    sink.buf.clearRetainingCapacity();
    _ = line.applyInput("git push --force origin master\r");
    try testing.expectEqual(m.Action.forward, try G.onInput(&rt, &ctx, "\r"));
    try testing.expectEqual(@as(usize, 0), sink.buf.items.len);
}

test ".confirm_once is per-rule: confirming rule A does not silence rule B" {
    // Without a second rule, a future refactor could accidentally
    // make `confirmed_once` module-wide (single bool, or keyed off
    // something coarser than `match.idx`) and nothing would catch
    // it. This pins the per-rule invariant.
    const rules = [_]Rule{
        .{
            .name = "rule-a",
            .match = .{ .substring = "AAA" },
            .reason = "a",
            .behavior = .confirm_once,
        },
        .{
            .name = "rule-b",
            .match = .{ .substring = "BBB" },
            .reason = "b",
            .behavior = .confirm_once,
        },
    };
    const G = configure(.{ .rules = &rules });
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    // Arm + confirm rule A.
    _ = line.applyInput("echo AAA\r");
    try testing.expectEqual(m.Action.swallow, try G.onInput(&rt, &ctx, "\r"));
    _ = line.applyInput("\r");
    try testing.expectEqual(m.Action.forward, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(rt.confirmed_once[0]);
    try testing.expect(!rt.confirmed_once[1]);

    // Rule B's first match must still banner + swallow — confirming
    // A is not module-wide.
    sink.buf.clearRetainingCapacity();
    _ = line.applyInput("echo BBB\r");
    try testing.expectEqual(m.Action.swallow, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "guardrail") != null);
}

test "AuthorMask filtering: rule scoped to .llm is invisible to .user line" {
    const rules = [_]Rule{.{
        .name = "llm-only",
        .match = .{ .substring = "danger" },
        .reason = "llm-only",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    }};
    const G = configure(.{ .rules = &rules });
    try testing.expect(G.checkAs("danger", .user) == null);
    try testing.expect(G.checkAs("danger", .llm) != null);
}

test "custom rule list overrides defaults" {
    const my_rules = [_]Rule{
        .{
            .name = "git-force",
            .match = .{ .substring = "git push --force" },
            .reason = "force-pushing",
        },
    };
    const G = configure(.{ .rules = &my_rules });
    try testing.expect(G.check("git push --force origin main") != null);
    try testing.expect(G.check("rm -rf /") == null);
}

test "extra_rules: user rule prepends to defaults and wins under first-match-wins" {
    const extra = [_]Rule{.{
        .name = "git-force-extra",
        .match = .{ .substring = "git push --force" },
        .reason = "force-pushing (user-extra)",
        .behavior = .confirm_once,
    }};
    const G = configure(.{ .extra_rules = &extra });

    // The new rule matches.
    const hit = G.check("git push --force origin main").?;
    try testing.expectEqualStrings("git-force-extra", hit.name);
    try testing.expectEqual(Behavior.confirm_once, hit.behavior);

    // Defaults still active.
    try testing.expect(G.check("rm -rf /") != null);
    try testing.expectEqual(Behavior.block, G.check("rm -rf /").?.behavior);
}

test "extra_rules: user rule overrides default behavior on the same pattern (prepend wins)" {
    // Default `sudo` is .confirm for both authors. User pre-empts
    // with a .warn rule (e.g. audit but never block on sudo).
    const extra = [_]Rule{.{
        .name = "sudo-warn",
        .match = .{ .prefix = "sudo " },
        .reason = "sudo audit",
        .behavior = .warn,
    }};
    const G = configure(.{ .extra_rules = &extra });

    const hit = G.check("sudo apt update").?;
    try testing.expectEqualStrings("sudo-warn", hit.name);
    try testing.expectEqual(Behavior.warn, hit.behavior);
}

test "sudo-prefixed mkfs/dd from llm still hits .block (generic sudo rule must not shadow)" {
    const G = configure(.{});

    const mkfs_user = G.checkAs("sudo mkfs.ext4 /dev/sda1", .user).?;
    try testing.expectEqual(Behavior.confirm, mkfs_user.behavior);

    const mkfs_llm = G.checkAs("sudo mkfs.ext4 /dev/sda1", .llm).?;
    try testing.expectEqual(Behavior.block, mkfs_llm.behavior);
    try testing.expectEqualStrings("sudo-mkfs-llm", mkfs_llm.name);

    const dd_user = G.checkAs("sudo dd if=/dev/zero of=/dev/sda", .user).?;
    try testing.expectEqual(Behavior.confirm, dd_user.behavior);

    const dd_llm = G.checkAs("sudo dd if=/dev/zero of=/dev/sda", .llm).?;
    try testing.expectEqual(Behavior.block, dd_llm.behavior);
    try testing.expectEqualStrings("sudo-dd-llm", dd_llm.name);

    // Sanity: plain `sudo apt update` from llm still only `.confirm`.
    const sudo_apt_llm = G.checkAs("sudo apt update", .llm).?;
    try testing.expectEqual(Behavior.confirm, sudo_apt_llm.behavior);
}

test "first matching rule wins in declaration order — including across author masks" {
    // Two rules pattern-overlap. Earlier-declared one must win even
    // when a later one is more specific.
    const rules = [_]Rule{
        .{
            .name = "first-warn-user",
            .match = .{ .substring = "danger" },
            .reason = "first",
            .authors = .{ .user = true, .llm = false },
            .behavior = .warn,
        },
        .{
            .name = "second-block-user",
            .match = .{ .substring = "danger" },
            .reason = "second",
            .authors = .{ .user = true, .llm = false },
            .behavior = .block,
        },
        .{
            // Only-this-rule applies to llm; user-author probe must
            // skip it entirely.
            .name = "third-llm-only",
            .match = .{ .substring = "danger" },
            .reason = "third",
            .authors = .{ .user = false, .llm = true },
            .behavior = .block,
        },
    };
    const G = configure(.{ .rules = &rules });
    const user_hit = G.checkAs("danger", .user).?;
    try testing.expectEqualStrings("first-warn-user", user_hit.name);
    try testing.expectEqual(Behavior.warn, user_hit.behavior);

    const llm_hit = G.checkAs("danger", .llm).?;
    try testing.expectEqualStrings("third-llm-only", llm_hit.name);
}

test "empty rules list always returns null" {
    const empty = [_]Rule{};
    const G = configure(.{ .rules = &empty });
    try testing.expect(G.check("rm -rf /") == null);
    try testing.expect(G.check("") == null);
}
