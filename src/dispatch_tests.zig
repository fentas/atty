//! Tests for `dispatch.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("dispatch.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const module = @import("module.zig");
const keymap = @import("keymap.zig");

// Re-binds of pub decls so test bodies stay short.
const Action = mod.Action;
const Context = mod.Context;
const Dispatcher = mod.Dispatcher;
const Error = mod.Error;

// ===========================================================================
// Tests — stub modules defined inline so we can verify the dispatch
// contract without dragging in the real Atuin/Guardrail.
// ===========================================================================

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

const CommitReplacer = struct {
    pub const name = "commit-replacer";
    pub const Runtime = struct { buf: [16]u8 = undefined };

    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn onInput(rt: *Runtime, _: *Context, input: []const u8) Error!Action {
        const n = @min(input.len, rt.buf.len);
        for (input[0..n], 0..) |b, i| rt.buf[i] = std.ascii.toUpper(b);
        return .{ .replace_commit = rt.buf[0..n] };
    }
};

test "dispatchInput preserves .replace_commit across downstream modules" {
    // A later module returning plain `.replace` must NOT downgrade
    // an earlier `.replace_commit` — once a module asked for the
    // commit to fire, that decision sticks.
    const D = Dispatcher(.{ CommitReplacer, Replacer });
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    const action = try D.dispatchInput(&rts, &ctx, "hi");
    try testing.expect(action == .replace_commit);
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
        actions_seen: usize = 0,
        consume_next: bool = true,
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
    pub fn onAction(rt: *Runtime, _: *Context, _: anytype) Error!bool {
        rt.actions_seen += 1;
        return rt.consume_next;
    }
};

const FailingActor = struct {
    pub const name = "failing-actor";
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn onAction(_: *Runtime, _: *Context, _: anytype) Error!bool {
        return Error.ModuleFailed;
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

const FailingDeleter = struct {
    pub const name = "failing-deleter";
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn deleteHistoryMatch(_: *Runtime, _: *Context, _: []const u8) Error!void {
        return Error.ModuleFailed;
    }
};

test "dispatchDeleteHistoryMatch isolates per-module errors (later modules still fire)" {
    // Regression scenario: user has `.{ atuin, history }`. They
    // see a ghost from history, press Ctrl+Shift+D. atuin's
    // delete hook errors (CLI not found, daemon down, DB locked,
    // …). Pre-fix, `try` propagated the error out of the inline
    // fan-out and history's hook never ran, so the entry stayed
    // in ~/.bash_history and the ghost reappeared on the next
    // typed keystroke. Post-fix, each module's failure is caught
    // per-iteration; later modules still get a chance to delete
    // from their own store.
    const D = Dispatcher(.{ FailingDeleter, Recorder });
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    // The walker must not propagate FailingDeleter's error.
    try D.dispatchDeleteHistoryMatch(&rts, &ctx, "secret-cmd");

    // Recorder (second module) still got the request — that's
    // the whole point of the fix.
    try testing.expectEqualStrings("secret-cmd\n", rts[1].deleted.items);
}

test "dispatchAction fans out to every onAction-implementing module" {
    // Two recorders both implement onAction. The walker must
    // call both so a module further down the chain can observe
    // (and possibly act on) an action even if an earlier module
    // already consumed it. Matches the fan-out semantics of
    // dispatchDeleteHistoryMatch.
    const D = D_RecorderPair;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    _ = D.dispatchAction(&rts, &ctx, .ghost_accept);

    try testing.expectEqual(@as(usize, 1), rts[0].actions_seen);
    try testing.expectEqual(@as(usize, 1), rts[1].actions_seen);
}

test "dispatchAction returns true when ANY module consumes the action" {
    // First module consumes, second doesn't. The walker must
    // still return true overall — the consumed-OR semantic is
    // what the proxy uses to decide whether to swallow the
    // binding bytes.
    const D = D_RecorderPair;
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);
    rts[0].consume_next = true;
    rts[1].consume_next = false;

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    try testing.expect(D.dispatchAction(&rts, &ctx, .ghost_accept));

    // And the reverse: no module consumes → false (proxy lets
    // the bytes flow through to readline / inner programs).
    rts[0].consume_next = false;
    rts[1].consume_next = false;
    try testing.expect(!D.dispatchAction(&rts, &ctx, .ghost_accept));
}

test "dispatchAction isolates per-module errors (later modules still fire)" {
    // First module errors out of onAction. The walker must
    // swallow the error AND still call the second module's
    // hook — the proxy needs all modules to get a chance to
    // observe the action, and a single module's failure must
    // not block the rest. Matches the same isolation guarantee
    // as dispatchDeleteHistoryMatch.
    const D = Dispatcher(.{ FailingActor, Recorder });
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeContext(&line, &scratch);

    // FailingActor's onAction returns ModuleFailed. The walker
    // must NOT propagate it; Recorder (second) still gets the
    // action.
    _ = D.dispatchAction(&rts, &ctx, .ghost_accept);

    try testing.expectEqual(@as(usize, 1), rts[1].actions_seen);
}

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

const ReserveRowsClaimer = struct {
    pub const name = "reserve-claimer";
    pub const Runtime = struct {
        rows_wanted: u16 = 0,
        resize_count: usize = 0,
    };

    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub fn extraReserveRows(rt: *Runtime) u16 {
        return rt.rows_wanted;
    }
    pub fn onResize(rt: *Runtime) void {
        rt.resize_count += 1;
    }
};

const NoReserveModule = struct {
    pub const name = "no-reserve";
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    // Deliberately no extraReserveRows / onResize — exercises the
    // comptime @hasDecl gate.
};

test "extraReserveRows: sums declaring modules, skips non-declaring ones, saturates" {
    const D = Dispatcher(&.{ ReserveRowsClaimer, NoReserveModule });
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    try testing.expectEqual(@as(u16, 0), D.extraReserveRows(&rts));

    rts[0].rows_wanted = 7;
    try testing.expectEqual(@as(u16, 7), D.extraReserveRows(&rts));

    // Saturating-add: u16.max + 1 would wrap but must clamp instead.
    rts[0].rows_wanted = std.math.maxInt(u16);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), D.extraReserveRows(&rts));
}

