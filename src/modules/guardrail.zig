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

/// How a rule decides whether the committed line is a hit. `prefix` and
/// `substring` are O(n) byte scans; `glob` runs an iterative
/// `*`-backtrack matcher (no character classes, no recursion).
pub const Match = union(enum) {
    /// Line starts with this exact byte sequence.
    prefix: []const u8,
    /// `std.mem.indexOf` non-null.
    substring: []const u8,
    /// Shell-style: `*` = any (greedy) run, `?` = any single byte.
    /// Anchored to both ends of the line.
    glob: []const u8,
};

/// Whether a rule fires depending on who initiated the commit.
/// Default = applies to both. Use this to declare two rules for the
/// same pattern with different `Behavior` per author (the canonical
/// "confirm for user, block for llm" shape).
pub const AuthorMask = struct {
    user: bool = true,
    llm: bool = true,

    pub fn applies(self: AuthorMask, author: m.Author) bool {
        return switch (author) {
            .user => self.user,
            .llm => self.llm,
        };
    }
};

/// What to do when a rule matches.
pub const Behavior = enum {
    /// Banner + swallow. Press Enter again to confirm (forwards),
    /// any other key to cancel (disarms; user can keep editing).
    confirm,
    /// Like `.confirm`, but the confirmation persists for the rest of
    /// the session. Once the user confirms this rule once, subsequent
    /// matches forward immediately with no banner. Per-rule, not
    /// module-wide.
    confirm_once,
    /// Banner with a "blocked." trailer; the Enter is replaced with
    /// Ctrl+U (unix-line-discard) so readline kills the typed line.
    /// Nothing reaches the shell.
    block,
    /// Banner with a "warning — running anyway." trailer; the Enter
    /// is forwarded. Use for lines that should be flagged but not
    /// stopped (audit trail without friction).
    warn,
};

pub const Rule = struct {
    name: []const u8,
    match: Match,
    reason: []const u8,
    /// Which author(s) trigger this rule. Default = both. To get
    /// different behavior per author for the same pattern, declare
    /// two rules with mutually-exclusive masks.
    authors: AuthorMask = .{},
    behavior: Behavior = .confirm,
};

/// Default rules. Catastrophic patterns (exact `rm -rf /`, fork bomb)
/// are `.block` for both authors so neither party can talk their way
/// past them. Merely-dangerous patterns (`rm -rf` with a subpath,
/// `mkfs`, `dd …`) `.block` when the line is `.llm`-authored but only
/// `.confirm` for `.user` — the human can override their own decision;
/// a model suggesting the same line cannot.
pub const default_rules = [_]Rule{
    .{
        // Exact-only — `rm -rf /home/me` falls through to the
        // broader "rm -rf" substring rules below (confirm for
        // user, block for llm). Use `.glob` not `.substring` so
        // typing `rm -rf /something` doesn't get blocked outright.
        .name = "rm-rf-root",
        .match = .{ .glob = "rm -rf /" },
        .reason = "rm -rf on the root path",
        .behavior = .block,
    },
    .{
        .name = "fork-bomb",
        .match = .{ .substring = ":(){ :|:& };:" },
        .reason = "classic fork bomb",
        .behavior = .block,
    },
    .{
        .name = "rm-rf-tilde-user",
        .match = .{ .substring = "rm -rf ~" },
        .reason = "rm -rf on home",
        .authors = .{ .user = true, .llm = false },
        .behavior = .confirm,
    },
    .{
        .name = "rm-rf-tilde-llm",
        .match = .{ .substring = "rm -rf ~" },
        .reason = "rm -rf on home (llm)",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        .name = "rm-rf-user",
        .match = .{ .substring = "rm -rf" },
        .reason = "rm -rf invocation",
        .authors = .{ .user = true, .llm = false },
        .behavior = .confirm,
    },
    .{
        .name = "rm-rf-llm",
        .match = .{ .substring = "rm -rf" },
        .reason = "rm -rf invocation",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        .name = "sudo",
        .match = .{ .prefix = "sudo " },
        .reason = "sudo invocation",
        .behavior = .confirm,
    },
    .{
        .name = "mkfs-user",
        .match = .{ .prefix = "mkfs" },
        .reason = "filesystem creation",
        .authors = .{ .user = true, .llm = false },
        .behavior = .confirm,
    },
    .{
        .name = "mkfs-llm",
        .match = .{ .prefix = "mkfs" },
        .reason = "filesystem creation (llm)",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        // Prefix not substring — any `dd ` invocation deserves a beat
        // (covers both `dd if=/dev/sda …` reads and
        // `dd … of=/dev/sda` writes; `dd if=/tmp of=/tmp/copy` too,
        // which is fine, the confirm prompt is cheap).
        .name = "dd-user",
        .match = .{ .prefix = "dd " },
        .reason = "dd invocation",
        .authors = .{ .user = true, .llm = false },
        .behavior = .confirm,
    },
    .{
        .name = "dd-llm",
        .match = .{ .prefix = "dd " },
        .reason = "dd invocation",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        .name = "curl-pipe-sh",
        .match = .{ .substring = "| sh" },
        .reason = "piping untrusted output into a shell",
        .behavior = .confirm,
    },
    .{
        .name = "curl-pipe-bash",
        .match = .{ .substring = "| bash" },
        .reason = "piping untrusted output into a shell",
        .behavior = .confirm,
    },
    .{
        .name = "chmod-world",
        .match = .{ .substring = "chmod 777 /" },
        .reason = "world-writable root path",
        .behavior = .confirm,
    },
};

