//! Guardrail module — confirmation prompt for dangerous commands.
//!
//! Pure logic, no I/O on the hot path apart from a single bufPrint +
//! writeAll when a rule fires. Pattern matching is intentionally simple
//! (substring + anchored prefix); a regex engine on the input hot path
//! would be a strict regression.

const std = @import("std");
const m = @import("../module.zig");
const ansi = @import("../ansi.zig");
const style_mod = @import("../style.zig");

/// What to do when a rule matches a typed Enter.
pub const Mode = enum {
    /// Show the warning banner. Press Enter again to confirm
    /// (forwards the Enter), any other key to cancel (disarms;
    /// the user can keep editing the line). Default — matches
    /// the historical behavior.
    confirm,
    /// Like `.confirm`, but the confirmation persists for the
    /// rest of the session. Once the user confirms this rule
    /// once, subsequent matches forward immediately with no
    /// banner. Per-rule (not module-wide): confirming
    /// `rm -rf /` doesn't suppress `git push --force`.
    confirm_once,
    /// Show the banner with a "blocked." trailer; never allow
    /// the command to run. The Enter is replaced with Ctrl+U
    /// (unix-line-discard) so the shell clears the typed line —
    /// the user sees their text vanish, prompt fresh.
    block,
    /// Like `.block` but no banner. Looks to the user like Enter
    /// did nothing; the typed line just disappears. Useful for
    /// rules where even the banner is too much noise (sensitive
    /// shells, demo recordings).
    silent_block,
};

pub const Rule = struct {
    name: []const u8,
    kind: union(enum) {
        prefix: []const u8,
        substring: []const u8,
    },
    reason: []const u8,
    /// What to do when this rule matches. Default `.confirm`
    /// keeps the historical "press Enter again" behavior.
    mode: Mode = .confirm,
};

/// Reasonable defaults. Override by passing your own `.rules` to
/// `configure(.{ .rules = &my_rules })`.
pub const default_rules = [_]Rule{
    .{
        .name = "rm-rf-root",
        .kind = .{ .substring = "rm -rf /" },
        .reason = "rm -rf on a root-ish path",
    },
    .{
        .name = "rm-rf-tilde",
        .kind = .{ .substring = "rm -rf ~" },
        .reason = "rm -rf on home",
    },
    .{
        .name = "dd-raw-device",
        .kind = .{ .prefix = "dd " },
        .reason = "dd writing to a raw device",
    },
    .{
        .name = "mkfs",
        .kind = .{ .prefix = "mkfs" },
        .reason = "filesystem creation",
    },
    .{
        .name = "fork-bomb",
        .kind = .{ .substring = ":(){ :|:& };:" },
        .reason = "classic fork bomb",
    },
    .{
        .name = "curl-pipe-sh",
        .kind = .{ .substring = "| sh" },
        .reason = "piping untrusted output into a shell",
    },
    .{
        .name = "curl-pipe-bash",
        .kind = .{ .substring = "| bash" },
        .reason = "piping untrusted output into a shell",
    },
    .{
        .name = "chmod-world",
        .kind = .{ .substring = "chmod 777 /" },
        .reason = "world-writable root path",
    },
};

pub const Config = struct {
    rules: []const Rule = &default_rules,
    /// Visual style for the warning banner. Defaults match the
    /// historical look (dim + italic).
    warning_style: style_mod.Style = .{ .dim = true, .italic = true },
};

