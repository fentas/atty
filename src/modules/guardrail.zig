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

pub const Rule = struct {
    name: []const u8,
    kind: union(enum) {
        prefix: []const u8,
        substring: []const u8,
    },
    reason: []const u8,
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
            /// True between a fired rule and the user's next Enter (which
            /// confirms) or any other keystroke (which disarms).
            armed: bool = false,
            /// Optional sink override — tests inject a stub writer here
            /// to avoid scribbling on stderr.
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
            inline for (config.rules) |rule| {
                switch (rule.kind) {
                    .prefix => |p| if (std.mem.startsWith(u8, line, p)) return rule,
                    .substring => |s| if (std.mem.indexOf(u8, line, s) != null) return rule,
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

            const line = ctx.line.current();

            if (rt.armed) {
                rt.armed = false;
                return .forward;
            }

            if (check(line)) |rule| {
                rt.armed = true;
                writeWarning(rt, rule, line);
                return .swallow;
            }

            return .forward;
        }

        fn writeWarning(rt: *Runtime, rule: Rule, line: []const u8) void {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "\r\n{f}atty guardrail: {s}{s}\r\n        line: {s}\r\n        press Enter again to confirm, any other key to cancel.\r\n",
                .{ cfg.warning_style, rule.reason, style_mod.reset, line },
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

test "Enter on dangerous line swallows and arms" {
    const G = configure(.{});
    var rt = try G.attach(testing.allocator, test_io);
    defer G.detach(&rt, test_io);

    var sink = TestSink{ .buf = .empty };
    defer sink.buf.deinit(testing.allocator);
    G.setSink(&rt, &sink, TestSink.write);

    var line = LineState{};
    _ = line.applyInput("rm -rf /home/user");
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
    try testing.expectEqual(m.Action.swallow, action);
    try testing.expect(rt.armed);
    try testing.expect(std.mem.indexOf(u8, sink.buf.items, "guardrail") != null);

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
    _ = line.applyInput("rm -rf /");
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
    _ = line.applyInput("ls -la");
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