pub const Config = struct {
    rules: []const Rule = &default_rules,
    warning_style: style_mod.Style = .{ .dim = true, .italic = true },
};

/// Compile-time-baked module type.
pub fn configure(comptime cfg: Config) type {
    return struct {
        pub const name = "guardrail";
        pub const config = cfg;

        pub const Runtime = struct {
            armed: bool = false,
            armed_rule_idx: usize = 0,
            confirmed_once: [cfg.rules.len]bool = .{false} ** cfg.rules.len,
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
            inline for (config.rules, 0..) |rule, i| {
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
                if (rt.armed_rule_idx < cfg.rules.len) {
                    const armed_rule = cfg.rules[rt.armed_rule_idx];
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

fn matches(match: Match, line: []const u8) bool {
    return switch (match) {
        .prefix => |p| std.mem.startsWith(u8, line, p),
        .substring => |s| std.mem.indexOf(u8, line, s) != null,
        .glob => |g| globMatch(g, line),
    };
}

/// Iterative `*` / `?` matcher with backtracking to the most recent
/// `*`. Anchored to both ends — same shape as shell globs (no `[abc]`
/// classes). No recursion: O(pattern × line) worst case, constant
/// stack.
fn globMatch(pattern: []const u8, line: []const u8) bool {
    var pi: usize = 0;
    var li: usize = 0;
    var star_pi: ?usize = null;
    var star_li: usize = 0;
    while (li < line.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_li = li;
            pi += 1;
        } else if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == line[li])) {
            pi += 1;
            li += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_li += 1;
            li = star_li;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const LineState = @import("../line_state.zig").LineState;

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

test "glob: simple star and question" {
    try testing.expect(globMatch("rm *", "rm foo"));
    try testing.expect(globMatch("rm *", "rm "));
    try testing.expect(!globMatch("rm *", "rmfoo"));
    try testing.expect(globMatch("?at", "cat"));
    try testing.expect(!globMatch("?at", "cats"));
    try testing.expect(globMatch("*", ""));
    try testing.expect(globMatch("a*b", "ab"));
    try testing.expect(globMatch("a*b", "aXYZb"));
    try testing.expect(!globMatch("a*b", "axyzc"));
}

test "glob: anchored on both ends" {
    try testing.expect(!globMatch("rm", "rm foo"));
    try testing.expect(!globMatch("foo", "echo foo"));
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