/// Returns a module type with `cfg` baked in. The rules list, every
/// reason string, and every pattern are visible to the optimiser as
/// compile-time constants.
pub fn configure(comptime cfg: Config) type {
    return struct {
        pub const name = "guardrail";
        pub const config = cfg;

        pub const Runtime = struct {
            /// True between a fired rule and the user's next Enter
            /// (which confirms) or any other keystroke (which disarms).
            armed: bool = false,
            /// Index into `cfg.rules` of the rule that armed us — used
            /// to record persistent confirmation for `.confirm_once`
            /// rules when the user confirms.
            armed_rule_idx: usize = 0,
            /// One slot per rule. Set to true when the user confirms
            /// a `.confirm_once` rule; checked on subsequent matches
            /// to skip the banner + forward immediately.
            confirmed_once: [cfg.rules.len]bool = .{false} ** cfg.rules.len,
            /// Optional sink override — tests inject a stub writer
            /// here to avoid scribbling on stderr.
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

        /// First matching rule wins, in declaration order.
        pub fn check(line: []const u8) ?Rule {
            if (findRule(line)) |hit| return hit.rule;
            return null;
        }

        const Match = struct { rule: Rule, idx: usize };

        fn findRule(line: []const u8) ?Match {
            inline for (config.rules, 0..) |rule, i| {
                switch (rule.kind) {
                    .prefix => |p| if (std.mem.startsWith(u8, line, p)) return .{ .rule = rule, .idx = i },
                    .substring => |s| if (std.mem.indexOf(u8, line, s) != null) return .{ .rule = rule, .idx = i },
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
                // Any non-Enter key disarms — if the user kept typing
                // they're already past the guard.
                rt.armed = false;
                return .forward;
            }

            // applyInput ran before dispatchInput, so for an Enter
            // keystroke `ctx.line.current()` is already empty — the
            // line we want to check sits in `lastCommitted()` instead.
            // Fall back to current() for the (rare) case where a hook
            // pipeline upstream applied input differently. Note: if
            // the user history-recalled the line via Up-arrow,
            // lastCommitted is null (line_state can't observe a
            // shell-side history recall) and we won't fire — known
            // limitation, OSC 133 would fix it.
            const line = ctx.line.lastCommitted() orelse ctx.line.current();

            // Armed = user previously hit Enter on a dangerous line
            // (with `.confirm` or `.confirm_once`); this Enter confirms.
            if (rt.armed) {
                rt.armed = false;
                if (rt.armed_rule_idx < cfg.rules.len) {
                    const armed_rule = cfg.rules[rt.armed_rule_idx];
                    if (armed_rule.mode == .confirm_once) {
                        rt.confirmed_once[rt.armed_rule_idx] = true;
                    }
                }
                return .forward;
            }

            const match = findRule(line) orelse return .forward;

            // `.confirm_once` already confirmed this session → no
            // banner, no swallow, just forward like a normal line.
            if (match.rule.mode == .confirm_once and rt.confirmed_once[match.idx]) {
                return .forward;
            }

            switch (match.rule.mode) {
                .confirm, .confirm_once => {
                    rt.armed = true;
                    rt.armed_rule_idx = match.idx;
                    writeWarning(rt, match.rule, line, "press Enter again to confirm, any other key to cancel.");
                    return .swallow;
                },
                .block => {
                    writeWarning(rt, match.rule, line, "blocked.");
                    // Replace the Enter with Ctrl+U (unix-line-discard)
                    // so readline kills the typed text. No Enter
                    // reaches the shell — nothing runs.
                    return .{ .replace = "\x15" };
                },
                .silent_block => {
                    return .{ .replace = "\x15" };
                },
            }
        }

        fn writeWarning(rt: *Runtime, rule: Rule, line: []const u8, trailer: []const u8) void {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "\r\n{f}atty guardrail: {s}{s}\r\n        line: {s}\r\n        {s}\r\n",
                .{ cfg.warning_style, rule.reason, style_mod.reset, line, trailer },
            ) catch return;
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

const TestSink = struct {
    buf: std.ArrayList(u8),

    fn write(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        try self.buf.appendSlice(testing.allocator, bytes);
    }
};

test "check matches default rules" {
    const G = configure(.{});

    try testing.expect(G.check("rm -rf /") != null);
    try testing.expect(G.check("sudo rm -rf /home/user") != null);
    try testing.expect(G.check("dd if=/dev/zero of=/dev/sda") != null);
    try testing.expect(G.check("ls -la") == null);
}

// std.Io.failing — a no-op Io for tests that don't touch I/O.
const test_io: std.Io = std.Io.failing;

test "Enter on dangerous line swallows and arms (proxy-flow: applyInput first, then dispatch)" {
    // Regression: prior to a 2026-05 fix, guardrail.onInput read
    // ctx.line.current(), but the proxy ran applyInput("rm -rf /...\r")
    // BEFORE dispatchInput. submit() had already emptied current()
    // and stashed the line in `committed`. The check silently passed,
    // rm fired, and no banner ever printed. This test mirrors the
    // exact proxy flow so the bug can't come back.
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    // Single applyInput including the \r, as the proxy does.
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
    // Sanity: applyInput emptied current() and filled committed.
    try testing.expectEqualSlices(u8, "", line.current());
    try testing.expectEqualStrings("rm -rf /home/user", line.lastCommitted().?);

    const action = try G.onInput(&rt, &ctx, "\r");
    try testing.expectEqual(m.Action.swallow, action);
    try testing.expect(rt.armed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "guardrail") != null);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "rm -rf /home/user") != null);

    // Second Enter forwards (user confirmed). Same proxy flow: typing
    // \r calls applyInput first; current() is empty, lastCommitted
    // is null (was cleared by the proxy after dispatchLineCommit),
    // so the check sees an empty line and no rule matches anyway —
    // but the `armed` short-circuit means we never reach the check.
    _ = line.applyInput("\r");
    const second = try G.onInput(&rt, &ctx, "\r");
    try testing.expectEqual(m.Action.forward, second);
    try testing.expect(!rt.armed);
}

test "non-Enter keystroke disarms" {
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("rm -rf /\r");
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

    const action = try G.onInput(&rt, &ctx, "\r");
    try testing.expectEqual(m.Action.forward, action);
    try testing.expect(!rt.armed);
}

test "prefix rule requires the line to start with the pattern (no mid-line match)" {
    const rules = [_]Rule{
        .{
            .name = "dd-prefix",
            .kind = .{ .prefix = "dd " },
            .reason = "raw write",
        },
    };
    const G = configure(.{ .rules = &rules });
    try testing.expect(G.check("dd if=/dev/zero of=/tmp/x") != null);
    // Should NOT fire when "dd " appears mid-line — that's the
    // substring rule's job, not prefix's.
    try testing.expect(G.check("echo dd ") == null);
    try testing.expect(G.check("sudo dd if=...") == null);
}

test "first matching rule wins (declaration-order)" {
    const rules = [_]Rule{
        .{
            .name = "first",
            .kind = .{ .substring = "danger" },
            .reason = "first rule's reason",
        },
        .{
            .name = "second",
            .kind = .{ .substring = "danger" },
            .reason = "second rule's reason",
        },
    };
    const G = configure(.{ .rules = &rules });
    const r = G.check("very danger here").?;
    try testing.expectEqualStrings("first", r.name);
    try testing.expectEqualStrings("first rule's reason", r.reason);
}

test "empty rules list always returns null" {
    const empty = [_]Rule{};
    const G = configure(.{ .rules = &empty });
    try testing.expect(G.check("rm -rf /") == null);
    try testing.expect(G.check("") == null);
}

test ".block mode replaces the Enter with Ctrl+U and never arms" {
    // A `.block` rule says "never allow this command, ever." The
    // banner fires (so the user knows why nothing happened) but the
    // module returns Action.replace = "\x15" instead of swallowing,
    // so readline kills the typed line. armed stays false — there's
    // no second-Enter confirm path.
    const rules = [_]Rule{.{
        .name = "no-rm-rf-slash",
        .kind = .{ .substring = "rm -rf /" },
        .reason = "blocked: rm -rf on root",
        .mode = .block,
    }};
    const G = configure(.{ .rules = &rules });
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("rm -rf /home\r");
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
    try testing.expect(!rt.armed); // never arms
    // Banner still fires — the user needs to know.
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "guardrail") != null);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "blocked.") != null);
}

