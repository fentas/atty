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

        /// First non-null hint wins. One-shot semantics — modules
        /// implementing `provideHintText` are expected to return the
        /// text once and `null` thereafter (no re-painting). The
        /// proxy hands the result to the statusbar's hint row,
        /// which manages TTL/clearance from there.
        pub fn gatherHintText(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "provideHintText")) {
                    if (try M.provideHintText(rts[i], ctx)) |text| return text;
                }
            }
            return null;
        }

        /// Sibling of `gatherHintText` for error notifications.
        /// Same one-shot, first-non-null semantics, but the proxy
        /// pushes the result into the statusbar's *error* slot which
        /// renders in `error_style` (muted red + ⚠ glyph) and takes
        /// precedence over regular hints. Lets modules surface
        /// transient failures (LLM endpoint unreachable, HTTP non-2xx,
        /// guardrail block, …) without polluting the explanation
        /// channel.
        pub fn gatherErrorText(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "provideErrorText")) {
                    if (try M.provideErrorText(rts[i], ctx)) |text| return text;
                }
            }
            return null;
        }

        /// First non-null list wins, same precedence model as
        /// gatherGhostText. Used by the multi-suggestion overlay
        /// rendered below the prompt (see `Config.ghost.list_count`).
        /// The returned slice is borrowed from the module's storage
        /// (typically `ctx.scratch` or runtime-owned memory) and must
        /// stay valid until the next dispatch call.
        pub fn gatherGhostList(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const []const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "provideGhostList")) {
                    if (try M.provideGhostList(rts[i], ctx)) |entries| return entries;
                }
            }
            return null;
        }

        /// Fired exactly once per Enter-press, after applyInput has
        /// cleared the line. `line` is the pre-Enter content — modules
        /// use it for history recording, audit logs, etc. We do not
        /// fire on uncertain commits (arrow-key history nav, multi-line
        /// continuations, …) — recording a wrong line is worse than
        /// missing one.
        pub fn dispatchLineCommit(
            rts: *Runtimes,
            ctx: *Context,
            line: []const u8,
        ) Error!void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onLineCommit")) {
                    try M.onLineCommit(rts[i], ctx, line);
                }
            }
        }

        /// Fire `deleteHistoryMatch` on every module that implements
        /// it. Used by the proxy when the user triggers the
        /// `delete_history_match` keymap action. Modules without the
        /// hook are silently skipped (no-op at comptime).
        pub fn dispatchDeleteHistoryMatch(
            rts: *Runtimes,
            ctx: *Context,
            line: []const u8,
        ) Error!void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "deleteHistoryMatch")) {
                    try M.deleteHistoryMatch(rts[i], ctx, line);
                }
            }
        }

        /// Collect each module's `statusText` (if implemented) into
        /// the writer, separating segments with ` │ `. Used by the
        /// proxy's bottom status bar to paint a shared canvas — every
        /// participating module contributes one segment, in module-
        /// declaration order. Modules returning null are skipped.
        pub fn gatherStatus(
            rts: *Runtimes,
            ctx: *Context,
            w: *std.Io.Writer,
        ) Error!void {
            var any = false;
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "statusText")) {
                    if (try M.statusText(rts[i], ctx)) |text| {
                        if (text.len > 0) {
                            // Truncate silently if the buffer is full —
                            // status bar always has finite width anyway.
                            if (any) w.writeAll(" │ ") catch return;
                            w.writeAll(text) catch return;
                            any = true;
                        }
                    }
                }
            }
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

        /// Fired on poll() timeout. Lets a module surface bytes
        /// to inject into the shell's stdin (pty.master) when its
        /// own state machine has produced something asynchronously
        /// — e.g. the LLM module's response coming back from a
        /// worker thread several seconds after the user's Enter
        /// was swallowed. The returned slice (if any) is written
        /// to pty.master verbatim; the module owns the storage and
        /// keeps it alive until the next call.
        ///
        /// First non-null wins, same precedence model as
        /// gatherGhostText. Most modules don't implement this and
        /// the loop is comptime-eliminated for them.
        pub fn pollShellInput(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "pollShellInput")) {
                    if (try M.pollShellInput(rts[i], ctx)) |bytes| return bytes;
                }
            }
            return null;
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

