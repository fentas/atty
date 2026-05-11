//! Comptime dispatch — the Suckless secret sauce.
//!
//! `Dispatcher(modules)` is a factory that, given a comptime tuple of
//! module *types*, produces a namespace with:
//!
//!   • `Runtimes` — a comptime-generated heterogeneous tuple struct,
//!     one field per module holding that module's `Runtime`.
//!   • `attachAll` / `detachAll` — lifecycle.
//!   • `dispatchInput` / `dispatchOutput` / `gatherGhostText` / `dispatchTick`
//!     — fan-out the corresponding hook into every module that
//!     declares it.
//!
//! Every hook lookup goes through `@hasDecl` at comptime, so modules
//! that don't implement a hook contribute *zero* bytes of code to the
//! relevant dispatch loop. If you delete a module from the config
//! tuple, every line of its onInput/onOutput/onTick handler vanishes
//! from the binary.
//!
//! There is no vtable, no `*anyopaque` pointer, no runtime branch on
//! the module list — `inline for` unrolls everything at compile time.

const std = @import("std");
const module = @import("module.zig");

pub const Action = module.Action;
pub const Context = module.Context;
pub const Error = module.Error;

/// Build a dispatcher specialised on a comptime tuple of module types.
///
/// Usage:
///     const D = Dispatcher(.{ Guardrail, Atuin });
///     var rts = try D.attachAll(allocator);
///     defer D.detachAll(allocator, &rts);
///     ...
pub fn Dispatcher(comptime modules: anytype) type {
    const N = modules.len;

    return struct {
        /// Heterogeneous tuple of *pointers* to each module's runtime.
        ///
        /// We store pointers (not values) for two reasons:
        ///   1. Each runtime lives at a stable heap address — modules
        ///      can hold long-lived self-references (e.g. the Atuin
        ///      worker thread captures `*Shared`).
        ///   2. Zig's strict "no comptime-var pointer at runtime" check
        ///      fires when dispatch code computes `&tuple[i]` for a
        ///      value tuple. Storing pointers means we just read them.
        pub const Runtimes = blk: {
            var types: [N]type = undefined;
            for (modules, 0..) |M, i| types[i] = *M.Runtime;
            break :blk std.meta.Tuple(&types);
        };

        // ---------------------------------------------------------------------
        // Lifecycle
        // ---------------------------------------------------------------------

        pub fn attachAll(allocator: std.mem.Allocator, io: std.Io) !Runtimes {
            var rts: Runtimes = undefined;
            var attached: usize = 0;
            errdefer detachUpTo(allocator, io, &rts, attached);

            inline for (modules, 0..) |M, i| {
                const slot = try allocator.create(M.Runtime);
                slot.* = M.attach(allocator, io) catch |err| {
                    allocator.destroy(slot);
                    return err;
                };
                rts[i] = slot;
                attached = i + 1;
            }
            return rts;
        }

        pub fn detachAll(allocator: std.mem.Allocator, io: std.Io, rts: *Runtimes) void {
            detachUpTo(allocator, io, rts, N);
        }

        fn detachUpTo(allocator: std.mem.Allocator, io: std.Io, rts: *Runtimes, count: usize) void {
            inline for (modules, 0..) |M, i| {
                if (i < count) {
                    if (comptime @hasDecl(M, "detach")) M.detach(rts[i], io);
                    allocator.destroy(rts[i]);
                }
            }
        }

        // ---------------------------------------------------------------------
        // Hooks
        // ---------------------------------------------------------------------

        /// Walk modules front-to-back. First .swallow short-circuits;
        /// .replace updates the byte slice for downstream modules.
        pub fn dispatchInput(
            rts: *Runtimes,
            ctx: *Context,
            input: []const u8,
        ) Error!Action {
            var current = input;
            var final_action: Action = .forward;
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onInput")) {
                    switch (try M.onInput(rts[i], ctx, current)) {
                        .forward => {},
                        .swallow => return .swallow,
                        .replace => |b| {
                            current = b;
                            final_action = .{ .replace = b };
                        },
                    }
                }
            }
            return final_action;
        }

        /// Observe-only fan-out. Modules cannot mutate shell output
        /// (that would corrupt the terminal's ANSI state machine).
        pub fn dispatchOutput(
            rts: *Runtimes,
            ctx: *Context,
            output: []const u8,
        ) Error!void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onOutput")) {
                    try M.onOutput(rts[i], ctx, output);
                }
            }
        }

        /// First non-null suggestion wins. Order modules in the config
        /// to express priority.
        pub fn gatherGhostText(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "provideGhostText")) {
                    if (try M.provideGhostText(rts[i], ctx)) |text| return text;
                }
            }
            return null;
        }

        /// Fired on poll() timeout. Modules use this for periodic
        /// work: ghost-text TTL expiry, status indicators, etc.
        pub fn dispatchTick(
            rts: *Runtimes,
            ctx: *Context,
            elapsed_ms: u64,
        ) Error!void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onTick")) {
                    try M.onTick(rts[i], ctx, elapsed_ms);
                }
            }
        }
    };
}