test "notifyResize: fires onResize on declaring modules only" {
    const D = Dispatcher(&.{ ReserveRowsClaimer, NoReserveModule });
    var rts = try D.attachAll(testing.allocator, test_io);
    defer D.detachAll(testing.allocator, test_io, &rts);

    D.notifyResize(&rts);
    D.notifyResize(&rts);
    try testing.expectEqual(@as(usize, 2), rts[0].resize_count);
}

const ModuleWithBindings = struct {
    pub const name = "with-bindings";
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
    pub const default_bindings: []const keymap.Binding = &.{
        .{ .bytes = "\x01", .action = .ghost_accept, .label = "Test+A", .description = "test alpha" },
        .{ .bytes = "\x02", .action = .incognito_toggle, .label = "Test+B", .description = "test beta" },
    };
};

const ModuleWithoutBindings = struct {
    pub const name = "no-bindings";
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
        return .{};
    }
    pub fn detach(_: *Runtime, _: std.Io) void {}
};

test "allDefaultBindings: comptime-concatenates declaring modules' bindings, skips non-declaring" {
    const D = Dispatcher(&.{ ModuleWithBindings, ModuleWithoutBindings });
    const all = D.all_default_bindings;
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(keymap.Action.ghost_accept, all[0].action);
    try testing.expectEqual(keymap.Action.incognito_toggle, all[1].action);
    try testing.expectEqualStrings("Test+A", all[0].label);
    try testing.expectEqualStrings("test alpha", all[0].description);
}

test "allDefaultBindings: empty when no module declares default_bindings" {
    const D = Dispatcher(&.{ ModuleWithoutBindings, NoReserveModule });
    try testing.expectEqual(@as(usize, 0), D.all_default_bindings.len);
}

// Regression: real modules wrap their definition in `pub fn configure(cfg) type`
// — the LLM module returns an inner struct from `configure(.{...})`, and THAT
// inner struct is what lands in `config.modules`. `default_bindings` must live
// INSIDE the returned struct, not at the wrapping file's top level, or the
// dispatcher's `@hasDecl(M, "default_bindings")` gate silently misses it.
fn FactoryModule(comptime tag: u8) type {
    return struct {
        pub const name = "factory";
        pub const Runtime = struct {};
        pub fn attach(_: std.mem.Allocator, _: std.Io) !Runtime {
            return .{};
        }
        pub fn detach(_: *Runtime, _: std.Io) void {}
        pub const default_bindings: []const keymap.Binding = &.{
            .{ .bytes = &[_]u8{tag}, .action = .ghost_accept, .label = "Factory", .description = "from factory" },
        };
    };
}

test "allDefaultBindings: picks up bindings from configure()-style factory modules" {
    // Exercise the actual code shape user configs use:
    //   pub const modules = .{ atty.modules.llm.configure(.{ ... }) };
    // where `configure` returns a parameterised type that carries
    // `default_bindings`. If the walker only inspected the top-level
    // file (not the returned type), Alt+C/Alt+S/etc. would silently
    // miss for every user — exactly the regression that shipped with
    // PR #70 before this fix.
    const FA = FactoryModule('A');
    const FB = FactoryModule('B');
    const D = Dispatcher(&.{ FA, FB });
    const all = D.all_default_bindings;
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualSlices(u8, "A", all[0].bytes);
    try testing.expectEqualSlices(u8, "B", all[1].bytes);
}