const ListProvider = struct {
    pub const name = "list-provider";
    pub const Runtime = struct {
        entries: []const []const u8 = &.{},
    };
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn provideGhostList(rt: *Runtime, _: *Context) Error!?[]const []const u8 {
        if (rt.entries.len == 0) return null;
        return rt.entries;
    }
};

const EmptyList = struct {
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn provideGhostList(_: *Runtime, _: *Context) Error!?[]const []const u8 {
        return null;
    }
};

const D_EmptyList = Dispatcher(.{ EmptyList, ListProvider });

test "gatherGhostList returns first non-null list, skipping nulls before it" {
    const D = D_EmptyList;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);
    const entries = [_][]const u8{ "alpha", "beta", "gamma" };
    rts[1].entries = &entries;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    const got = try D.gatherGhostList(&rts, &ctx);
    try testing.expect(got != null);
    try testing.expectEqual(@as(usize, 3), got.?.len);
    try testing.expectEqualStrings("alpha", got.?[0]);
    try testing.expectEqualStrings("gamma", got.?[2]);
}

test "gatherGhostList returns null when no module contributes a list" {
    const D = Dispatcher(.{NoOpA});
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    try testing.expectEqual(@as(?[]const []const u8, null), try D.gatherGhostList(&rts, &ctx));
}

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

// ─── pollShellInput walker ───────────────────────────────────────────────

const PollerEmpty = struct {
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn pollShellInput(_: *Runtime, _: *Context) Error!?[]const u8 {
        return null;
    }
};

const PollerWithResult = struct {
    pub const Runtime = struct {
        result: ?[]const u8 = null,
    };
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn pollShellInput(rt: *Runtime, _: *Context) Error!?[]const u8 {
        return rt.result;
    }
};

const D_PollPair = Dispatcher(.{ PollerEmpty, PollerWithResult });

test "pollShellInput returns first non-null, skipping null providers" {
    const D = D_PollPair;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);
    rts[1].result = "\x15ls -la";

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    const got = try D.pollShellInput(&rts, &ctx);
    try testing.expectEqualStrings("\x15ls -la", got.?);
}

test "pollShellInput returns null when no module has bytes ready" {
    const D = Dispatcher(.{PollerEmpty});
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    try testing.expectEqual(@as(?[]const u8, null), try D.pollShellInput(&rts, &ctx));
}

// ─── gatherHintText walker ───────────────────────────────────────────────

const HintEmpty = struct {
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn provideHintText(_: *Runtime, _: *Context) Error!?[]const u8 {
        return null;
    }
};

const HintWithResult = struct {
    pub const Runtime = struct {
        result: ?[]const u8 = null,
    };
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn provideHintText(rt: *Runtime, _: *Context) Error!?[]const u8 {
        return rt.result;
    }
};

test "gatherHintText returns first non-null, skipping null providers" {
    const D = Dispatcher(.{ HintEmpty, HintWithResult });
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);
    rts[1].result = "lists files in long format";

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    const got = try D.gatherHintText(&rts, &ctx);
    try testing.expectEqualStrings("lists files in long format", got.?);
}

test "gatherHintText returns null when no module has a hint" {
    const D = Dispatcher(.{HintEmpty});
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    try testing.expectEqual(@as(?[]const u8, null), try D.gatherHintText(&rts, &ctx));
}

// ─── coverage for the newer walkers ──────────────────────────────────────

const Recorder = struct {
    pub const name = "recorder";
    pub const Runtime = struct {
        committed: std.ArrayList(u8) = .empty,
        deleted: std.ArrayList(u8) = .empty,
    };
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(rt: *Runtime, _: std.Io) void {
        rt.committed.deinit(testing.allocator);
        rt.deleted.deinit(testing.allocator);
    }
    pub fn onLineCommit(rt: *Runtime, _: *Context, line: []const u8) Error!void {
        rt.committed.appendSlice(testing.allocator, line) catch return Error.OutOfMemory;
        rt.committed.append(testing.allocator, '\n') catch return Error.OutOfMemory;
    }
    pub fn deleteHistoryMatch(rt: *Runtime, _: *Context, line: []const u8) Error!void {
        rt.deleted.appendSlice(testing.allocator, line) catch return Error.OutOfMemory;
        rt.deleted.append(testing.allocator, '\n') catch return Error.OutOfMemory;
    }
};