// ===========================================================================
// Tests — stub modules defined inline so we can verify the dispatch
// contract without dragging in the real Atuin/Guardrail.
// ===========================================================================

const testing = std.testing;
const LineState = @import("line_state.zig").LineState;
const test_io: std.Io = std.Io.failing;

const NoOpA = struct {
    pub const name = "noop-a";
    pub const Runtime = struct { input_count: usize = 0 };

    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn onInput(rt: *Runtime, _: *Context, _: []const u8) Error!Action {
        rt.input_count += 1;
        return .forward;
    }
};

const Swallower = struct {
    pub const name = "swallower";
    pub const Runtime = struct {};

    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn onInput(_: *Runtime, _: *Context, _: []const u8) Error!Action {
        return .swallow;
    }
};

const Replacer = struct {
    pub const name = "replacer";
    pub const Runtime = struct { buf: [16]u8 = undefined };

    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn onInput(rt: *Runtime, _: *Context, input: []const u8) Error!Action {
        const n = @min(input.len, rt.buf.len);
        for (input[0..n], 0..) |b, i| rt.buf[i] = std.ascii.toUpper(b);
        return .{ .replace = rt.buf[0..n] };
    }
};

const GhostProvider = struct {
    pub const name = "ghost";
    pub const Runtime = struct { suggestion: []const u8 = "" };

    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn provideGhostText(rt: *Runtime, _: *Context) Error!?[]const u8 {
        if (rt.suggestion.len == 0) return null;
        return rt.suggestion;
    }
};

const Ticker = struct {
    pub const name = "ticker";
    pub const Runtime = struct { ticks: u64 = 0, total_elapsed: u64 = 0 };

    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn onTick(rt: *Runtime, _: *Context, elapsed_ms: u64) Error!void {
        rt.ticks += 1;
        rt.total_elapsed += elapsed_ms;
    }
};

fn makeContext(line: *LineState, scratch: *std.ArrayList(u8)) Context {
    return .{
        .allocator = testing.allocator,
        .io = test_io,
        .line = line,
        .scratch = scratch,
        .is_tty = false,
    };
}

// Dispatchers materialised at module scope. Zig's strict "comptime var
// pointer at runtime" check fires on the @Type-generated tuple
// metadata when the Dispatcher type is created at function scope —
// hoisting to module scope keeps the metadata pinned to the binary.
const D_NoOpSwallower = Dispatcher(.{ NoOpA, Swallower });
const D_NoOpNoOp = Dispatcher(.{ NoOpA, NoOpA });
const D_SwallowerNoOp = Dispatcher(.{ Swallower, NoOpA });
const D_ReplacerNoOp = Dispatcher(.{ Replacer, NoOpA });

test "Dispatcher attaches and detaches all modules" {
    const D = D_NoOpSwallower;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    try testing.expectEqual(@as(usize, 0), rts[0].input_count);
}

test "dispatchInput forwards through all modules" {
    const D = D_NoOpNoOp;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    const action = try D.dispatchInput(&rts, &ctx, "hi");
    try testing.expectEqual(Action.forward, action);
    try testing.expectEqual(@as(usize, 1), rts[0].input_count);
    try testing.expectEqual(@as(usize, 1), rts[1].input_count);
}

test "dispatchInput short-circuits on swallow" {
    const D = D_SwallowerNoOp;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    const action = try D.dispatchInput(&rts, &ctx, "x");
    try testing.expectEqual(Action.swallow, action);
    // Second module must not run.
    try testing.expectEqual(@as(usize, 0), rts[1].input_count);
}

test "dispatchInput passes replaced bytes downstream" {
    const D = D_ReplacerNoOp;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    const action = try D.dispatchInput(&rts, &ctx, "hi");
    try testing.expect(action == .replace);
    try testing.expectEqualSlices(u8, "HI", action.replace);
}

const EmptyGhost = struct {
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn provideGhostText(_: *Runtime, _: *Context) Error!?[]const u8 {
        return null;
    }
};

const D_EmptyGhost = Dispatcher(.{ EmptyGhost, GhostProvider });

test "gatherGhostText returns first non-null" {
    const D = D_EmptyGhost;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);
    rts[1].suggestion = "tail";

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    const got = try D.gatherGhostText(&rts, &ctx);
    try testing.expectEqualSlices(u8, "tail", got.?);
}

const D_TickerTicker = Dispatcher(.{ Ticker, NoOpA, Ticker });

test "dispatchTick fans out to every module with onTick" {
    const D = D_TickerTicker;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    try D.dispatchTick(&rts, &ctx, 100);
    try D.dispatchTick(&rts, &ctx, 50);

    try testing.expectEqual(@as(u64, 2), rts[0].ticks);
    try testing.expectEqual(@as(u64, 150), rts[0].total_elapsed);
    try testing.expectEqual(@as(u64, 2), rts[2].ticks);
}