test ".silent_block replaces the Enter with Ctrl+U + no banner" {
    const rules = [_]Rule{.{
        .name = "shh",
        .kind = .{ .substring = "rm -rf /" },
        .reason = "should not be visible",
        .mode = .silent_block,
    }};
    const G = configure(.{ .rules = &rules });
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("rm -rf /tmp\r");
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
    try testing.expectEqual(@as(usize, 0), sink.buf.items.len);
    try testing.expect(!rt.armed);
}

test ".confirm_once: first match arms + banners; after confirm, subsequent matches forward silently" {
    const rules = [_]Rule{.{
        .name = "ask-once",
        .kind = .{ .substring = "git push --force" },
        .reason = "force-pushing",
        .mode = .confirm_once,
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

    // First invocation: arm + banner + swallow.
    _ = line.applyInput("git push --force\r");
    try testing.expectEqual(m.Action.swallow, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(rt.armed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "guardrail") != null);

    // Confirm Enter: armed → forward + record persistent confirmation.
    _ = line.applyInput("\r"); // empty, doesn't change committed
    try testing.expectEqual(m.Action.forward, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(!rt.armed);
    try testing.expect(rt.confirmed_once[0]);

    // Second invocation, same rule: no banner, just forward.
    sink.buf.clearRetainingCapacity();
    _ = line.applyInput("git push --force origin master\r");
    try testing.expectEqual(m.Action.forward, try G.onInput(&rt, &ctx, "\r"));
    try testing.expectEqual(@as(usize, 0), sink.buf.items.len);
}

test ".confirm_once is per-rule: confirming one rule doesn't suppress another" {
    const rules = [_]Rule{
        .{
            .name = "once-a",
            .kind = .{ .substring = "force-push" },
            .reason = "a",
            .mode = .confirm_once,
        },
        .{
            .name = "once-b",
            .kind = .{ .substring = "rm-bad" },
            .reason = "b",
            .mode = .confirm_once,
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

    // Confirm rule A.
    _ = line.applyInput("force-push\r");
    _ = try G.onInput(&rt, &ctx, "\r");
    _ = line.applyInput("\r");
    _ = try G.onInput(&rt, &ctx, "\r");
    try testing.expect(rt.confirmed_once[0]);
    try testing.expect(!rt.confirmed_once[1]); // rule B still un-confirmed

    // Rule B's first invocation must still banner + swallow.
    sink.buf.clearRetainingCapacity();
    _ = line.applyInput("rm-bad path\r");
    try testing.expectEqual(m.Action.swallow, try G.onInput(&rt, &ctx, "\r"));
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "guardrail") != null);
}

test "custom rule list" {
    const my_rules = [_]Rule{
        .{
            .name = "git-force",
            .kind = .{ .substring = "git push --force" },
            .reason = "force-pushing to a shared branch",
        },
    };
    const G = configure(.{ .rules = &my_rules });

    try testing.expect(G.check("git push --force origin main") != null);
    // Default rules disabled — `rm -rf /` not in the custom list.
    try testing.expect(G.check("rm -rf /") == null);
}
