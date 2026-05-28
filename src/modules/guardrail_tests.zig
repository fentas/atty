//! Tests for `modules/guardrail.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("guardrail.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const m = @import("../module.zig");
const style_mod = @import("../style.zig");
const match_mod = @import("guardrail/match.zig");
const rules_mod = @import("guardrail/rules.zig");
const matches = match_mod.matches;
const globMatch = match_mod.globMatch;

// Re-binds of pub decls so test bodies stay short.
const AuthorMask = mod.AuthorMask;
const Behavior = mod.Behavior;
const Config = mod.Config;
const configure = mod.configure;
const default_rules = mod.default_rules;
const Match = mod.Match;
const Rule = mod.Rule;

// ===========================================================================
// Tests
// ===========================================================================

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

test "extra_rules: prepended rule wins over default match under first-match-wins" {
    // No .authors mask on the extra rule → applies to both .user
    // and .llm. The assertion is purely about prepend ordering,
    // not author-gated behavior.
    const extra = [_]Rule{.{
        .name = "git-force-extra",
        .match = .{ .substring = "git push --force" },
        .reason = "force-pushing (extra)",
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

test "extra_rules: prepended rule overrides default behavior on the same pattern" {
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

test "isEnterOnly accepts pure CR/LF, rejects everything else" {
    const G = configure(.{});
    try testing.expect(G.isEnterOnly("\r"));
    try testing.expect(G.isEnterOnly("\n"));
    try testing.expect(G.isEnterOnly("\r\n"));
    try testing.expect(G.isEnterOnly("\n\r"));
    try testing.expect(G.isEnterOnly("\r\r"));
    try testing.expect(!G.isEnterOnly(""));
    try testing.expect(!G.isEnterOnly("y\r"));
    try testing.expect(!G.isEnterOnly("\rx"));
    try testing.expect(!G.isEnterOnly("; rm -rf /\r"));
    try testing.expect(!G.isEnterOnly("hi"));
    // ESC byte is NOT enter — bracketed-paste sequences must
    // disqualify even if they end in CR/LF.
    try testing.expect(!G.isEnterOnly("\x1b[200~hi\x1b[201~\r"));
}

test "armed-state paste with appended CR re-checks rules instead of forwarding" {
    // Invariant: the rule a confirm grants is only valid for the
    // exact buffer it was armed against. A mixed chunk (paste
    // bytes ending in CR) changes the buffer and must trigger a
    // fresh findRule on the new line. Without this, a paste of
    // `; <dangerous>` + CR after `sudo apt update` (confirmed)
    // would execute the combined string with the original
    // arming's grant.
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    // Step 1: type `sudo apt update` + Enter. Matches the
    // sudo-prefix rule (.confirm) → arm.
    _ = line.applyInput("sudo apt update\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };
    const arm_action = try G.onInput(&rt, &ctx, "\r");
    try testing.expectEqual(m.Action.swallow, arm_action);
    try testing.expect(rt.armed);

    // Step 2: paste a fork bomb with trailing CR. applyInput
    // re-runs first (proxy convention), updating the live buffer
    // + committing on \r. The CR in the paste must NOT be
    // honored as a second-press confirm.
    sink.buf.clearRetainingCapacity();
    _ = line.applyInput("; :(){ :|:& };:\r");
    const paste_action = try G.onInput(&rt, &ctx, "; :(){ :|:& };:\r");

    // Fork-bomb rule fires .block → Ctrl+U replaces the chunk so
    // the shell never sees the dangerous bytes.
    switch (paste_action) {
        .replace => |bytes| try testing.expectEqualSlices(u8, "\x15", bytes),
        else => return error.TestFailedBypassActive,
    }
    try testing.expect(!rt.armed);
    // Banner cites the new rule's reason ("fork bomb"), not the
    // original sudo-apt-update arming.
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "fork bomb") != null);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "blocked.") != null);
}

test "armed-state paste with new .confirm rule re-arms instead of forwarding" {
    // Companion invariant: when the pasted-with-CR content matches
    // a .confirm rule (not .block), the armed branch must disarm
    // and RE-ARM on the new rule rather than forwarding the
    // already-granted (stale) confirmation.
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("sudo apt update\r");
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

    // Paste appends `rm -rf` content (matches substring rule
    // → .confirm for user author). The fix must re-arm on this
    // new rule, not blindly forward.
    sink.buf.clearRetainingCapacity();
    _ = line.applyInput("; rm -rf /home/me\r");
    const paste_action = try G.onInput(&rt, &ctx, "; rm -rf /home/me\r");

    try testing.expectEqual(m.Action.swallow, paste_action);
    try testing.expect(rt.armed); // re-armed on the rm-rf rule
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "rm -rf") != null);
}

test "armed-state pure CR confirms (preserves existing happy path)" {
    // Regression guard: pure-Enter input on an armed rule still
    // forwards as confirmation.
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("sudo apt update\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };
    const first = try G.onInput(&rt, &ctx, "\r");
    try testing.expectEqual(m.Action.swallow, first);
    try testing.expect(rt.armed);

    // A FRESH pure CR (single byte) is the legit confirm.
    const second = try G.onInput(&rt, &ctx, "\r");
    try testing.expectEqual(m.Action.forward, second);
    try testing.expect(!rt.armed);
}