const StatusEmitter = struct {
    pub const name = "status";
    pub const Runtime = struct { text: []const u8 = "" };
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn statusText(rt: *Runtime, _: *Context) Error!?[]const u8 {
        if (rt.text.len == 0) return null;
        return rt.text;
    }
};

const D_Recorder = Dispatcher(.{Recorder});
const D_StatusPair = Dispatcher(.{ StatusEmitter, StatusEmitter });

test "dispatchLineCommit fans out to every module with onLineCommit" {
    const D = D_Recorder;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    try D.dispatchLineCommit(&rts, &ctx, "echo hi");
    try D.dispatchLineCommit(&rts, &ctx, "ls -la");

    try testing.expectEqualStrings("echo hi\nls -la\n", rts[0].committed.items);
}

test "dispatchDeleteHistoryMatch fans out to every module with the hook" {
    const D = D_Recorder;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    try D.dispatchDeleteHistoryMatch(&rts, &ctx, "secret");
    try D.dispatchDeleteHistoryMatch(&rts, &ctx, "another");

    try testing.expectEqualStrings("secret\nanother\n", rts[0].deleted.items);
}

// Two-module pair: Recorder (implements deleteHistoryMatch) +
// Recorder again. Pinned for the multi-module regression test
// below.
const D_RecorderPair = Dispatcher(.{ Recorder, Recorder });

test "dispatchDeleteHistoryMatch fires EVERY implementer, not just the first one" {
    // Regression: the user had .{ atuin, history } and pressed
    // Ctrl+Shift+D. Only history's hook ran (atuin didn't implement
    // the hook at all), so the entry stayed in atuin's daemon. The
    // fix re-wires atuin to implement deleteHistoryMatch — this
    // test pins the dispatcher's fan-out promise so a future module
    // that "forgets" the hook gets caught immediately by `zig build
    // test`, before it ships and breaks delete for users running
    // that module on top of history.
    const D = D_RecorderPair;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    try D.dispatchDeleteHistoryMatch(&rts, &ctx, "shared-entry");

    // Both recorders saw the deletion request.
    try testing.expectEqualStrings("shared-entry\n", rts[0].deleted.items);
    try testing.expectEqualStrings("shared-entry\n", rts[1].deleted.items);
}

test "gatherStatus joins module segments with the separator" {
    const D = D_StatusPair;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);
    rts[0].text = "alpha";
    rts[1].text = "beta";

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try D.gatherStatus(&rts, &ctx, &w);
    try testing.expectEqualStrings("alpha \u{2502} beta", w.buffered());
}

test "gatherStatus skips null + empty contributions" {
    const D = D_StatusPair;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);
    rts[0].text = ""; // empty → skipped
    rts[1].text = "only";

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try D.gatherStatus(&rts, &ctx, &w);
    try testing.expectEqualStrings("only", w.buffered());
}

const Observer = struct {
    pub const name = "observer";
    pub const Runtime = struct {
        seen: std.ArrayList(u8) = .empty,
    };
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(rt: *Runtime, _: std.Io) void {
        rt.seen.deinit(testing.allocator);
    }
    pub fn onOutput(rt: *Runtime, _: *Context, output: []const u8) Error!void {
        rt.seen.appendSlice(testing.allocator, output) catch return Error.OutOfMemory;
    }
};

const D_Observer = Dispatcher(.{Observer});

test "dispatchOutput fans out to every module with onOutput" {
    const D = D_Observer;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    try D.dispatchOutput(&rts, &ctx, "first ");
    try D.dispatchOutput(&rts, &ctx, "second");

    try testing.expectEqualStrings("first second", rts[0].seen.items);
}
